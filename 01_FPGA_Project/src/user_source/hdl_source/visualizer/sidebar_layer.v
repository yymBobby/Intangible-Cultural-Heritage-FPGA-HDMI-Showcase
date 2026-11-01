`timescale 1ns/1ps
// Opaque 320px sidebar. One synchronous read stage, same as phase bitmap.
// Display order: automatic/manual, goniometer, horizontal L/R, 32-band FFT.
module sidebar_layer(
    input wire clk,rst_n,de,
    input wire [10:0] x,input wire [9:0] y,
    input wire auto_enabled,running,
    input wire [7:0] bar_height,bar_peak,
    output wire [4:0] bar_address,output wire bar_read,
    input wire [7:0] level_l,level_r,peak_l,peak_r,
    input wire clip_l,clip_r,phase_dot,
    input wire signed [1:0] phase_trend,
    output wire [11:0] phase_address,output wire phase_read,
    output reg valid,output wire [23:0] rgb
);
    wire field=x>=992&&x<1248&&y>=88&&y<344;
    wire [10:0] fx=x-992;
    wire [9:0] fy=y-88;
    assign phase_address={fy[7:2],fx[7:2]};
    assign phase_read=de&&field;
    wire [10:0] sx=x-992;
    wire [4:0] band=sx[7:3];
    wire frequency=x>=992&&x<1248&&y>=496&&y<=688;
    assign bar_address=band;
    assign bar_read=de&&frequency;
    wire [9:0] distance_y=688-y;
    wire [10:0] meter_x=x-976;
    wire right_meter=y>=420;
    wire [7:0] meter_level=right_meter ? level_r:level_l;
    wire [7:0] meter_peak=right_meter ? peak_r:peak_l;
    wire [8:0] filled={1'b0,meter_level}+{2'b0,meter_level[7:1]};
    wire [8:0] marker={1'b0,meter_peak}+{2'b0,meter_peak[7:1]};
    reg [23:0] color;
    reg glyph_hit;
    reg [3:0] glyph,row,col;
    reg [15:0] font[0:255]; /* fehdl force_ram=1, ram_style="bram" */
    reg [15:0] font_q;
    reg glyph_q,field_q,frequency_q;
    reg [9:0] distance_y_q;
    reg [2:0] gap_q;
    reg [3:0] col_q;
    reg [23:0] color_q;
    initial $readmemh("sidebar_font.hex",font);
    wire [10:0] text_x=x-984;
    wire [9:0] status_y=y-12,phase_y=y-52,level_y=y-348,freq_y=y-464;
    always @* begin
        color=24'h101c30;glyph_hit=0;glyph=0;row=0;col=0;
        if(field) begin
            if(x==1120||y==216) color=24'h30475e;
            if(fx==fy || fx==255-fy) color=24'h20354a;
        end
        if(y>=348&&y<351&&x>=1088&&x<1152) begin
            color=24'h263349;
            if((phase_trend<0&&x<1104)||(phase_trend==0&&x>=1112&&x<1128)||(phase_trend>0&&x>=1136))
                color=phase_trend<0 ? 24'hff647c:phase_trend>0 ? 24'h47ddb0:24'hb8cadd;
        end
        if(x>=976&&x<1264&&((y>=380&&y<404)||(y>=420&&y<444))) begin
            color=24'h263349;
            if(meter_x<filled) color=meter_x>=264 ? 24'hff647c:meter_x>=228 ? 24'hffcc63:24'h47ddb0;
            if(meter_peak!=0&&meter_x==marker) color=24'hffffff;
        end
        if(x>=1268&&x<1276&&((y>=380&&y<404)||(y>=420&&y<444)))
            color=(right_meter ? clip_r:clip_l) ? 24'hff425e:24'h263349;
        // 16px source glyphs rendered at 2x; no new SD font-set identifier.
        if(x>=984&&x<(auto_enabled ? 1112:1048)&&y>=12&&y<44) begin
            glyph_hit=1;row=status_y[4:1];col=text_x[4:1];
            glyph=auto_enabled ? {2'b0,text_x[6:5]} : text_x[5] ? 4'd1:4'd4;
        end else if(x>=984&&x<1048&&y>=52&&y<84) begin
            glyph_hit=1;row=phase_y[4:1];col=text_x[4:1];glyph=text_x[5] ? 4'd6:4'd5;
        end else if(x>=984&&x<1048&&y>=348&&y<380) begin
            glyph_hit=1;row=level_y[4:1];col=text_x[4:1];glyph=text_x[5] ? 4'd8:4'd7;
        end else if(x>=984&&x<1048&&y>=464&&y<496) begin
            glyph_hit=1;row=freq_y[4:1];col=text_x[4:1];glyph=text_x[5] ? 4'd10:4'd9;
        end else if(x>=960&&x<976&&((y>=384&&y<400)||(y>=424&&y<440))) begin
            glyph_hit=1;row=y-(right_meter ? 424:384);col=x-960;glyph=right_meter ? 4'd12:4'd11;
        end else if(x>=1056&&x<1088&&y>=476&&y<492) begin
            glyph_hit=1;row=y-476;col=x-1056;glyph=x>=1072 ? 4'd14:4'd13;
        end
        if(x>=1256&&x<1264&&y>=20&&y<28) color=running ? 24'h47ddb0:24'hffcc63;
    end
    always @(posedge clk) font_q<=font[{glyph,row}];
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin valid<=0;glyph_q<=0;field_q<=0;col_q<=0;color_q<=0;frequency_q<=0;distance_y_q<=0;gap_q<=0;end
        else begin valid<=de&&x>=960;glyph_q<=glyph_hit;field_q<=field;col_q<=col;color_q<=color;
            frequency_q<=frequency;distance_y_q<=distance_y;gap_q<=sx[2:0];end
    end
    reg [23:0] frequency_color;
    always @* begin
        frequency_color=24'h101c30;
        if(distance_y_q==0||distance_y_q==48||distance_y_q==96||distance_y_q==144||distance_y_q==192) frequency_color=24'h27354a;
        if(gap_q<6&&distance_y_q<bar_height)
            frequency_color=distance_y_q>160 ? 24'hffac55:distance_y_q>112 ? 24'h51e3b5:24'h36b7e8;
        if(gap_q<6&&bar_peak!=0&&distance_y_q==bar_peak) frequency_color=24'hf5e6a8;
    end
    assign rgb=glyph_q&&font_q[15-col_q] ? 24'hd9e9f2:
        field_q&&phase_dot ? 24'h64e5d1:frequency_q ? frequency_color:color_q;
endmodule
