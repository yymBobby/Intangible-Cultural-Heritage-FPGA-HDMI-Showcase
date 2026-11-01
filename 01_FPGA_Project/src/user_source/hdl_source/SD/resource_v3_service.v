`timescale 1ns/1ps
// ICHSHOW3 v0.1 candidate file-byte service; old service is unchanged.
// Directory CRC/overlap and SD initialization are upstream responsibilities.
// This module never parses a FAT filesystem or accepts a partially loaded table.
// All public ports and the sector backend are synchronous to clk_sys.
module resource_v3_service #(
    parameter [31:0] SECTOR_TIMEOUT = 32'd1000000,
    parameter [31:0] RECOVERY_DRAIN_TIMEOUT = 32'd100000000
) (
    input wire clk_sys,
    input wire rst_sys_n,
    // Fixed 24-entry publication; four narrow RAM writes per accepted entry.
    // Hold valid/payload until ready. Commit may follow the last acceptance
    // immediately; service_ready waits until its pending writes finish.
    input wire catalog_valid,
    output wire catalog_ready,
    input wire [7:0] catalog_resource_id,
    input wire [31:0] catalog_start_lba, catalog_bytes,
    input wire [31:0] catalog_total_sectors,
    input wire catalog_commit,
    input wire [7:0] catalog_error,
    output reg service_ready,
    output reg [7:0] service_error,
    output reg recovery_req,
    // A: BMP and ICHTXT02 share this display-resource client.
    input wire img_req_valid,
    output wire img_req_ready,
    input wire [7:0] img_req_resource_id,
    input wire [31:0] img_req_block_index,
    output wire img_data_valid,
    input wire img_data_ready,
    output wire [7:0] img_data,
    output wire img_data_last,
    output wire img_file_last,
    output wire img_rsp_valid,
    input wire img_rsp_ready,
    output wire [2:0] img_rsp_status,
    // B: WAV client.
    input wire aud_req_valid,
    output wire aud_req_ready,
    input wire [7:0] aud_req_resource_id,
    input wire [31:0] aud_req_block_index,
    output wire aud_data_valid,
    input wire aud_data_ready,
    output wire [7:0] aud_data,
    output wire aud_data_last,
    output wire aud_file_last,
    output wire aud_rsp_valid,
    input wire aud_rsp_ready,
    output wire [2:0] aud_rsp_status,
    input wire audio_urgent,
    // One non-stallable 512-byte physical-sector reader. sec_done may coincide
    // with its final sec_data_valid. No next request until this one completes.
    output wire sec_req_valid,
    input wire sec_req_ready,
    output wire [31:0] sec_req_lba,
    input wire sec_data_valid,
    input wire [7:0] sec_data,
    input wire sec_done,
    input wire sec_error
);
    localparam [2:0] C_IDLE = 3'd0, C_WAIT = 3'd1,
                     C_SEND = 3'd2, C_RSP = 3'd3, C_PRIME = 3'd4,
                     C_LOOKUP = 3'd5;
    localparam [1:0] P_IDLE = 2'd0, P_ISSUE = 2'd1, P_READ = 2'd2;
    localparam [31:0] TIMEOUT_CYCLES = SECTOR_TIMEOUT == 0 ? 32'd1 : SECTOR_TIMEOUT;
    localparam [31:0] DRAIN_CYCLES = RECOVERY_DRAIN_TIMEOUT == 0 ?
                                     32'd1 : RECOVERY_DRAIN_TIMEOUT;

    reg [31:0] total_sectors;
    // Only validity resets: the BRAM contents are overwritten at catalog load.
    // Unpublished resource slots remain inaccessible after any reset.
    reg [23:0] metadata_valid;
    reg meta_busy, commit_pending;
    reg [1:0] meta_write_word, lookup_word;
    reg [4:0] meta_pending_slot;
    reg [31:0] meta_pending_start, meta_pending_length;
    reg [7:0] img_id_pending, aud_id_pending;
    reg [31:0] img_block_pending, aud_block_pending;

    localparam [2:0] Q_IDLE=0, Q_ADDR=1, Q_READ=2, Q_DATA=3, Q_CALC=4, Q_CHECK=5;
    reg [2:0] lookup_state;
    reg lookup_sel;
    reg [4:0] lookup_slot;
    reg lookup_id_valid, lookup_present;
    reg [31:0] lookup_block, lookup_start, lookup_length;
    reg [32:0] lookup_blocks, lookup_phys_lba, lookup_remaining;
    wire [7:0] selected_id = lookup_sel ? aud_id_pending : img_id_pending;
    wire pub_image = catalog_resource_id < 8'd16;
    wire pub_audio = catalog_resource_id >= 8'h40 && catalog_resource_id <= 8'h43;
    wire pub_text = catalog_resource_id >= 8'h80 && catalog_resource_id <= 8'h83;
    wire pub_id_ok = pub_image || pub_audio || pub_text;
    wire [4:0] pub_slot = pub_image ? {1'b0,catalog_resource_id[3:0]} :
                         pub_audio ? 5'd16 + {3'b0,catalog_resource_id[1:0]} :
                                     5'd20 + {3'b0,catalog_resource_id[1:0]};
    wire [32:0] pub_end = {1'b0,catalog_start_lba} +
                         (({1'b0,catalog_bytes}+33'd511)>>9);
    wire pub_range_ok = catalog_start_lba>=32'd2048 && catalog_bytes!=0 &&
                        catalog_total_sectors>32'd2048 &&
                        pub_end<={1'b0,catalog_total_sectors};
    assign catalog_ready = rst_sys_n && !service_ready && service_error==0 && catalog_error==0 &&
                           !meta_busy && !commit_pending;
    wire pub_accept = catalog_valid && catalog_ready;
    wire pub_good = pub_accept && pub_id_ok && pub_range_ok && !metadata_valid[pub_slot] &&
                   (metadata_valid==0 || total_sectors==catalog_total_sectors);
    wire meta_read = rst_sys_n && service_ready && lookup_state==Q_READ;
    wire meta_we = rst_sys_n && service_error==0 && catalog_error==0 &&
                   ((pub_good && !catalog_commit) || meta_busy);
    wire [6:0] meta_address = pub_good ? {pub_slot,2'b00} :
                             meta_busy ? {meta_pending_slot,meta_write_word} : {lookup_slot,lookup_word};
    wire [17:0] meta_write_data = pub_good ? catalog_start_lba[17:0] :
                          meta_write_word==1 ? {4'd0,meta_pending_start[31:18]} :
                          meta_write_word==2 ? meta_pending_length[17:0] : {4'd0,meta_pending_length[31:18]};
    wire [17:0] meta_data;
    wire [23:0] complete_or_pending = metadata_valid |
                             (meta_busy ? (24'd1 << meta_pending_slot) : 24'd0);
    // Four 18-bit words per resource; one narrow SP bank instead of a wide DP
    // macro. Validity becomes visible only after the final word is written.
    resource_v3_metadata_ram u_metadata (
        .clk(clk_sys), .we(meta_we), .ce(meta_we || meta_read),
        .addr(meta_address), .data_in(meta_write_data), .data_out(meta_data)
    );

    reg [2:0] img_state, aud_state;
    reg [1:0] phy_state;
    reg [31:0] img_lba, aud_lba;
    reg [9:0] img_count, aud_count;
    reg [9:0] img_index, aud_index;
    reg img_eof, aud_eof;
    reg [2:0] img_status, aud_status;
    reg phy_sel;                 // 0=image, 1=audio
    reg round_robin_aud;        // preference when both are pending
    reg [9:0] physical_count;
    reg physical_overflow;
    reg [31:0] physical_timer;
    reg recovery_pending;
    reg [31:0] recovery_timer;

    // One 8x1024 true dual-port bank with permanently disjoint ownership:
    // A=image addresses 0..511, B=audio addresses 512..1023. Each port can
    // independently read or write, so a stalled image never blocks audio fill
    // and both buffered clients can still emit one byte on the same clock.
    wire img_ram_write = rst_sys_n && phy_state == P_READ && !phy_sel &&
                         sec_data_valid && physical_count < 10'd512;
    wire aud_ram_write = rst_sys_n && phy_state == P_READ && phy_sel &&
                         sec_data_valid && physical_count < 10'd512;
    wire img_ram_read = rst_sys_n && (img_state == C_PRIME ||
                         (img_data_valid && img_data_ready && !img_data_last));
    wire aud_ram_read = rst_sys_n && (aud_state == C_PRIME ||
                         (aud_data_valid && aud_data_ready && !aud_data_last));
    wire [8:0] img_next_addr = img_index[8:0] + 9'd1;
    wire [8:0] aud_next_addr = aud_index[8:0] + 9'd1;
    wire [8:0] img_ram_addr = img_ram_write ? physical_count[8:0] :
                              (img_state == C_PRIME ? 9'd0 : img_next_addr);
    wire [8:0] aud_ram_addr = aud_ram_write ? physical_count[8:0] :
                              (aud_state == C_PRIME ? 9'd0 : aud_next_addr);
    wire [7:0] img_ram_data, aud_ram_data;

    resource_v3_sector_ram u_sector_cache (
        .clk(clk_sys),.img_ce(img_ram_write || img_ram_read),.img_we(img_ram_write),
        .img_addr(img_ram_addr),.img_out(img_ram_data),
        .aud_ce(aud_ram_write || aud_ram_read),.aud_we(aud_ram_write),
        .aud_addr(aud_ram_addr),.aud_out(aud_ram_data),.data_in(sec_data)
    );

    assign img_req_ready = service_ready && img_state == C_IDLE;
    assign aud_req_ready = service_ready && aud_state == C_IDLE;
    assign img_data_valid = img_state == C_SEND;
    assign aud_data_valid = aud_state == C_SEND;
    assign img_data = img_data_valid ? img_ram_data : 8'd0;
    assign aud_data = aud_data_valid ? aud_ram_data : 8'd0;
    assign img_data_last = img_data_valid && (img_index + 10'd1 == img_count);
    assign aud_data_last = aud_data_valid && (aud_index + 10'd1 == aud_count);
    assign img_file_last = img_data_last && img_eof;
    assign aud_file_last = aud_data_last && aud_eof;
    assign img_rsp_valid = img_state == C_RSP;
    assign aud_rsp_valid = aud_state == C_RSP;
    assign img_rsp_status = img_status;
    assign aud_rsp_status = aud_status;
    assign sec_req_valid = phy_state == P_ISSUE;
    assign sec_req_lba = phy_sel ? aud_lba : img_lba;

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            service_ready <= 1'b0;
            service_error <= 8'd0;
            recovery_req <= 1'b0;
            total_sectors <= 32'd0;
            img_state <= C_IDLE;
            aud_state <= C_IDLE;
            phy_state <= P_IDLE;
            img_lba <= 32'd0;
            aud_lba <= 32'd0;
            img_count <= 10'd0;
            aud_count <= 10'd0;
            img_index <= 10'd0;
            aud_index <= 10'd0;
            img_eof <= 1'b0;
            aud_eof <= 1'b0;
            img_status <= 3'd0;
            aud_status <= 3'd0;
            phy_sel <= 1'b0;
            round_robin_aud <= 1'b0;
            physical_count <= 10'd0;
            physical_overflow <= 1'b0;
            physical_timer <= 32'd0;
            recovery_pending <= 1'b0;
            recovery_timer <= 32'd0;
            metadata_valid <= 24'd0;
            meta_busy <= 0; commit_pending <= 0; meta_write_word <= 0; lookup_word <= 0;
            meta_pending_slot <= 0; meta_pending_start <= 0; meta_pending_length <= 0;
            img_id_pending <= 0; aud_id_pending <= 0;
            img_block_pending <= 0; aud_block_pending <= 0;
            lookup_state <= Q_IDLE; lookup_sel <= 0;
            lookup_slot <= 0;
            lookup_id_valid <= 0; lookup_present <= 0;
            lookup_block <= 0; lookup_start <= 0; lookup_length <= 0;
            lookup_blocks <= 0; lookup_phys_lba <= 0; lookup_remaining <= 0;
        end else begin
            // After a public fault, allow accepted clients to drain normally.
            // A stuck data/response consumer cannot postpone coordinated reset
            // forever. This request is sticky until rst_sys_n resets the service.
            if (recovery_pending && !recovery_req) begin
                if ((img_state == C_IDLE && aud_state == C_IDLE && phy_state == P_IDLE) ||
                    recovery_timer >= DRAIN_CYCLES - 32'd1)
                    recovery_req <= 1'b1;
                else
                    recovery_timer <= recovery_timer + 32'd1;
            end
            if (!service_ready && service_error == 0) begin
                if (catalog_error != 0) begin
                    service_error <= catalog_error;
                    meta_busy <= 0; commit_pending <= 0;
                    // No client is accepted before catalog_commit. A boot
                    // failure therefore has nothing to drain, but still
                    // requires a coordinated reset of SD and this service.
                    recovery_pending <= 1'b1;
                end else if (commit_pending && catalog_valid) begin
                    service_error <= 8'd2; recovery_pending <= 1'b1;
                    meta_busy <= 0; commit_pending <= 0;
                end else if (pub_accept) begin
                    if (!pub_good || catalog_commit) begin
                        service_error <= 8'd2;
                        recovery_pending <= 1'b1;
                    end else begin
                        meta_pending_slot <= pub_slot;
                        meta_pending_start <= catalog_start_lba;
                        meta_pending_length <= catalog_bytes;
                        meta_busy <= 1'b1;
                        meta_write_word <= 2'd1;
                        total_sectors <= catalog_total_sectors;
                    end
                end else if (catalog_commit) begin
                    if (complete_or_pending == 24'hffffff && !catalog_valid)
                        commit_pending <= 1'b1;
                    else begin
                        service_error <= 8'd2;
                        meta_busy <= 0;
                        recovery_pending <= 1'b1;
                    end
                end
                if (catalog_error==0 && meta_busy) begin
                    if (meta_write_word==3) begin
                        metadata_valid[meta_pending_slot] <= 1'b1;
                        meta_busy <= 0;
                    end else meta_write_word <= meta_write_word + 2'd1;
                end
                if (catalog_error==0 && !catalog_valid && commit_pending && !meta_busy && metadata_valid==24'hffffff)
                    begin service_ready <= 1'b1; commit_pending <= 0; end
            end

            // Requests are immutable after handshake. A/B may both enqueue
            // on the same edge; the shared lookup engine services them in turn.
            if (img_req_valid && img_req_ready) begin
                img_id_pending <= img_req_resource_id;
                img_block_pending <= img_req_block_index;
                img_index <= 0;
                img_state <= C_LOOKUP;
            end
            if (aud_req_valid && aud_req_ready) begin
                aud_id_pending <= aud_req_resource_id;
                aud_block_pending <= aud_req_block_index;
                aud_index <= 0;
                aud_state <= C_LOOKUP;
            end

            case (lookup_state)
                Q_IDLE: if (service_ready && (img_state==C_LOOKUP || aud_state==C_LOOKUP)) begin
                    if (img_state==C_LOOKUP && aud_state==C_LOOKUP)
                        lookup_sel <= audio_urgent || round_robin_aud;
                    else lookup_sel <= aud_state==C_LOOKUP;
                    // Selection registers settle before address/decode stage.
                    lookup_state <= Q_ADDR;
                end
                Q_ADDR: begin
                    // This stage decodes the latched request; RAM read occurs
                    // in Q_READ, with a full clock for address setup.
                    lookup_block <= lookup_sel ? aud_block_pending : img_block_pending;
                    lookup_word <= 0;
                    lookup_id_valid <= 0;
                    lookup_slot <= 0;
                    if (!lookup_sel && selected_id<8'd16) begin
                        lookup_id_valid <= 1;
                        lookup_slot <= {1'b0,selected_id[3:0]};
                    end else if (lookup_sel && selected_id>=8'h40 && selected_id<=8'h43) begin
                        lookup_id_valid <= 1;
                        lookup_slot <= 5'd16+{3'b0,selected_id[1:0]};
                    end else if (!lookup_sel && selected_id>=8'h80 && selected_id<=8'h83) begin
                        lookup_id_valid <= 1;
                        lookup_slot <= 5'd20+{3'b0,selected_id[1:0]};
                    end
                    lookup_state <= Q_READ;
                end
                Q_READ: lookup_state <= Q_DATA;
                Q_DATA: begin
                    // Capture synchronous RAM outputs, no address arithmetic.
                    case (lookup_word)
                        0: lookup_start[17:0] <= meta_data;
                        1: lookup_start[31:18] <= meta_data[13:0];
                        2: lookup_length[17:0] <= meta_data;
                        3: lookup_length[31:18] <= meta_data[13:0];
                    endcase
                    if (lookup_word==3) begin
                        lookup_present <= metadata_valid[lookup_slot];
                        lookup_id_valid <= lookup_id_valid && metadata_valid[lookup_slot];
                        lookup_state <= Q_CALC;
                    end else begin lookup_word <= lookup_word + 2'd1; lookup_state <= Q_READ; end
                end
                Q_CALC: begin
                    // Independent wide operations end in registers. Keep the
                    // carry bit so a 32-bit LBA addition cannot silently wrap.
                    lookup_blocks <= ({1'b0,lookup_length}+33'd511)>>9;
                    lookup_phys_lba <= {1'b0,lookup_start}+{1'b0,lookup_block};
                    lookup_remaining <= {1'b0,lookup_length}-{lookup_block[23:0],9'b0};
                    lookup_state <= Q_CHECK;
                end
                Q_CHECK: begin
                    // A simultaneous physical fault takes precedence below.
                    // Once service_ready falls, stale lookup results cannot
                    // resurrect a cancelled client or issue another SD read.
                    if (service_ready && (lookup_sel ? aud_state==C_LOOKUP : img_state==C_LOOKUP)) begin
                        if (!lookup_id_valid || !lookup_present || lookup_length==0 || lookup_start<2048) begin
                            if (lookup_sel) begin aud_status<=3'd1; aud_state<=C_RSP; end
                            else begin img_status<=3'd1; img_state<=C_RSP; end
                        end else if ({1'b0,lookup_block}>=lookup_blocks || lookup_phys_lba[32] ||
                                     lookup_phys_lba>={1'b0,total_sectors}) begin
                            if (lookup_sel) begin aud_status<=3'd2; aud_state<=C_RSP; end
                            else begin img_status<=3'd2; img_state<=C_RSP; end
                        end else if (lookup_sel) begin
                            aud_lba<=lookup_phys_lba[31:0];
                            aud_count<=lookup_remaining>=512 ? 10'd512 : lookup_remaining[9:0];
                            aud_eof<=lookup_remaining<=512;
                            aud_state<=C_WAIT;
                        end else begin
                            img_lba<=lookup_phys_lba[31:0];
                            img_count<=lookup_remaining>=512 ? 10'd512 : lookup_remaining[9:0];
                            img_eof<=lookup_remaining<=512;
                            img_state<=C_WAIT;
                        end
                    end
                    lookup_state <= Q_IDLE;
                end
                default: lookup_state <= Q_IDLE;
            endcase

            // PRIME reads address zero after the final sector write. While
            // SEND is stalled, CEA stays low and DOA holds the current byte.
            // Each accepted non-final byte reads its successor on that same
            // edge, preserving one byte per clock without an extra output reg.
            if (img_state == C_PRIME)
                img_state <= C_SEND;
            if (aud_state == C_PRIME)
                aud_state <= C_SEND;
            if (img_data_valid && img_data_ready) begin
                if (img_data_last) begin
                    img_status <= 3'd0;
                    img_state <= C_RSP;
                end else begin
                    img_index <= img_index + 10'd1;
                end
            end
            if (aud_data_valid && aud_data_ready) begin
                if (aud_data_last) begin
                    aud_status <= 3'd0;
                    aud_state <= C_RSP;
                end else begin
                    aud_index <= aud_index + 10'd1;
                end
            end
            if (img_rsp_valid && img_rsp_ready)
                img_state <= C_IDLE;
            if (aud_rsp_valid && aud_rsp_ready)
                aud_state <= C_IDLE;

            case (phy_state)
                P_IDLE: begin
                    if (service_ready && (img_state == C_WAIT || aud_state == C_WAIT) &&
                        !(audio_urgent && aud_state==C_LOOKUP && img_state==C_WAIT)) begin
                        if (img_state == C_WAIT && aud_state == C_WAIT)
                            phy_sel <= audio_urgent || round_robin_aud;
                        else
                            phy_sel <= aud_state == C_WAIT;
                        phy_state <= P_ISSUE;
                        physical_timer <= 32'd0;
                    end
                end
                P_ISSUE: begin
                    // The deadline covers both request acceptance and reading.
                    // On its last cycle an acceptance cannot also finish a
                    // sector, so it is already too late to meet the deadline.
                    if (physical_timer >= TIMEOUT_CYCLES - 32'd1) begin
                        phy_state <= P_IDLE;
                        if (phy_sel) begin
                            aud_status <= 3'd4;
                            aud_state <= C_RSP;
                            if (img_state == C_WAIT || img_state == C_LOOKUP || (img_req_valid && img_req_ready)) begin
                                img_status <= 3'd5;
                                img_state <= C_RSP;
                            end
                        end else begin
                            img_status <= 3'd4;
                            img_state <= C_RSP;
                            if (aud_state == C_WAIT || aud_state == C_LOOKUP || (aud_req_valid && aud_req_ready)) begin
                                aud_status <= 3'd5;
                                aud_state <= C_RSP;
                            end
                        end
                        service_error <= 8'd5;
                        service_ready <= 1'b0;
                        recovery_pending <= 1'b1;
                    end else if (sec_req_valid && sec_req_ready) begin
                        phy_state <= P_READ;
                        physical_count <= 10'd0;
                        physical_overflow <= 1'b0;
                        physical_timer <= physical_timer + 32'd1;
                        round_robin_aud <= ~phy_sel;
                    end else begin
                        physical_timer <= physical_timer + 32'd1;
                    end
                end
                P_READ: begin
                    if (sec_data_valid) begin
                        if (physical_count < 10'd512) begin
                            physical_count <= physical_count + 10'd1;
                        end else begin
                            physical_overflow <= 1'b1;
                        end
                    end
                    if (sec_done) begin
                        phy_state <= P_IDLE;
                        if (sec_error || physical_overflow ||
                            (physical_count + {9'd0, sec_data_valid} != 10'd512)) begin
                            if (phy_sel) begin
                                aud_status <= 3'd3;
                                aud_state <= C_RSP;
                                if (img_state == C_WAIT || img_state == C_LOOKUP || (img_req_valid && img_req_ready)) begin
                                    img_status <= 3'd5;
                                    img_state <= C_RSP;
                                end
                            end else begin
                                img_status <= 3'd3;
                                img_state <= C_RSP;
                                if (aud_state == C_WAIT || aud_state == C_LOOKUP || (aud_req_valid && aud_req_ready)) begin
                                    aud_status <= 3'd5;
                                    aud_state <= C_RSP;
                                end
                            end
                            service_error <= 8'd5;
                            service_ready <= 1'b0;
                            recovery_pending <= 1'b1;
                        end else if (phy_sel) begin
                            aud_index <= 10'd0;
                            aud_state <= C_PRIME;
                        end else begin
                            img_index <= 10'd0;
                            img_state <= C_PRIME;
                        end
                    end else if (physical_timer >= TIMEOUT_CYCLES - 32'd1) begin
                        phy_state <= P_IDLE;
                        if (phy_sel) begin
                            aud_status <= 3'd4;
                            aud_state <= C_RSP;
                            if (img_state == C_WAIT || img_state == C_LOOKUP || (img_req_valid && img_req_ready)) begin
                                img_status <= 3'd5;
                                img_state <= C_RSP;
                            end
                        end else begin
                            img_status <= 3'd4;
                            img_state <= C_RSP;
                            if (aud_state == C_WAIT || aud_state == C_LOOKUP || (aud_req_valid && aud_req_ready)) begin
                                aud_status <= 3'd5;
                                aud_state <= C_RSP;
                            end
                        end
                        service_error <= 8'd5;
                        service_ready <= 1'b0;
                        recovery_pending <= 1'b1;
                    end else begin
                        physical_timer <= physical_timer + 32'd1;
                    end
                end
                default: phy_state <= P_IDLE;
            endcase
        end
    end
endmodule

// Each client exclusively owns one physical port AND one address half.
// No cross-port same-address collision occurs, regardless of backpressure.
module resource_v3_sector_ram (
    input wire clk, img_ce, img_we, aud_ce, aud_we,
    input wire [8:0] img_addr, aud_addr,
    input wire [7:0] data_in,
    output wire [7:0] img_out, aud_out
);
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(8),.ADDR_WIDTH_A(10),.DATA_DEPTH_A(1024),
        .DATA_WIDTH_B(8),.ADDR_WIDTH_B(10),.DATA_DEPTH_B(1024),
        .MODE("DP"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.RESETMODE("SYNC"),
        .IMPLEMENT("9K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE("NONE"),.FILL_ALL("NONE")
    ) inst (.clka(clk),.clkb(clk),.cea(img_ce),.ceb(aud_ce),
        .addra({1'b0,img_addr}),.addrb({1'b1,aud_addr}),
        .dia(data_in),.dib(data_in),.doa(img_out),.dob(aud_out),.wea(img_we),.web(aud_we),
        .bea(1'b0),.beb(1'b0),.ocea(1'b0),.oceb(1'b0),.rsta(1'b0),.rstb(1'b0));
endmodule

// Explicit Anlogic BRAM: 18x128 single port, synchronous read, NOREG,
// no initialization. Publication finishes before any runtime lookup.
// Kept in this registered source file so existing TD/simulation source lists
// continue to resolve it without regenerating unrelated catalog IPs.
module resource_v3_metadata_ram (
    input wire clk, we, ce,
    input wire [6:0] addr,
    input wire [17:0] data_in,
    output wire [17:0] data_out
);
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(18), .ADDR_WIDTH_A(7), .DATA_DEPTH_A(128),
        .DATA_WIDTH_B(18), .ADDR_WIDTH_B(7), .DATA_DEPTH_B(128),
        .MODE("SP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K"), .DEBUGGABLE("NO"),
        .PACKABLE("NO"), .INIT_FILE("NONE"), .FILL_ALL("NONE")
    ) inst (
        .clka(clk), .clkb(1'b0), .cea(ce), .ceb(1'b0),
        .addra(addr), .addrb(7'd0),
        .dia(data_in), .dib(18'd0), .doa(data_out), .dob(),
        .wea(we), .web(1'b0), .bea(1'b0), .beb(1'b0),
        .ocea(1'b0), .oceb(1'b0), .rsta(1'b0), .rstb(1'b0)
    );
endmodule
