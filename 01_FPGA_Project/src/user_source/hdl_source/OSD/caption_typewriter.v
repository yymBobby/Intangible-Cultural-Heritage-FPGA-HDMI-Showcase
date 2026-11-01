`timescale 1ns/1ps
// Once per theme. Peek next token through the existing subtitle RAM in blank;
// no extra text/classification RAM. Empty layout cells advance silently.
// Cue occurs on the first REAL renderer read of each newly revealed glyph.
module caption_typewriter #(
    parameter integer FRAMES_PER_GLYPH=4,
    parameter integer COMMA_FRAMES=12,
    parameter integer PERIOD_FRAMES=24
)(
    input wire clk_sys,rst_sys_n,skip_pulse_sys,
    output wire typing_sys,
    input wire clk_pix,rst_pix_n,frame_start_pix,commit_pix,
    input wire [6:0] count_pix,
    input wire [7:0] theme_pix,
    input wire lookup_enable_pix,lookup_ready_pix,lookup_valid_pix,
    input wire [7:0] lookup_glyph_pix,
    output wire lookup_req_pix,
    output wire [5:0] lookup_addr_pix,
    input wire glyph_read_req_pix,
    input wire [5:0] glyph_read_addr_pix,
    output reg [6:0] visible_count_pix,
    output reg glyph_toggle_pix
);
    localparam integer LONGEST=PERIOD_FRAMES>COMMA_FRAMES ?
        (PERIOD_FRAMES>FRAMES_PER_GLYPH ? PERIOD_FRAMES:FRAMES_PER_GLYPH):
        (COMMA_FRAMES>FRAMES_PER_GLYPH ? COMMA_FRAMES:FRAMES_PER_GLYPH);
    localparam integer CW=LONGEST>1 ? $clog2(LONGEST):1;
    reg [6:0] total;
    reg [7:0] theme;
    reg have_theme;
    reg [CW-1:0] interval;
    reg peek_pending,peek_valid,reveal_due,cue_pending;
    reg [1:0] peek_class;
    reg [5:0] cue_addr;
    reg force_toggle_sys,force_seen_pix;
    (* ASYNC_REG="TRUE" *) reg force_meta_pix,force_sync_pix,ack_meta_sys,ack_sync_sys;
    (* ASYNC_REG="TRUE" *) reg typing_meta_sys,typing_sync_sys;
    wire typing_pix=visible_count_pix<total;
    assign typing_sys=typing_sync_sys || force_toggle_sys!=ack_sync_sys;
    assign lookup_req_pix=lookup_enable_pix && typing_pix && !peek_valid && !peek_pending && !commit_pix;
    assign lookup_addr_pix=visible_count_pix[5:0];
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin force_toggle_sys<=0;ack_meta_sys<=0;ack_sync_sys<=0;typing_meta_sys<=0;typing_sync_sys<=0;end
        else begin
            ack_meta_sys<=force_seen_pix;ack_sync_sys<=ack_meta_sys;
            typing_meta_sys<=typing_pix;typing_sync_sys<=typing_meta_sys;
            if(skip_pulse_sys && force_toggle_sys==ack_sync_sys) force_toggle_sys<=!force_toggle_sys;
        end
    end
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin force_meta_pix<=0;force_sync_pix<=0;end
        else begin force_meta_pix<=force_toggle_sys;force_sync_pix<=force_meta_pix;end
    end
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin
            total<=0;visible_count_pix<=0;interval<=0;glyph_toggle_pix<=0;force_seen_pix<=0;theme<=0;have_theme<=0;
            peek_pending<=0;peek_valid<=0;peek_class<=0;reveal_due<=0;cue_pending<=0;cue_addr<=0;
        end else if(commit_pix) begin
            total<=count_pix>64 ? 7'd64:count_pix;
            // A text apply exchanges banks; all old RAM requests are drained.
            peek_pending<=0;peek_valid<=0;
            if(!have_theme || theme_pix!=theme) begin
                theme<=theme_pix;have_theme<=1;visible_count_pix<=0;interval<=0;
                reveal_due<=0;cue_pending<=0;
            end else if(!typing_pix || visible_count_pix>(count_pix>64 ? 7'd64:count_pix)) begin
                visible_count_pix<=count_pix>64 ? 7'd64:count_pix;
            end
        end else if(frame_start_pix && force_sync_pix!=force_seen_pix) begin
            visible_count_pix<=total;force_seen_pix<=force_sync_pix;interval<=0;
            peek_pending<=0;peek_valid<=0;reveal_due<=0;cue_pending<=0;
        end else begin
            if(cue_pending && glyph_read_req_pix && glyph_read_addr_pix==cue_addr) begin
                glyph_toggle_pix<=!glyph_toggle_pix;cue_pending<=0;
            end
            if(lookup_req_pix && lookup_ready_pix) peek_pending<=1;
            if(lookup_valid_pix && peek_pending) begin
                peek_pending<=0;peek_valid<=1;
                // Compact font CBE17BCF: 0 blank, 162 comma, 20 period.
                peek_class<=lookup_glyph_pix==0 ? 2'd0:lookup_glyph_pix==162 ? 2'd2:
                    lookup_glyph_pix==20 ? 2'd3:2'd1;
            end
            if(frame_start_pix && typing_pix) begin
                if(interval==0) reveal_due<=1;
                else interval<=interval-1'b1;
            end
            if(lookup_enable_pix && peek_valid && typing_pix &&
                (peek_class==0 || (!cue_pending && (reveal_due || (frame_start_pix && interval==0))))) begin
                visible_count_pix<=visible_count_pix+1'b1;peek_valid<=0;
                if(peek_class!=0) begin
                    interval<=peek_class==3 ? PERIOD_FRAMES-1:peek_class==2 ? COMMA_FRAMES-1:FRAMES_PER_GLYPH-1;
                    reveal_due<=0;cue_addr<=visible_count_pix[5:0];cue_pending<=1;
                end
            end
        end
    end
endmodule
