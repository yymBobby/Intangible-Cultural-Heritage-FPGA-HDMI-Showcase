`timescale 1ns/1ps
// System-clock-only ICHTXT02 reader. This is an INTERNAL component of A's
// future image_text_loader, not the complete image/BMP loader or a CDC RAM.
// Provisional writes may touch only the selected BACK bank. Never display it
// unless text_prepared is set, and later commit image + text together.
module osd_text_loader #(
    parameter [31:0] FONT_SET_ID = 32'hCBE17BCF,
    parameter [15:0] GLYPH_COUNT = 16'd175,
    // Whole text-load budget in clk_sys cycles, including request/cache stalls.
    // Timeout does NOT withdraw a published request or discard its response.
    parameter [31:0] LOAD_TIMEOUT_CYCLES = 32'd10000000
) (
    input wire clk_sys,
    input wire rst_sys_n,
    input wire service_ready,
    input wire [7:0] service_error,
    // Internal start interface. Outer loader locks fields from img_load_*.
    input wire text_load_valid,
    output wire text_load_ready,
    input wire [7:0] text_load_resource_id,
    input wire [31:0] text_load_file_bytes,
    input wire [31:0] text_load_font_set_id,
    input wire [15:0] text_load_glyph_count,
    input wire text_load_bank,
    input wire text_stop_req,
    output wire text_idle,
    output reg text_prepared,
    output wire text_error,
    output reg [7:0] text_error_code,
    // Sticky timeout alarm for the outer controller's coordinated reset.
    output reg text_recovery_needed,
    output reg [6:0] text_token_count,
    // C's unchanged display-file stream. Outer loader later arbitrates BMP.
    output wire img_req_valid,
    input wire img_req_ready,
    output wire [7:0] img_req_resource_id,
    output wire [31:0] img_req_block_index,
    input wire img_data_valid,
    output wire img_data_ready,
    input wire [7:0] img_data,
    input wire img_data_last,
    input wire img_file_last,
    input wire img_rsp_valid,
    output wire img_rsp_ready,
    input wire [2:0] img_rsp_status,
    // Internal BACK-bank write stream, all in clk_sys, valid/ready handshake.
    output wire text_write_valid,
    input wire text_write_ready,
    output wire text_write_bank,
    output wire [5:0] text_write_addr,
    output wire [15:0] text_write_glyph_id
);
    localparam [1:0] S_IDLE=2'd0, S_REQ=2'd1, S_RX=2'd2, S_RSP=2'd3;
    localparam [31:0] TIMEOUT_LIMIT = LOAD_TIMEOUT_CYCLES == 0 ? 32'd1 : LOAD_TIMEOUT_CYCLES;
    reg [1:0] state;
    reg [7:0] resource_id;
    // Load admission checks the full 32-bit input (24..152). Keeping the
    // admitted length in eight bits shortens per-byte end/range comparisons.
    reg [7:0] file_bytes;
    reg write_bank;
    reg [9:0] received_count; // Saturates at 1023; excess bytes stay invalid.
    reg [15:0] header_token_count;
    reg [7:0] glyph_low;
    reg [31:0] expected_crc, crc_state;
    reg saw_end, abort_active;
    reg [31:0] load_timer;
    reg [7:0] byte_error, response_error, failure_now;
    reg glyph_pending;
    reg [15:0] pending_glyph;
    reg [5:0] pending_addr;

    function [7:0] magic_byte;
        input [2:0] index;
        begin
            case (index)
                0: magic_byte="I"; 1: magic_byte="C";
                2: magic_byte="H"; 3: magic_byte="T";
                4: magic_byte="X"; 5: magic_byte="T";
                6: magic_byte="0"; 7: magic_byte="2";
            endcase
        end
    endfunction

    // Reflected CRC-32/ISO-HDLC: init FFFFFFFF, polynomial EDB88320,
    // final XOR FFFFFFFF; only payload bytes (including padding space IDs).
    function [31:0] crc_byte;
        input [31:0] previous;
        input [7:0] value;
        reg [31:0] next_crc;
        integer bit_index;
        begin
            next_crc = previous ^ {24'd0,value};
            for (bit_index=0; bit_index<8; bit_index=bit_index+1)
                next_crc = next_crc[0] ? ((next_crc >> 1) ^ 32'hEDB88320) : (next_crc >> 1);
            crc_byte = next_crc;
        end
    endfunction

    wire [15:0] incoming_glyph = {img_data,glyph_low};
    wire [15:0] incoming_count = {img_data,header_token_count[7:0]};
    wire [9:0] payload_offset = received_count - 10'd24;
    wire service_fault = !service_ready || service_error != 0;
    wire payload_high = received_count >= 10'd24 && received_count[0];
    wire writable_glyph = state == S_RX && payload_high &&
        received_count < {2'd0,file_bytes} && received_count < 10'd152 &&
        incoming_glyph < GLYPH_COUNT && text_error_code == 0 &&
        !abort_active && !text_stop_req && !service_fault && !img_rsp_valid;
    wire req_fire = img_req_valid && img_req_ready;
    wire data_fire = img_data_valid && img_data_ready;
    wire rsp_fire = img_rsp_valid && img_rsp_ready;
    // A response accepted exactly at the limit is allowed; no second budget.
    wire timeout_now = state != S_IDLE && !text_recovery_needed &&
        load_timer >= TIMEOUT_LIMIT - 32'd1 && !rsp_fire;

    assign text_load_ready = state == S_IDLE && service_ready && service_error == 0 &&
                             !text_stop_req && !text_recovery_needed;
    assign text_idle = state == S_IDLE;
    assign text_error = text_error_code != 0;
    assign img_req_valid = state == S_REQ;
    assign img_req_resource_id = resource_id;
    assign img_req_block_index = 32'd0;
    // Backpressure is based on the held glyph, never the current RAM byte.
    // Low bytes may advance while the previous complete glyph waits to write.
    assign img_data_ready = state == S_RX ?
        (abort_active || text_stop_req || service_fault || text_error_code!=0 ||
         !payload_high || !glyph_pending || text_write_ready) : state == S_RSP;
    assign img_rsp_ready = (state == S_RX || state == S_RSP) &&
        (!glyph_pending || text_write_ready || abort_active || text_stop_req || service_fault || text_error_code!=0);
    assign text_write_valid = glyph_pending && !abort_active && !text_stop_req &&
        !service_fault && text_error_code==0 && !timeout_now;
    assign text_write_bank = write_bank;
    assign text_write_addr = pending_addr;
    assign text_write_glyph_id = pending_glyph;

    always @* begin
        byte_error = 8'd0;
        if (state == S_RSP || received_count >= {2'd0,file_bytes})
            byte_error = 8'd2;
        else if (received_count < 8) begin
            if (img_data != magic_byte(received_count[2:0])) byte_error=8'd1;
        end else begin
            case (received_count)
                8: if (img_data != 8'd2) byte_error=8'd1;
                9: if (img_data != 0) byte_error=8'd1;
                10,11: if (img_data != 8'd32) byte_error=8'd1;
                12: if (img_data != FONT_SET_ID[7:0]) byte_error=8'd1;
                13: if (img_data != FONT_SET_ID[15:8]) byte_error=8'd1;
                14: if (img_data != FONT_SET_ID[23:16]) byte_error=8'd1;
                15: if (img_data != FONT_SET_ID[31:24]) byte_error=8'd1;
                17: begin
                    if (incoming_count > 16'd64) byte_error=8'd1;
                    else if ({1'b0,file_bytes} != 9'd24 + {1'b0,incoming_count[6:0],1'b0}) byte_error=8'd2;
                end
                18: if (img_data != 8'd16) byte_error=8'd1;
                19: if (img_data != 8'd4) byte_error=8'd1;
                default: if (payload_high && incoming_glyph >= GLYPH_COUNT) byte_error=8'd1;
            endcase
        end
        // There is only one block: both end flags belong to the exact final byte.
        if ((img_data_last || img_file_last) &&
            (!img_data_last || !img_file_last || received_count+10'd1 != {2'd0,file_bytes}))
            byte_error=8'd2;
        if (received_count+10'd1 == {2'd0,file_bytes} && (!img_data_last || !img_file_last))
            byte_error=8'd2;

        response_error = 8'd0;
        if (img_rsp_status != 0) response_error=8'd3;
        else if (state != S_RSP || !saw_end || received_count != {2'd0,file_bytes} || img_data_valid)
            response_error=8'd2;
        else if ((crc_state ^ 32'hFFFFFFFF) != expected_crc) response_error=8'd6;

        failure_now = 8'd0;
        if (state != S_IDLE) begin
            if (service_fault) failure_now=8'd3;
            else if (timeout_now) failure_now=8'd4;
            else if (rsp_fire && response_error != 0) failure_now=response_error;
            else if (data_fire && byte_error != 0) failure_now=byte_error;
        end
    end

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            state<=S_IDLE; resource_id<=0; file_bytes<=0; write_bank<=0;
            received_count<=0; header_token_count<=0; glyph_low<=0;
            expected_crc<=0; crc_state<=32'hFFFFFFFF; saw_end<=0;
            abort_active<=0; load_timer<=0; text_prepared<=0;
            text_error_code<=0; text_recovery_needed<=0; text_token_count<=0;
            glyph_pending<=0;pending_glyph<=0;pending_addr<=0;
        end else begin
            if(text_write_valid && text_write_ready) glyph_pending<=0;
            if(text_stop_req || service_fault || timeout_now || text_error_code!=0) glyph_pending<=0;
            if (text_stop_req) text_prepared<=0;
            if (state != S_IDLE) begin
                if (load_timer < TIMEOUT_LIMIT) load_timer<=load_timer+32'd1;
                if (text_stop_req || service_fault || timeout_now) begin
                    abort_active<=1;
                    text_prepared<=0;
                end
                if (timeout_now) text_recovery_needed<=1;
                if (text_error_code == 0 && failure_now != 0) text_error_code<=failure_now;
            end
            case (state)
                S_IDLE: if (text_load_valid && text_load_ready) begin
                    resource_id<=text_load_resource_id;
                    file_bytes<=text_load_file_bytes[7:0];
                    write_bank<=text_load_bank;
                    received_count<=0; header_token_count<=0; glyph_low<=0;
                    expected_crc<=0; crc_state<=32'hFFFFFFFF; saw_end<=0;
                    abort_active<=0; load_timer<=0; text_token_count<=0;
                    text_prepared<=0; text_error_code<=0;
                    glyph_pending<=0;
                    if (text_load_font_set_id != FONT_SET_ID ||
                        text_load_glyph_count != GLYPH_COUNT || GLYPH_COUNT == 0 || GLYPH_COUNT > 512 ||
                        text_load_resource_id < 8'h80 || text_load_resource_id > 8'h8F)
                        text_error_code<=8'd1;
                    else if (text_load_file_bytes < 24 || text_load_file_bytes > 152 || text_load_file_bytes[0])
                        text_error_code<=8'd2;
                    else state<=S_REQ;
                end
                S_REQ: if (req_fire) state<=S_RX;
                S_RX, S_RSP: begin
                    if (data_fire) begin
                        if(writable_glyph && !timeout_now && byte_error==0) begin
                            pending_glyph<=incoming_glyph;pending_addr<=payload_offset[6:1];glyph_pending<=1;
                        end
                        if (received_count != 10'd1023) received_count<=received_count+10'd1;
                        if (state == S_RX) begin
                            case (received_count)
                                16: header_token_count[7:0]<=img_data;
                                17: header_token_count[15:8]<=img_data;
                                20: expected_crc[7:0]<=img_data;
                                21: expected_crc[15:8]<=img_data;
                                22: expected_crc[23:16]<=img_data;
                                23: expected_crc[31:24]<=img_data;
                                default: ;
                            endcase
                            if (received_count >= 24) begin
                                crc_state<=crc_byte(crc_state,img_data);
                                if (!received_count[0]) glyph_low<=img_data;
                            end
                            if (img_data_last) begin
                                saw_end<=img_file_last;
                                state<=S_RSP;
                            end
                        end
                    end
                    if (rsp_fire) begin
                        state<=S_IDLE;
                        if (!abort_active && !text_stop_req && text_error_code == 0 &&
                            failure_now == 0 && response_error == 0) begin
                            text_prepared<=1;
                            text_token_count<=header_token_count[6:0];
                        end else begin
                            text_prepared<=0;
                            text_token_count<=0;
                        end
                    end
                end
                default: state<=S_IDLE;
            endcase
        end
    end
endmodule
