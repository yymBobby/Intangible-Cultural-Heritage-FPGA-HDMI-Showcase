`timescale 1ns/1ps
// vblank_pix must come from the timing generator's VERTICAL active flag,
// delayed together with its DE. Horizontal DE gaps and a raw VS are not valid.
module video_commit_window #(
    parameter integer BLANK_CYCLES=36000, // (525-480)*800 at 640x480
    parameter integer BEGIN_GUARD_CYCLES=32,
    parameter integer END_GUARD_CYCLES=128,
    parameter integer PREPARATION_BUDGET_CYCLES=25008 // 1ms pixel timeout + capture/apply/verify
) (
    input wire clk_pix, rst_pix_n,
    input wire vblank_pix, video_de_pix,
    input wire [31:0] vblank_cycles_left_pix,
    output wire safe_commit_window_pix,
    output wire image_stage_start_allowed_pix,
    output wire vblank_start_pix,
    output wire prepare_frame_pix,
    output reg window_error_pix
);
    reg blank_d, safe_d;
    reg [31:0] blank_age;
    localparam integer CLOSE_AT=BLANK_CYCLES-END_GUARD_CYCLES;
    wire config_valid=BEGIN_GUARD_CYCLES>=4 && END_GUARD_CYCLES>=4 &&
        BLANK_CYCLES>BEGIN_GUARD_CYCLES+END_GUARD_CYCLES;
    assign vblank_start_pix=rst_pix_n && vblank_pix && !blank_d;
    assign safe_commit_window_pix=rst_pix_n && config_valid && !window_error_pix &&
        vblank_pix && !video_de_pix && blank_age>=BEGIN_GUARD_CYCLES && blank_age<CLOSE_AT &&
        vblank_cycles_left_pix>END_GUARD_CYCLES;
    assign prepare_frame_pix=safe_commit_window_pix && !safe_d;
    // Start cutoff is EARLIER than the apply deadline. A late descriptor waits
    // for next frame; an already-started preparation keeps the full window.
    assign image_stage_start_allowed_pix=safe_commit_window_pix &&
        vblank_cycles_left_pix>END_GUARD_CYCLES+PREPARATION_BUDGET_CYCLES;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin blank_d<=0;safe_d<=0;blank_age<=0;window_error_pix<=0;end
        else begin
            blank_d<=vblank_pix;safe_d<=safe_commit_window_pix;
            if(!vblank_pix) blank_age<=0;
            else if(!blank_d) blank_age<=1;
            else if(blank_age<BLANK_CYCLES) blank_age<=blank_age+1'b1;
            // A too-long/initial partial blank never reopens the window.
            if(!config_valid || (vblank_pix && video_de_pix)) window_error_pix<=1;
        end
    end
endmodule
