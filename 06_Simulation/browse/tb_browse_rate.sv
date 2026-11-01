`timescale 1ns/1ps
module tb_browse_rate;
 reg clk=0,rst_n=0,push=0,start=0,finish=0,resume=0;reg [3:0] command=0;
 always #12.5 clk=~clk;
 wire ready,inflight,full,overflow;wire [3:0] head,count;
 browse_command_queue dut(.*);
 integer cycles=0,accepted=0,base,tests=0;
 always @(posedge clk)begin cycles=cycles+1;if(rst_n&&push&&ready)accepted=accepted+1;end
 task check(input bit ok,input string what);begin tests++;if(!ok)$fatal(1,"%s cycle=%0d count=%0d accepted=%0d",what,cycles,count,accepted);end endtask
 task event_at(input integer offset,input integer expected);
  begin
   while(cycles<base+offset-1)@(negedge clk);
   push=1;command=accepted;
   @(posedge clk);#1;check(accepted==expected,"exact 150ms acceptance boundary");
   @(negedge clk);push=0;
  end
 endtask
 initial begin
  $dumpfile("browse_rate.vcd");
  $dumpvars(0,push,ready,count,head,full,overflow,inflight,accepted,start,finish,resume);
  repeat(3)@(negedge clk);rst_n=1;push=1;
  @(posedge clk);#1;base=cycles;check(accepted==1,"first command is immediate");
  @(negedge clk);push=0;
  event_at(100,1);event_at(5999999,1);event_at(6000000,2);
  check($time>=150000000,"production 40MHz elapsed 150ms");
  check(count==2&&!overflow&&!full,"too-fast inputs are ignored without false overflow");
  // Rejected events at the boundary do not move the next acceptance deadline.
  base=cycles;event_at(6000000,3);
  $display("PASS: production 40MHz exact 150ms=6000000 clocks; N-1 rejected, N accepted; first immediate, rejected input does not extend timer; checks=%0d",tests);$finish;
 end
 initial begin #400000000;$fatal(1,"rate watchdog");end
endmodule
