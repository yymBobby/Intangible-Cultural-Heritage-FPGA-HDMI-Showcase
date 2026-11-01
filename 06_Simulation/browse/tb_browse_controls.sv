`timescale 1ns/1ps
module tb_browse_controls;
 reg clk=0,rst=0,a=1,b=1,s=1,sw=0,up=0,down=0,left=0,right=0,joy=0;
 always #12.5 clk=~clk;
 wire [67:0] snap;wire cw,ccw,click,back,inputs_ready,invalid,confirm;
 wire next_image,prev_image,next_theme;
 board_menu_input #(.JOYSTICK_MODE(1),.AB_FILTER_CYCLES(2),.BUTTON_FILTER_CYCLES(2),.SW_FILTER_CYCLES(2)) dut(
  .clk_sys(clk),.rst_sys_n(rst),.encoder_a(a),.encoder_b(b),.encoder_s_n(s),.key_back_n(1'b1),.sw0_on(sw),
  .joy_up(up),.joy_down(down),.joy_left(left),.joy_right(right),.joy_click(joy),
  .menu_snapshot_sys(snap),.step_cw(cw),.step_ccw(ccw),.click_press(click),.back_press(back),
  .inputs_ready(inputs_ready),.invalid_transition(invalid),.confirm_pulse(confirm));
 board_browse_control route(.menu_open(snap[0]),.zoom_level(snap[23:22]),
  .encoder_next(ccw),.encoder_prev(cw),.encoder_click(click),.joy_left(left),.joy_right(right),
  .image_next(next_image),.image_prev(prev_image),.theme_next(next_theme));
 integer next_count=0,prev_count=0,theme_count=0,checks=0;
 always @(posedge clk) if(rst)begin
  next_count+=next_image;prev_count+=prev_image;theme_count+=next_theme;
  if(next_image&&prev_image)$fatal(1,"Opposite picture commands overlapped");
  if(snap[0]&&(next_image||prev_image||next_theme))$fatal(1,"Menu navigation escaped to media");
 end
 task tick(input integer n);repeat(n)@(negedge clk);endtask
 task check(input bit ok,input string why);begin checks++;if(!ok)$fatal(1,"%s counts=%0d/%0d/%0d snap=%h",why,next_count,prev_count,theme_count,snap);end endtask
 task press(input integer k);begin
  case(k)0:joy=1;1:right=1;2:up=1;3:down=1;4:left=1;endcase
  tick(1);joy=0;right=0;up=0;down=0;left=0;tick(3);
 end endtask
 task rotate(input bit forward);begin
  if(forward)begin {a,b}=2'b10;tick(10);{a,b}=0;tick(10);{a,b}=1;tick(10);end
  else begin {a,b}=1;tick(10);{a,b}=0;tick(10);{a,b}=2;tick(10);end
  {a,b}=3;tick(10);
 end endtask
 task click_encoder;begin s=0;tick(20);s=1;tick(20);end endtask
 integer before_next,before_prev;
 initial begin
  $dumpfile("browse_controls.vcd");$dumpvars(0,tb_browse_controls);
  tick(4);rst=1;tick(20);check(inputs_ready&&!snap[0],"reset browse mode");
  repeat(10)begin press(2);press(3);end
  check(theme_count==0&&next_count==0&&prev_count==0,"up/down never browse or change theme");
  press(1);press(4);check(next_count==1&&prev_count==1&&theme_count==0,"joystick right/left browse images");
  rotate(1);rotate(0);check(next_count==2&&prev_count==2,"physical knob direction preserved");
  click_encoder;check(theme_count==1,"only physical encoder click changes theme");
  press(0);check(snap[0],"joystick click opens menu");
  press(1);press(3);press(3);press(1);rotate(1);check(snap[23:22]==2,"menu enables 150 percent zoom");
  click_encoder;press(0);check(!snap[0],"close menu retaining zoom");
  before_next=next_count;before_prev=prev_count;
  press(1);check($signed(snap[57:48])==12,"zoomed right pans X");
  press(2);check($signed(snap[67:58])==12,"zoomed up pans Y");
  press(4);press(3);check(snap[67:48]==0,"opposite pan returns to centre");
  check(next_count==before_next&&prev_count==before_prev&&theme_count==1,"zoomed joystick never changes image/theme");
  rotate(1);rotate(0);check(next_count==before_next+1&&prev_count==before_prev+1,"encoder still browses while zoomed");
  click_encoder;check(theme_count==2,"encoder still changes theme while zoomed");
  left=1;right=1;tick(1);left=0;right=0;tick(2);
  check(next_count==before_next+1&&prev_count==before_prev+1,"opposite joystick inputs do not browse");
  $display("PASS: actual filtered encoder/menu UI, no up/down theme misfire, joystick browse vs zoom pan, menu isolation, checks=%0d",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"Browse controls watchdog");end
endmodule
