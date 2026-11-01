`timescale 1ns/1ps
module tb_alarm_control;
 reg clk=0,rst=0,reed=0,knob=0,joy=0;always #12.5 clk=~clk;
 wire active,muted,blocked,tick,silence,buzzer;
 exhibit_alarm_control #(.CLK_HZ(40000),.STARTUP_MS(4),.LEAVE_MS(3),.RETURN_MS(5)) dut(
  .clk_sys(clk),.rst_alarm_n(rst),.reed_async(reed),.knob_press(knob),.joystick_press(joy),
  .alarm_active(active),.silenced(muted),.controls_block(blocked),.silence_pulse(silence),.tick_ms(tick));
 alarm_buzzer #(.CLK_HZ(40000),.TONE_HZ(1000),.PERIOD_MS(8),.ON_MS(3)) sound(
  .clk_sys(clk),.rst_alarm_n(rst),.tick_ms(tick),.sound_enable(blocked),.buzzer_n(buzzer));
 task cycles(input integer n);repeat(n)@(negedge clk);endtask
 task check(input bit condition,input string what);if(!condition)$fatal(1,"%s",what);endtask
 integer low_count=0,high_count=0;
 initial begin
  $dumpfile("alarm_control.vcd");$dumpvars(0,tb_alarm_control);
  cycles(4);check(buzzer===1,"Reset must silence buzzer");rst=1;
  cycles(200);check(!active,"Present at boot");
  reed=1;cycles(40);reed=0;cycles(200);check(!active,"Short bounce must not trip");
  reed=1;cycles(200);check(active&&blocked&&!muted,"Persistent absence must trip");
  repeat(400)begin @(negedge clk);if(buzzer)high_count++;else low_count++;end
  check(low_count>0&&high_count>0,"Audible tone and silent envelope required");
  knob=1;cycles(1);check(active&&muted&&!blocked&&silence,"Knob silences only sound");knob=0;
  cycles(200);check(active&&muted&&buzzer,"Persistent warning after mute");
  reed=0;cycles(80);reed=1;cycles(200);check(active&&muted,"Short return must not rearm");
  reed=0;cycles(280);check(!active&&!muted&&!blocked,"Stable return clears and rearms");
  reed=1;cycles(200);check(active&&blocked&&!muted,"Second removal must sound again");
  joy=1;cycles(1);check(active&&muted&&!blocked&&silence,"Joystick silences");joy=0;
  // Reset while absent must not leave the installation permanently disarmed.
  rst=0;cycles(4);rst=1;cycles(80);check(!active,"Startup guard");
  cycles(200);check(active&&blocked,"Absent at startup must alarm after guard");
  rst=0;#1;check(buzzer,"Async reset drives buzzer inactive");
  $display("PASS: debounce, startup absence, two mute sources, persistent warning, return hysteresis, rearm, buzzer fail-safe");$finish;
 end
 initial begin #500000;$fatal(1,"Alarm controller timeout");end
endmodule
