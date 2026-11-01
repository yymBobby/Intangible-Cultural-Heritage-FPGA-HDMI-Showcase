`timescale 1ns/1ps
// One outstanding SYS->PIX transaction. Reset both domains coherently.
// The brightness/subtitle bundle stays held until the returned acknowledgement; only
// an empty vertical-blank pipeline may change the applied pixel gain.
module video_brightness #(parameter integer ENABLE_ALARM=0) (
    input wire alarm_ink_pix,
    input wire subtitle_valid_sys,subtitle_enable_sys,
    output wire subtitle_ready_sys,
    output reg subtitle_applied_sys,subtitle_actual_sys,
    output reg subtitle_enable_pix,
    input wire clk_sys,rst_sys_n,request_valid_sys,
    output wire request_ready_sys,
    input wire [1:0] request_level_sys,
    output reg applied_pulse_sys,
    output reg [1:0] actual_level_sys,
    input wire clk_pix,rst_pix_n,apply_safe_pix,
    input wire [23:0] rgb_in,
    output reg [23:0] rgb_out,
    output reg [1:0] level_pix
);
    reg [1:0] level_hold_sys;
    reg subtitle_hold_sys,subtitle_operation_sys;
    reg request_toggle_sys,inflight_sys;
    reg ack_toggle_pix;
    (* async_reg="true" *) reg request_meta_pix,request_sync_pix;
    (* async_reg="true" *) reg ack_meta_sys,ack_sync_sys;
    assign subtitle_ready_sys=!inflight_sys && !request_valid_sys && rst_sys_n;
    assign request_ready_sys=!inflight_sys && rst_sys_n;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            level_hold_sys<=3;request_toggle_sys<=0;inflight_sys<=0;
            subtitle_hold_sys<=1;subtitle_operation_sys<=0;subtitle_applied_sys<=0;subtitle_actual_sys<=1;
            ack_meta_sys<=0;ack_sync_sys<=0;actual_level_sys<=3;applied_pulse_sys<=0;
        end else begin
            ack_meta_sys<=ack_toggle_pix;ack_sync_sys<=ack_meta_sys;
            applied_pulse_sys<=0;subtitle_applied_sys<=0;
            if(request_valid_sys && request_ready_sys) begin
                level_hold_sys<=request_level_sys;subtitle_hold_sys<=subtitle_actual_sys;subtitle_operation_sys<=0;
                request_toggle_sys<=!request_toggle_sys;inflight_sys<=1;
            end else if(subtitle_valid_sys && subtitle_ready_sys) begin
                level_hold_sys<=actual_level_sys;subtitle_hold_sys<=subtitle_enable_sys;subtitle_operation_sys<=1;
                request_toggle_sys<=!request_toggle_sys;inflight_sys<=1;
            end
            if(inflight_sys && ack_sync_sys==request_toggle_sys) begin
                actual_level_sys<=level_hold_sys;
                subtitle_actual_sys<=subtitle_hold_sys;
                applied_pulse_sys<=!subtitle_operation_sys;subtitle_applied_sys<=subtitle_operation_sys;inflight_sys<=0;
            end
        end
    end
    function [7:0] gain;
        input [7:0] channel;
        input [1:0] level;
        begin
            case(level)
                0:gain={2'b00,channel[7:2]};
                1:gain={1'b0,channel[7:1]};
                2:gain=channel-{2'b00,channel[7:2]}; // ceil(3*C/4)
                3:gain=channel;
            endcase
        end
    endfunction
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin
            request_meta_pix<=0;request_sync_pix<=0;ack_toggle_pix<=0;
            level_pix<=3;subtitle_enable_pix<=1;rgb_out<=0;
        end else begin
            request_meta_pix<=request_toggle_sys;request_sync_pix<=request_meta_pix;
            if(apply_safe_pix && request_sync_pix!=ack_toggle_pix) begin
                level_pix<=level_hold_sys;subtitle_enable_pix<=subtitle_hold_sys;ack_toggle_pix<=request_sync_pix;
            end
            rgb_out<=ENABLE_ALARM && alarm_ink_pix ? 24'hf4e9d4:
                {gain(rgb_in[23:16],level_pix),gain(rgb_in[15:8],level_pix),gain(rgb_in[7:0],level_pix)};
        end
    end
endmodule
