`timescale 1ns/1ps
module tb_alarm_osd;
 reg clk=0,rst=0,alarm=1;always #6.666667 clk=~clk;
 reg [67:0] snapshot=0;reg [10:0] x=0;reg [9:0] y=0;reg [23:0] base=24'h80c0f0;
 wire req,panel_cover,ink,alarm_cover,ode,ohs,ovs,idle;wire [12:0] addr;wire [31:0] row;wire [23:0] rgb,final_rgb;
 osd_menu_layer #(.ENABLE_ALARM(1)) dut(.alarm_active_pix(alarm),.alarm_cover_out(alarm_cover),.alarm_ink_out(ink),
  .clk_pix(clk),.rst_pix_n(rst),.snapshot_pix(snapshot),.x_in(x),.y_in(y),.rgb_in(base),.de_in(1'b1),.hs_in(1'b0),.vs_in(1'b0),
  .font_req(req),.font_addr(addr),.font_row(row),.rgb_out(rgb),.de_out(ode),.hs_out(ohs),.vs_out(ovs),.cover_out(panel_cover),.pipeline_idle(idle));
 OSD_FONT_ROM font(.clka(clk),.addra(addr),.doa(row));
 defparam font.inst.memory.INIT_FILE="../../tools/font_rom/release_alarm_192/font_rom_16.mif";
 video_brightness #(.ENABLE_ALARM(1)) brightness(.alarm_ink_pix(ink),.clk_sys(clk),.rst_sys_n(rst),.request_valid_sys(1'b0),
  .request_ready_sys(),.request_level_sys(2'd0),.applied_pulse_sys(),.actual_level_sys(),
  .subtitle_valid_sys(1'b0),.subtitle_enable_sys(1'b0),.subtitle_ready_sys(),.subtitle_applied_sys(),.subtitle_actual_sys(),
  .subtitle_enable_pix(),.clk_pix(clk),.rst_pix_n(rst),.apply_safe_pix(1'b0),.rgb_in(rgb),.rgb_out(final_rgb),.level_pix());
 reg [31:0] golden[0:6143];
 `include "alarm_text_lut.vh"
 integer count=0,fg_count=0,bg_count=0,icon_count=0,glyph,rr,cc;reg expect_ink;reg [23:0] expected,mixed;
 task settle;repeat(8)@(negedge clk);endtask
 function [23:0] half(input [23:0] p);
  integer a,b,c;begin a=p[23:16]+8'h64;b=p[15:8]+8'h1d;c=p[7:0]+8'h26;half={8'(a/2),8'(b/2),8'(c/2)};end
 endfunction
 initial begin
  $readmemh("../../tools/font_rom/release_alarm_192/font_rom.hex",golden);
  $dumpfile("alarm_osd.vcd");$dumpvars(1,tb_alarm_osd);$dumpoff;
  settle;rst=1;force brightness.level_pix=0;
  // Exercise every pixel of the banner through the actual physical MIF ROM.
  for(integer yy=0;yy<112;yy++)for(integer xx=0;xx<960;xx++)begin
   x=xx;y=yy;base={xx[7:0],yy[7:0],8'hff};settle;expect_ink=0;
   if(xx>=24&&xx<88&&yy>=24&&yy<88)begin
    rr=(yy-24)/2;cc=(xx-24)/2;expect_ink=golden[ALARM_ICON_GLYPH*32+rr][31-cc];if(expect_ink)icon_count++;
   end else if(xx>=128&&xx<256&&yy>=40&&yy<72)begin
    glyph=ALARM_TEXT_WORD[((xx-128)/32)*8+:8];
    if(glyph!=0)expect_ink=golden[glyph*32+yy-40][31-((xx-128)%32)];
   end
   mixed=half(base);expected=expect_ink ? 24'hf4e9d4:mixed;
   if(!alarm_cover||ink!==expect_ink||rgb!==expected)$fatal(1,"Banner pixel x=%0d y=%0d got=%h want=%h ink=%b/%b",xx,yy,rgb,expected,ink,expect_ink);
   expected=expect_ink ? 24'hf4e9d4:{2'b0,mixed[23:18],2'b0,mixed[15:10],2'b0,mixed[7:2]};
   if(final_rgb!==expected)$fatal(1,"25 percent brightness must preserve alarm foreground");
   count++;if(expect_ink)fg_count++;else bg_count++;
  end
  for(integer yy=0;yy<112;yy++)begin x=960;y=yy;settle;if(alarm_cover||ink)$fatal(1,"Alarm leaked into sidebar");end
  x=0;y=112;settle;if(alarm_cover)$fatal(1,"Banner lower boundary");
  alarm=0;x=128;y=40;settle;if(alarm_cover||ink||rgb!==base)$fatal(1,"Alarm disabled pass-through");
  if(icon_count<100||fg_count<1000||bg_count<50000)$fatal(1,"Empty icon/text");
  $display("PASS: %0d banner pixels, exact RGB half blend, 32px text, 64px icon, bright foreground at 25 percent gain, sidebar boundary; fg=%0d bg=%0d icon=%0d",count,fg_count,bg_count,icon_count);$finish;
 end
 initial begin #30000000;$fatal(1,"Alarm OSD timeout");end
endmodule
