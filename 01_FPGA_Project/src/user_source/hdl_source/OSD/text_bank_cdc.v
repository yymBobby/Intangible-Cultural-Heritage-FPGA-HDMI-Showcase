`timescale 1ns/1ps
// A-internal 2 x 64 x 16 subtitle-ID store. The ROM is NOT duplicated here.
// clk_sys writes only the back bank; clk_pix performs a registered front read.
// The unified video_frame_commit must grant apply ONLY after old image/text
// reads and the full downstream pixel pipeline have drained at a safe boundary.
// Both resets must participate in the same coordinated reset, with synchronous
// release in each domain. A single-domain reset during use is unsupported.
module text_bank_cdc #(
    parameter [15:0] GLYPH_COUNT = 16'd175,
    parameter [31:0] COMMIT_TIMEOUT_CYCLES = 32'd10000000
) (
    input wire clk_sys, rst_sys_n,
    input wire clk_pix, rst_pix_n,
    input wire text_write_valid,
    output wire text_write_ready,
    input wire text_write_bank,
    input wire [5:0] text_write_addr,
    input wire [15:0] text_write_glyph_id,
    // Connect the loader's sticky prepared level. A new load clears it.
    // Do NOT gate new load acceptance with prepared: that would deadlock reuse.
    input wire text_prepared_sys,
    output wire text_back_bank_sys,
    output wire text_back_available_sys,
    // INTERNAL four-phase request from A's unified video_frame_commit.
    // bank/count must describe validated text and stay stable through ack low.
    input wire text_commit_req_sys,
    input wire text_commit_bank_sys,
    input wire [6:0] text_commit_count_sys,
    output reg text_commit_ack_sys,
    output wire text_commit_busy_sys,
    output wire text_cache_error_sys,
    output reg [7:0] text_cache_error_code_sys,
    output wire text_recovery_needed_sys,
    // Pending descriptor available to the pixel-side unified commit control.
    output wire text_commit_pending_pix,
    output wire text_commit_bank_pix,
    output wire [6:0] text_commit_count_pix,
    input wire text_commit_apply_pix,
    input wire text_read_req_pix,
    input wire [5:0] text_read_addr_pix,
    output reg text_read_valid_pix,
    output wire [15:0] text_read_glyph_id_pix,
    output reg front_bank_pix,
    output reg [6:0] front_token_count_pix
);
    localparam [1:0] S_IDLE=0, S_ACK=1, S_REQ_LOW=2, S_ACK_LOW=3;
    localparam [1:0] P_IDLE=0, P_CAPTURE=1, P_APPLY=2, P_RELEASE=3;
    localparam [31:0] LIMIT=COMMIT_TIMEOUT_CYCLES==0 ? 32'd1 : COMMIT_TIMEOUT_CYCLES;
    reg [1:0] sys_state, pix_state;
    reg front_bank_sys;
    reg req_hold_sys, bank_hold_sys;
    reg [6:0] count_hold_sys;
    reg [31:0] commit_timer;
    reg ack_hold_pix, pending_bank_pix;
    reg [6:0] pending_count_pix;
    // Synchronize ONLY control levels. The multi-bit descriptor is bundled:
    // it is held for the entire handshake and sampled after an extra pix cycle.
    (* async_reg="true" *) reg req_meta_pix, req_sync_pix;
    (* async_reg="true" *) reg fault_meta_pix, fault_sync_pix;
    (* async_reg="true" *) reg ack_meta_sys, ack_sync_sys;
    wire [15:0] ids_q;
    reg read_accept_q;

    assign text_cache_error_sys=(text_cache_error_code_sys!=0);
    assign text_recovery_needed_sys=text_cache_error_sys;
    assign text_commit_busy_sys=(sys_state!=S_IDLE) || text_commit_req_sys || text_cache_error_sys;
    assign text_back_bank_sys=~front_bank_sys;
    assign text_back_available_sys=rst_sys_n && !text_commit_busy_sys;
    assign text_write_ready=text_back_available_sys && !text_prepared_sys &&
        (text_write_bank!=front_bank_sys) && (text_write_glyph_id<GLYPH_COUNT) &&
        (GLYPH_COUNT!=0 && GLYPH_COUNT<=512);
    assign text_commit_pending_pix=(pix_state==P_APPLY) && !fault_sync_pix;
    assign text_commit_bank_pix=pending_bank_pix;
    assign text_commit_count_pix=pending_count_pix;
    wire apply_fire=text_commit_pending_pix && text_commit_apply_pix &&
        !text_read_req_pix && !text_read_valid_pix;
    wire finish_phase=(sys_state==S_ACK_LOW && !ack_sync_sys);
    wire timeout_now=(sys_state!=S_IDLE) && !text_cache_error_sys &&
        (commit_timer>=LIMIT-1) && !finish_phase;

    // Explicit simple dual-port 9K memory replaces the inferred LUT store.
    // EG4 PDPW supports 512x16 in one block. Retain all16 stored bits so even
    // native uninitialized-memory behavior agrees with the original cache.
    // Port B has exactly one synchronous read stage, with no extra OUTREG.
    // No RAM reset: the async-reset accept bit masks reset/fault/range misses.
    wire write_accept=rst_sys_n&&text_write_valid&&text_write_ready;
    wire read_accept=rst_pix_n&&text_read_req_pix&&!fault_sync_pix&&
        {1'b0,text_read_addr_pix}<front_token_count_pix;
    EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(7),.DATA_DEPTH_A(128),
        .DATA_WIDTH_B(16),.ADDR_WIDTH_B(7),.DATA_DEPTH_B(128),.MODE("PDPW"),
        .REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.WRITEMODE_A("NORMAL"),
        .WRITEMODE_B("NORMAL"),.RESETMODE("SYNC"),.IMPLEMENT("9K"),
        .DEBUGGABLE("NO"),.PACKABLE("NO"),.INIT_FILE("NONE"),.FILL_ALL("NONE")) ids_ram(
        .dia(text_write_glyph_id),.dib(16'd0),.addra({text_write_bank,text_write_addr}),
        .addrb({front_bank_pix,text_read_addr_pix}),.cea(write_accept),.ceb(read_accept),
        .ocea(1'b0),.oceb(1'b0),.clka(clk_sys),.clkb(clk_pix),
        .wea(1'b1),.web(1'b0),.bea(1'b0),.beb(1'b0),
        .rsta(1'b0),.rstb(1'b0),.doa(),.dob(ids_q));
    assign text_read_glyph_id_pix=read_accept_q ? ids_q:16'd0;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            text_read_valid_pix<=0;
            read_accept_q<=0;
        end else begin
            text_read_valid_pix<=text_read_req_pix && !fault_sync_pix;
            read_accept_q<=read_accept;
        end
    end

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin ack_meta_sys<=0; ack_sync_sys<=0; end
        else begin ack_meta_sys<=ack_hold_pix; ack_sync_sys<=ack_meta_sys; end
    end
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            req_meta_pix<=0; req_sync_pix<=0; fault_meta_pix<=0; fault_sync_pix<=0;
        end else begin
            req_meta_pix<=req_hold_sys; req_sync_pix<=req_meta_pix;
            fault_meta_pix<=text_cache_error_sys; fault_sync_pix<=fault_meta_pix;
        end
    end

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            sys_state<=S_IDLE; front_bank_sys<=0;
            req_hold_sys<=0; bank_hold_sys<=0; count_hold_sys<=0;
            commit_timer<=0; text_commit_ack_sys<=0; text_cache_error_code_sys<=0;
        end else if (!text_cache_error_sys) begin
            if (sys_state!=S_IDLE && commit_timer<LIMIT) commit_timer<=commit_timer+1'b1;
            if (timeout_now) begin
                // Keep the in-flight request/descriptor frozen. No forced cancel,
                // false success or automatic reuse; require coordinated reset.
                text_cache_error_code_sys<=8'd3;
            end else case (sys_state)
                S_IDLE: begin
                    commit_timer<=0;
                    if (text_commit_req_sys) begin
                        if (!text_prepared_sys || text_commit_bank_sys==front_bank_sys ||
                            text_commit_count_sys>64 || GLYPH_COUNT==0 || GLYPH_COUNT>512)
                            text_cache_error_code_sys<=8'd2;
                        else begin
                            bank_hold_sys<=text_commit_bank_sys;
                            count_hold_sys<=text_commit_count_sys;
                            req_hold_sys<=1; sys_state<=S_ACK;
                        end
                    end else if (text_write_valid && !text_prepared_sys &&
                        (text_write_bank==front_bank_sys || text_write_glyph_id>=GLYPH_COUNT ||
                         GLYPH_COUNT==0 || GLYPH_COUNT>512))
                        text_cache_error_code_sys<=8'd1;
                end
                S_ACK: if (ack_sync_sys) begin
                    front_bank_sys<=bank_hold_sys;
                    text_commit_ack_sys<=1; sys_state<=S_REQ_LOW;
                end
                S_REQ_LOW: if (!text_commit_req_sys) begin
                    req_hold_sys<=0; sys_state<=S_ACK_LOW;
                end
                S_ACK_LOW: if (!ack_sync_sys) begin
                    text_commit_ack_sys<=0; sys_state<=S_IDLE;
                end
                default: text_cache_error_code_sys<=8'd2;
            endcase
        end
    end

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            pix_state<=P_IDLE; ack_hold_pix<=0;
            pending_bank_pix<=0; pending_count_pix<=0;
            front_bank_pix<=0; front_token_count_pix<=0;
        end else if (!fault_sync_pix) begin
            case (pix_state)
                P_IDLE: if (req_sync_pix) pix_state<=P_CAPTURE;
                P_CAPTURE: begin
                    pending_bank_pix<=bank_hold_sys;
                    pending_count_pix<=count_hold_sys;
                    pix_state<=P_APPLY;
                end
                P_APPLY: if (apply_fire) begin
                    front_bank_pix<=pending_bank_pix;
                    front_token_count_pix<=pending_count_pix;
                    ack_hold_pix<=1; pix_state<=P_RELEASE;
                end
                P_RELEASE: if (!req_sync_pix) begin
                    ack_hold_pix<=0; pix_state<=P_IDLE;
                end
            endcase
        end
    end
endmodule
