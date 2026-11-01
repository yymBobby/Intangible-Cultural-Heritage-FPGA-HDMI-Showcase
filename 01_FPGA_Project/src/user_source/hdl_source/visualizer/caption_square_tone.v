`timescale 1ns/1ps
// 1 kHz square pulse, 10 ms with 32-sample attack/release, PCM16/48 kHz.
// Peak 8192/32768 = -12.04 dBFS; power-of-two gain needs no multiplier.
// Counts advance on valid stereo samples, not PIX clocks. Adds no DSP or RAM.
module caption_square_tone(
    input wire clk,rst_n,glyph_toggle_pix,enabled_sys,
    input wire valid_in,
    input wire [23:0] left_in,right_in,
    output reg valid_out,
    output reg [23:0] left_out,right_out
);
    (* ASYNC_REG="TRUE" *) reg enabled_meta_pix,enabled_sync_pix;
    reg glyph_seen,polarity;
    reg [9:0] remaining;
    reg [4:0] half_period;
    wire [5:0] ramp=remaining>448 ? 10'd480-remaining:remaining<32 ? remaining:6'd32;
    // Gain is an exact multiple of 256. The PCM low byte cannot carry;
    // saturate a signed nine-bit HIGH-byte sum instead of two 17-bit adders.
    wire signed [8:0] amplitude=$signed({3'd0,ramp});
    wire signed [8:0] tone=remaining!=0 && enabled_sync_pix ? (polarity ? -amplitude:amplitude):9'sd0;
    wire signed [8:0] lsum=$signed({left_in[23],left_in[23:16]})+tone;
    wire signed [8:0] rsum=$signed({right_in[23],right_in[23:16]})+tone;
    function [15:0] clamp(input signed [8:0] value,input [7:0] low_byte);
        begin clamp=value[8:7]==2'b01 ? 16'h7fff:value[8:7]==2'b10 ? 16'h8000:{value[7:0],low_byte};end
    endfunction
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            enabled_meta_pix<=0;enabled_sync_pix<=0;glyph_seen<=0;polarity<=0;remaining<=0;half_period<=0;
            valid_out<=0;left_out<=0;right_out<=0;
        end else begin
            enabled_meta_pix<=enabled_sys;enabled_sync_pix<=enabled_meta_pix;
            glyph_seen<=glyph_toggle_pix;valid_out<=valid_in;
            if(valid_in) begin left_out<={clamp(lsum,left_in[15:8]),left_in[7:0]};right_out<={clamp(rsum,right_in[15:8]),right_in[7:0]};end
            if(!enabled_sync_pix) begin remaining<=0;half_period<=0;polarity<=0;end
            else if(glyph_toggle_pix!=glyph_seen) begin remaining<=480;half_period<=0;polarity<=0;end
            else if(valid_in && remaining!=0) begin
                remaining<=remaining-1'b1;
                if(half_period==23) begin half_period<=0;polarity<=!polarity;end
                else half_period<=half_period+1'b1;
            end
        end
    end
endmodule
