`timescale 1ns/1ps
module joystick_reset(input wire clk,reset_n,locked,output wire run_n);
    (* async_reg="true" *) reg [2:0] release_pipe;
    wire async_run_n=reset_n && locked;
    always @(posedge clk or negedge async_run_n)
        if(!async_run_n) release_pipe<=0;
        else release_pipe<={release_pipe[1:0],1'b1};
    assign run_n=release_pipe[2];
endmodule
