`timescale 1ns/1ps
// Passive 3.3V encoder + active-low click/back/play contacts. No divided clocks,
// vendor IP, RAM, DSP or media state. The consumer must capture each SYS pulse;
// this input layer has no backpressure queue and must not be gated by media busy.
// Independently written after reviewing GitHub FPGA quadrature implementations;
// see tools/rotary_console_test/README.md for sources and behavioral differences.
module rotary_console_input #(
    parameter integer CLK_HZ = 40000000,
    // Cycle overrides allow short simulations without changing the SYS clock.
    // Defaults: A/B stable for 300us, buttons stable for 10ms (ceiling division).
    parameter integer AB_FILTER_CYCLES = (CLK_HZ / 10000) * 3 +
                                       ((CLK_HZ % 10000) * 3 + 9999) / 10000,
    parameter integer BUTTON_FILTER_CYCLES = (CLK_HZ + 99) / 100,
    parameter integer STEP_EDGES = 4,   // Supported: 4 (full), 2 (half), 1 (x4).
    parameter integer REVERSE_DIRECTION = 0
)(
    input wire clk_sys, rst_sys_n,
    input wire encoder_a, encoder_b,
    input wire encoder_s_n, key_back_n, key_play_n,
    output reg step_cw, step_ccw,
    output wire click_press, back_press, play_press,
    output reg invalid_transition,
    output wire inputs_ready,
    output wire [1:0] ab_filtered,
    // [2]=play, [1]=back, [0]=encoder click; 1 means pressed.
    output wire [2:0] buttons_pressed
);
    wire ab_valid;
    wire [2:0] button_level, button_valid;
    wire [2:0] button_async = {key_play_n, key_back_n, encoder_s_n};
    reg [2:0] button_seen, button_previous, button_press_pulse;
    reg encoder_started, armed;
    reg [1:0] previous_ab;
    reg signed [3:0] edge_sum;
    reg signed [3:0] edge_delta;
    wire signed [3:0] next_sum = edge_sum + edge_delta;
    wire diagonal = (previous_ab ^ ab_filtered) == 2'b11;
    wire boundary = STEP_EDGES == 1 || ab_filtered == 2'b11 ||
                    (STEP_EDGES == 2 && ab_filtered == 2'b00);

    assign inputs_ready = encoder_started && (&button_seen);
    assign buttons_pressed = ~button_level;
    assign click_press = button_press_pulse[0] && inputs_ready;
    assign back_press = button_press_pulse[1] && inputs_ready;
    assign play_press = button_press_pulse[2] && inputs_ready;

    console_input_filter #(.WIDTH(2), .STABLE_CYCLES(AB_FILTER_CYCLES)) ab_filter (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n),
        .contact_async({encoder_a, encoder_b}),
        .level(ab_filtered), .valid(ab_valid)
    );
    genvar i;
    generate for (i = 0; i < 3; i = i + 1) begin: buttons
        console_input_filter #(.STABLE_CYCLES(BUTTON_FILTER_CYCLES)) filter (
            .clk_sys(clk_sys), .rst_sys_n(rst_sys_n),
            .contact_async(button_async[i]),
            .level(button_level[i]), .valid(button_valid[i])
        );
        always @(posedge clk_sys or negedge rst_sys_n) begin
            if (!rst_sys_n) begin
                button_seen[i] <= 0;
                button_previous[i] <= 1;
                button_press_pulse[i] <= 0;
            end else begin
                button_press_pulse[i] <= 0;
                if (button_valid[i]) begin
                    button_seen[i] <= 1;
                    button_previous[i] <= button_level[i];
                    // Held at reset: acquire its level, require release/repress.
                    if (button_seen[i] && button_previous[i] && !button_level[i])
                        button_press_pulse[i] <= 1;
                end
            end
        end
    end endgenerate

    // Clockwise per supplied manual: A falls before B, starting at idle 11.
    // 11 -> 01 -> 00 -> 10 -> 11. Physical direction is configurable.
    always @* begin
        edge_delta = 0;
        case ({previous_ab, ab_filtered})
            4'b1101, 4'b0100, 4'b0010, 4'b1011: edge_delta = 1;
            4'b1110, 4'b1000, 4'b0001, 4'b0111: edge_delta = -1;
            default: edge_delta = 0;
        endcase
    end

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            encoder_started <= 0;
            armed <= 0;
            previous_ab <= 2'b11;
            edge_sum <= 0;
            step_cw <= 0;
            step_ccw <= 0;
            invalid_transition <= 0;
        end else begin
            step_cw <= 0;
            step_ccw <= 0;
            invalid_transition <= 0;
            if (!ab_valid || !(&button_valid)) begin
                encoder_started <= 0;
                armed <= 0;
                edge_sum <= 0;
                previous_ab <= ab_filtered;
            end else if (!encoder_started) begin
                encoder_started <= 1;
                previous_ab <= ab_filtered;
                armed <= boundary;
                edge_sum <= 0;
            end else if (previous_ab != ab_filtered) begin
                previous_ab <= ab_filtered;
                if (diagonal) begin
                    // Lost/noisy edge: discard partial travel; resync at the
                    // next detent boundary instead of guessing its direction.
                    invalid_transition <= 1;
                    edge_sum <= 0;
                    armed <= boundary;
                end else if (!armed) begin
                    if (boundary) armed <= 1;
                    edge_sum <= 0;
                end else if (boundary) begin
                    edge_sum <= 0;
                    if (next_sum == STEP_EDGES) begin
                        step_cw <= REVERSE_DIRECTION == 0;
                        step_ccw <= REVERSE_DIRECTION != 0;
                    end else if (next_sum == -STEP_EDGES) begin
                        step_cw <= REVERSE_DIRECTION != 0;
                        step_ccw <= REVERSE_DIRECTION == 0;
                    end
                end else begin
                    edge_sum <= next_sum;
                end
            end
        end
    end

    // synthesis translate_off
    initial begin
        if (CLK_HZ < 1 || AB_FILTER_CYCLES < 1 || BUTTON_FILTER_CYCLES < 1)
            $fatal(1, "rotary_console_input: timing parameters must be positive");
        if (STEP_EDGES != 1 && STEP_EDGES != 2 && STEP_EDGES != 4)
            $fatal(1, "rotary_console_input: STEP_EDGES must be 1, 2 or 4");
    end
    // synthesis translate_on
endmodule
