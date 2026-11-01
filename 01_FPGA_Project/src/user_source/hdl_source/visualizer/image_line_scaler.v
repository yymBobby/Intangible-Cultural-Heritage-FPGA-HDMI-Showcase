`timescale 1ns/1ps
// 640x480 -> 960x720 nearest-neighbour, floor(2*x/3), floor(2*y/3).
// Two independent 1024x24 SP 32K RAMs: display one line, fill the other.
// Only the invisible bank is written. Source words are consumed exactly once.
module image_line_scaler #(parameter LINE_RAM_IMPLEMENT="32K")(
    input wire clk,rst_n,stream_ready,source_valid,front_valid,
    input wire [8:0] source_level,
    input wire [31:0] source_word,
    input wire de,hs,vs,vblank,
    input wire [10:0] x,input wire [9:0] y,
    input wire [9:0] start_column,
    input wire [10:0] show_begin,show_end,
    output wire source_read,
    output reg [23:0] rgb,
    output reg de_q,hs_q,vs_q,
    output reg [10:0] x_q,output reg [9:0] y_q,
    output reg underflow
);
    reg stream_d,fill_active,pending;
    reg [1:0] ready;
    reg [8:0] tag0,tag1,next_row;
    reg [9:0] fill_x,source_x;
    reg [8:0] source_y;
    reg [1:0] x_phase,y_phase;
    wire restart=stream_ready&&!stream_d;
    wire bank=next_row[0];
    wire show=de && x>=show_begin && x<show_end && front_valid;
    wire line_ready=ready[source_y[0]]&&
        (source_y[0] ? tag1:tag0)==source_y;
    assign source_read=fill_active&&!pending&&stream_ready&&source_level!=0&&!restart&&!underflow;
    wire write_word=source_valid&&pending&&fill_active&&!restart;
    // A filling bank has ready=0 and cannot supply a visible pixel. Select
    // its address from registered ownership, keeping stream/restart gating
    // on the RAM enables instead of the BRAM address critical path.
    wire [9:0] addr0=(fill_active&&!bank) ? fill_x:source_x;
    wire [9:0] addr1=(fill_active&&bank) ? fill_x:source_x;
    wire [23:0] ram0,ram1;
    EG_LOGIC_BRAM #(.DATA_WIDTH_A(24),.ADDR_WIDTH_A(10),.DATA_DEPTH_A(1024),
        .DATA_WIDTH_B(24),.ADDR_WIDTH_B(10),.DATA_DEPTH_B(1024),
        .MODE("SP"),.REGMODE_A("NOREG"),.WRITEMODE_A("NORMAL"),
        .RESETMODE("SYNC"),.IMPLEMENT(LINE_RAM_IMPLEMENT),.DEBUGGABLE("NO"),
        .PACKABLE("NO"),.INIT_FILE("NONE"),.FILL_ALL("NONE")) line0(
        .dia(source_word[31:8]),.dib(24'd0),.addra(addr0),.addrb(10'd0),
        .cea((show&&!source_y[0])||(write_word&&!bank)),.ceb(1'b0),
        .ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(1'b0),
        .wea(write_word&&!bank),.web(1'b0),.bea(1'b0),.beb(1'b0),
        .rsta(1'b0),.rstb(1'b0),.doa(ram0),.dob());
    EG_LOGIC_BRAM #(.DATA_WIDTH_A(24),.ADDR_WIDTH_A(10),.DATA_DEPTH_A(1024),
        .DATA_WIDTH_B(24),.ADDR_WIDTH_B(10),.DATA_DEPTH_B(1024),
        .MODE("SP"),.REGMODE_A("NOREG"),.WRITEMODE_A("NORMAL"),
        .RESETMODE("SYNC"),.IMPLEMENT(LINE_RAM_IMPLEMENT),.DEBUGGABLE("NO"),
        .PACKABLE("NO"),.INIT_FILE("NONE"),.FILL_ALL("NONE")) line1(
        .dia(source_word[31:8]),.dib(24'd0),.addra(addr1),.addrb(10'd0),
        .cea((show&&source_y[0])||(write_word&&bank)),.ceb(1'b0),
        .ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(1'b0),
        .wea(write_word&&bank),.web(1'b0),.bea(1'b0),.beb(1'b0),
        .rsta(1'b0),.rstb(1'b0),.doa(ram1),.dob());
    reg selected_bank,show_q,ready_q;
    // NOREG RAM still has one synchronous read stage. Metadata follows it.
    always @* rgb=show_q&&ready_q ? (selected_bank ? ram1:ram0):24'd0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            stream_d<=0;fill_active<=0;pending<=0;ready<=0;
            tag0<=0;tag1<=0;next_row<=0;fill_x<=0;
            source_x<=0;source_y<=0;x_phase<=0;y_phase<=0;
            selected_bank<=0;show_q<=0;ready_q<=0;underflow<=0;
            de_q<=0;hs_q<=0;vs_q<=0;x_q<=0;y_q<=0;
        end else begin
            stream_d<=stream_ready;
            de_q<=de;hs_q<=hs;vs_q<=vs;x_q<=x;y_q<=y;
            selected_bank<=source_y[0];show_q<=show;ready_q<=line_ready;
            if(vblank) begin source_x<=start_column;source_y<=0;x_phase<=0;y_phase<=0;end
            else if(de) begin
                if(x>=show_begin && x<show_end) begin
                    if(x_phase!=0) source_x<=source_x+1'b1;
                    x_phase<=x_phase==2 ? 0:x_phase+1'b1;
                    if(show&&!line_ready) underflow<=1;
                end
                if(x==959 && y_phase!=0 && front_valid) ready[source_y[0]]<=0;
                if(x==1279) begin
                    source_x<=start_column;x_phase<=0;
                    if(y_phase!=0) source_y<=source_y+1'b1;
                    y_phase<=y_phase==2 ? 0:y_phase+1'b1;
                end
            end
            if(restart) begin ready<=0;next_row<=0;fill_active<=0;pending<=0;fill_x<=0;end
            else begin
                if(!fill_active&&next_row<480&&!ready[next_row[0]]&&stream_ready) begin
                    fill_active<=1;fill_x<=0;pending<=0;
                end
                if(source_read) pending<=1;
                if(write_word) begin
                    pending<=0;
                    if(fill_x==639) begin
                        if(bank) tag1<=next_row;else tag0<=next_row;
                        ready[bank]<=1;next_row<=next_row+1'b1;fill_active<=0;
                    end else fill_x<=fill_x+1'b1;
                end
            end
        end
    end
endmodule
