`timescale 1ns/1ps
// SYS-domain joint task owner. Reuses the existing two parsers; no extra RAM,
// FIFO, PLL, SD driver or independent frame commit. The img_* resource channel
// belongs to text until its FINAL response, then to BMP until physical finish.
// Connect joint_image_prepared_sys (NOT raw writer prepared) to frame commit.
module image_text_loader #(
    parameter integer RESOURCE_VERSION=2,
    parameter integer BANK_BITS=2,
    parameter integer IMAGE_BANK_COUNT=2,
    parameter integer CACHE_CONTROL=0,
    parameter [31:0] FONT_SET_ID=32'hCBE17BCF,
    parameter [15:0] GLYPH_COUNT=16'd175,
    parameter [31:0] LOAD_TIMEOUT_CYCLES=32'd500000000,
    parameter [31:0] TEXT_TIMEOUT_CYCLES=32'd10000000,
    parameter [31:0] DRAIN_TIMEOUT_CYCLES=32'd10000000
) (
    input wire clk_sys,rst_sys_n,service_ready,
    input wire [7:0] service_error,
    input wire cache_hit,cache_only,
    input wire [BANK_BITS-1:0] cache_slot,
    input wire img_load_valid,
    output wire img_load_ready,
    input wire [7:0] img_load_theme_id,img_load_image_index,img_load_resource_id,img_load_text_resource_id,
    input wire [31:0] img_load_file_bytes,img_load_text_file_bytes,img_load_font_set_id,
    input wire [15:0] img_load_glyph_count,
    input wire img_stop_req,
    output wire img_idle,img_error,
    output reg img_prepared,img_recovery_needed,
    output reg [7:0] img_error_code,
    output reg [1:0] img_error_stage, // 0 joint controller, 1 subtitle, 2 BMP
    output reg [7:0] img_prepared_theme_id,
    // A-internal admission/ownership, all SYS. Never load an active bank.
    input wire video_load_allowed_sys,text_back_available_sys,text_back_bank_sys,
    input wire [BANK_BITS-1:0] active_image_bank_sys,
    output reg [BANK_BITS-1:0] img_prepared_image_bank_sys,
    output reg img_prepared_text_bank_sys,
    output reg [6:0] img_prepared_text_count_sys,
    output wire text_prepared_sys,joint_image_prepared_sys,
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
    output wire text_write_valid,text_write_bank,
    input wire text_write_ready,
    output wire [5:0] text_write_addr,
    output wire [15:0] text_write_glyph_id,
    output wire image_write_start_sys,image_write_abort_sys,
    input wire image_write_start_ready_sys,image_write_abort_ack_sys,
    output wire [BANK_BITS-1:0] image_write_bank_sys,
    output wire image_write_data_valid_sys,
    output wire [31:0] image_write_data_sys,
    input wire image_write_data_ready_sys,image_write_busy_sys,image_prepared_sys,
    input wire [BANK_BITS-1:0] prepared_image_bank_sys,
    input wire image_write_error_sys
);
    localparam [2:0] IDLE=0,TEXT_START=1,TEXT_WAIT=2,BMP_START=3,BMP_WAIT=4,DRAIN=5;
    localparam [31:0] LOAD_LIMIT=LOAD_TIMEOUT_CYCLES==0 ? 1:LOAD_TIMEOUT_CYCLES;
    localparam [31:0] DRAIN_LIMIT=DRAIN_TIMEOUT_CYCLES==0 ? 1:DRAIN_TIMEOUT_CYCLES;
    reg [2:0] state;
    reg owner_bmp,abort_active,text_validated,hit_job,background_job;
    reg [7:0] image_id,text_id;
    reg [31:0] image_bytes,text_bytes,load_timer,drain_timer;
    // Predict the next counter comparison at its incrementing edge. This is
    // exactly load_timer >= LOAD_LIMIT-1, including LIMIT=1, but keeps the
    // wide comparator out of the combinational parser/writer stop path.
    reg load_budget_expired;
    wire text_load_ready,text_idle,text_prepared,text_error,text_recovery;
    wire [7:0] text_code;
    wire [6:0] text_count;
    wire bmp_load_ready,bmp_idle,bmp_prepared,bmp_error,bmp_recovery;
    wire [7:0] bmp_code;
    wire [BANK_BITS-1:0] bmp_bank;
    wire t_req,t_data_ready,t_rsp_ready,b_req,b_data_ready,b_rsp_ready;
    wire [7:0] t_id,b_id;
    wire [31:0] t_block,b_block;
    wire active=state!=IDLE;
    wire service_fault=!service_ready || service_error!=0;
    wire successful_finish=state==BMP_WAIT && bmp_idle && bmp_prepared &&
        !image_write_busy_sys && !image_write_abort_ack_sys &&
        bmp_bank==img_prepared_image_bank_sys;
    // One total budget across both files, never restarted at the owner switch.
    wire load_timeout=active && state!=DRAIN && load_budget_expired && !successful_finish;
    wire drain_timeout=state==DRAIN && drain_timer>=DRAIN_LIMIT-1 &&
        !(text_idle && bmp_idle && !image_write_busy_sys && !image_write_abort_ack_sys);
    wire text_failure=state==TEXT_WAIT && text_error;
    wire bmp_failure=state==BMP_WAIT && bmp_error;
    wire ownership_fault=active && state!=DRAIN &&
        (!video_load_allowed_sys || (!background_job && (!text_back_available_sys ||
         text_back_bank_sys!=img_prepared_text_bank_sys)) ||
         active_image_bank_sys>=IMAGE_BANK_COUNT || (!hit_job && active_image_bank_sys==img_prepared_image_bank_sys));
    wire abort_now=abort_active || img_stop_req ||
        (active && (service_fault || image_write_error_sys || load_timeout ||
                    ownership_fault || text_failure || bmp_failure));
    wire quiet_stop=state==IDLE && !img_prepared;
    wire parsers_stop=abort_now || quiet_stop;
    assign img_idle=state==IDLE && text_idle && bmp_idle &&
        !image_write_busy_sys && !image_write_abort_ack_sys;
    assign img_load_ready=rst_sys_n && img_idle && service_ready && service_error==0 &&
        video_load_allowed_sys && (CACHE_CONTROL && cache_only || text_back_available_sys) && active_image_bank_sys<IMAGE_BANK_COUNT &&
        image_write_start_ready_sys && !img_stop_req && !img_recovery_needed && !image_write_error_sys;
    assign img_error=img_error_code!=0;
    // This level freezes the completed subtitle bank even while BMP is loading.
    assign text_prepared_sys=text_validated && !abort_now && img_error_code==0 &&
        !service_fault && !image_write_error_sys;
    assign joint_image_prepared_sys=img_prepared && text_prepared_sys;
    assign img_req_valid=active && (owner_bmp ? b_req:t_req);
    assign img_req_resource_id=owner_bmp ? b_id:t_id;
    assign img_req_block_index=owner_bmp ? b_block:t_block;
    assign img_data_ready=active && (owner_bmp ? b_data_ready:t_data_ready);
    assign img_rsp_ready=active && (owner_bmp ? b_rsp_ready:t_rsp_ready);

    osd_text_loader #(.FONT_SET_ID(FONT_SET_ID),.GLYPH_COUNT(GLYPH_COUNT),
        .LOAD_TIMEOUT_CYCLES(TEXT_TIMEOUT_CYCLES)) text_loader(
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.service_ready(service_ready),.service_error(service_error),
        .text_load_valid(state==TEXT_START && !abort_now),.text_load_ready(text_load_ready),
        .text_load_resource_id(text_id),.text_load_file_bytes(text_bytes),
        .text_load_font_set_id(FONT_SET_ID),.text_load_glyph_count(GLYPH_COUNT),
        .text_load_bank(img_prepared_text_bank_sys),.text_stop_req(parsers_stop),
        .text_idle(text_idle),.text_prepared(text_prepared),.text_error(text_error),
        .text_error_code(text_code),.text_recovery_needed(text_recovery),.text_token_count(text_count),
        .img_req_valid(t_req),.img_req_ready(img_req_ready && active && !owner_bmp),
        .img_req_resource_id(t_id),.img_req_block_index(t_block),
        .img_data_valid(img_data_valid && active && !owner_bmp),.img_data_ready(t_data_ready),
        .img_data(img_data),.img_data_last(img_data_last),.img_file_last(img_file_last),
        .img_rsp_valid(img_rsp_valid && active && !owner_bmp),.img_rsp_ready(t_rsp_ready),.img_rsp_status(img_rsp_status),
        .text_write_valid(text_write_valid),.text_write_ready(text_write_ready),.text_write_bank(text_write_bank),
        .text_write_addr(text_write_addr),.text_write_glyph_id(text_write_glyph_id));
    bmp_resource_loader #(.RESOURCE_VERSION(RESOURCE_VERSION),.BANK_BITS(BANK_BITS),.IMAGE_BANK_COUNT(IMAGE_BANK_COUNT),.LOAD_TIMEOUT_CYCLES(LOAD_TIMEOUT_CYCLES),
        .DRAIN_TIMEOUT_CYCLES(DRAIN_TIMEOUT_CYCLES)) bmp_loader(
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.service_ready(service_ready),.service_error(service_error),
        .bmp_load_valid(state==BMP_START && !abort_now),.bmp_load_ready(bmp_load_ready),
        .bmp_load_resource_id(image_id),.bmp_load_file_bytes(image_bytes),.bmp_load_bank(img_prepared_image_bank_sys),
        .bmp_stop_req(parsers_stop),.bmp_idle(bmp_idle),.bmp_prepared(bmp_prepared),.bmp_error(bmp_error),
        .bmp_prepared_bank(bmp_bank),.bmp_error_code(bmp_code),.bmp_recovery_needed(bmp_recovery),
        .img_req_valid(b_req),.img_req_ready(img_req_ready && active && owner_bmp),
        .img_req_resource_id(b_id),.img_req_block_index(b_block),
        .img_data_valid(img_data_valid && active && owner_bmp),.img_data_ready(b_data_ready),
        .img_data(img_data),.img_data_last(img_data_last),.img_file_last(img_file_last),
        .img_rsp_valid(img_rsp_valid && active && owner_bmp),.img_rsp_ready(b_rsp_ready),.img_rsp_status(img_rsp_status),
        .image_write_start_sys(image_write_start_sys),.image_write_start_ready_sys(image_write_start_ready_sys),
        .image_write_bank_sys(image_write_bank_sys),.image_write_data_valid_sys(image_write_data_valid_sys),
        .image_write_data_sys(image_write_data_sys),.image_write_data_ready_sys(image_write_data_ready_sys),
        .image_write_busy_sys(image_write_busy_sys),.image_prepared_sys(image_prepared_sys),
        .prepared_image_bank_sys(prepared_image_bank_sys),.image_write_error_sys(image_write_error_sys),
        .image_write_abort_sys(image_write_abort_sys),.image_write_abort_ack_sys(image_write_abort_ack_sys));

    function [7:0] text_diagnostic;
        input [7:0] code;
        begin case(code) 1:text_diagnostic=1;2:text_diagnostic=2;3:text_diagnostic=3;
            4:text_diagnostic=4;6:text_diagnostic=6;default:text_diagnostic=5;endcase end
    endfunction
    function [7:0] bmp_diagnostic;
        input [7:0] code;
        begin case(code) 1:bmp_diagnostic=1;2:bmp_diagnostic=2;3:bmp_diagnostic=4;
            4:bmp_diagnostic=5;5:bmp_diagnostic=3;default:bmp_diagnostic=5;endcase end
    endfunction
    wire metadata_ok=(RESOURCE_VERSION==3 ?
        (img_load_theme_id<4 && img_load_image_index<4 &&
         img_load_resource_id=={4'd0,img_load_theme_id[1:0],img_load_image_index[1:0]}) :
        (img_load_theme_id<16 && img_load_resource_id=={img_load_theme_id[6:0],1'b0})) &&
        img_load_text_resource_id==(8'h80 | img_load_theme_id) &&
        img_load_file_bytes>=921654 && img_load_text_file_bytes>=24 &&
        img_load_text_file_bytes<=152 && !img_load_text_file_bytes[0] &&
        img_load_font_set_id==FONT_SET_ID && img_load_glyph_count==GLYPH_COUNT &&
        GLYPH_COUNT>0 && GLYPH_COUNT<=512;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            state<=IDLE;owner_bmp<=0;abort_active<=0;text_validated<=0;hit_job<=0;background_job<=0;
            image_id<=0;text_id<=0;image_bytes<=0;text_bytes<=0;load_timer<=0;drain_timer<=0;
            load_budget_expired<=LOAD_LIMIT<=1;
            img_prepared<=0;img_recovery_needed<=0;img_error_code<=0;img_error_stage<=0;
            img_prepared_theme_id<=0;img_prepared_image_bank_sys<=0;
            img_prepared_text_bank_sys<=0;img_prepared_text_count_sys<=0;
        end else begin
            if(img_stop_req || service_fault || image_write_error_sys) begin
                img_prepared<=0;text_validated<=0;
            end
            if(image_write_error_sys) begin
                img_recovery_needed<=1;
                if(img_error_code==0) begin img_error_code<=5;img_error_stage<=0;end
            end
            if(state==IDLE && img_prepared && service_fault && img_error_code==0) begin
                img_error_code<=3;img_error_stage<=0;
            end
            if(active) begin
                if(load_timer<LOAD_LIMIT) begin
                    load_timer<=load_timer+1'b1;
                    load_budget_expired<=LOAD_LIMIT<=1 || load_timer>=LOAD_LIMIT-2;
                end
                if(state==DRAIN && drain_timer<DRAIN_LIMIT) drain_timer<=drain_timer+1'b1;
                if(load_timeout || drain_timeout || text_recovery || bmp_recovery || ownership_fault)
                    img_recovery_needed<=1;
                if(img_error_code==0) begin
                    if(service_fault) begin img_error_code<=3;img_error_stage<=0;end
                    else if(image_write_error_sys) begin img_error_code<=5;img_error_stage<=0;end
                    else if(load_timeout || drain_timeout) begin img_error_code<=4;img_error_stage<=0;end
                    else if(ownership_fault) begin img_error_code<=5;img_error_stage<=0;end
                    else if(text_failure) begin img_error_code<=text_diagnostic(text_code);img_error_stage<=1;end
                    else if(bmp_failure) begin img_error_code<=bmp_diagnostic(bmp_code);img_error_stage<=2;end
                end
            end
            if(active && state!=DRAIN && abort_now) begin
                abort_active<=1;text_validated<=0;img_prepared<=0;drain_timer<=0;state<=DRAIN;
            end else case(state)
                IDLE: begin
                    abort_active<=0;
                    if(img_load_valid && img_load_ready) begin
                        img_prepared<=0;text_validated<=0;img_prepared_text_count_sys<=0;
                        img_error_code<=0;img_error_stage<=0;load_timer<=0;drain_timer<=0;
                        load_budget_expired<=LOAD_LIMIT<=1;
                        img_prepared_theme_id<=img_load_theme_id;
                        img_prepared_image_bank_sys<=CACHE_CONTROL ? cache_slot:!active_image_bank_sys[0];
                        hit_job<=CACHE_CONTROL && cache_hit;background_job<=CACHE_CONTROL && cache_only;
                        img_prepared_text_bank_sys<=text_back_bank_sys;
                        image_id<=img_load_resource_id;text_id<=img_load_text_resource_id;
                        image_bytes<=img_load_file_bytes;text_bytes<=img_load_text_file_bytes;owner_bmp<=0;
                        if(metadata_ok) begin
                            if(CACHE_CONTROL && cache_only) begin owner_bmp<=1;state<=BMP_START;end
                            else state<=TEXT_START;
                        end
                        else img_error_code<=1;
                    end
                end
                TEXT_START: if(text_load_ready) state<=TEXT_WAIT;
                TEXT_WAIT: if(text_idle) begin
                    if(text_prepared) begin
                        text_validated<=1;img_prepared_text_count_sys<=text_count;
                        if(hit_job) begin img_prepared<=1;state<=IDLE;end
                        else begin owner_bmp<=1;state<=BMP_START;end
                    end else begin
                        abort_active<=1;state<=DRAIN;img_error_code<=5;img_error_stage<=1;
                    end
                end
                BMP_START: if(bmp_load_ready) state<=BMP_WAIT;
                BMP_WAIT: if(successful_finish) begin
                    if(background_job || (text_validated && text_prepared)) begin img_prepared<=1;state<=IDLE;end
                    else begin abort_active<=1;state<=DRAIN;img_error_code<=5;img_error_stage<=2;end
                end else if(bmp_idle && !bmp_prepared) begin
                    abort_active<=1;state<=DRAIN;img_error_code<=5;img_error_stage<=2;
                end
                DRAIN: if(text_idle && bmp_idle && !image_write_busy_sys && !image_write_abort_ack_sys) begin
                    img_prepared<=0;text_validated<=0;img_prepared_text_count_sys<=0;state<=IDLE;
                end
                default: begin
                    abort_active<=1;state<=DRAIN;img_prepared<=0;text_validated<=0;
                    img_error_code<=5;img_error_stage<=0;img_recovery_needed<=1;
                end
            endcase
        end
    end
endmodule
