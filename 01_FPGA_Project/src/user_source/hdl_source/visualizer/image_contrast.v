`timescale 1ns/1ps
// Two pixel stages, no multiplier or frame storage. Levels: 75/100/125/150%.
// round-to-nearest (ties towards +infinity), then saturate to RGB888.
module image_contrast(
    input wire clk,rst_n,
    input wire [1:0] level,
    input wire [23:0] rgb_in,
    input wire de,hs,vs,input wire [10:0] x,input wire [9:0] y,
    output reg [23:0] rgb_out,
    output reg de_q,hs_q,vs_q,output reg [10:0] x_q,output reg [9:0] y_q,
    output wire pipeline_idle
);
    reg signed [11:0] weighted[0:2];
    reg [23:0] bypass;
    reg picture;
    reg de_s,hs_s,vs_s;
    reg [10:0] x_s;reg [9:0] y_s;
    function signed [11:0] numerator;
        input [7:0] channel;input [1:0] gain;
        reg signed [11:0] base,delta;
        begin
            base=$signed({2'b00,channel,2'b00});
            delta=$signed({4'b0000,channel})-12'sd128;
            case(gain)
                0:numerator=base-delta+12'sd2;
                1:numerator=base+12'sd2;
                2:numerator=base+delta+12'sd2;
                3:numerator=base+(delta<<<1)+12'sd2;
            endcase
        end
    endfunction
    function [7:0] clip;
        input signed [11:0] value;
        begin
            if(value<0)clip=0;
            else if(value>=12'sd1024)clip=255;
            else clip=value[9:2];
        end
    endfunction
    integer c;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            for(c=0;c<3;c=c+1)weighted[c]<=0;
            bypass<=0;picture<=0;de_s<=0;hs_s<=0;vs_s<=0;x_s<=0;y_s<=0;
            rgb_out<=0;de_q<=0;hs_q<=0;vs_q<=0;x_q<=0;y_q<=0;
        end else begin
            for(c=0;c<3;c=c+1)begin
                weighted[c]<=numerator(rgb_in[c*8+:8],level);
                rgb_out[c*8+:8]<=picture ? clip(weighted[c]):bypass[c*8+:8];
            end
            bypass<=rgb_in;picture<=x<960;
            de_s<=de;hs_s<=hs;vs_s<=vs;x_s<=x;y_s<=y;
            de_q<=de_s;hs_q<=hs_s;vs_q<=vs_s;x_q<=x_s;y_q<=y_s;
        end
    end
    assign pipeline_idle=!de_s && !de_q;
endmodule
