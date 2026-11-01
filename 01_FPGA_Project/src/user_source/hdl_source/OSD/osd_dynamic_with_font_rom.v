`timescale 1ns/1ps
// Hardware wrapper. Add this file, osd_dynamic.v and the generated ROM .ipc
// to TD when integrating the renderer. Only one complete font ROM is used.
module osd_dynamic_with_font_rom #(
    parameter integer TEXT_X=408,
    parameter integer TEXT_Y=552,
    parameter [15:0] GLYPH_COUNT=16'd175,
    parameter HS_IDLE=1'b1,
    parameter VS_IDLE=1'b1
) (
    input wire clk_pix, rst_pix_n,
    input wire osd_enable_pix,
    input wire [6:0] front_token_count_pix,
    input wire [9:0] x_in, y_in,
    input wire [23:0] rgb_in,
    input wire de_in, hs_in, vs_in,
    output wire text_read_req_pix,
    output wire [5:0] text_read_addr_pix,
    input wire text_read_valid_pix,
    input wire [15:0] text_read_glyph_id_pix,
    output wire [23:0] rgb_out,
    output wire de_out, hs_out, vs_out,
    output wire pipeline_idle_pix
);
    wire [12:0] font_rom_addr;
    wire [31:0] font_rom_row;
    OSD_FONT_ROM font_rom(.clka(clk_pix),.addra(font_rom_addr),.doa(font_rom_row));
    osd_dynamic #(.TEXT_X(TEXT_X),.TEXT_Y(TEXT_Y),.GLYPH_COUNT(GLYPH_COUNT),
                  .HS_IDLE(HS_IDLE),.VS_IDLE(VS_IDLE)) renderer (
        .clk_pix(clk_pix),.rst_pix_n(rst_pix_n),.osd_enable_pix(osd_enable_pix),
        .front_token_count_pix(front_token_count_pix),.x_in(x_in),.y_in(y_in),
        .rgb_in(rgb_in),.de_in(de_in),.hs_in(hs_in),.vs_in(vs_in),
        .text_read_req_pix(text_read_req_pix),.text_read_addr_pix(text_read_addr_pix),
        .text_read_valid_pix(text_read_valid_pix),.text_read_glyph_id_pix(text_read_glyph_id_pix),
        .font_rom_addr(font_rom_addr),.font_rom_row(font_rom_row),
        .rgb_out(rgb_out),.de_out(de_out),.hs_out(hs_out),.vs_out(vs_out),
        .pipeline_idle_pix(pipeline_idle_pix)
    );
endmodule
