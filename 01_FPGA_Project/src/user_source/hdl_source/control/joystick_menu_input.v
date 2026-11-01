`timescale 1ns/1ps
// Hardware acquisition and navigation exactly reuse the tested KEY2 status
// page modules. SYS=40MHz, ADC=10MHz. No display/counter test logic is included.
module joystick_menu_input #(
    parameter integer BUTTON_CYCLES=400000,
    parameter integer SETTLE_CYCLES=10000000,
    parameter integer CAL_LOG2=8,
    parameter integer CONTROL_DIV=40000,
    parameter integer REPEAT_DELAY=400,
    parameter integer REPEAT_PERIOD=150
)(
    input wire clk_sys,rst_sys_n,clk_adc,rst_adc_n,joy_button,
    output wire up_press,down_press,left_press,right_press,up_repeat,down_repeat,left_repeat,right_repeat,button_press,
    output wire ready,fault,calibration_error
);
    wire adc_pd,adc_soc_command,adc_eoc,adc_fault,pair_valid,sample_valid;
    reg adc_soc;
    // ADC SOC requires 10 ns of hold after its rising clock edge. Publish
    // this one-clock pulse on the opposite edge, giving 50 ns at 10 MHz.
    always @(negedge clk_adc or negedge rst_adc_n)
        if(!rst_adc_n) adc_soc<=0;else adc_soc<=adc_soc_command;
    wire [2:0] adc_channel;
    wire [11:0] adc_dout,pair_x,pair_y,x_raw,y_raw;
    EG_PHY_ADC #(.CH1("ENABLE"),.CH2("ENABLE"),.VREF("ENABLE")) adc_inst(
        .clk(clk_adc),.pd(adc_pd),.s(adc_channel),.soc(adc_soc),.eoc(adc_eoc),.dout(adc_dout));
    joystick_adc_pair acquisition(.clk_adc(clk_adc),.rst_adc_n(rst_adc_n),
        .adc_eoc(adc_eoc),.adc_dout(adc_dout),.adc_pd(adc_pd),.adc_soc(adc_soc_command),
        .adc_channel(adc_channel),.pair_x(pair_x),.pair_y(pair_y),.pair_valid(pair_valid),.fault(adc_fault));
    joystick_pair_cdc mailbox(.clk_adc(clk_adc),.rst_adc_n(rst_adc_n),
        .pair_x(pair_x),.pair_y(pair_y),.pair_valid(pair_valid),
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.x_raw(x_raw),.y_raw(y_raw),.sample_valid(sample_valid));
    // Preserve the actual CDC stages so TD resolves their register names, not the ADC producer alias.
    (* async_reg="true" *) reg fault_meta,fault_sys /* fehdl keep="true" */;
    always @(posedge clk_sys or negedge rst_sys_n)
        if(!rst_sys_n) begin fault_meta<=0;fault_sys<=0;end
        else begin fault_meta<=adc_fault;fault_sys<=fault_meta;end
    assign fault=fault_sys;
    wire calibrated,filtered_valid;
    wire signed [12:0] dx,dy;
    joystick_condition #(.SETTLE_CYCLES(SETTLE_CYCLES),.CAL_LOG2(CAL_LOG2),
        .INVERT_X(1),.INVERT_Y(1)) conditioning(
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.recalibrate(1'b0),
        .x_raw(x_raw),.y_raw(y_raw),.sample_valid(sample_valid),
        .x_average(),.y_average(),.center_x(),.center_y(),.dx(dx),.dy(dy),
        .filtered_valid(filtered_valid),.ready(calibrated),.calibration_error(calibration_error));
    assign ready=calibrated && !fault_sys && !calibration_error;
    localparam integer TW=CONTROL_DIV>1 ? $clog2(CONTROL_DIV):1;
    reg [TW-1:0] control_timer;
    wire control_tick=control_timer==CONTROL_DIV-1;
    always @(posedge clk_sys or negedge rst_sys_n)
        if(!rst_sys_n) control_timer<=0;
        else control_timer<=control_tick ? 0:control_timer+1'b1;
    joystick_navigation #(.REPEAT_DELAY_TICKS(REPEAT_DELAY),.REPEAT_PERIOD_TICKS(REPEAT_PERIOD)) navigation(
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.ready(ready),.control_tick(control_tick),.dx(dx),.dy(dy),
        .up_press(up_press),.down_press(down_press),.left_press(left_press),.right_press(right_press),
        .up_repeat(up_repeat),.down_repeat(down_repeat),.left_repeat(left_repeat),.right_repeat(right_repeat),.direction(),.centered());
    wire button_event;
    // Actual board test: external B=0 released, B=1 pressed. The reusable
    // contact filter takes active-low, so invert here just as in the test top.
    joystick_button #(.STABLE_CYCLES(BUTTON_CYCLES)) button_filter(
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.contact_n(!joy_button),
        .pressed(),.press_pulse(button_event),.valid());
    assign button_press=button_event && ready;
endmodule
