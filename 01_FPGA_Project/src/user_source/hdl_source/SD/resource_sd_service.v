`timescale 1ns/1ps
// ICHSHOW2 file-byte service. Directory validation and SD initialization are
// upstream responsibilities; this module never parses a FAT filesystem.
// All public ports and the sector backend are synchronous to clk_sys.
module resource_sd_service #(
    parameter [31:0] SECTOR_TIMEOUT = 32'd1000000,
    parameter [31:0] RECOVERY_DRAIN_TIMEOUT = 32'd100000000
) (
    input wire clk_sys,
    input wire rst_sys_n,
    // Load each already-validated directory entry before catalog_commit.
    input wire catalog_we,
    // Hold catalog_we and all descriptor fields until this completion handshake.
    output wire catalog_ready,
    input wire [3:0] catalog_theme_id,
    input wire [7:0] catalog_flags,
    input wire [31:0] catalog_image_lba,
    input wire [31:0] catalog_image_bytes,
    input wire [31:0] catalog_audio_lba,
    input wire [31:0] catalog_audio_bytes,
    input wire [31:0] catalog_text_lba,
    input wire [31:0] catalog_text_bytes,
    input wire catalog_commit,
    input wire [4:0] catalog_theme_count,
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

    reg [4:0] theme_count;
    // Only validity resets: the BRAM contents are overwritten at catalog load.
    // An unpublished theme must behave as the old zero-initialized table did.
    reg [15:0] metadata_valid;
    reg [7:0] img_id_pending, aud_id_pending;
    reg [31:0] img_block_pending, aud_block_pending;

    localparam [2:0] Q_IDLE=0, Q_ADDR=1, Q_READ=2, Q_DATA=3, Q_CALC=4, Q_CHECK=5;
    reg [2:0] lookup_state;
    reg lookup_sel;
    reg [1:0] lookup_kind; // 0=BMP, 1=WAV, 2=text
    reg [3:0] lookup_theme;
    reg lookup_id_valid, lookup_present;
    reg [31:0] lookup_block, lookup_start, lookup_length;
    reg [32:0] lookup_blocks, lookup_phys_lba, lookup_remaining;
    wire [7:0] selected_id = lookup_sel ? aud_id_pending : img_id_pending;
    wire meta_we = rst_sys_n && !service_ready && service_error==0 &&
                   catalog_error==0 && catalog_we;
    wire meta_read = rst_sys_n && service_ready && lookup_state==Q_READ;
    reg [1:0] meta_write_kind, meta_write_word, lookup_word;
    wire [3:0] meta_theme = meta_we ? catalog_theme_id : lookup_theme;
    wire [1:0] meta_kind = meta_we ? meta_write_kind : lookup_kind;
    // 48 records * 4 words = 192 of 256 addresses. Shift/add uses no DSP.
    wire [5:0] meta_record = {2'b0,meta_theme} + {1'b0,meta_theme,1'b0} +
                             {4'b0,meta_kind};
    wire [7:0] meta_addr = {meta_record, (meta_we ? meta_write_word : lookup_word)};
    wire [64:0] meta_input = meta_write_kind==0 ?
        {catalog_flags[0],catalog_image_lba,catalog_image_bytes} :
        meta_write_kind==1 ? {catalog_flags[1],catalog_audio_lba,catalog_audio_bytes} :
                            {catalog_flags[2],catalog_text_lba,catalog_text_bytes};
    reg [17:0] meta_data_in;
    always @* begin
        case (meta_write_word)
            0: meta_data_in = meta_input[17:0];
            1: meta_data_in = meta_input[35:18];
            2: meta_data_in = meta_input[53:36];
            default: meta_data_in = {7'd0,meta_input[64:54]};
        endcase
    end
    wire [17:0] meta_data_out;
    // Ready is asserted on the twelfth physical write. No wide staging FIFO:
    // the upstream producer holds its existing descriptor registers throughout.
    assign catalog_ready = meta_we && meta_write_kind==2 && meta_write_word==3;
    resource_metadata_ram u_metadata (
        .clk(clk_sys), .we(meta_we), .ce(meta_we || meta_read),
        .addr(meta_addr), .data_in(meta_data_in), .data_out(meta_data_out)
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

    // Each client owns a synchronous single-port 512x8 BRAM. A client cannot
    // accept another request until its response is consumed, so filling and
    // draining that client's bank never overlap. The other bank is independent.
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

    CATALOG_INDEX_RAM u_img_sector_ram (
        .clka(clk_sys), .cea(img_ram_write || img_ram_read),
        .wea(img_ram_write), .addra(img_ram_addr),
        .dia(sec_data), .doa(img_ram_data)
    );
    CATALOG_INDEX_RAM u_aud_sector_ram (
        .clka(clk_sys), .cea(aud_ram_write || aud_ram_read),
        .wea(aud_ram_write), .addra(aud_ram_addr),
        .dia(sec_data), .doa(aud_ram_data)
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
            theme_count <= 5'd0;
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
            metadata_valid <= 16'd0;
            meta_write_kind <= 0; meta_write_word <= 0; lookup_word <= 0;
            img_id_pending <= 0; aud_id_pending <= 0;
            img_block_pending <= 0; aud_block_pending <= 0;
            lookup_state <= Q_IDLE; lookup_sel <= 0;
            lookup_kind <= 0; lookup_theme <= 0;
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
                    // No client is accepted before catalog_commit. A boot
                    // failure therefore has nothing to drain, but still
                    // requires a coordinated reset of SD and this service.
                    recovery_pending <= 1'b1;
                end else if (catalog_we) begin
                    if (meta_write_word==3) begin
                        meta_write_word <= 0;
                        if (meta_write_kind==2) begin
                            meta_write_kind <= 0;
                            metadata_valid[catalog_theme_id] <= 1'b1;
                        end else meta_write_kind <= meta_write_kind + 1'b1;
                    end else meta_write_word <= meta_write_word + 1'b1;
                end else if (catalog_commit) begin
                    if (catalog_theme_count >= 5'd1 && catalog_theme_count <= 5'd16 &&
                        meta_write_kind==0 && meta_write_word==0) begin
                        theme_count <= catalog_theme_count;
                        service_ready <= 1'b1;
                    end else begin
                        service_error <= 8'd2;
                        recovery_pending <= 1'b1;
                    end
                end
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
                    lookup_theme <= selected_id[4:1];
                    lookup_kind <= lookup_sel ? 1 : 0;
                    if (selected_id<8'd32 && selected_id[0]==lookup_sel)
                        lookup_id_valid <= 1;
                    else if (!lookup_sel && selected_id>=8'h80 && selected_id<=8'h8f) begin
                        lookup_id_valid <= 1;
                        lookup_theme <= selected_id[3:0];
                        lookup_kind <= 2;
                    end
                    lookup_state <= Q_READ;
                end
                Q_READ: lookup_state <= Q_DATA;
                Q_DATA: begin
                    // Capture fixed slices of four synchronous 18-bit reads.
                    // The last word carries the presence bit and LBA high bits.
                    case (lookup_word)
                        0: lookup_length[17:0] <= meta_data_out;
                        1: begin
                            lookup_length[31:18] <= meta_data_out[13:0];
                            lookup_start[3:0] <= meta_data_out[17:14];
                        end
                        2: lookup_start[21:4] <= meta_data_out;
                        3: begin
                            lookup_start[31:22] <= meta_data_out[9:0];
                            lookup_present <= meta_data_out[10];
                        end
                    endcase
                    if (lookup_word==3) begin
                        lookup_id_valid <= lookup_id_valid && metadata_valid[lookup_theme] &&
                                           {1'b0,lookup_theme}<theme_count;
                        lookup_state <= Q_CALC;
                    end else begin
                        lookup_word <= lookup_word + 1'b1;
                        lookup_state <= Q_READ;
                    end
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
                        end else if ({1'b0,lookup_block}>=lookup_blocks || lookup_phys_lba[32]) begin
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

// Explicit IP-equivalent Anlogic single-port EMB9K: 18 x 256, synchronous
// NOREG, No Change, no initialization. Existing TD source registration suffices.
module resource_metadata_ram (
    input wire clk, we, ce,
    input wire [7:0] addr,
    input wire [17:0] data_in,
    output wire [17:0] data_out
);
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(18), .ADDR_WIDTH_A(8), .DATA_DEPTH_A(256),
        .DATA_WIDTH_B(18), .ADDR_WIDTH_B(8), .DATA_DEPTH_B(256),
        .MODE("SP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .WRITEMODE_A("NORMAL"), .WRITEMODE_B("NORMAL"),
        .RESETMODE("SYNC"), .IMPLEMENT("9K"), .DEBUGGABLE("NO"),
        .PACKABLE("NO"), .INIT_FILE("NONE"), .FILL_ALL("NONE")
    ) inst (
        .clka(clk), .clkb(1'b0), .cea(ce), .ceb(1'b0),
        .addra(addr), .addrb(8'd0), .dia(data_in), .dib(18'd0),
        .doa(data_out), .dob(), .wea(we), .web(1'b0), .bea(1'b0), .beb(1'b0),
        .ocea(1'b0), .oceb(1'b0), .rsta(1'b0), .rstb(1'b0)
    );
endmodule
