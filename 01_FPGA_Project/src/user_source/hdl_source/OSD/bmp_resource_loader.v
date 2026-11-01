`timescale 1ns/1ps
// Internal SYS-clock BMP client of image_text_loader. Example-5 header policy:
// BM, width/height LOW 16 bits = 640/480, 24-bit, BI_RGB. Other header fields
// are trusted to the offline packer. Directory file_bytes is authoritative.
// File-order (bottom-up) RGB words require WRITE_BOTTOM_UP=1 in
// sdram_image_backend. No SD pins, FAT parsing, framebuffer or extra sector RAM.
// A published request is NEVER withdrawn on stop/error. Drain its data/response
// and cancel the back-bank writer before reporting idle. Timeouts request a
// coordinated reset; they do not falsely claim that outstanding work vanished.
module bmp_resource_loader #(
    parameter integer RESOURCE_VERSION=2,
    parameter integer BANK_BITS=2,
    parameter integer IMAGE_BANK_COUNT=2,
    parameter [31:0] LOAD_TIMEOUT_CYCLES=32'd500000000,
    parameter [31:0] DRAIN_TIMEOUT_CYCLES=32'd10000000
) (
    input wire clk_sys,rst_sys_n,service_ready,
    input wire [7:0] service_error,
    input wire bmp_load_valid,
    output wire bmp_load_ready,
    input wire [7:0] bmp_load_resource_id,
    input wire [31:0] bmp_load_file_bytes,
    input wire [BANK_BITS-1:0] bmp_load_bank,
    input wire bmp_stop_req,
    output wire bmp_idle,bmp_error,
    output reg bmp_prepared,
    output reg [BANK_BITS-1:0] bmp_prepared_bank,
    output reg [7:0] bmp_error_code,
    output reg bmp_recovery_needed,
    output wire img_req_valid,
    input wire img_req_ready,
    output wire [7:0] img_req_resource_id,
    output wire [31:0] img_req_block_index,
    input wire img_data_valid,
    output wire img_data_ready,
    input wire [7:0] img_data,
    input wire img_data_last,img_file_last,img_rsp_valid,
    output wire img_rsp_ready,
    input wire [2:0] img_rsp_status,
    output wire image_write_start_sys,
    output wire [BANK_BITS-1:0] image_write_bank_sys,
    input wire image_write_start_ready_sys,
    output wire image_write_data_valid_sys,
    output wire [31:0] image_write_data_sys,
    input wire image_write_data_ready_sys,image_write_busy_sys,image_prepared_sys,
    input wire [BANK_BITS-1:0] prepared_image_bank_sys,
    input wire image_write_error_sys,
    output wire image_write_abort_sys,
    input wire image_write_abort_ack_sys
);
    localparam [2:0] IDLE=0,REQ=1,RX=2,RSP=3,DRAIN=4;
    localparam [19:0] PIXEL_BYTES=20'd921600;
    localparam [31:0] LOAD_LIMIT=LOAD_TIMEOUT_CYCLES==0 ? 1:LOAD_TIMEOUT_CYCLES;
    localparam [31:0] DRAIN_LIMIT=DRAIN_TIMEOUT_CYCLES==0 ? 1:DRAIN_TIMEOUT_CYCLES;
    reg [2:0] state;
    reg [7:0] resource_id;
    reg [31:0] file_bytes,block_index,byte_count,pixel_offset;
    reg [19:0] pixel_bytes_left;
    reg header_bad;
    reg header_ok,writer_started,abort_active,abort_acked,file_ended;
    reg [1:0] color_index;
    reg [7:0] blue,green;
    reg [31:0] pixel_hold;
    reg pixel_valid;
    reg [31:0] load_timer,drain_timer;
    reg header_byte_bad;
    wire service_fault=!service_ready || service_error!=0;
    wire timeout_now=state!=IDLE && !bmp_recovery_needed &&
        (load_timer>=LOAD_LIMIT-1 || (abort_active && drain_timer>=DRAIN_LIMIT-1));
    wire abort_now=abort_active || bmp_stop_req || service_fault || image_write_error_sys || timeout_now;
    // Bound the physical image to one complete frame and discard trailing
    // file bytes, even while the final pixel is held under backpressure.
    wire in_pixels=byte_count>=pixel_offset && byte_count<file_bytes && pixel_bytes_left!=0;
    wire req_fire=img_req_valid && img_req_ready;
    wire data_fire=img_data_valid && img_data_ready;
    wire rsp_fire=img_rsp_valid && img_rsp_ready;
    wire pixel_fire=image_write_data_valid_sys && image_write_data_ready_sys;
    wire header_valid=!header_bad;
    wire [7:0] byte_failure=(byte_count==53 && !header_valid) ? 8'd1:8'd0;
    wire [7:0] rsp_failure=img_rsp_status!=0 ? 8'd5:8'd0;
    assign bmp_idle=state==IDLE;
    assign bmp_error=bmp_error_code!=0;
    assign bmp_load_ready=state==IDLE && service_ready && service_error==0 &&
        !bmp_stop_req && !bmp_recovery_needed && !image_write_busy_sys && !image_write_error_sys;
    assign img_req_valid=state==REQ;
    assign img_req_resource_id=resource_id;
    assign img_req_block_index=block_index;
    // Buffered service can pause at any byte. A pixel hold register protects
    // B/G/R assembly through stalls and through a 512-byte block boundary.
    assign img_data_ready=state==RSP || (state==RX && (abort_now || byte_count<54 ||
        (writer_started && (!in_pixels || !pixel_valid || image_write_data_ready_sys))));
    assign img_rsp_ready=state==RX || state==RSP;
    assign image_write_start_sys=state!=IDLE && header_ok && !writer_started && !abort_now;
    assign image_write_bank_sys=bmp_prepared_bank;
    assign image_write_data_valid_sys=pixel_valid && !abort_now;
    assign image_write_data_sys=pixel_hold;
    // A completed task owns no in-flight writer. Stopping an IDLE prepared
    // task only invalidates its public descriptor; never strand a cancel ack.
    assign image_write_abort_sys=state!=IDLE && writer_started && abort_now && !abort_acked;
    always @* begin
        // Same header_match predicate as example 5, checked as bytes arrive.
        // No full-field shift registers or duplicate final comparators.
        header_byte_bad=0;
        case(byte_count)
            0: header_byte_bad=img_data!=8'h42;
            1: header_byte_bad=img_data!=8'h4d;
            18: header_byte_bad=img_data!=8'h80;
            19: header_byte_bad=img_data!=8'h02;
            22: header_byte_bad=img_data!=8'he0;
            23: header_byte_bad=img_data!=8'h01;
            28: header_byte_bad=img_data!=8'h18;
            29,30,31,32,33: header_byte_bad=img_data!=0;
            default: ;
        endcase
    end
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            state<=IDLE;resource_id<=0;file_bytes<=0;block_index<=0;byte_count<=0;
            pixel_offset<=0;pixel_bytes_left<=0;header_bad<=0;header_ok<=0;
            writer_started<=0;abort_active<=0;abort_acked<=0;file_ended<=0;
            color_index<=0;blue<=0;green<=0;pixel_hold<=0;pixel_valid<=0;
            load_timer<=0;drain_timer<=0;bmp_prepared<=0;bmp_prepared_bank<=0;
            bmp_error_code<=0;bmp_recovery_needed<=0;
        end else begin
            if(state!=IDLE) begin
                if(load_timer<LOAD_LIMIT) load_timer<=load_timer+1'b1;
                if(abort_active && drain_timer<DRAIN_LIMIT) drain_timer<=drain_timer+1'b1;
                if(bmp_stop_req || service_fault || image_write_error_sys || timeout_now) begin
                    abort_active<=1;pixel_valid<=0;
                    if(bmp_error_code==0) begin
                        if(timeout_now) bmp_error_code<=3;
                        else if(image_write_error_sys) bmp_error_code<=4;
                        else if(service_fault) bmp_error_code<=5;
                    end
                    if(timeout_now || image_write_error_sys) bmp_recovery_needed<=1;
                end
                if(image_write_abort_sys && image_write_abort_ack_sys) abort_acked<=1;
                if(image_write_start_sys && image_write_start_ready_sys) writer_started<=1;
                if(pixel_fire) pixel_valid<=0;
            end
            case(state)
                IDLE: begin
                    if(bmp_stop_req) bmp_prepared<=0;
                    if(bmp_load_valid && bmp_load_ready) begin
                        resource_id<=bmp_load_resource_id;file_bytes<=bmp_load_file_bytes;
                        bmp_prepared_bank<=bmp_load_bank;bmp_prepared<=0;bmp_error_code<=0;
                        block_index<=0;byte_count<=0;
                        pixel_offset<=0;pixel_bytes_left<=PIXEL_BYTES;header_bad<=0;
                        header_ok<=0;writer_started<=0;abort_active<=0;abort_acked<=0;
                        file_ended<=0;color_index<=0;pixel_valid<=0;
                        load_timer<=0;drain_timer<=0;
                        if(bmp_load_bank>=IMAGE_BANK_COUNT || (RESOURCE_VERSION==3 ? bmp_load_resource_id>=16 : (bmp_load_resource_id>30 || bmp_load_resource_id[0])) ||
                            bmp_load_file_bytes<54) begin
                            bmp_error_code<=1;state<=IDLE;
                        end else state<=REQ;
                    end
                end
                REQ: if(req_fire) state<=RX;
                RX,RSP: begin
                    if(data_fire) begin
                        if(byte_count<file_bytes) byte_count<=byte_count+1'b1;
                        if(img_data_last) state<=RSP;
                        if(img_file_last) file_ended<=1;
                        if(!abort_now && byte_failure!=0) begin
                            abort_active<=1;pixel_valid<=0;
                            if(bmp_error_code==0) bmp_error_code<=byte_failure;
                        end
                        if(!abort_now && byte_failure==0) begin
                            case(byte_count)
                                // Fixed byte shift, little-endian after 4 bytes.
                                // Avoid variable bit-select/barrel-write logic.
                                10,11,12,13: pixel_offset<={img_data,pixel_offset[31:8]};
                                53: header_ok<=1;
                                default: ;
                            endcase
                            if(header_byte_bad) header_bad<=1;
                            if(header_ok && in_pixels) begin
                                pixel_bytes_left<=pixel_bytes_left-1'b1;
                                case(color_index)
                                    0: begin blue<=img_data;color_index<=1;end
                                    1: begin green<=img_data;color_index<=2;end
                                    2: begin pixel_hold<={img_data,green,blue,8'h00};pixel_valid<=1;color_index<=0;end
                                    default: color_index<=0;
                                endcase
                            end
                        end
                    end
                    if(rsp_fire) begin
                        if(rsp_failure!=0 && !abort_now) begin
                            abort_active<=1;pixel_valid<=0;
                            if(bmp_error_code==0) bmp_error_code<=rsp_failure;
                        end
                        if(abort_now || bmp_error_code!=0 || rsp_failure!=0 ||
                            (data_fire && byte_failure!=0)) state<=DRAIN;
                        // The real resource service owns block byte counts,
                        // last-marker correctness and file length validation.
                        // Its successful final response is authoritative.
                        else if(file_ended || (data_fire && img_file_last)) state<=DRAIN;
                        else begin block_index<=block_index+1'b1;state<=REQ;end
                    end
                end
                DRAIN: begin
                    if(abort_now || bmp_error_code!=0) begin
                        pixel_valid<=0;
                        if(!writer_started || (abort_acked && !image_write_abort_ack_sys && !image_write_busy_sys)) state<=IDLE;
                    end else if(pixel_bytes_left!=0 || color_index!=0) begin
                        bmp_error_code<=2;abort_active<=1;pixel_valid<=0;
                    end else if(!pixel_valid && image_prepared_sys) begin
                        if(prepared_image_bank_sys==bmp_prepared_bank) begin bmp_prepared<=1;state<=IDLE;end
                        else begin bmp_error_code<=2;abort_active<=1;end
                    end
                end
                default: state<=IDLE;
            endcase
        end
    end
endmodule
