`timescale 1ns/1ps
module tb_contrast_ui;
 reg clk_sys=0,rst_sys_n=0;always #12.5 clk_sys=~clk_sys;
 reg sw0_valid_sys=0,sw0_on_sys=0,step_cw_sys=0,step_ccw_sys=0,click_sys=0,back_sys=0;
 reg up_sys=0,down_sys=0,left_sys=0,right_sys=0,joy_click_sys=0;
 wire [67:0] snapshot_sys;wire ui_confirm_pulse_sys;
 menu_ui_state_v2 dut(.ui_inhibit_sys(1'b0),.*);
 integer checks=0;reg [67:0] held;
 task tick;@(negedge clk_sys);endtask
 task event_one(input integer key);
  begin
   tick();case(key)0:joy_click_sys=1;1:right_sys=1;2:left_sys=1;3:up_sys=1;4:down_sys=1;5:step_cw_sys=1;6:step_ccw_sys=1;7:click_sys=1;8:back_sys=1;endcase
   tick();joy_click_sys=0;right_sys=0;left_sys=0;up_sys=0;down_sys=0;step_cw_sys=0;step_ccw_sys=0;click_sys=0;back_sys=0;tick();
  end
 endtask
 task check(input bit pass,input string message);
  begin checks++;if(!pass)$fatal(1,"%s snapshot=%h",message,snapshot_sys);end
 endtask
 initial begin
  $dumpfile("contrast_ui.vcd");$dumpvars(0,tb_contrast_ui);
  repeat(3)tick();rst_sys_n=1;tick();check(snapshot_sys[46:45]==1,"Default 100 percent");
  event_one(0);event_one(1);event_one(4);event_one(1);
  check(snapshot_sys[6:4]==1&&snapshot_sys[8],"Contrast is second image item");
  event_one(5);check(snapshot_sys[46:45]==2,"CW 100 to 125");
  event_one(5);check(snapshot_sys[46:45]==3,"CW 125 to 150");
  held=snapshot_sys;repeat(12)event_one(5);check(snapshot_sys==held,"Maximum does not wrap or resubmit changes");
  event_one(6);check(snapshot_sys[46:45]==2,"Reverse immediately gives 125");
  event_one(5);check(snapshot_sys[46:45]==3,"CW returns to 150");
  repeat(3)event_one(6);check(snapshot_sys[46:45]==0,"CCW reaches 75");
  held=snapshot_sys;repeat(12)event_one(6);check(snapshot_sys==held,"Minimum does not wrap or resubmit changes");
  event_one(5);check(snapshot_sys[46:45]==1,"Reverse immediately gives 100");
  repeat(7)event_one(3);check(snapshot_sys[46:45]==3,"Joystick up saturates maximum too");
  repeat(7)event_one(4);check(snapshot_sys[46:45]==0,"Joystick down saturates minimum too");
  event_one(7);check(!snapshot_sys[8]&&snapshot_sys[46:45]==0,"Click accepts the chosen level");
  repeat(5)event_one(4);check(snapshot_sys[6:4]==6,"Seven image items reachable");
  event_one(1);check(!snapshot_sys[8],"Center remains an action");
  event_one(4);check(snapshot_sys[6:4]==0,"Item list still wraps");
  event_one(3);check(snapshot_sys[6:4]==6,"Reverse item-list wrap");
  event_one(2);event_one(4);event_one(4);event_one(1);event_one(1);event_one(4);event_one(1);
  check(snapshot_sys[46:45]==1&&snapshot_sys[44],"Restore resets contrast and publishes transaction");
  check(snapshot_sys[39:20]==20'h80003&&snapshot_sys[43:40]==4'b0111,"Other defaults preserved");
  $display("PASS: contrast UI checks=%0d; four levels, encoder/joystick endpoint saturation and immediate reversal, seven-item wrap, accept and restore",checks);$finish;
 end
 initial begin #200000;$fatal(1,"Contrast UI timeout");end
endmodule
