`timescale 1ns/1ps
// Millisecond envelope plus a clock-enable tone divider; no generated clocks.
module alarm_buzzer #(
    parameter integer CLK_HZ=40000000,TONE_HZ=2000,
    parameter integer PERIOD_MS=1000,ON_MS=200,
    parameter integer ACTIVE_BUZZER=0
)(
    input wire clk_sys,rst_alarm_n,tick_ms,sound_enable,
    output wire buzzer_n
);
    localparam integer HALF=CLK_HZ/(2*TONE_HZ)<1 ? 1:CLK_HZ/(2*TONE_HZ);
    localparam integer TW=HALF<2 ? 1:$clog2(HALF);
    localparam integer EW=PERIOD_MS<2 ? 1:$clog2(PERIOD_MS);
    reg [TW-1:0] tone_count;
    reg [EW-1:0] envelope_ms;
    reg tone;
    wire window_on=sound_enable && envelope_ms<ON_MS;
    assign buzzer_n=!(rst_alarm_n && window_on && (ACTIVE_BUZZER!=0 || tone));
    always @(posedge clk_sys or negedge rst_alarm_n) begin
        if(!rst_alarm_n) begin tone_count<=0;tone<=0;envelope_ms<=0;end
        else begin
            if(!sound_enable)envelope_ms<=0;
            else if(tick_ms)envelope_ms<=envelope_ms==PERIOD_MS-1 ? 0:envelope_ms+1'b1;
            if(!window_on)begin tone_count<=0;tone<=0;end
            else if(tone_count==HALF-1)begin tone_count<=0;tone<=!tone;end
            else tone_count<=tone_count+1'b1;
        end
    end
endmodule
