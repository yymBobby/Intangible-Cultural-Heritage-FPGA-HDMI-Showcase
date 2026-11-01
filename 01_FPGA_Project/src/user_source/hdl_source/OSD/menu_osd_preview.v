`timescale 1ns/1ps
// Independent menu display chain. No physical pin assignments or media controls.
// sw0_on_async must be normalized so 1 means menu ON. Pixel source is the
// existing post-brightness picture/sidebar stream; caller provides drained
// frame boundary. Existing decoded rotary events are consumed at 40MHz.
module menu_osd_preview #(
    parameter integer SW0_FILTER_CYCLES=400000
)(
    input wire clk_sys,rst_sys_n,sw0_on_async,
    input wire step_cw_sys,step_ccw_sys,click_sys,back_sys,
    input wire clk_pix,rst_pix_n,apply_safe_pix,
    input wire subtitle_enable_pix,
    input wire [6:0] front_token_count_pix,
    input wire [10:0] x_in,
    input wire [9:0] y_in,
    input wire [23:0] rgb_in,
    input wire de_in,hs_in,vs_in,
    output wire text_read_req_pix,
    output wire [5:0] text_read_addr_pix,
    input wire text_read_valid_pix,
    input wire [15:0] text_read_glyph_id_pix,
    output wire [23:0] rgb_out,
    output wire de_out,hs_out,vs_out,pipeline_idle_pix,
    output wire [47:0] snapshot_sys,snapshot_pix,
    output wire ui_confirm_pulse_sys,snapshot_ready_sys,snapshot_applied_sys,snapshot_applied_pix
);
    wire sw0_level,sw0_valid;
    console_input_filter #(.STABLE_CYCLES(SW0_FILTER_CYCLES),.RESET_LEVEL(1'b0)) sw0_filter(
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.contact_async(sw0_on_async),.level(sw0_level),.valid(sw0_valid));
    menu_ui_state state(.clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.sw0_valid_sys(sw0_valid),.sw0_on_sys(sw0_level),
        .step_cw_sys(step_cw_sys),.step_ccw_sys(step_ccw_sys),.click_sys(click_sys),.back_sys(back_sys),
        .snapshot_sys(snapshot_sys),.ui_confirm_pulse_sys(ui_confirm_pulse_sys));
    menu_snapshot_cdc mailbox(.clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.snapshot_sys(snapshot_sys),
        .ready_sys(snapshot_ready_sys),.applied_sys(snapshot_applied_sys),.clk_pix(clk_pix),.rst_pix_n(rst_pix_n),
        .apply_safe_pix(apply_safe_pix && pipeline_idle_pix),.snapshot_pix(snapshot_pix),.applied_pix(snapshot_applied_pix));
    osd_menu_with_subtitles display(.clk_pix(clk_pix),.rst_pix_n(rst_pix_n),.snapshot_pix({20'd0,snapshot_pix}),
        .subtitle_enable_pix(subtitle_enable_pix),.front_token_count_pix(front_token_count_pix),
        .x_in(x_in),.y_in(y_in),.rgb_in(rgb_in),.de_in(de_in),.hs_in(hs_in),.vs_in(vs_in),
        .text_read_req_pix(text_read_req_pix),.text_read_addr_pix(text_read_addr_pix),
        .text_read_valid_pix(text_read_valid_pix),.text_read_glyph_id_pix(text_read_glyph_id_pix),
        .rgb_out(rgb_out),.de_out(de_out),.hs_out(hs_out),.vs_out(vs_out),.pipeline_idle_pix(pipeline_idle_pix));
endmodule
