`timescale 1ns/1ps
// One cheap shared pipeline, before captions/menu/sidebar composition.
module image_filter(
    input wire clk,rst_n,
    input wire [1:0] mode,
    input wire [23:0] rgb_in,
    input wire de,hs,vs,input wire [10:0] x,input wire [9:0] y,
    output reg [23:0] rgb_out,
    output reg de_q,hs_q,vs_q,output reg [10:0] x_q,output reg [9:0] y_q
);
    wire [7:0] r=rgb_in[23:16],g=rgb_in[15:8],b=rgb_in[7:0];
    wire [9:0] gray_sum={2'd0,r}+{1'b0,g,1'b0}+{2'd0,b}+10'd2;
    wire [8:0] warm_r={1'b0,r}+{4'd0,r[7:3]};
    wire [7:0] warm_b=b-{3'd0,b[7:3]};
    wire [23:0] filtered=mode==1 ? {3{gray_sum[9:2]}}:
        mode==2 ? {warm_r[8] ? 8'hff:warm_r[7:0],g,warm_b}:rgb_in;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin rgb_out<=0;de_q<=0;hs_q<=0;vs_q<=0;x_q<=0;y_q<=0;end
        else begin
            rgb_out<=x<960 ? filtered:rgb_in;
            de_q<=de;hs_q<=hs;vs_q<=vs;x_q<=x;y_q<=y;
        end
    end
endmodule
