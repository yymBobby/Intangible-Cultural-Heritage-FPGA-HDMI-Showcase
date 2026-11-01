`timescale 1ns/1ps
// Portable behavioral test model, NOT vendor simulation or synthesis input.
// Tests exercise equal-width SP/DP/PDPW, NOREG, synchronous No Change ports, and
// explicit-address HEX MIF initial contents (the same file read by TD).
module EG_LOGIC_BRAM #(
    parameter DATA_WIDTH_A=8,ADDR_WIDTH_A=9,DATA_DEPTH_A=512,
    parameter DATA_WIDTH_B=8,ADDR_WIDTH_B=9,DATA_DEPTH_B=512,
    parameter MODE="SP",REGMODE_A="NOREG",REGMODE_B="NOREG",
    parameter WRITEMODE_A="NORMAL",WRITEMODE_B="NORMAL",RESETMODE="SYNC",
    parameter IMPLEMENT="9K",DEBUGGABLE="NO",PACKABLE="NO",
    parameter INIT_FILE="NONE",FILL_ALL="NONE"
) (
    input clka,clkb,cea,ceb,ocea,oceb,wea,web,bea,beb,rsta,rstb,
    input [ADDR_WIDTH_A-1:0] addra,
    input [ADDR_WIDTH_B-1:0] addrb,
    input [DATA_WIDTH_A-1:0] dia,
    input [DATA_WIDTH_B-1:0] dib,
    output reg [DATA_WIDTH_A-1:0] doa,
    output reg [DATA_WIDTH_B-1:0] dob
);
    localparam DEPTH=DATA_DEPTH_A>DATA_DEPTH_B?DATA_DEPTH_A:DATA_DEPTH_B;
    reg [DATA_WIDTH_A-1:0] mem[0:DEPTH-1];
    integer mif_file,mif_address,mif_count,mif_scan;
    reg [DATA_WIDTH_A-1:0] mif_value;
    reg [2047:0] mif_line;
    initial begin
        if(DATA_WIDTH_A!=DATA_WIDTH_B || REGMODE_A!="NOREG" || REGMODE_B!="NOREG")
            $fatal(1,"Portable BRAM model configuration unsupported");
        if(INIT_FILE!="NONE") begin
            mif_file=$fopen(INIT_FILE,"r");mif_count=0;
            if(mif_file==0) $fatal(1,"Cannot read shared TD MIF: %s",INIT_FILE);
            while(!$feof(mif_file)) begin
                mif_scan=$fgets(mif_line,mif_file);
                if($sscanf(mif_line,"%h : %h;",mif_address,mif_value)==2) begin
                    if(mif_address<0||mif_address>=DEPTH) $fatal(1,"MIF address out of range");
                    mem[mif_address]=mif_value;mif_count=mif_count+1;
                end
            end
            $fclose(mif_file);
            if(mif_count!=DEPTH) $fatal(1,"MIF incomplete: %0d/%0d",mif_count,DEPTH);
        end
    end
    always @(posedge clka) begin
        if(rsta) doa<=0;
        else if(cea) begin
            if(wea) mem[addra]<=dia;
            else doa<=mem[addra];
        end
    end
    always @(posedge clkb) begin
        if(rstb) dob<=0;
        else if(ceb) begin
            if(web) mem[addrb]<=dib;
            else dob<=mem[addrb];
        end
    end
endmodule
