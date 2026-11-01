`timescale 1ns/1ps
// Unified image/text commit. C's public handshake lives in clk_sys.
// Image preparation and the atomic visible apply live in clk_pix. The image
// adapter owns pix<->mem CDC, burst fencing, FIFO clearing and prefill.
// This controller does NOT turn a raw VS edge or DE=0 into a safe window.
// All participating domains require coordinated reset, synchronous release.
module video_frame_commit #(
    parameter [31:0] COMMIT_TIMEOUT_CYCLES=32'd10000000,
    parameter integer IMAGE_BANK_COUNT=2,
    parameter integer BANK_BITS=2,
    parameter integer ALLOW_SAME_BANK=0,
    // Enable when connected to the real timing/image adapter. Kept optional
    // for existing tests whose supplied window already budgets preparation.
    parameter integer USE_STAGE_START_GUARD=0
) (
    input wire clk_sys, rst_sys_n,
    input wire clk_pix, rst_pix_n,
    // Public C -> A four-phase handshake. Do not withdraw req before ack.
    input wire video_commit_req,
    output reg video_commit_ack,
    output wire video_commit_busy_sys,
    output wire video_load_allowed_sys,
    output wire video_commit_error_sys,
    output reg [7:0] video_commit_error_code_sys,
    output wire video_recovery_needed_sys,
    input wire upstream_error_sys,
    // Validated, same-task descriptor; latched once at public request accept.
    input wire image_prepared_sys, text_prepared_sys,
    input wire [BANK_BITS-1:0] prepared_image_bank_sys,
    input wire prepared_text_bank_sys,
    input wire [6:0] prepared_text_count_sys,
    input wire text_back_bank_sys, text_back_available_sys,
    // Connect to the existing text_bank_cdc internal commit port.
    output reg text_commit_req_sys,
    output wire text_commit_bank_sys,
    output wire [6:0] text_commit_count_sys,
    input wire text_commit_ack_sys, text_commit_busy_sys, text_cache_error_sys,
    input wire text_commit_pending_pix, text_commit_bank_pix,
    input wire [6:0] text_commit_count_pix,
    output wire text_commit_apply_pix,
    input wire text_read_req_pix, text_read_valid_pix,
    input wire text_front_bank_pix,
    input wire [6:0] text_front_count_pix,
    // Guarded VBLANK window, including time for preparation/apply/verification.
    // old_video_drained must include image/OSD/AXIS old pixels, not OSD alone.
    input wire safe_commit_window_pix, video_de_pix, old_video_drained_pix,
    input wire image_stage_start_allowed_pix,
    // Internal image-adapter contract (all signals in clk_pix).
    // ready: old mem bursts/FIFO fenced and new-frame prefill complete.
    // applied: visible bank latched on image_apply_pix. Both hold until req low.
    output reg image_stage_req_pix,
    output wire [BANK_BITS-1:0] image_stage_bank_pix,
    input wire image_stage_ready_pix, image_applied_pix, image_stage_error_pix,
    input wire [BANK_BITS-1:0] image_front_bank_pix,
    output wire image_apply_pix,
    output reg [BANK_BITS-1:0] front_image_bank_pix,
    output reg front_valid_pix,
    // Keep HDMI timing running. Block RGB/OSD use during preparation or fault.
    output wire video_output_block_pix,
    output reg [BANK_BITS-1:0] active_image_bank_sys
);
    localparam [2:0] S_IDLE=0, S_WAIT_DONE=1, S_WAIT_REQ_LOW=2, S_RELEASE=3;
    localparam [2:0] P_IDLE=0, P_CAPTURE=1, P_WAIT_WINDOW=2, P_STAGE=3,
                     P_VERIFY=4, P_WAIT_REQ_LOW=5, P_RELEASE=6;
    localparam [31:0] LIMIT=COMMIT_TIMEOUT_CYCLES==0 ? 32'd1 : COMMIT_TIMEOUT_CYCLES;
    reg [2:0] sys_state, pix_state;
    reg request_hold_sys, descriptor_text_bank_sys, have_front_sys;
    reg [BANK_BITS-1:0] descriptor_image_bank_sys, pending_image_bank_pix;
    reg [6:0] descriptor_count_sys, pending_count_pix;
    reg pending_text_bank_pix, apply_ack_pix;
    reg window_used_pix;
    reg [7:0] pixel_error_code;
    reg [31:0] commit_timer;
    // Synchronize control ONLY. Descriptor is held through the complete
    // handshake and captured after an additional pixel cycle.
    (* async_reg="true" *) reg request_meta_pix, request_sync_pix;
    (* async_reg="true" *) reg fault_meta_pix, fault_sync_pix;
    (* async_reg="true" *) reg ack_meta_sys, ack_sync_sys;
    (* async_reg="true" *) reg pixel_fault_meta_sys, pixel_fault_sync_sys;

    assign video_commit_error_sys=(video_commit_error_code_sys!=0);
    assign video_recovery_needed_sys=video_commit_error_sys;
    assign video_commit_busy_sys=(sys_state!=S_IDLE) || video_commit_req || video_commit_error_sys;
    assign video_load_allowed_sys=rst_sys_n && !video_commit_busy_sys && !upstream_error_sys && !text_cache_error_sys;
    assign text_commit_bank_sys=descriptor_text_bank_sys;
    assign text_commit_count_sys=descriptor_count_sys;
    assign image_stage_bank_pix=pending_image_bank_pix;
    wire pixel_fault=(pixel_error_code!=0);
    wire local_fault=fault_sync_pix || pixel_fault || image_stage_error_pix;
    wire read_clear=!text_read_req_pix && !text_read_valid_pix;
    wire descriptor_match=text_commit_pending_pix &&
        text_commit_bank_pix==pending_text_bank_pix && text_commit_count_pix==pending_count_pix;
    wire window_clear=safe_commit_window_pix && !video_de_pix && old_video_drained_pix && read_clear;
    // Both consumers sample this SAME combinational grant on the same edge.
    wire apply_fire=rst_pix_n && pix_state==P_STAGE && !local_fault && window_clear &&
        descriptor_match && image_stage_ready_pix && !image_applied_pix;
    assign text_commit_apply_pix=apply_fire;
    assign image_apply_pix=apply_fire;
    assign video_output_block_pix=!rst_pix_n || !front_valid_pix || local_fault ||
        pix_state==P_STAGE || pix_state==P_VERIFY;
    wire release_finished=sys_state==S_RELEASE && !video_commit_req &&
        !ack_sync_sys && !text_commit_ack_sys && !text_commit_busy_sys;
    wire timeout_now=sys_state!=S_IDLE && commit_timer>=LIMIT-1 && !release_finished;
    wire invalid_descriptor=!image_prepared_sys || !text_prepared_sys ||
        !text_back_available_sys || prepared_text_bank_sys!=text_back_bank_sys ||
        prepared_text_count_sys>7'd64 || IMAGE_BANK_COUNT<2 || IMAGE_BANK_COUNT>6 ||
        {1'b0,prepared_image_bank_sys}>=IMAGE_BANK_COUNT ||
        (!ALLOW_SAME_BANK && have_front_sys && prepared_image_bank_sys==active_image_bank_sys);

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin request_meta_pix<=0;request_sync_pix<=0;fault_meta_pix<=0;fault_sync_pix<=0;end
        else begin
            request_meta_pix<=request_hold_sys;request_sync_pix<=request_meta_pix;
            fault_meta_pix<=video_commit_error_sys;fault_sync_pix<=fault_meta_pix;
        end
    end
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin ack_meta_sys<=0;ack_sync_sys<=0;pixel_fault_meta_sys<=0;pixel_fault_sync_sys<=0;end
        else begin
            ack_meta_sys<=apply_ack_pix;ack_sync_sys<=ack_meta_sys;
            pixel_fault_meta_sys<=pixel_fault;pixel_fault_sync_sys<=pixel_fault_meta_sys;
        end
    end

    // Exactly one visible commit per guarded VBLANK window. The timing adapter
    // must supply one contiguous window per frame, not horizontal DE gaps.
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) window_used_pix<=0;
        else if(!safe_commit_window_pix) window_used_pix<=0;
        else if(apply_fire) window_used_pix<=1;
    end

    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin
            sys_state<=S_IDLE;request_hold_sys<=0;text_commit_req_sys<=0;
            descriptor_image_bank_sys<=0;descriptor_text_bank_sys<=0;descriptor_count_sys<=0;
            video_commit_ack<=0;video_commit_error_code_sys<=0;commit_timer<=0;
            active_image_bank_sys<=0;have_front_sys<=0;
        end else if(!video_commit_error_sys) begin
            if(sys_state!=S_IDLE && commit_timer<LIMIT) commit_timer<=commit_timer+1'b1;
            // Faults outrank a simultaneous successful acknowledgement. Preserve
            // any request/ack already published; recovery owns cancellation.
            if(text_cache_error_sys || pixel_fault_sync_sys || (upstream_error_sys && sys_state!=S_IDLE))
                video_commit_error_code_sys<=8'd4;
            else if((sys_state==S_WAIT_DONE && !video_commit_req) ||
                    (sys_state==S_RELEASE && video_commit_req))
                video_commit_error_code_sys<=8'd2;
            else if(timeout_now) video_commit_error_code_sys<=8'd3;
            else case(sys_state)
                S_IDLE: begin
                    commit_timer<=0;
                    if(video_commit_req) begin
                        if(invalid_descriptor || upstream_error_sys) video_commit_error_code_sys<=8'd1;
                        else begin
                            descriptor_image_bank_sys<=prepared_image_bank_sys;
                            descriptor_text_bank_sys<=prepared_text_bank_sys;
                            descriptor_count_sys<=prepared_text_count_sys;
                            request_hold_sys<=1;text_commit_req_sys<=1;sys_state<=S_WAIT_DONE;
                        end
                    end
                end
                S_WAIT_DONE: if(ack_sync_sys && text_commit_ack_sys) begin
                    active_image_bank_sys<=descriptor_image_bank_sys;have_front_sys<=1;
                    video_commit_ack<=1;sys_state<=S_WAIT_REQ_LOW;
                end
                S_WAIT_REQ_LOW: if(!video_commit_req) begin
                    request_hold_sys<=0;text_commit_req_sys<=0;sys_state<=S_RELEASE;
                end
                S_RELEASE: if(release_finished) begin video_commit_ack<=0;sys_state<=S_IDLE;end
                default: video_commit_error_code_sys<=8'd4;
            endcase
        end
    end

    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin
            pix_state<=P_IDLE;pending_image_bank_pix<=0;pending_text_bank_pix<=0;pending_count_pix<=0;
            image_stage_req_pix<=0;apply_ack_pix<=0;pixel_error_code<=0;
            front_image_bank_pix<=0;front_valid_pix<=0;
        end else if(!fault_sync_pix && !pixel_fault) begin
            // Adapter faults also matter after a completed commit: otherwise
            // RGB would be blocked without a corresponding sys recovery status.
            if(image_stage_error_pix) pixel_error_code<=8'd1;
            else case(pix_state)
                P_IDLE: if(request_sync_pix) pix_state<=P_CAPTURE;
                P_CAPTURE: begin
                    pending_image_bank_pix<=descriptor_image_bank_sys;
                    pending_text_bank_pix<=descriptor_text_bank_sys;
                    pending_count_pix<=descriptor_count_sys;pix_state<=P_WAIT_WINDOW;
                end
                P_WAIT_WINDOW: if(window_clear && !window_used_pix && text_commit_pending_pix &&
                    (USE_STAGE_START_GUARD==0 || image_stage_start_allowed_pix)) begin
                    if(!descriptor_match || image_stage_ready_pix || image_applied_pix)
                        pixel_error_code<=8'd2; // Stale image acknowledgement or descriptor mismatch.
                    else begin image_stage_req_pix<=1;pix_state<=P_STAGE;end
                end
                P_STAGE: begin
                    // Once image preparation may clear the old FIFO, missing
                    // the guarded deadline is a fault, not a safe rollback.
                    if(!safe_commit_window_pix || video_de_pix) pixel_error_code<=8'd3;
                    else if(!descriptor_match || image_applied_pix) pixel_error_code<=8'd2;
                    else if(apply_fire) begin
                        front_image_bank_pix<=pending_image_bank_pix;pix_state<=P_VERIFY;
                    end
                end
                P_VERIFY: begin
                    if(!safe_commit_window_pix || video_de_pix) pixel_error_code<=8'd3;
                    else if(!old_video_drained_pix || !read_clear) pixel_error_code<=8'd2;
                    else if(!image_stage_ready_pix || !image_applied_pix ||
                        image_front_bank_pix!=pending_image_bank_pix ||
                        text_front_bank_pix!=pending_text_bank_pix || text_front_count_pix!=pending_count_pix)
                        pixel_error_code<=8'd2;
                    else begin front_valid_pix<=1;apply_ack_pix<=1;pix_state<=P_WAIT_REQ_LOW;end
                end
                P_WAIT_REQ_LOW: begin
                    if(!image_stage_ready_pix || !image_applied_pix || image_front_bank_pix!=pending_image_bank_pix)
                        pixel_error_code<=8'd2;
                    else if(!request_sync_pix) begin image_stage_req_pix<=0;pix_state<=P_RELEASE;end
                end
                P_RELEASE: if(!image_stage_ready_pix && !image_applied_pix) begin
                    apply_ack_pix<=0;pix_state<=P_IDLE;
                end
                default: pixel_error_code<=8'd2;
            endcase
        end
    end
endmodule
