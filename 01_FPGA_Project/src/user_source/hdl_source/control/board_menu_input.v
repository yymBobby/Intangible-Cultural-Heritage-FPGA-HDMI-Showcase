`timescale 1ns/1ps
// Board contacts -> 40MHz menu UI. The optional back input is unused by the stage-2 top; KEY4 pauses there.
// Parameter overrides are for simulation and encoder detent calibration.
// Menu values are consumed by the media pipeline; contact pulses remain raw.
module board_menu_input #(
    parameter integer AB_FILTER_CYCLES=12000,
    parameter integer BUTTON_FILTER_CYCLES=400000,
    parameter integer SW_FILTER_CYCLES=400000,
    parameter integer STEP_EDGES=4,
    parameter integer REVERSE_DIRECTION=0,
    parameter integer JOYSTICK_MODE=0,
    parameter integer ENABLE_ALARM_INPUT=0
)(
    input wire alarm_inhibit,
    input wire clk_sys,rst_sys_n,
    input wire encoder_a,encoder_b,encoder_s_n,key_back_n,
    input wire sw0_on,
    input wire joy_up,joy_down,joy_left,joy_right,joy_click,
    output wire [67:0] menu_snapshot_sys,
    output wire step_cw,step_ccw,click_press,back_press,
    output wire inputs_ready,invalid_transition,confirm_pulse
);
    wire sw_level,sw_valid;
    rotary_console_input #(.CLK_HZ(40000000),.AB_FILTER_CYCLES(AB_FILTER_CYCLES),
        .BUTTON_FILTER_CYCLES(BUTTON_FILTER_CYCLES),.STEP_EDGES(STEP_EDGES),
        .REVERSE_DIRECTION(REVERSE_DIRECTION)) rotary(
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.encoder_a(encoder_a),.encoder_b(encoder_b),
        .encoder_s_n(encoder_s_n),.key_back_n(key_back_n),.key_play_n(1'b1),
        .step_cw(step_cw),.step_ccw(step_ccw),.click_press(click_press),.back_press(back_press),
        .play_press(),.inputs_ready(inputs_ready),.invalid_transition(invalid_transition),
        .ab_filtered(),.buttons_pressed());
    // The board switch selects either 3V3 or GND; 1 means menu open.
    console_input_filter #(.STABLE_CYCLES(SW_FILTER_CYCLES),.RESET_LEVEL(1'b0)) sw_filter(
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.contact_async(sw0_on),.level(sw_level),.valid(sw_valid));
    generate if(JOYSTICK_MODE) begin: stage2
    menu_ui_state_v2 #(.ENABLE_INHIBIT(ENABLE_ALARM_INPUT)) ui(.ui_inhibit_sys(alarm_inhibit),.clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.sw0_valid_sys(sw_valid),.sw0_on_sys(sw_level),
        .up_sys(joy_up),.down_sys(joy_down),.left_sys(joy_left),.right_sys(joy_right),.joy_click_sys(joy_click),
        // Physical clockwise was decoded as CCW on this board. Reverse only
        // menu adjustment/navigation; leave outside-menu picture pulses intact.
        .step_cw_sys(step_ccw),.step_ccw_sys(step_cw),.click_sys(click_press),.back_sys(back_press),
        .snapshot_sys(menu_snapshot_sys),.ui_confirm_pulse_sys(confirm_pulse));
    end else begin: stage1
    assign menu_snapshot_sys[67:40]=28'd0;
    menu_ui_state ui(.clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.sw0_valid_sys(sw_valid),.sw0_on_sys(sw_level),
        .step_cw_sys(step_cw),.step_ccw_sys(step_ccw),.click_sys(click_press),.back_sys(back_press),
        .snapshot_sys(menu_snapshot_sys[39:0]),.ui_confirm_pulse_sys(confirm_pulse));
    end endgenerate
endmodule

// Browse only: joystick axes never select a theme. At 150/200% the menu
// state owns all four joystick directions for pan; encoder image browsing
// remains available. Contacts publish one press, not pan-repeat events.
module board_browse_control(
    input wire menu_open,
    input wire [1:0] zoom_level,
    input wire encoder_next,encoder_prev,encoder_click,joy_left,joy_right,
    output wire image_next,image_prev,theme_next
);
    wire joystick_browse=zoom_level<2;
    wire next_request=encoder_next || (joystick_browse && joy_right);
    wire prev_request=encoder_prev || (joystick_browse && joy_left);
    assign theme_next=!menu_open && encoder_click;
    // Theme confirmation wins over a simultaneous picture event; opposing
    // picture directions cancel rather than silently preferring one side.
    assign image_next=!menu_open && !encoder_click && next_request && !prev_request;
    assign image_prev=!menu_open && !encoder_click && prev_request && !next_request;
endmodule
