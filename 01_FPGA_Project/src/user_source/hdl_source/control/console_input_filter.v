`timescale 1ns/1ps
// Synchronize external contacts, then accept a vector only after N identical
// samples. Filtering A/B together preserves their order and rejects diagonal
// changes rather than manufacturing an intermediate quadrature state.
module console_input_filter #(
    parameter integer WIDTH = 1,
    parameter integer STABLE_CYCLES = 400000,
    parameter [WIDTH-1:0] RESET_LEVEL = {WIDTH{1'b1}}
)(
    input wire clk_sys, rst_sys_n,
    input wire [WIDTH-1:0] contact_async,
    output reg [WIDTH-1:0] level,
    output reg valid
);
    localparam integer LIMIT = STABLE_CYCLES < 1 ? 1 : STABLE_CYCLES;
    localparam integer COUNT_WIDTH = LIMIT <= 1 ? 1 : $clog2(LIMIT + 1);
    (* async_reg = "true" *) reg [WIDTH-1:0] sync_meta, sync_level;
    reg [1:0] sync_ready;
    reg [WIDTH-1:0] candidate;
    reg [COUNT_WIDTH-1:0] stable_count;

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            sync_meta <= RESET_LEVEL;
            sync_level <= RESET_LEVEL;
            sync_ready <= 0;
            candidate <= RESET_LEVEL;
            stable_count <= 0;
            level <= RESET_LEVEL;
            valid <= 0;
        end else begin
            sync_meta <= contact_async;
            sync_level <= sync_meta;
            sync_ready <= {sync_ready[0], 1'b1};
            if (!sync_ready[1]) begin
                stable_count <= 0;
            end else if (sync_level != candidate) begin
                candidate <= sync_level;
                stable_count <= 1;
                if (LIMIT == 1) begin
                    level <= sync_level;
                    valid <= 1;
                end
            end else if (stable_count < LIMIT) begin
                stable_count <= stable_count + 1'b1;
                if (stable_count == LIMIT - 1) begin
                    level <= candidate;
                    valid <= 1;
                end
            end
        end
    end
endmodule
