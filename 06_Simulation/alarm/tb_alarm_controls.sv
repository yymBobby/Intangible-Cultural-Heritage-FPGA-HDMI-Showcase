`timescale 1ns/1ps
module tb_alarm_controls;
 reg clk=0,rst=0,reed=0,sw=0,a=1,b=1,sn=1,ju=0,jd=0,jl=0,jr=0,jc=0;
 always #12.5 clk=~clk;
 wire active,muted,block,silence,tick,cw,ccw,click,back,ready,invalid,confirm;
 wire inhibit=block||silence;
 wire [67:0] snapshot;
 board_menu_input #(.JOYSTICK_MODE(1),.ENABLE_ALARM_INPUT(1),.AB_FILTER_CYCLES(2),.BUTTON_FILTER_CYCLES(2),.SW_FILTER_CYCLES(2)) board(
  .alarm_inhibit(inhibit),.clk_sys(clk),.rst_sys_n(rst),.encoder_a(a),.encoder_b(b),.encoder_s_n(sn),.key_back_n(1'b1),.sw0_on(sw),
  .joy_up(ju),.joy_down(jd),.joy_left(jl),.joy_right(jr),.joy_click(jc),.menu_snapshot_sys(snapshot),
  .step_cw(cw),.step_ccw(ccw),.click_press(click),.back_press(back),.inputs_ready(ready),.invalid_transition(invalid),.confirm_pulse(confirm));
 exhibit_alarm_control #(.CLK_HZ(40000),.STARTUP_MS(3),.LEAVE_MS(2),.RETURN_MS(4)) alarm(
  .clk_sys(clk),.rst_alarm_n(rst),.reed_async(reed),.knob_press(click),.joystick_press(jc),
  .alarm_active(active),.silenced(muted),.controls_block(block),.silence_pulse(silence),.tick_ms(tick));
 wire next_raw,prev_raw,theme_raw;
 board_browse_control browse(.menu_open(snapshot[0]),.zoom_level(snapshot[23:22]),
  .encoder_next(ccw),.encoder_prev(cw),.encoder_click(click),.joy_left(jl),.joy_right(jr),
  .image_next(next_raw),.image_prev(prev_raw),.theme_next(theme_raw));
 integer themes=0,images=0;
 always @(posedge clk)if(rst&&!inhibit)begin
  if(theme_raw)themes++;if(next_raw||prev_raw)images++;
 end
 task wait_cycles(input integer n);repeat(n)@(negedge clk);endtask
 task ck(input bit c,input string t);if(!c)$fatal(1,"%s",t);endtask
 task knob_click;sn=0;wait_cycles(18);sn=1;wait_cycles(18);endtask
 task joy_click;jc=1;wait_cycles(1);jc=0;wait_cycles(3);endtask
 task right;jr=1;wait_cycles(1);jr=0;wait_cycles(3);endtask
 reg [67:0] held;integer before_theme,before_image;
 initial begin
  $dumpfile("alarm_controls.vcd");$dumpvars(0,tb_alarm_controls);
  wait_cycles(4);rst=1;wait_cycles(180);ck(ready&&!snapshot[0],"Initial input ready");
  reed=1;wait_cycles(150);ck(block,"Trip");held=snapshot;
  sw=1;wait_cycles(15);right;ju=1;wait_cycles(1);ju=0;wait_cycles(2);
  ck(snapshot===held&&images==0&&themes==0,"Blocked menu/browse changes must be discarded");
  knob_click;ck(active&&muted&&!block,"Knob mute");
  ck(snapshot===held&&themes==0,"Mute press must not select theme or replay SW0");
  knob_click;ck(themes==1&&active,"Fresh knob click resumes theme switching while warning remains");
  before_image=images;right;ck(images==before_image+1,"Images resume after mute");
  joy_click;ck(snapshot[0]&&active,"Menu opens after mute with active warning");
  right;ck(snapshot[1],"Menu navigation after mute");
  // Preserve an open menu through another incident and consume joystick mute.
  reed=0;wait_cycles(230);ck(!active,"Return");reed=1;wait_cycles(150);ck(block,"Retrip");
  held=snapshot;joy_click;ck(active&&muted&&snapshot===held,"Joystick mute must not close or confirm menu");
  jl=1;wait_cycles(1);jl=0;wait_cycles(3);ck(!snapshot[1]&&snapshot[0],"Menu back works after joystick mute");
  $display("PASS: actual debounced encoder + joystick mute consumed, SW0 not replayed, menu/image/theme controls resume while warning persists");$finish;
 end
 initial begin #200000;$fatal(1,"Alarm controls timeout");end
endmodule
