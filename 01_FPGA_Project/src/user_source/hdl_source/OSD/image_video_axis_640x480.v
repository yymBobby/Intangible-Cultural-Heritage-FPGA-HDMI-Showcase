`timescale 1ns/1ps
// Private endpoint of the NEW SDRAM integration; the original example's
// video_rgb_to_axis_640x480 is deliberately untouched. Always-accepting sink.
module image_video_axis_640x480 #(parameter integer HACTIVE=640) (
    input wire I_clk,I_rst,I_vs,I_de,
    input wire [23:0] I_rgb,
    output reg O_video_user,O_video_valid,O_video_last,
    output reg [23:0] O_video_data
);
    reg vs_d,de_d,frame_arm;
    reg [10:0] next_x;
    always @(posedge I_clk or posedge I_rst) begin
        if(I_rst) begin vs_d<=0;de_d<=0;frame_arm<=1;next_x<=0;
            O_video_user<=0;O_video_valid<=0;O_video_last<=0;O_video_data<=0;end
        else begin
            vs_d<=I_vs;de_d<=I_de;
            O_video_valid<=I_de;O_video_data<=I_rgb;O_video_user<=0;O_video_last<=0;
            if(vs_d!=I_vs) frame_arm<=1;
            if(I_de) begin
                if(!de_d) begin next_x<=1;
                    if(frame_arm) begin O_video_user<=1;frame_arm<=0;end
                end else begin next_x<=next_x+1'b1;O_video_last<=next_x==HACTIVE-1;end
            end else next_x<=0;
        end
    end
endmodule
