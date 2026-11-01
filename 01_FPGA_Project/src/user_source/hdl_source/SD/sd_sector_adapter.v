`timescale 1ns/1ps
// One-request bridge from resource-service ready/valid to the legacy SD
// controller's pulse/read-data/end interface. All signals use clk_sys.
// A failed read latches FAULT until coordinated reset of both this adapter
// and the legacy SD controller; old late bytes must not enter a new request.
module sd_sector_adapter #(
    parameter [31:0] READ_TIMEOUT = 32'd1000000
) (
    input wire clk_sys,
    input wire rst_sys_n,
    input wire sd_init_done,
    input wire [2:0] sd_init_error,
    output wire sd_sec_read,
    output reg [31:0] sd_sec_read_addr,
    input wire [7:0] sd_sec_read_data,
    input wire sd_sec_read_data_valid,
    input wire sd_sec_read_end,
    input wire sd_sec_read_error,
    output wire sec_req_ready,
    input wire sec_req_valid,
    input wire [31:0] sec_req_lba,
    output wire sec_data_valid,
    output wire [7:0] sec_data,
    output wire sec_done,
    output wire sec_error,
    output wire fault
);
    localparam [2:0] IDLE = 3'd0, START = 3'd1, READ = 3'd2,
                     DONE = 3'd3, FAULT = 3'd4;
    localparam [31:0] LIMIT = READ_TIMEOUT == 0 ? 32'd1 : READ_TIMEOUT;
    reg [2:0] state;
    reg [9:0] count;
    reg [31:0] timer;
    reg read_failed;

    assign sec_req_ready = state == IDLE && sd_init_done && sd_init_error == 0;
    assign sd_sec_read = state == START;
    assign sec_data_valid = state == READ && sd_sec_read_data_valid;
    assign sec_data = sd_sec_read_data;
    assign sec_done = state == DONE;
    assign sec_error = read_failed;
    assign fault = state == FAULT || (state == DONE && read_failed);

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            state <= IDLE;
            sd_sec_read_addr <= 32'd0;
            count <= 10'd0;
            timer <= 32'd0;
            read_failed <= 1'b0;
        end else begin
            case (state)
                IDLE: if (sec_req_valid && sec_req_ready) begin
                    sd_sec_read_addr <= sec_req_lba;
                    count <= 10'd0;
                    timer <= 32'd0;
                    read_failed <= 1'b0;
                    state <= START;
                end
                START: begin
                    if (!sd_init_done || sd_init_error != 0 || timer >= LIMIT - 32'd1) begin
                        read_failed <= 1'b1;
                        state <= DONE;
                    end else begin
                        timer <= timer + 32'd1;
                        state <= READ;
                    end
                end
                READ: begin
                    if (sd_sec_read_data_valid) begin
                        if (count < 10'd513)
                            count <= count + 10'd1;
                    end
                    if (!sd_init_done || sd_init_error != 0) begin
                        read_failed <= 1'b1;
                        state <= DONE;
                    end else if (sd_sec_read_end) begin
                        read_failed <= sd_sec_read_error ||
                                       count + {9'd0, sd_sec_read_data_valid} != 10'd512;
                        state <= DONE;
                    end else if (timer >= LIMIT - 32'd1) begin
                        read_failed <= 1'b1;
                        state <= DONE;
                    end else
                        timer <= timer + 32'd1;
                end
                DONE: state <= read_failed ? FAULT : IDLE;
                FAULT: state <= FAULT;
                default: state <= FAULT;
            endcase
        end
    end
endmodule
