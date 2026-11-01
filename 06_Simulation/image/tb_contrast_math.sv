`timescale 1ns/1ps
module tb_contrast_math;
 reg clk=0,rst_n=0;always #6.666667 clk=~clk;
 reg [1:0] level=1;reg [23:0] rgb_in=0;
 reg de=0,hs=0,vs=0;reg [10:0] x=0;reg [9:0] y=0;
 wire [23:0] rgb_out;wire de_q,hs_q,vs_q,idle;wire [10:0] x_q;wire [9:0] y_q;
 image_contrast dut(.*,.pipeline_idle(idle));
 reg [23:0] expected,previous_rgb;reg previous_de,previous_hs,previous_vs;
 reg [10:0] previous_x;reg [9:0] previous_y;
 bit previous_valid=0;integer checks=0,csv,serial=0,previous_level=1,previous_input_r=0;
 function automatic [7:0] reference(input integer c,l);
  integer value,coefficient;
  begin
   case(l)0:coefficient=3;1:coefficient=4;2:coefficient=5;3:coefficient=6;endcase
   // Independent centered contrast formula, rounded once before clamping.
   value=512+(c-128)*coefficient+2;
   value=value<0 ? 0:value/4;
   reference=value>255 ? 255:value;
  end
 endfunction
 task sample(input integer gain,xx,yy,input [23:0] color,input bit valid);
  begin
   @(negedge clk);level=gain;rgb_in=color;x=xx;y=yy;de=valid;hs=serial[0];vs=serial[3];
   expected=xx<960 ? {reference(color[23:16],gain),reference(color[15:8],gain),reference(color[7:0],gain)}:color;
   @(posedge clk);#1;
   if(previous_valid)begin
    checks++;
    if({rgb_out,de_q,hs_q,vs_q,x_q,y_q}!=={previous_rgb,previous_de,previous_hs,previous_vs,previous_x,previous_y})
     $fatal(1,"contrast/latency x=%0d got=%h expected=%h",previous_x,rgb_out,previous_rgb);
    $fwrite(csv,"%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",serial,previous_level,previous_input_r,rgb_out[23:16],previous_rgb[23:16],de_q,x_q);
   end
   previous_rgb=expected;previous_de=de;previous_hs=hs;previous_vs=vs;previous_x=x;previous_y=y;
   previous_valid=1;previous_level=gain;previous_input_r=color[23:16];serial++;
  end
 endtask
 initial begin
  $dumpfile("contrast_math.vcd");$dumpvars(0,tb_contrast_math);
  csv=$fopen("contrast_samples.csv","w");$fwrite(csv,"sample,level,input_r,output_r,expected_r,de,x\n");
  repeat(3)@(negedge clk);rst_n=1;
  for(integer l=0;l<4;l++)for(integer c=0;c<256;c++)begin
   sample(l,959,c,{c[7:0],8'd255-c[7:0],c[7:0]^8'ha5},c%7!=0);
   sample(l,960,c,{c[7:0],8'd255-c[7:0],c[7:0]^8'ha5},1);
   sample(l,1279,c,{c[7:0],8'd255-c[7:0],c[7:0]^8'ha5},1);
  end
  for(integer l=0;l<4;l++)begin
   sample(l,0,0,24'h000000,1);sample(l,1,0,24'h808080,1);sample(l,2,0,24'hffffff,1);
  end
  for(integer k=0;k<500;k++)sample(k%4,k%1280,k%720,$random,k%3!=0);
  sample(1,0,0,0,0);sample(1,0,0,0,0);
  if(!idle)$fatal(1,"contrast pipeline did not drain");
  @(negedge clk);rst_n=0;#1;if(rgb_out!==0||de_q!==0||!idle)$fatal(1,"Reset did not clear pipeline");
  $fclose(csv);
  $display("PASS: contrast checks=%0d, all 256 RGB values x four gains; saturation/rounding/100%% identity, sidebar boundaries, sync, bubbles, rapid gain changes/reset",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"Contrast math timeout");end
endmodule
