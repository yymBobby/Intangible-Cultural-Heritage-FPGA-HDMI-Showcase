`timescale 1ns/1ps
// Pixel-domain renderer: 4 rows x 16 columns, 32 x 32 font, half-opacity panel.
// Contract: text_bank_cdc registered read = 1 stage; font ROM = 1 stage.
// Total = 3 registered stages (cache, ROM, blend), including RGB/DE/HS/VS.
// The front bank/count and osd_enable_pix are controlled by the unified commit
// controller. Change the front descriptor only with the old pipeline drained.
module osd_dynamic #(
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
    // Connect directly to text_bank_cdc's pixel read port.
    output wire text_read_req_pix,
    output wire [5:0] text_read_addr_pix,
    input wire text_read_valid_pix,
    input wire [15:0] text_read_glyph_id_pix,
    // One synchronous read stage, NO extra output register.
    output wire [12:0] font_rom_addr,
    input wire [31:0] font_rom_row,
    output reg [23:0] rgb_out,
    output reg de_out, hs_out, vs_out,
    // Local valid-video/lookup drain indication; not a frame-switch grant.
    output wire pipeline_idle_pix
);
    localparam integer TEXT_W=512, TEXT_H=128, PANEL_PAD=8;
    localparam [23:0] PANEL_COLOR=24'h111318, BORDER_COLOR=24'h8f7955,
        TITLE_COLOR=24'hdcc398, TEXT_COLOR=24'hece7da;
    // Full 9-bit sum keeps the carry and odd+odd contribution before /2.
    // Blend in the existing ROM stage; no extra pixel/sync latency or RAM.
    function [23:0] half_rgb;
        input [23:0] picture,tint;
        reg [8:0] r,g,b;
        begin
            r={1'b0,picture[23:16]}+{1'b0,tint[23:16]};
            g={1'b0,picture[15:8]}+{1'b0,tint[15:8]};
            b={1'b0,picture[7:0]}+{1'b0,tint[7:0]};
            half_rgb={r[8:1],g[8:1],b[8:1]};
        end
    endfunction
    wire [9:0] local_x=x_in-TEXT_X;
    wire [9:0] local_y=y_in-TEXT_Y;
    wire [5:0] cell_index={local_y[6:5],local_x[8:5]};
    wire text_present=(front_token_count_pix!=0 && front_token_count_pix<=7'd64);
    wire in_text=(x_in>=TEXT_X && x_in<TEXT_X+TEXT_W &&
                  y_in>=TEXT_Y && y_in<TEXT_Y+TEXT_H);
    wire in_panel=(x_in>=TEXT_X-PANEL_PAD && x_in<TEXT_X+TEXT_W+PANEL_PAD &&
                   y_in>=TEXT_Y-PANEL_PAD && y_in<TEXT_Y+TEXT_H+PANEL_PAD);
    wire on_border=(x_in==TEXT_X-PANEL_PAD || x_in==TEXT_X+TEXT_W+PANEL_PAD-1 ||
                    y_in==TEXT_Y-PANEL_PAD || y_in==TEXT_Y+TEXT_H+PANEL_PAD-1);
    assign text_read_req_pix=rst_pix_n && de_in && osd_enable_pix &&
        text_present && in_text && ({1'b0,cell_index}<front_token_count_pix);
    assign text_read_addr_pix=text_read_req_pix ? cell_index : 6'd0;

    reg [23:0] rgb_s1, rgb_s2;
    reg de_s1, hs_s1, vs_s1, de_s2, hs_s2, vs_s2;
    reg panel_s1, panel_s2, hit_s1, hit_s2;
    reg border_s1, border_s2, title_s1, title_s2;
    reg [4:0] row_s1, col_s1, col_s2;
    wire glyph_valid=hit_s1 && text_read_valid_pix &&
        (text_read_glyph_id_pix<GLYPH_COUNT) &&
        (GLYPH_COUNT!=0 && GLYPH_COUNT<=16'd256);
    // Concatenation implements glyph_id*32 + row without a multiplier.
    assign font_rom_addr=glyph_valid ? {text_read_glyph_id_pix[7:0],row_s1} : 13'd0;
    wire ink_s2=hit_s2 && font_rom_row[5'd31-col_s2];
    assign pipeline_idle_pix=!(de_in || de_s1 || de_s2 || de_out ||
        text_read_req_pix || text_read_valid_pix || hit_s1 || hit_s2);

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if (!rst_pix_n) begin
            rgb_s1<=0; rgb_s2<=0; rgb_out<=0;
            de_s1<=0; de_s2<=0; de_out<=0;
            hs_s1<=HS_IDLE; hs_s2<=HS_IDLE; hs_out<=HS_IDLE;
            vs_s1<=VS_IDLE; vs_s2<=VS_IDLE; vs_out<=VS_IDLE;
            panel_s1<=0; panel_s2<=0; hit_s1<=0; hit_s2<=0;
            border_s1<=0; border_s2<=0; title_s1<=0; title_s2<=0;
            row_s1<=0; col_s1<=0; col_s2<=0;
        end else begin
            // Stage 1: cache samples req/addr on the same rising edge.
            rgb_s1<=rgb_in; de_s1<=de_in; hs_s1<=hs_in; vs_s1<=vs_in;
            panel_s1<=de_in && osd_enable_pix && text_present && in_panel;
            border_s1<=on_border;
            title_s1<=(local_y[6:5]==0);
            hit_s1<=text_read_req_pix;
            row_s1<=local_y[4:0]; col_s1<=local_x[4:0];
            // Stage 2: font ROM samples the ID+row from stage 1.
            rgb_s2<=panel_s1 ? half_rgb(rgb_s1,PANEL_COLOR):rgb_s1;
            de_s2<=de_s1; hs_s2<=hs_s1; vs_s2<=vs_s1;
            panel_s2<=panel_s1; hit_s2<=glyph_valid; col_s2<=col_s1;
            border_s2<=border_s1; title_s2<=title_s1;
            // Stage 3: ROM row and metadata now refer to the same input pixel.
            de_out<=de_s2; hs_out<=hs_s2; vs_out<=vs_s2;
            if (!de_s2) rgb_out<=24'd0;
            else if (ink_s2) rgb_out<=title_s2 ? TITLE_COLOR:TEXT_COLOR;
            else if (panel_s2) rgb_out<=border_s2 ? BORDER_COLOR:rgb_s2;
            else rgb_out<=rgb_s2;
        end
    end
endmodule
