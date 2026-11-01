`timescale 1ns/1ps
module tb_browse_queue;
 reg clk=0,rst_n=0,push=0,start=0,finish=0,resume=0;reg [3:0] command=0;
 always #12.5 clk=~clk;
 wire ready,inflight,full,overflow;wire [3:0] head,count;
 browse_command_queue #(.MIN_INTERVAL_CYCLES(1)) dut(.*);
 integer rd=0,wr=0,depth=0,simultaneous=0,locks=0;reg live=0,locked=0;
 reg [3:0] reference[0:4095];reg [15:0] random_bits=16'h1ace;
 reg take,drop;
 task cycle;
  begin
   take=push&&ready;drop=finish&&live;
   if(locked&&ready)$fatal(1,"locked queue admitted a new command");
   if(take)begin reference[wr]=command;wr++;end
   if(drop)begin rd++;live=0;end else if(start&&depth!=0&&!live)live=1;
   if(take&&!drop&&depth==7)begin locked=1;locks++;end
   else if(depth==0&&resume)locked=0;
   if(take&&drop)simultaneous++;
   depth=depth+take-drop;
   @(posedge clk);#1;
   if(count!=depth||inflight!=live||full!=locked||depth>8||depth<0)$fatal(1,"queue reference mismatch");
   if(depth!=0&&head!==reference[rd])$fatal(1,"FIFO reordered/overwrote head");
   @(negedge clk);
  end
 endtask
 initial begin
  $dumpfile("browse_queue.vcd");$dumpvars(0,push,ready,count,head,full,inflight,start,finish,resume);
  repeat(3)@(negedge clk);rst_n=1;
  // Force a full queue, then free one slot: admission stays locked.
  push=1;for(integer i=0;i<8;i++)begin command=i;cycle();end
  push=0;start=1;cycle();start=0;finish=1;cycle();finish=0;
  if(count!=7||ready||!full)$fatal(1,"full queue reopened before draining");
  for(integer i=0;i<2500;i++)begin
   random_bits={random_bits[14:0],random_bits[15]^random_bits[13]^random_bits[12]^random_bits[10]};
   push=random_bits[0]||random_bits[1];command=random_bits[7:4];
   start=!inflight&&count!=0;finish=inflight&&random_bits[2];resume=random_bits[3];cycle();
  end
  push=0;resume=1;
  while(depth!=0)begin start=!inflight;finish=inflight;cycle();end
  start=0;finish=0;cycle();
  if(wr!=rd||wr<100||locks<2||simultaneous<2||full)$fatal(1,"insufficient queue corner coverage");
  $display("PASS: eight-entry FIFO model accepted=%0d full_locks=%0d simultaneous_push_pop=%0d; no overwrite, drain-unlock, pointer wrap",wr,locks,simultaneous);$finish;
 end
 initial begin #1000000;$fatal(1,"queue watchdog");end
endmodule
