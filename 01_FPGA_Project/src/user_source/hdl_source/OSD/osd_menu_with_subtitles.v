`timescale 1ns/1ps
// One ROM for spatially disjoint menu and captions, without another BRAM bank.
// Both layers have five stages: caption input is delayed two stages so its
// cache+ROM stages align with menu geometry+layout+glyph+ROM. RGB/sync = 5 stages.
module osd_menu_with_subtitles #(parameter integer ENABLE_ALARM=0)(
    input wire alarm_active_pix,
    output wire alarm_cover_out,alarm_ink_out,
    input wire clk_pix,rst_pix_n,
    input wire [67:0] snapshot_pix,
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
    output wire de_out,hs_out,vs_out,pipeline_idle_pix
);
    wire [12:0] menu_addr,subtitle_addr,font_addr;
    wire [31:0] font_row;
    wire menu_req,menu_cover,menu_idle,subtitle_idle;
    wire [23:0] menu_rgb,subtitle_rgb;
    wire subtitle_de,subtitle_hs,subtitle_vs;
    reg [9:0] caption_x_s0,caption_y_s0;
    reg [23:0] caption_rgb_s0;
    reg caption_de_s0,caption_hs_s0,caption_vs_s0,caption_enable_s0;
    reg [9:0] caption_x_s1,caption_y_s1;
    reg [23:0] caption_rgb_s1;
    reg caption_de_s1,caption_hs_s1,caption_vs_s1,caption_enable_s1;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin
            caption_x_s0<=0;caption_y_s0<=0;caption_rgb_s0<=0;
            caption_de_s0<=0;caption_hs_s0<=0;caption_vs_s0<=0;caption_enable_s0<=0;
            caption_x_s1<=0;caption_y_s1<=0;caption_rgb_s1<=0;
            caption_de_s1<=0;caption_hs_s1<=0;caption_vs_s1<=0;caption_enable_s1<=0;
        end else begin
            caption_x_s0<=x_in[9:0];caption_y_s0<=y_in;caption_rgb_s0<=rgb_in;
            caption_de_s0<=de_in;caption_hs_s0<=hs_in;caption_vs_s0<=vs_in;
            caption_enable_s0<=subtitle_enable_pix && x_in<960;
            caption_x_s1<=caption_x_s0;caption_y_s1<=caption_y_s0;caption_rgb_s1<=caption_rgb_s0;
            caption_de_s1<=caption_de_s0;caption_hs_s1<=caption_hs_s0;caption_vs_s1<=caption_vs_s0;caption_enable_s1<=caption_enable_s0;
        end
    end
    assign font_addr=menu_req ? menu_addr:subtitle_addr;
    OSD_FONT_ROM font_rom(.clka(clk_pix),.addra(font_addr),.doa(font_row));
    osd_menu_layer #(.ENABLE_ALARM(ENABLE_ALARM)) menu(.alarm_active_pix(alarm_active_pix),
        .alarm_cover_out(alarm_cover_out),.alarm_ink_out(alarm_ink_out),.clk_pix(clk_pix),.rst_pix_n(rst_pix_n),.snapshot_pix(snapshot_pix),
        .x_in(x_in),.y_in(y_in),.rgb_in(rgb_in),.de_in(de_in),.hs_in(hs_in),.vs_in(vs_in),
        .font_req(menu_req),.font_addr(menu_addr),.font_row(font_row),.rgb_out(menu_rgb),
        .de_out(de_out),.hs_out(hs_out),.vs_out(vs_out),.cover_out(menu_cover),.pipeline_idle(menu_idle));
    osd_dynamic #(.HS_IDLE(0),.VS_IDLE(0)) subtitle(.clk_pix(clk_pix),.rst_pix_n(rst_pix_n),
        .osd_enable_pix(caption_enable_s1),.front_token_count_pix(front_token_count_pix),
        .x_in(caption_x_s1),.y_in(caption_y_s1),.rgb_in(caption_rgb_s1),.de_in(caption_de_s1),.hs_in(caption_hs_s1),.vs_in(caption_vs_s1),
        .text_read_req_pix(text_read_req_pix),.text_read_addr_pix(text_read_addr_pix),
        .text_read_valid_pix(text_read_valid_pix),.text_read_glyph_id_pix(text_read_glyph_id_pix),
        .font_rom_addr(subtitle_addr),.font_rom_row(font_row),.rgb_out(subtitle_rgb),
        .de_out(subtitle_de),.hs_out(subtitle_hs),.vs_out(subtitle_vs),.pipeline_idle_pix(subtitle_idle));
    assign rgb_out=menu_cover ? menu_rgb:subtitle_rgb;
    assign pipeline_idle_pix=menu_idle && subtitle_idle && !caption_de_s0 && !caption_de_s1;
endmodule
