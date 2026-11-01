`timescale 1ns/1ps
// Two identical three-row PDPW memories. Each has a fixed read role (top or
// bottom); both receive the same writes. Dedicated read/write ports remove
// the three-way colour mux. Full TD mapping measured 62 BRAM9K and 13
// BRAM32K for this top-level design. No new framebuffer is allocated.
module image_viewport_scaler #(parameter LINE_RAM_IMPLEMENT="32K")(
    input wire clk,rst_n,stream_ready,source_valid,front_valid,
    input wire [8:0] source_level,input wire [31:0] source_word,
    input wire [21:0] transform,input wire [8:0] first_row,
    input wire de,hs,vs,vblank,input wire [10:0] x,input wire [9:0] y,
    input wire [10:0] show_begin,show_end,view_shift,input wire subtract_shift,
    output wire source_read,output wire [23:0] rgb,
    output wire de_q,hs_q,vs_q,output wire [10:0] x_q,
    output wire [9:0] y_q,output reg underflow,output wire pipeline_idle
);
    wire show=de && x>=show_begin && x<show_end && front_valid;
    wire [9:0] sx;wire [8:0] sy;wire [7:0] fx,fy;wire seed_valid;wire [1:0] row_bank;
    viewport_raster_coordinates point(.clk(clk),.rst_n(rst_n),.transform(transform),
        .show_begin(show_begin),.view_shift(view_shift),.subtract_shift(subtract_shift),
        .show(show),.de(de),.vblank(vblank),.sx(sx),.sy(sy),.fx(fx),.fy(fy),
        .seed_valid(seed_valid),.row_bank(row_bank));
    reg stream_d,fill_active,pending;
    reg [2:0] ready;reg [8:0] tags[0:2];reg [9:0] next_row,fill_x;reg [1:0] fill_bank;
    wire restart=stream_ready && !stream_d;
    wire keep_row=show_begin<show_end;
    wire fill_write=source_valid && pending && fill_active && !restart;
    assign source_read=fill_active && !pending && stream_ready && source_level!=0 && !restart && !underflow;
    function [10:0] row_base;
        input [1:0] bank;
        begin case(bank) 0:row_base=0;1:row_base=640;default:row_base=1280;endcase end
    endfunction
    wire [1:0] lower_bank=sy==479 ? row_bank:row_bank==2 ? 2'd0:row_bank+2'd1;
    wire [8:0] lower_row=sy==479 ? 9'd479:sy+9'd1;
    wire [9:0] read_x=show ? (sx==639 ? 10'd639:sx+10'd1):sx;
    wire [10:0] write_address=row_base(fill_bank)+{1'b0,fill_x};
    wire [10:0] read_address[0:1];
    assign read_address[0]=row_base(row_bank)+{1'b0,read_x};
    assign read_address[1]=row_base(lower_bank)+{1'b0,read_x};
    wire [1:0] read_enable;
    assign read_enable[0]=ready[row_bank] && tags[row_bank]==sy &&
        !(fill_active && keep_row && fill_bank==row_bank);
    assign read_enable[1]=ready[lower_bank] && tags[lower_bank]==lower_row &&
        !(fill_active && keep_row && fill_bank==lower_bank);
    wire [23:0] ram[0:1];
    genvar port;
    generate for(port=0;port<2;port=port+1) begin: rows
        EG_LOGIC_BRAM #(.DATA_WIDTH_A(24),.ADDR_WIDTH_A(11),.DATA_DEPTH_A(2048),
            .DATA_WIDTH_B(24),.ADDR_WIDTH_B(11),.DATA_DEPTH_B(2048),
            .MODE("PDPW"),.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),
            .WRITEMODE_A("NORMAL"),.WRITEMODE_B("NORMAL"),.RESETMODE("SYNC"),
            .IMPLEMENT(LINE_RAM_IMPLEMENT),.DEBUGGABLE("NO"),.PACKABLE("NO"),
            .INIT_FILE("NONE"),.FILL_ALL("NONE")) line_ram(
            .dia(source_word[31:8]),.dib(24'd0),.addra(write_address),.addrb(read_address[port]),
            .cea(fill_write && keep_row),.ceb(read_enable[port]),.ocea(1'b0),.oceb(1'b0),
            .clka(clk),.clkb(clk),.wea(fill_write && keep_row),.web(1'b0),
            .bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(),.dob(ram[port]));
    end endgenerate
    reg [23:0] left_pixel[0:1],previous_right[0:1];reg [1:0] read_valid,left_valid;
    reg show_s,de_s,hs_s,vs_s,last_show;
    reg [10:0] x_s;reg [9:0] y_s,sx_s,last_x;reg [7:0] fx_s,fy_s;
    wire advance=last_show && sx_s!=last_x;
    wire [23:0] p00=advance ? previous_right[0]:left_pixel[0];
    wire [23:0] p01=advance ? previous_right[1]:left_pixel[1];
    wire sample_ok=(&read_valid) && (&left_valid);
    viewport_bilinear blend(.clk(clk),.rst_n(rst_n),.valid(show_s && sample_ok),
        .p00(p00),.p10(ram[0]),.p01(p01),.p11(ram[1]),.fx(fx_s),.fy(fy_s),
        .de(de_s),.hs(hs_s),.vs(vs_s),.x(x_s),.y(y_s),
        .rgb(rgb),.de_q(de_q),.hs_q(hs_q),.vs_q(vs_q),.x_q(x_q),.y_q(y_q),.pipeline_idle(pipeline_idle));
    integer k;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            stream_d<=0;fill_active<=0;pending<=0;ready<=0;next_row<=0;fill_x<=0;fill_bank<=0;
            read_valid<=0;left_valid<=0;show_s<=0;de_s<=0;hs_s<=0;vs_s<=0;
            x_s<=0;y_s<=0;sx_s<=0;fx_s<=0;fy_s<=0;last_x<=0;last_show<=0;underflow<=0;
            for(k=0;k<3;k=k+1)tags[k]<=0;
            for(k=0;k<2;k=k+1)begin left_pixel[k]<=0;previous_right[k]<=0;end
        end else begin
            stream_d<=stream_ready;show_s<=show;de_s<=de;hs_s<=hs;vs_s<=vs;x_s<=x;y_s<=y;
            sx_s<=sx;fx_s<=fx;fy_s<=fy;last_x<=sx_s;last_show<=show_s;
            if((show_s && !sample_ok) || (show && !seed_valid))underflow<=1;
            for(k=0;k<2;k=k+1)begin
                read_valid[k]<=read_enable[k];previous_right[k]<=ram[k];
                if(!read_enable[k])left_valid[k]<=0;
                else if(!show_s && read_valid[k])begin left_pixel[k]<=ram[k];left_valid[k]<=1;end
                else if(show_s && advance && read_valid[k])left_pixel[k]<=previous_right[k];
            end
            for(k=0;k<3;k=k+1)if(seed_valid && ready[k] && tags[k]<sy)ready[k]<=0;
            if(restart) begin
                ready<=0;read_valid<=0;left_valid<=0;fill_active<=0;pending<=0;fill_x<=0;
                next_row<={1'b0,first_row};fill_bank<=first_row%3;
            end else begin
                if(!fill_active && (!keep_row || !ready[fill_bank]) && stream_ready)begin fill_active<=1;fill_x<=0;pending<=0;end
                if(source_read)pending<=1;
                if(fill_write)begin
                    pending<=0;
                    if(fill_x==639)begin
                        if(keep_row)begin tags[fill_bank]<=next_row[8:0];ready[fill_bank]<=1;end
                        next_row<=next_row+1'b1;fill_bank<=fill_bank==2 ? 0:fill_bank+1'b1;fill_active<=0;
                    end else fill_x<=fill_x+1'b1;
                end
            end
        end
    end
endmodule

// Nine multiplications per RGB path; differences avoid redundant products.
// Q8 x Q8 bilinear, no intermediate rounding, one final half-up rounding.
module viewport_bilinear(
    input wire clk,rst_n,valid,input wire [23:0] p00,p10,p01,p11,
    input wire [7:0] fx,fy,input wire de,hs,vs,input wire [10:0] x,input wire [9:0] y,
    output wire [23:0] rgb,output wire de_q,hs_q,vs_q,
    output wire [10:0] x_q,output wire [9:0] y_q,output wire pipeline_idle
);
    reg [3:0] active,dp,hp,vp;reg [7:0] fy1;
    reg [7:0] fx0,fy0;
    always @(posedge clk) begin fx0<=fx;fy0<=fy;end
    reg [10:0] xp[0:3];reg [9:0] yp[0:3];
    genvar c;
    generate for(c=0;c<3;c=c+1) begin: channel
        wire [7:0] a=p00[c*8+:8],b=p10[c*8+:8],d=p01[c*8+:8],e=p11[c*8+:8];
        // Separate row/RAM selection and subtraction from the DSP product.
        // Unreset datapath registers permit DSP input-register extraction;
        // the reset validity pipe keeps these values invisible until filled.
        reg signed [8:0] top_difference,bottom_difference;
        reg [7:0] a0,d0;
        always @(posedge clk) begin
            top_difference<=$signed({1'b0,b})-$signed({1'b0,a});
            bottom_difference<=$signed({1'b0,e})-$signed({1'b0,d});a0<=a;d0<=d;
        end
        wire signed [17:0] top_product=top_difference*$signed({1'b0,fx0});
        wire signed [17:0] bottom_product=bottom_difference*$signed({1'b0,fx0});
        reg [15:0] top,bottom;reg signed [25:0] vertical;
        reg [7:0] result;
        wire signed [16:0] vertical_difference=$signed({1'b0,bottom})-$signed({1'b0,top});
        wire signed [25:0] vertical_product=vertical_difference*$signed({1'b0,fy1});
        wire signed [25:0] rounded=vertical+26'sd32768;
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin top<=0;bottom<=0;vertical<=0;result<=0;end
            else begin
                top<=$signed({2'b00,a0,8'd0})+top_product;
                bottom<=$signed({2'b00,d0,8'd0})+bottom_product;
                vertical<=$signed({2'b00,top,8'd0})+vertical_product;
                result<=rounded[23:16];
            end
        end
        assign rgb[c*8+:8]=active[3] ? result:8'd0;
    end endgenerate
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            active<=0;dp<=0;hp<=0;vp<=0;fy1<=0;
            for(i=0;i<4;i=i+1) begin xp[i]<=0;yp[i]<=0;end
        end else begin
            active<={active[2:0],valid};dp<={dp[2:0],de};hp<={hp[2:0],hs};vp<={vp[2:0],vs};fy1<=fy0;
            xp[0]<=x;yp[0]<=y;
            for(i=1;i<4;i=i+1) begin xp[i]<=xp[i-1];yp[i]<=yp[i-1];end
        end
    end
    assign de_q=dp[3];assign hs_q=hp[3];assign vs_q=vp[3];assign x_q=xp[3];assign y_q=yp[3];
    assign pipeline_idle=!(de || |dp);
endmodule
