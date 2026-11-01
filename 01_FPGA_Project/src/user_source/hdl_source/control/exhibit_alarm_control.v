`timescale 1ns/1ps
// Persistent exhibit status. Business recovery is deliberately not a reset.
module exhibit_alarm_control #(
    parameter integer CLK_HZ=40000000,
    parameter integer STARTUP_MS=1000,
    parameter integer LEAVE_MS=100,
    parameter integer RETURN_MS=500,
    parameter PRESENT_LEVEL=1'b0
)(
    input wire clk_sys,rst_alarm_n,reed_async,knob_press,joystick_press,
    output reg alarm_active,silenced,
    output wire controls_block,tick_ms,
    output reg silence_pulse
);
    localparam integer DIV=CLK_HZ/1000<1 ? 1:CLK_HZ/1000;
    localparam integer DW=DIV<2 ? 1:$clog2(DIV);
    localparam integer MAX_MS=LEAVE_MS>RETURN_MS ? LEAVE_MS:RETURN_MS;
    localparam integer SW=MAX_MS<2 ? 1:$clog2(MAX_MS+1);
    localparam integer IW=STARTUP_MS<2 ? 1:$clog2(STARTUP_MS+1);
    reg [DW-1:0] divider;
    reg [SW-1:0] stable_ms;
    reg [IW-1:0] startup_ms;
    reg candidate_absent,startup_done;
    (* async_reg="true" *) reg reed_meta,reed_sync;
    wire absent=reed_sync!=PRESENT_LEVEL;
    assign tick_ms=divider==DIV-1;
    assign controls_block=alarm_active && !silenced;
    always @(posedge clk_sys or negedge rst_alarm_n) begin
        if(!rst_alarm_n) begin
            divider<=0;stable_ms<=0;startup_ms<=0;startup_done<=0;
            candidate_absent<=0;reed_meta<=PRESENT_LEVEL;reed_sync<=PRESENT_LEVEL;
            alarm_active<=0;silenced<=0;silence_pulse<=0;
        end else begin
            reed_meta<=reed_async;reed_sync<=reed_meta;
            divider<=tick_ms ? 0:divider+1'b1;
            silence_pulse<=0;
            if(tick_ms) begin
                if(absent!=candidate_absent) begin candidate_absent<=absent;stable_ms<=1;end
                else if(stable_ms<MAX_MS)stable_ms<=stable_ms+1'b1;
                if(!startup_done) begin
                    if(STARTUP_MS<=1 || startup_ms==STARTUP_MS-1)startup_done<=1;
                    else startup_ms<=startup_ms+1'b1;
                end
            end
            // A fresh trip wins over a coincident click; an old held button
            // cannot acknowledge a new incident (contacts produce press pulses).
            if(tick_ms && startup_done && absent && candidate_absent && stable_ms>=LEAVE_MS-1 && !alarm_active) begin
                alarm_active<=1;silenced<=0;
            end else if(tick_ms && alarm_active && !absent && !candidate_absent && stable_ms>=RETURN_MS-1) begin
                alarm_active<=0;silenced<=0;
            end else if(controls_block && (knob_press || joystick_press)) begin
                silenced<=1;silence_pulse<=1;
            end
        end
    end
endmodule
