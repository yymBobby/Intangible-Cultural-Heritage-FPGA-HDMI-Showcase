// Gray-pointer dual-clock FIFO. Synchronous BRAM read feeds one output register.
// Both pointers must be reset together: the player holds both clear levels until ack.
module pcm_async_fifo #(
    parameter integer ADDR_WIDTH=12
)(
    input wire wr_clk, input wire wr_rst_n, input wire wr_clear,
    input wire wr_valid, output wire wr_ready, input wire [32:0] wr_data,
    output wire [ADDR_WIDTH:0] wr_used,
    input wire rd_clk, input wire rd_rst_n, input wire rd_clear,
    output reg rd_valid, input wire rd_ready, output reg [32:0] rd_data
);
    localparam integer DEPTH=1<<ADDR_WIDTH;
    reg [32:0] mem [0:DEPTH-1];
    reg [ADDR_WIDTH:0] wbin, wgray, rbin, rgray;
    (* ASYNC_REG="TRUE" *) reg [ADDR_WIDTH:0] rg1, rg2, wg1, wg2;
    wire [ADDR_WIDTH:0] full_gray = {~rg2[ADDR_WIDTH:ADDR_WIDTH-1],rg2[ADDR_WIDTH-2:0]};
    wire full = wgray==full_gray;
    wire empty = rgray==wg2;
    assign wr_ready = !full && !wr_clear && wr_rst_n;
    function [ADDR_WIDTH:0] gray_to_bin;
        input [ADDR_WIDTH:0] gray;
        integer bit_index;
        begin
            gray_to_bin[ADDR_WIDTH]=gray[ADDR_WIDTH];
            for(bit_index=ADDR_WIDTH-1;bit_index>=0;bit_index=bit_index-1)
                gray_to_bin[bit_index]=gray_to_bin[bit_index+1]^gray[bit_index];
        end
    endfunction
    assign wr_used = wbin-gray_to_bin(rg2);
    always @(posedge wr_clk or negedge wr_rst_n) begin
        if(!wr_rst_n) begin wbin<=0; wgray<=0; rg1<=0; rg2<=0; end
        else if(wr_clear) begin wbin<=0; wgray<=0; rg1<=0; rg2<=0; end
        else begin
            rg1<=rgray; rg2<=rg1;
            if(wr_valid && wr_ready) begin
                wbin<=wbin+1; wgray<=((wbin+1'b1)>>1)^(wbin+1'b1);
            end
        end
    end
    always @(posedge wr_clk) if(wr_valid && wr_ready) mem[wbin[ADDR_WIDTH-1:0]]<=wr_data;
    always @(posedge rd_clk or negedge rd_rst_n) begin
        if(!rd_rst_n) begin rbin<=0; rgray<=0; wg1<=0; wg2<=0; rd_valid<=0; end
        else if(rd_clear) begin rbin<=0; rgray<=0; wg1<=0; wg2<=0; rd_valid<=0; end
        else begin
            wg1<=wgray; wg2<=wg1;
            if(!rd_valid || rd_ready) begin
                rd_valid<=!empty;
                if(!empty) begin rbin<=rbin+1; rgray<=((rbin+1'b1)>>1)^(rbin+1'b1); end
            end
        end
    end
    // No reset on RAM or its data output, so inference can retain block RAM.
    always @(posedge rd_clk)
        if(!rd_clear && (!rd_valid || rd_ready) && !empty) rd_data<=mem[rbin[ADDR_WIDTH-1:0]];
endmodule
