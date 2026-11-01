`timescale 1ns/1ps
// Exact endpoints, round-to-nearest, full RGB888 precision. Three dedicated
// Anlogic multipliers are shared by crossfade and fade-to/from-black.
module image_crossfade(
    input wire clk,rst_n,
    input wire [23:0] old_rgb,new_rgb,
    input wire [8:0] alpha,
    input wire de,hs,vs,
    input wire [10:0] x,input wire [9:0] y,
    output reg [23:0] rgb,
    output wire de_q,hs_q,vs_q,
    output wire [10:0] x_q,output wire [9:0] y_q
);
    reg [23:0] old1,old2,old3,new1;
    reg [8:0] alpha1;
    reg [3:0] de_pipe,hs_pipe,vs_pipe;
    reg [10:0] x_pipe[0:3];reg [9:0] y_pipe[0:3];
    wire [35:0] product[0:2];
    genvar c;
    generate for(c=0;c<3;c=c+1) begin: channel
        wire signed [8:0] delta=$signed({1'b0,new1[8*c+:8]})-$signed({1'b0,old1[8*c+:8]});
        EG_LOGIC_MULT #(.INPUT_WIDTH_A(18),.INPUT_WIDTH_B(18),.OUTPUT_WIDTH(36),
            .INPUTFORMAT("SIGNED"),.INPUTREGA("ENABLE"),.INPUTREGB("ENABLE"),
            .OUTPUTREG("ENABLE"),.IMPLEMENT("AUTO"),.SRMODE("ASYNC")) mult(
            .a({{9{delta[8]}},delta}),.b({9'd0,alpha1}),.p(product[c]),
            .cea(1'b1),.ceb(1'b1),.cepd(1'b1),.clk(clk),.rstan(rst_n),.rstbn(rst_n),.rstpdn(rst_n));
        wire signed [18:0] sum=$signed({3'd0,old3[8*c+:8],8'd0})+$signed(product[c][18:0])+19'sd128;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin rgb[8*c+:8]<=0;end
            else begin
                rgb[8*c+:8]<=sum[15:8];
            end
        end
    end endgenerate
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            old1<=0;old2<=0;old3<=0;new1<=0;alpha1<=0;de_pipe<=0;hs_pipe<=0;vs_pipe<=0;
            for(k=0;k<4;k=k+1) begin x_pipe[k]<=0;y_pipe[k]<=0;end
        end else begin
            old1<=old_rgb;old2<=old1;old3<=old2;new1<=new_rgb;alpha1<=alpha>256 ? 9'd256:alpha;
            de_pipe<={de_pipe[2:0],de};hs_pipe<={hs_pipe[2:0],hs};vs_pipe<={vs_pipe[2:0],vs};
            x_pipe[0]<=x;x_pipe[1]<=x_pipe[0];x_pipe[2]<=x_pipe[1];x_pipe[3]<=x_pipe[2];
            y_pipe[0]<=y;y_pipe[1]<=y_pipe[0];y_pipe[2]<=y_pipe[1];y_pipe[3]<=y_pipe[2];
        end
    end
    assign de_q=de_pipe[3];assign hs_q=hs_pipe[3];assign vs_q=vs_pipe[3];
    assign x_q=x_pipe[3];assign y_q=y_pipe[3];
endmodule
