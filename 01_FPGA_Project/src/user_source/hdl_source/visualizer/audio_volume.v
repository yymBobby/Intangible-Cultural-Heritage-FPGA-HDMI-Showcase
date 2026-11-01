`timescale 1ns/1ps
// Whole-output PCM gain after music/caption mixing. Exact binary fractions;
// signed shifts/subtraction, no new RAM/DSP. Valid and stereo data move together.
module audio_volume(
    input wire clk_sys,rst_sys_n,input wire [1:0] level_sys,
    input wire clk_pix,rst_pix_n,valid_in,
    input wire [23:0] left_in,right_in,
    output reg valid_out,output reg [23:0] left_out,right_out
);
    wire [47:0] settings_pix;
    // Held-bundle handshake prevents torn multi-bit values across SYS/PIX.
    menu_snapshot_cdc #(.RESET_SNAPSHOT(48'd3)) gain_mailbox(
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.snapshot_sys({46'd0,level_sys}),
        .ready_sys(),.applied_sys(),.clk_pix(clk_pix),.rst_pix_n(rst_pix_n),
        .apply_safe_pix(1'b1),.snapshot_pix(settings_pix),.applied_pix());
    function [23:0] gain;
        input signed [23:0] sample;
        input [1:0] level;
        begin case(level)
            0:gain=sample>>>2;
            1:gain=sample>>>1;
            2:gain=sample-(sample>>>2);
            default:gain=sample;
        endcase end
    endfunction
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin valid_out<=0;left_out<=0;right_out<=0;end
        else begin
            valid_out<=valid_in;
            if(valid_in) begin
                left_out<=gain($signed(left_in),settings_pix[1:0]);
                right_out<=gain($signed(right_in),settings_pix[1:0]);
            end
        end
    end
endmodule
