`timescale 1ns/1ps
// Active-low buttons: KEY1 next theme, KEY2 automatic playback toggle.
// Each button needs a stable 20 ms level. One pending event per button;
// separate simultaneous presses are delivered in order and held through stall.
module theme_key_control #(parameter integer DEBOUNCE_CYCLES=2000000)(
    input wire clk_sys, rst_sys_n, key_next_n, key_auto_n, key_pause_n,
    input wire restore_defaults,
    output reg playback_paused,
    output wire ctl_valid,
    input wire ctl_ready,
    output wire [1:0] ctl_op,
    output wire [7:0] ctl_theme_id
);
    localparam integer LIMIT=DEBOUNCE_CYCLES<1 ? 1:DEBOUNCE_CYCLES;
    localparam integer CW=LIMIT<=1 ? 1:$clog2(LIMIT);
    (* async_reg="true" *) reg [1:0] next_sync, auto_sync, pause_sync;
    reg next_stable,auto_stable,next_pending,auto_pending,pause_stable;
    reg [CW-1:0] next_count,auto_count,pause_count;
    wire next_press=!next_sync[1] && next_stable && next_count==LIMIT-1;
    wire auto_press=!auto_sync[1] && auto_stable && auto_count==LIMIT-1;
    wire pause_press=!pause_sync[1] && pause_stable && pause_count==LIMIT-1;
    // Pause is independent of the catalogue-command handshake. Long holds
    // toggle once; switch commands preserve the requested pause state.
    // Lock a published command until acceptance, even if another key arrives.
    reg cmd_valid;reg [1:0] cmd_op;
    assign ctl_valid=cmd_valid;
    assign ctl_op=cmd_op;
    assign ctl_theme_id=8'd0;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            next_sync<=2'b11;auto_sync<=2'b11;pause_sync<=2'b11;pause_stable<=1;pause_count<=0;playback_paused<=0;
            next_stable<=1;auto_stable<=1;next_count<=0;auto_count<=0;
            next_pending<=0;auto_pending<=0;cmd_valid<=0;cmd_op<=0;
        end else begin
            next_sync<={next_sync[0],key_next_n};auto_sync<={auto_sync[0],key_auto_n};
            pause_sync<={pause_sync[0],key_pause_n};
            if(pause_sync[1]==pause_stable) pause_count<=0;
            else if(pause_count==LIMIT-1) begin pause_stable<=pause_sync[1];pause_count<=0;end
            else pause_count<=pause_count+1'b1;
            if(restore_defaults) playback_paused<=0;
            else if(pause_press) playback_paused<=!playback_paused;
            if(next_sync[1]==next_stable) next_count<=0;
            else if(next_count==LIMIT-1) begin next_stable<=next_sync[1];next_count<=0;end
            else next_count<=next_count+1'b1;
            if(auto_sync[1]==auto_stable) auto_count<=0;
            else if(auto_count==LIMIT-1) begin auto_stable<=auto_sync[1];auto_count<=0;end
            else auto_count<=auto_count+1'b1;
            if(cmd_valid) begin if(ctl_ready)cmd_valid<=0;end
            else if(next_pending) begin cmd_valid<=1;cmd_op<=1;next_pending<=0;end
            else if(auto_pending) begin cmd_valid<=1;cmd_op<=3;auto_pending<=0;end
            // Set wins over dequeue: a fresh press is retained as a new event.
            if(next_press)next_pending<=1;
            if(auto_press)auto_pending<=1;
        end
    end
endmodule
