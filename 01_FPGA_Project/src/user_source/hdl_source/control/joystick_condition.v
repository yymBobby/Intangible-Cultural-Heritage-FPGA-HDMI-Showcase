`timescale 1ns/1ps
// Block averages and power-on/manual centre calibration. No multiplier/divider/RAM.
module joystick_condition #(
    parameter integer AVG_LOG2=3,
    parameter integer CAL_LOG2=8,
    parameter integer SETTLE_CYCLES=10000000,
    parameter integer CENTER_MIN=1024,
    parameter integer CENTER_MAX=3071,
    parameter integer INVERT_X=0,
    parameter integer INVERT_Y=0
)(
    input wire clk_sys,rst_sys_n,recalibrate,
    input wire [11:0] x_raw,y_raw,
    input wire sample_valid,
    output reg [11:0] x_average,y_average,center_x,center_y,
    output reg signed [12:0] dx,dy,
    output reg filtered_valid,ready,calibration_error
);
    localparam integer AW=12+AVG_LOG2, CW=12+CAL_LOG2;
    localparam integer SW=SETTLE_CYCLES>1 ? $clog2(SETTLE_CYCLES+1):1;
    reg [AW-1:0] sum_x,sum_y;
    reg [AVG_LOG2-1:0] average_count;
    reg [CW-1:0] cal_sum_x,cal_sum_y;
    reg [CAL_LOG2-1:0] cal_count;
    reg [SW-1:0] settle;
    wire [AW-1:0] next_sum_x=sum_x+x_raw,next_sum_y=sum_y+y_raw;
    wire [11:0] average_x=next_sum_x>>AVG_LOG2,average_y=next_sum_y>>AVG_LOG2;
    wire [CW-1:0] next_cal_x=cal_sum_x+average_x,next_cal_y=cal_sum_y+average_y;
    wire [11:0] calibrated_x=next_cal_x>>CAL_LOG2,calibrated_y=next_cal_y>>CAL_LOG2;
    wire signed [12:0] offset_x=$signed({1'b0,average_x})-$signed({1'b0,center_x});
    wire signed [12:0] offset_y=$signed({1'b0,average_y})-$signed({1'b0,center_y});
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            sum_x<=0;sum_y<=0;average_count<=0;cal_sum_x<=0;cal_sum_y<=0;cal_count<=0;
            settle<=SETTLE_CYCLES;center_x<=2048;center_y<=2048;
            x_average<=0;y_average<=0;dx<=0;dy<=0;filtered_valid<=0;ready<=0;calibration_error<=0;
        end else begin
            filtered_valid<=0;
            if(recalibrate) begin
                sum_x<=0;sum_y<=0;average_count<=0;cal_sum_x<=0;cal_sum_y<=0;cal_count<=0;
                settle<=SETTLE_CYCLES;dx<=0;dy<=0;ready<=0;calibration_error<=0;
            end else if(settle!=0) settle<=settle-1'b1;
            else if(sample_valid) begin
                if(&average_count) begin
                    sum_x<=0;sum_y<=0;average_count<=0;x_average<=average_x;y_average<=average_y;
                    if(!ready && !calibration_error) begin
                        if(&cal_count) begin
                            cal_sum_x<=0;cal_sum_y<=0;cal_count<=0;
                            if(calibrated_x>=CENTER_MIN && calibrated_x<=CENTER_MAX &&
                               calibrated_y>=CENTER_MIN && calibrated_y<=CENTER_MAX) begin
                                center_x<=calibrated_x;center_y<=calibrated_y;ready<=1;
                            end else calibration_error<=1;
                        end else begin cal_sum_x<=next_cal_x;cal_sum_y<=next_cal_y;cal_count<=cal_count+1'b1;end
                    end else if(ready) begin
                        dx<=INVERT_X ? -offset_x:offset_x;dy<=INVERT_Y ? -offset_y:offset_y;
                        filtered_valid<=1;
                    end
                end else begin sum_x<=next_sum_x;sum_y<=next_sum_y;average_count<=average_count+1'b1;end
            end
        end
    end
endmodule

module joystick_navigation #(
    parameter integer ENTER_THRESHOLD=512,
    parameter integer EXIT_THRESHOLD=320,
    parameter integer REPEAT_DELAY_TICKS=400,
    parameter integer REPEAT_PERIOD_TICKS=150
)(
    input wire clk_sys,rst_sys_n,ready,control_tick,
    input wire signed [12:0] dx,dy,
    output reg up_press,down_press,left_press,right_press,
    output reg up_repeat,down_repeat,left_repeat,right_repeat,
    output reg [2:0] direction,
    output wire centered
);
    localparam integer RW=$clog2(REPEAT_DELAY_TICKS+REPEAT_PERIOD_TICKS+2);
    localparam [2:0] NONE=0,LEFT=1,RIGHT=2,UP=3,DOWN=4;
    wire [12:0] abs_x=dx[12] ? -dx:dx,abs_y=dy[12] ? -dy:dy;
    assign centered=ready && abs_x<=EXIT_THRESHOLD && abs_y<=EXIT_THRESHOLD;
    reg [RW-1:0] repeat_count;
    reg repeating;
    reg [2:0] chosen;
    always @* begin
        chosen=NONE;
        if(abs_x>=ENTER_THRESHOLD || abs_y>=ENTER_THRESHOLD) begin
            if(abs_x>=abs_y) chosen=dx[12] ? LEFT:RIGHT;
            else chosen=dy[12] ? UP:DOWN;
        end
    end
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            up_press<=0;down_press<=0;left_press<=0;right_press<=0;
            up_repeat<=0;down_repeat<=0;left_repeat<=0;right_repeat<=0;direction<=NONE;repeat_count<=0;repeating<=0;
        end else begin
            up_press<=0;down_press<=0;left_press<=0;right_press<=0;up_repeat<=0;down_repeat<=0;left_repeat<=0;right_repeat<=0;
            if(!ready) begin direction<=NONE;repeat_count<=0;repeating<=0;end
            else if(control_tick) begin
                if(centered) begin direction<=NONE;repeat_count<=0;repeating<=0;end
                else if(direction==NONE) begin
                    direction<=chosen;repeat_count<=0;repeating<=0;
                    left_press<=chosen==LEFT;right_press<=chosen==RIGHT;
                    up_press<=chosen==UP;down_press<=chosen==DOWN;
                end else if(direction!=NONE) begin
                    if(repeat_count==(repeating ? REPEAT_PERIOD_TICKS-1:REPEAT_DELAY_TICKS-1)) begin
                        up_repeat<=direction==UP;down_repeat<=direction==DOWN;
                        left_repeat<=direction==LEFT;right_repeat<=direction==RIGHT;
                        repeat_count<=0;repeating<=1;
                    end else repeat_count<=repeat_count+1'b1;
                end
            end
        end
    end
endmodule
