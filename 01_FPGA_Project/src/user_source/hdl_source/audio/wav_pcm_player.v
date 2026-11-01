`timescale 1ns/1ps
// Ultimate v0.6 player plus passive frame-gate feedback for UART completion.
module wav_pcm_player #(
    parameter integer RESOURCE_VERSION=2,
    parameter integer FIFO_ADDR_WIDTH=12,
    parameter integer LOW_WATER=2048, HIGH_WATER=3072, START_WATER=3072,
    parameter integer REQUEST_RESERVE=129,
    parameter integer LOAD_TIMEOUT_CYCLES=100000000,
    parameter integer TRANSACTION_TIMEOUT_CYCLES=100000000,
    parameter integer STOP_TIMEOUT_CYCLES=100000000
)(
    input wire clk_sys, rst_sys_n, I_mclk, rst_audio_n,
    input wire service_ready, input wire [7:0] service_error,
    input wire aud_load_valid, output wire aud_load_ready,
    input wire [7:0] aud_load_theme_id, aud_load_resource_id,
    input wire [31:0] aud_load_file_bytes,
    output wire aud_req_valid, input wire aud_req_ready,
    output reg [7:0] aud_req_resource_id, output reg [31:0] aud_req_block_index,
    input wire aud_data_valid, output wire aud_data_ready,
    input wire [7:0] aud_data, input wire aud_data_last, aud_file_last,
    input wire aud_rsp_valid, output wire aud_rsp_ready, input wire [2:0] aud_rsp_status,
    input wire aud_stop_req, audio_play_enable,
    output reg aud_idle, aud_prepared, aud_error, output reg [7:0] aud_error_code,
    output reg audio_urgent, output wire audio_ended, output reg audio_underflow,
    output wire audio_gate_applied,
    output reg O_i2s_BCLK, O_i2s_LRCK, O_i2s_DOUT
);
    localparam integer DEPTH=1<<FIFO_ADDR_WIDTH;
    localparam CLEAN=0, RELEASE=1, IDLE=2, RUN=3, FAULT=4;
    localparam NONE=0, REQUEST=1, DATA=2, RESPONSE=3, GAP=4;
    reg [2:0] control, transaction;
    reg clear_req, stop_seen, task_live, task_toggle;
    // Each counter only reaches parameter-1. Retain 32-bit modulo behavior
    // for zero/negative parameters, including legacy timeout-disabled cases.
    localparam integer LOAD_TIMER_WIDTH=LOAD_TIMEOUT_CYCLES>1 ? $clog2(LOAD_TIMEOUT_CYCLES) : (LOAD_TIMEOUT_CYCLES==1 ? 1:32);
    localparam integer IO_TIMER_WIDTH=TRANSACTION_TIMEOUT_CYCLES>1 ? $clog2(TRANSACTION_TIMEOUT_CYCLES) : (TRANSACTION_TIMEOUT_CYCLES==1 ? 1:32);
    localparam integer STOP_TIMER_WIDTH=STOP_TIMEOUT_CYCLES>1 ? $clog2(STOP_TIMEOUT_CYCLES) : (STOP_TIMEOUT_CYCLES==1 ? 1:32);
    localparam integer CONTROL_TIMER_WIDTH=LOAD_TIMER_WIDTH>STOP_TIMER_WIDTH ? LOAD_TIMER_WIDTH:STOP_TIMER_WIDTH;
    // Successful and hostile transactions both drain at most the declared
    // file bytes: expected final DATA automatically advances to RESPONSE.
    // Therefore file_length-received is nonnegative in every reachable task;
    // keep that difference directly and retain all 32 length bits.
    reg [31:0] file_remaining;
    reg [CONTROL_TIMER_WIDTH-1:0] control_timer;
    reg [IO_TIMER_WIDTH-1:0] io_timer;
    // DATA always completes after its expected final byte. One down-counter
    // replaces expected_bytes, expected_last and received-within-block.
    reg [9:0] block_remaining;
    reg any_pcm;
    wire load_fire=aud_load_valid && aud_load_ready;
    wire p_ready, p_valid, p_last, p_format, p_done, p_error;
    wire [7:0] p_error_code;
    wire signed [15:0] p_left, p_right;
    wire fifo_wr_ready, fifo_valid;
    wire [32:0] fifo_data;
    wire [FIFO_ADDR_WIDTH:0] fifo_used;
    wire discard = control!=RUN || aud_stop_req || aud_error || p_error || p_done;
    wire write_pcm = control==RUN && !aud_stop_req && !aud_error && !clear_req;
    wire data_fire=aud_data_valid && aud_data_ready;
    wire rsp_fire=aud_rsp_valid && aud_rsp_ready;
    assign aud_load_ready=control==IDLE && aud_idle && !aud_stop_req;
    assign aud_req_valid=transaction==REQUEST;
    assign aud_data_ready=transaction==DATA && (discard || p_ready);
    assign aud_rsp_ready=transaction==DATA || transaction==RESPONSE;

    wav_pcm_parser parser (
        .clk_sys(clk_sys), .rst_sys_n(rst_sys_n), .clear(clear_req), .start(load_fire),
        .file_bytes(aud_load_file_bytes), .byte_valid(data_fire && !discard),
        .byte_ready(p_ready), .byte_data(aud_data), .byte_file_last(aud_file_last),
        .pcm_valid(p_valid), .pcm_ready(fifo_wr_ready && write_pcm),
        .pcm_left(p_left), .pcm_right(p_right), .pcm_last(p_last),
        .format_valid(p_format), .data_done(p_done), .error(p_error), .error_code(p_error_code)
    );

    (* ASYNC_REG="TRUE" *) reg clear_a1, clear_a2, play_a1, play_a2, task_a1, task_a2;
    reg clear_ack_a, task_ack_a, ended_a, underflow_a;
    (* ASYNC_REG="TRUE" *) reg ack_s1, ack_s2, task_s1, task_s2;
    (* ASYNC_REG="TRUE" *) reg ended_s1, ended_s2, under_s1, under_s2;
    wire allow_play=control==RUN && aud_prepared && !aud_error && !aud_stop_req && audio_play_enable;
    assign audio_ended=control==RUN && !aud_stop_req && !aud_error && task_s2==task_toggle && ended_s2;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            ack_s1<=0; ack_s2<=0; task_s1<=0; task_s2<=0;
            ended_s1<=0; ended_s2<=0; under_s1<=0; under_s2<=0;
        end else begin
            ack_s1<=clear_ack_a; ack_s2<=ack_s1; task_s1<=task_ack_a; task_s2<=task_s1;
            ended_s1<=ended_a; ended_s2<=ended_s1; under_s1<=underflow_a; under_s2<=under_s1;
        end
    end
    always @(posedge I_mclk or negedge rst_audio_n) begin
        if(!rst_audio_n) begin clear_a1<=1; clear_a2<=1; play_a1<=0; play_a2<=0; task_a1<=0; task_a2<=0; end
        else begin
            clear_a1<=clear_req; clear_a2<=clear_a1;
            play_a1<=allow_play; play_a2<=play_a1; task_a1<=task_toggle; task_a2<=task_a1;
        end
    end

    reg [5:0] bit_count;
    // All loaded words have 48 trailing zeroes. Left-shifting never brings
    // those low bits into the retained 16-bit high portion except as zero.
    reg [15:0] shift_word;
    reg [15:0] right_word;
    reg frame_active, frame_last, last_pending, silent_frame;
    wire frame_boundary=O_i2s_BCLK && bit_count==63 && O_i2s_LRCK;
    reg gate_applied_a;
    (* ASYNC_REG="TRUE" *) reg gate_meta_sys,gate_sync_sys;
    assign audio_gate_applied=gate_sync_sys;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin gate_meta_sys<=0;gate_sync_sys<=0;end
        else begin gate_meta_sys<=gate_applied_a;gate_sync_sys<=gate_meta_sys;end
    end
    always @(posedge I_mclk or negedge rst_audio_n) begin
        if(!rst_audio_n) gate_applied_a<=0;
        else if(frame_boundary) gate_applied_a<=!clear_a2 && play_a2;
    end
    wire take_frame=frame_boundary && !clear_a2 && play_a2 && !ended_a && !frame_last && fifo_valid;
    pcm_async_fifo #(.ADDR_WIDTH(FIFO_ADDR_WIDTH)) fifo (
        .wr_clk(clk_sys), .wr_rst_n(rst_sys_n), .wr_clear(clear_req),
        .wr_valid(p_valid && write_pcm), .wr_ready(fifo_wr_ready),
        .wr_data({p_last,p_left,p_right}), .wr_used(fifo_used),
        .rd_clk(I_mclk), .rd_rst_n(rst_audio_n), .rd_clear(clear_a2),
        .rd_valid(fifo_valid), .rd_ready(take_frame), .rd_data(fifo_data)
    );
    always @(posedge I_mclk or negedge rst_audio_n) begin
        if(!rst_audio_n) begin
            O_i2s_BCLK<=0; O_i2s_LRCK<=0; O_i2s_DOUT<=0; bit_count<=0;
            shift_word<=0; right_word<=0; frame_active<=0; frame_last<=0;
            last_pending<=0; silent_frame<=0; clear_ack_a<=0;
            task_ack_a<=0; ended_a<=0; underflow_a<=0;
        end else begin
            O_i2s_BCLK<=~O_i2s_BCLK;
            if(!clear_a2) begin clear_ack_a<=0; silent_frame<=0; end
            if(task_a2!=task_ack_a) begin
                task_ack_a<=task_a2; ended_a<=0; underflow_a<=0;
            end
            if(clear_a2) begin
                last_pending<=0; ended_a<=0;
            end
            if(!O_i2s_BCLK && last_pending) begin
                // The final right-slot bit has now reached its sampling edge.
                if(!clear_a2) ended_a<=1;
                last_pending<=0;
            end
            if(O_i2s_BCLK) begin // falling BCLK: old final bit, then load next slot
                // Finish the already latched stereo frame, then send a full zero frame.
                O_i2s_DOUT<=shift_word[15];
                shift_word<={shift_word[14:0],1'b0};
                if(bit_count==63) begin
                    bit_count<=0; O_i2s_LRCK<=~O_i2s_LRCK;
                    if(!O_i2s_LRCK) shift_word<=right_word;
                    else begin
                        last_pending<=frame_active && frame_last && !clear_a2;
                        frame_active<=0; frame_last<=0; right_word<=0; shift_word<=0;
                        if(clear_a2) begin
                            if(silent_frame) clear_ack_a<=1;
                            silent_frame<=1;
                        end else if(take_frame) begin
                            shift_word<=fifo_data[31:16]; right_word<=fifo_data[15:0];
                            frame_active<=1; frame_last<=fifo_data[32];
                        end else if(play_a2 && !ended_a && !frame_last) underflow_a<=1;
                    end
                end else bit_count<=bit_count+1;
            end
        end
    end

    wire request_eligible=control==RUN && !aud_stop_req && !aud_error && !p_error && !p_done &&
         service_ready && service_error==0 && fifo_used<HIGH_WATER && fifo_used<=DEPTH-REQUEST_RESERVE;
    wire parser_fault=control==RUN && p_error;
    wire service_fault=control==RUN && service_error!=0;
    wire load_timeout=control==RUN && !aud_prepared && !aud_stop_req && control_timer==LOAD_TIMEOUT_CYCLES-1;
    wire stop_timeout=control==CLEAN && !(transaction==NONE && ack_s2) && control_timer==STOP_TIMEOUT_CYCLES-1;
    wire io_timeout=transaction!=NONE && transaction!=GAP && !data_fire && !rsp_fire &&
        !(aud_req_valid && aud_req_ready) && (transaction!=DATA || aud_data_ready) &&
        io_timer==TRANSACTION_TIMEOUT_CYCLES-1;
    wire flags_fault=data_fire && (aud_data_last!=(block_remaining==1) ||
                                  aud_file_last!=(file_remaining==1));
    wire response_fault=rsp_fire && (aud_rsp_status!=0 || transaction==DATA || block_remaining!=0);
    wire length_fault=transaction==NONE && request_eligible && file_remaining==0;
    // One error write per cycle. Earlier registered errors remain latched;
    // simultaneous events use parser, response, boundary, service, timeout priority.
    wire [7:0] next_error=parser_fault ? p_error_code :
        response_fault ? (aud_rsp_status!=0 ? 8'd3 : 8'd2) :
        (flags_fault || length_fault) ? 8'd2 : service_fault ? 8'd3 :
        stop_timeout ? 8'd5 : io_timeout ? (control==RUN ? 8'd4 : 8'd5) :
        load_timeout ? 8'd4 : 8'd0;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            control<=CLEAN; transaction<=NONE; clear_req<=1; stop_seen<=0;
            task_live<=0; task_toggle<=0; file_remaining<=0;
            control_timer<=0; io_timer<=0; block_remaining<=0;
            any_pcm<=0; aud_req_resource_id<=0; aud_req_block_index<=0;
            aud_idle<=0; aud_prepared<=0; aud_error<=0; aud_error_code<=0;
            audio_urgent<=0; audio_underflow<=0;
        end else begin
            if(task_s2==task_toggle && under_s2) audio_underflow<=1;
            if(p_valid && fifo_wr_ready && write_pcm) any_pcm<=1;
            if(control==RUN) begin
                if(!aud_prepared && !aud_error && !aud_stop_req) begin
                    if(control_timer!=LOAD_TIMEOUT_CYCLES-1) control_timer<=control_timer+1;
                end
                if(!aud_error && !p_error && !aud_stop_req && p_format &&
                   (fifo_used>=START_WATER || (p_done && transaction==NONE && any_pcm))) aud_prepared<=1;
                if(aud_stop_req || aud_error || p_error || service_error!=0) begin
                    control<=CLEAN; clear_req<=1; aud_prepared<=0;
                    stop_seen<=aud_stop_req; control_timer<=0;
                end
            end
            if(control!=RUN || aud_stop_req || aud_error || p_done) audio_urgent<=0;
            else if(fifo_used<=LOW_WATER) audio_urgent<=1;
            else if(fifo_used>=HIGH_WATER) audio_urgent<=0;

            case(control)
                CLEAN: begin
                    if(aud_stop_req) stop_seen<=1;
                    if(transaction==NONE && ack_s2) begin clear_req<=0; control<=RELEASE; end
                    else if(control_timer!=STOP_TIMEOUT_CYCLES-1) control_timer<=control_timer+1;
                end
                RELEASE: begin
                    if(aud_stop_req) stop_seen<=1;
                    if(!ack_s2) begin
                        if(!task_live || stop_seen || aud_stop_req) begin control<=IDLE; aud_idle<=1; end
                        else control<=FAULT;
                    end
                end
                FAULT: if(aud_stop_req) begin control<=CLEAN; clear_req<=1; stop_seen<=1; control_timer<=0; end
                default: begin end
            endcase

            if(transaction!=NONE && transaction!=GAP) begin
                if(data_fire || rsp_fire || (aud_req_valid && aud_req_ready)) io_timer<=0;
                else if(transaction!=DATA || aud_data_ready) begin
                    if(io_timer!=TRANSACTION_TIMEOUT_CYCLES-1) io_timer<=io_timer+1;
                end
            end else io_timer<=0;
            case(transaction)
                NONE: if(request_eligible) begin
                    if(file_remaining!=0) begin
                        transaction<=REQUEST;
                        block_remaining<=file_remaining>=512 ? 10'd512 : file_remaining;
                    end
                end
                REQUEST: if(aud_req_ready) transaction<=DATA;
                DATA: begin
                    if(data_fire) begin
                        block_remaining<=block_remaining-1'b1; file_remaining<=file_remaining-1'b1;
                        if(aud_data_last || block_remaining==1) transaction<=RESPONSE;
                    end
                    if(rsp_fire) begin
                        transaction<=GAP;
                    end
                end
                RESPONSE: if(rsp_fire) begin
                    transaction<=GAP;
                    if(aud_rsp_status==0 && block_remaining==0) // A 32-bit file has at most ceil((2^32-1)/512)=2^23 blocks.
                    // The post-response public index includes that final count,
                    // so retain 24 bits (never truncate the bit-23 carry).
                    aud_req_block_index<={8'd0,(aud_req_block_index[23:0]+24'd1)};
                end
                GAP: transaction<=NONE;
                default: transaction<=NONE;
            endcase
            if(!aud_error && next_error!=0) begin aud_error<=1;aud_error_code<=next_error;end
            if(load_fire) begin
                control<=RUN; task_live<=1; task_toggle<=~task_toggle;
                stop_seen<=0; aud_idle<=0; aud_prepared<=0; aud_error<=0; aud_error_code<=0;
                audio_underflow<=0; any_pcm<=0; control_timer<=0; io_timer<=0;
                file_remaining<=aud_load_file_bytes;
                aud_req_resource_id<=aud_load_resource_id;
                aud_req_block_index<=0;
                if((RESOURCE_VERSION==3 ? (aud_load_theme_id>=4 || aud_load_resource_id!=(8'h40 | aud_load_theme_id)) :
                   (aud_load_theme_id>=16 || aud_load_resource_id!={aud_load_theme_id[6:0],1'b1})) ||
                   aud_load_file_bytes<12) begin aud_error<=1; aud_error_code<=2; end
            end
        end
    end
endmodule
