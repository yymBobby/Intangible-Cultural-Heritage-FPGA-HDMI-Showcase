`timescale 1ns/1ps
// Integration boundary: validated RGB words from the image loader. Default
// order is top-down; positive-height BMP selects IMAGE_WRITE_BOTTOM_UP=1.
// text-cache writes from osd_text_loader, commit from the theme controller.
// AXIS is an always-accepting video stream (no TREADY/backpressure support).
// Uses existing SYS/MEM/PIX clocks; no additional PLL. Reset coherently.
module image_sdram_video_pipeline #(
    parameter integer IMAGE_LOAD_TIMEOUT_CYCLES=200000000, // SYS clocks, tune for actual TF loader
    parameter integer IMAGE_WRITE_BOTTOM_UP=0,
    parameter integer WIDESCREEN=0,
    parameter integer MENU_ENABLE=0,
    parameter integer BANK_BITS=2,
    parameter integer IMAGE_BANK_COUNT=2
) (
    input wire [67:0] menu_snapshot_sys,
    input wire [1:0] transition_speed_sys,
    input wire browse_full_sys,browse_overflow_sys,
    output wire browse_safe_sys,
    input wire [3:0] current_images_valid_sys,
    input wire caption_skip_sys,
    input wire [7:0] commit_theme_sys,
    output wire caption_typing_sys,caption_glyph_toggle_pix,
    input wire subtitle_valid,subtitle_enable,
    output wire subtitle_ready,subtitle_applied,subtitle_actual,
    input wire brightness_valid,
    output wire brightness_ready,brightness_applied,
    input wire [1:0] brightness_level,
    output wire [1:0] brightness_actual,
    input wire clk_sys, rst_sys_n, clk_mem, clk_mem_sft, rst_mem_n, clk_pix, rst_pix_n,
    input wire auto_enabled_sys,audio_play_sys,audio_sample_valid_pix,
    input wire [23:0] audio_sample_left_pix,audio_sample_right_pix,
    input wire target_cached_sys,backwards_sys,
    input wire animation_allowed_sys,
    output wire second_front_valid_sys,
    output wire [BANK_BITS-1:0] second_front_slot_sys,
    input wire commit_image_prepared_sys,
    input wire [BANK_BITS-1:0] commit_image_bank_sys,
    input wire image_write_start_sys,
    input wire image_write_abort_sys,
    output wire image_write_abort_ack_sys,
    input wire [BANK_BITS-1:0] image_write_bank_sys,
    output wire image_write_start_ready_sys,
    input wire image_write_data_valid_sys,
    input wire [31:0] image_write_data_sys,
    output wire image_write_data_ready_sys, image_write_busy_sys, image_prepared_sys,
    output wire [BANK_BITS-1:0] prepared_image_bank_sys,
    input wire text_write_valid, text_write_bank,
    input wire [5:0] text_write_addr,
    input wire [15:0] text_write_glyph_id,
    output wire text_write_ready,
    input wire text_prepared_sys, prepared_text_bank_sys,
    input wire [6:0] prepared_text_count_sys,
    output wire text_back_bank_sys, text_back_available_sys,
    input wire video_commit_req, upstream_error_sys,
    output wire video_commit_ack, video_commit_busy_sys, video_load_allowed_sys,
    output wire video_commit_error_sys, video_recovery_needed_sys,
    output wire [7:0] video_commit_error_code_sys,
    output wire [BANK_BITS-1:0] active_image_bank_sys,
    output wire image_write_error_sys,
    output wire [7:0] image_write_error_code_sys,
    output wire [23:0] rgb_out, axis_data,
    output wire de_out, hs_out, vs_out, axis_valid, axis_user, axis_last,
    output wire Sdr_init_done,
    output wire SDRAM_CLK, SDR_RAS, SDR_CAS, SDR_WE,
    output wire [1:0] SDR_BA,
    output wire [10:0] SDR_ADDR,
    output wire [3:0] SDR_DM,
    inout wire [31:0] SDR_DQ
);
    wire inner_commit_req,inner_commit_ack,inner_commit_busy,inner_load_allowed,animation_busy_sys;
    wire second_stage_request,second_stage_ready,second_applied,second_apply,second_old_drained;
    wire image_stage_req_pix;
    wire [2:0] second_stage_slot;
    wire [BANK_BITS-1:0] second_bank_pix;
    wire second_valid_pix,second_stream_ready,second_word_valid,second_read_idle,second_fault,second_fifo_reset;
    wire [31:0] second_word;
    wire [8:0] second_level;
    wire second_read_en,second_burst_req,second_rd_en,second_mem_permit,second_mem_busy,second_o_busy;
    wire [20:0] second_rd_addr;
    wire [7:0] second_error,second_mem_error;
    wire [1:0] effect_pix;
    wire [8:0] alpha_pix;
    wire [9:0] shift_pix,source_shift_pix;
    wire backwards_pix,animation_live_pix,second_repeat_pix,second_display_pix;
    wire video_de_pix,hs,vs,vblank_pix,safe_commit_window_pix,prepare_frame_pix;
    wire window_error_pix,vblank_start_pix,image_stage_start_allowed_pix;
    wire second_pixel_read;
    (* async_reg="true" *) reg front_meta_sys,front_valid_sys;
    (* ASYNC_REG="TRUE" *) reg second_valid_meta_sys,second_valid_sync_sys;
    (* ASYNC_REG="TRUE" *) reg [BANK_BITS-1:0] second_bank_meta_sys,second_bank_sync_sys;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin second_valid_meta_sys<=0;second_valid_sync_sys<=0;second_bank_meta_sys<=0;second_bank_sync_sys<=0;end
        else begin
            second_valid_meta_sys<=second_valid_pix && (animation_live_pix || !second_old_drained || second_stage_request);
            second_valid_sync_sys<=second_valid_meta_sys;
            second_bank_meta_sys<=second_bank_pix;second_bank_sync_sys<=second_bank_meta_sys;
        end
    end
    assign second_front_valid_sys=second_valid_sync_sys;
    assign second_front_slot_sys=second_bank_sync_sys;
    assign video_commit_busy_sys=inner_commit_busy || animation_busy_sys;
    assign video_load_allowed_sys=inner_load_allowed && !animation_busy_sys;
    // After secondary reads and the animation stop, observe two consecutive
    // frame boundaries: a complete stable frame before admitting the next head.
    wire browse_quiet_pix=!animation_live_pix && !second_stage_request && !image_stage_req_pix &&
        second_old_drained && second_read_idle;
    wire browse_frame_ready_sys;
    browse_frame_guard browse_guard(.clk_pix(clk_pix),.rst_pix_n(rst_pix_n),.clk_sys(clk_sys),.rst_sys_n(rst_sys_n),
        .frame_start_pix(vblank_start_pix),.quiet_pix(browse_quiet_pix),.ready_sys(browse_frame_ready_sys));
    assign browse_safe_sys=browse_frame_ready_sys && video_load_allowed_sys && !video_commit_busy_sys;
    image_transition_commit #(.ADAPTIVE_SPEED(MENU_ENABLE)) animation(
        .speed_sys(transition_speed_sys),
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.clk_pix(clk_pix),.rst_pix_n(rst_pix_n),
        .request_sys(video_commit_req),.inner_ack_sys(inner_commit_ack),
        .menu_mode_sys(animation_allowed_sys ? menu_snapshot_sys[38:37]:2'd0),
        .target_cached_sys(target_cached_sys),.current_valid_sys(front_valid_sys),
        .target_slot_sys(commit_image_bank_sys),.backwards_sys(backwards_sys),
        .inner_request_sys(inner_commit_req),.ack_sys(video_commit_ack),.busy_sys(animation_busy_sys),
        .frame_start_pix(vblank_start_pix),.safe_window_pix(safe_commit_window_pix),.stage_start_allowed_pix(image_stage_start_allowed_pix),
        .second_ready_pix(second_stage_ready),.second_applied_pix(second_applied),.second_drained_pix(second_old_drained),
        .second_request_pix(second_stage_request),.second_slot_pix(second_stage_slot),.second_apply_pix(second_apply),
        .effect_pix(effect_pix),.alpha_pix(alpha_pix),.shift_pix(shift_pix),.source_shift_pix(source_shift_pix),
        .backwards_pix(backwards_pix),.animation_live_pix(animation_live_pix),.second_repeat_pix(second_repeat_pix),
        .second_display_pix(second_display_pix));
    wire [31:0] vblank_cycles_left_pix;
    video_timing_data timing(.video_clk(clk_pix),.rst(!rst_pix_n),.read_req(),
        .read_req_ack(1'b1),.hs(hs),.vs(vs),.de(video_de_pix),.vblank(vblank_pix),
        .vblank_cycles_left(vblank_cycles_left_pix));
    // Bilinear needs two adjacent rows; an odd first row also consumes one
    // discarded alignment row. 3*640*3 = 5760 consumer clocks, plus bounded
    // controller/FIFO/refresh margin. Preserve old margins outside viewport.
    video_commit_window #(.BLANK_CYCLES(WIDESCREEN ? 49500:36000),
        .END_GUARD_CYCLES(WIDESCREEN ? (MENU_ENABLE ? 8192:4096):128)) window(
        .clk_pix(clk_pix),
        .rst_pix_n(rst_pix_n),
        .vblank_pix(vblank_pix),
        .video_de_pix(video_de_pix),
        .vblank_cycles_left_pix(vblank_cycles_left_pix),
        .safe_commit_window_pix(safe_commit_window_pix),
        .image_stage_start_allowed_pix(image_stage_start_allowed_pix),
        .vblank_start_pix(vblank_start_pix),
        .prepare_frame_pix(prepare_frame_pix),
        .window_error_pix(window_error_pix));
    wire text_commit_req_sys,text_commit_bank_sys,text_commit_ack_sys,text_commit_busy_sys;
    wire text_cache_error_sys,text_commit_pending_pix,text_commit_bank_pix,text_commit_apply_pix;
    wire text_read_req_pix,text_read_valid_pix,text_front_bank_pix;
    wire [6:0] text_commit_count_sys,text_commit_count_pix,text_front_count_pix;
    wire [5:0] text_read_addr_pix;
    wire [15:0] text_read_glyph_id_pix;
    wire caption_lookup_req,caption_lookup_ready,caption_lookup_valid,caption_lookup_enable;
    wire [5:0] caption_lookup_addr,cache_read_addr;
    wire cache_read_req,cache_read_valid;
    reg caption_read_owner_q;
    wire [7:0] text_cache_error_code_sys;
    wire image_stage_ready_pix,image_applied_pix,image_stage_error_pix;
    wire image_apply_pix,front_valid_pix,video_output_block_pix;
    wire [BANK_BITS-1:0] image_stage_bank_pix,image_front_bank_pix,front_image_bank_pix;
    wire [7:0] image_error_code_pix,mem_error_code,backend_mem_error_code;
    wire old_image_drained_pix,image_read_idle_pix,image_front_valid_pix,pixel_word_valid_pix;
    wire [31:0] pixel_word_pix;
    wire old_video_drained_pix,osd_pipeline_idle_pix;
    wire App_rd_en,App_rd_burst_req,O_rd_busy,Sdr_rd_en,fifo_reset_mem;
    wire [20:0] App_rd_addr;
    wire [31:0] Sdr_rd_dout;
    wire [8:0] fifo_level_pix;
    wire mem_write_busy,mem_read_permit;
    wire scaler_fault,pixel_stream_ready_pix;
    wire pixel_read_en_pix;
    (* async_reg="true" *) reg backend_fault_meta_pix,backend_fault_pix;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin front_meta_sys<=0;front_valid_sys<=0;end
        else begin front_meta_sys<=front_valid_pix;front_valid_sys<=front_meta_sys;end
    end
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin backend_fault_meta_pix<=0;backend_fault_pix<=0;end
        else begin backend_fault_meta_pix<=backend_mem_error_code!=0;
            backend_fault_pix<=backend_fault_meta_pix;end
    end
    sdram_image_backend #(.DUAL_READ(1),.REFRESH_CYCLES(781),.BANK_BITS(BANK_BITS),.IMAGE_BANK_COUNT(IMAGE_BANK_COUNT),.WATCHDOG_CYCLES(IMAGE_LOAD_TIMEOUT_CYCLES),.WRITE_BOTTOM_UP(IMAGE_WRITE_BOTTOM_UP)) backend(.clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.clk_mem(clk_mem),
        .clk_mem_sft(clk_mem_sft),.rst_mem_n(rst_mem_n),
        .App_rd_burst_req_b(second_burst_req),.App_rd_en_b(second_read_en),.App_rd_addr_b(second_rd_addr),
        .mem_read_permit_b(second_mem_permit),.mem_write_busy_b(second_mem_busy),.Sdr_rd_en_b(second_rd_en),
        .image_write_start_sys(image_write_start_sys),.image_write_bank_sys(image_write_bank_sys),
        .image_write_abort_sys(image_write_abort_sys),.image_write_abort_ack_sys(image_write_abort_ack_sys),
        .image_write_start_ready_sys(image_write_start_ready_sys),
        .image_write_data_valid_sys(image_write_data_valid_sys),.image_write_data_sys(image_write_data_sys),
        .image_write_data_ready_sys(image_write_data_ready_sys),.image_write_busy_sys(image_write_busy_sys),
        .image_prepared_sys(image_prepared_sys),.prepared_image_bank_sys(prepared_image_bank_sys),
        .write_allowed_sys(video_load_allowed_sys),.front_valid_sys(front_valid_sys),
        .active_image_bank_sys(active_image_bank_sys),.image_write_error_sys(image_write_error_sys),
        .image_write_error_code_sys(image_write_error_code_sys),.App_rd_burst_req(App_rd_burst_req),
        .App_rd_en(App_rd_en),.App_rd_addr(App_rd_addr),.mem_read_permit(mem_read_permit),
        .mem_write_busy(mem_write_busy),.Sdr_rd_en(Sdr_rd_en),.Sdr_rd_dout(Sdr_rd_dout),
        .Sdr_init_done(Sdr_init_done),.mem_error_code(backend_mem_error_code),
        .SDRAM_CLK(SDRAM_CLK),.SDR_RAS(SDR_RAS),.SDR_CAS(SDR_CAS),.SDR_WE(SDR_WE),
        .SDR_BA(SDR_BA),.SDR_ADDR(SDR_ADDR),.SDR_DM(SDR_DM),.SDR_DQ(SDR_DQ));
    wire [21:0] viewport_desired_pix,viewport_request_pix,viewport_actual_pix,second_viewport_actual_pix;
    wire [8:0] viewport_first_row_pix,second_viewport_first_row_pix;
    viewport_frame_lock viewport_lock(.clk_pix(clk_pix),.rst_pix_n(rst_pix_n),
        .prepare_frame_pix(prepare_frame_pix),.animation_live_pix(animation_live_pix),
        .requested(viewport_desired_pix),.frame_transform(viewport_request_pix));
    image_read_adapter #(.BANK_BITS(BANK_BITS),.IMAGE_BANK_COUNT(IMAGE_BANK_COUNT),.FINISH_BURST_ON_FENCE(1),
        .VIEWPORT_ENABLE(MENU_ENABLE && WIDESCREEN)) adapter(
        .viewport_request_pix(viewport_request_pix),.viewport_actual_pix(viewport_actual_pix),
        .viewport_first_row_pix(viewport_first_row_pix),
        .clk_mem(clk_mem),
        .rst_mem_n(rst_mem_n),
        .clk_pix(clk_pix),
        .rst_pix_n(rst_pix_n),
        .mem_read_permit(mem_read_permit),
        .mem_write_busy(mem_write_busy),
        .App_rd_en(App_rd_en),
        .App_rd_addr(App_rd_addr),
        .O_rd_busy(O_rd_busy),
        .App_rd_burst_req(App_rd_burst_req),
        .Sdr_rd_en(Sdr_rd_en),
        .Sdr_rd_dout(Sdr_rd_dout),
        .prepare_frame_pix(prepare_frame_pix),
        .safe_commit_window_pix(safe_commit_window_pix),
        .pixel_read_en_pix(pixel_read_en_pix),
        .image_stage_req_pix(image_stage_req_pix),
        .image_stage_bank_pix(image_stage_bank_pix),
        .image_stage_ready_pix(image_stage_ready_pix),
        .image_applied_pix(image_applied_pix),
        .image_apply_pix(image_apply_pix),
        .image_front_bank_pix(image_front_bank_pix),
        .image_front_valid_pix(image_front_valid_pix),
        .image_stage_error_pix(image_stage_error_pix),
        .image_error_code_pix(image_error_code_pix),
        .old_image_drained_pix(old_image_drained_pix),
        .pixel_word_pix(pixel_word_pix),
        .pixel_word_valid_pix(pixel_word_valid_pix),
        .pixel_stream_ready_pix(pixel_stream_ready_pix),
        .image_read_idle_pix(image_read_idle_pix),
        .fifo_level_pix(fifo_level_pix),
        .fifo_reset_mem(fifo_reset_mem),
        .mem_error_code(mem_error_code));
    image_read_adapter #(.BANK_BITS(BANK_BITS),.IMAGE_BANK_COUNT(IMAGE_BANK_COUNT),.FINISH_BURST_ON_FENCE(1),
        .VIEWPORT_ENABLE(MENU_ENABLE && WIDESCREEN)) second_adapter(
        .viewport_request_pix(viewport_request_pix),.viewport_actual_pix(second_viewport_actual_pix),
        .viewport_first_row_pix(second_viewport_first_row_pix),
        .clk_mem(clk_mem),.rst_mem_n(rst_mem_n),.clk_pix(clk_pix),.rst_pix_n(rst_pix_n),
        .mem_read_permit(second_mem_permit),.mem_write_busy(second_mem_busy),
        .App_rd_en(second_read_en),.App_rd_addr(second_rd_addr),.O_rd_busy(second_o_busy),.App_rd_burst_req(second_burst_req),
        .Sdr_rd_en(second_rd_en),.Sdr_rd_dout(Sdr_rd_dout),.prepare_frame_pix(prepare_frame_pix && second_repeat_pix),
        .safe_commit_window_pix(safe_commit_window_pix),.pixel_read_en_pix(second_pixel_read),
        .image_stage_req_pix(second_stage_request),.image_stage_bank_pix(second_stage_slot),
        .image_stage_ready_pix(second_stage_ready),.image_applied_pix(second_applied),.image_apply_pix(second_apply),
        .image_front_bank_pix(second_bank_pix),.image_front_valid_pix(second_valid_pix),
        .image_stage_error_pix(second_fault),.image_error_code_pix(second_error),.old_image_drained_pix(second_old_drained),
        .pixel_stream_ready_pix(second_stream_ready),.pixel_word_valid_pix(second_word_valid),.pixel_word_pix(second_word),
        .image_read_idle_pix(second_read_idle),.fifo_level_pix(second_level),.fifo_reset_mem(second_fifo_reset),.mem_error_code(second_mem_error));
    wire upstream_fault=upstream_error_sys || image_write_error_sys;
    video_frame_commit #(.COMMIT_TIMEOUT_CYCLES(80000000),.BANK_BITS(BANK_BITS),.IMAGE_BANK_COUNT(IMAGE_BANK_COUNT),.ALLOW_SAME_BANK(IMAGE_BANK_COUNT>2),.USE_STAGE_START_GUARD(1)) controller(
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n),
        .clk_pix(clk_pix),
        .rst_pix_n(rst_pix_n),
        .video_commit_req(inner_commit_req),
        .video_commit_ack(inner_commit_ack),
        .video_commit_busy_sys(inner_commit_busy),
        .video_load_allowed_sys(inner_load_allowed),
        .video_commit_error_sys(video_commit_error_sys),
        .video_commit_error_code_sys(video_commit_error_code_sys),
        .video_recovery_needed_sys(video_recovery_needed_sys),
        .upstream_error_sys(upstream_fault),
        .image_prepared_sys(IMAGE_BANK_COUNT>2 ? commit_image_prepared_sys:image_prepared_sys),
        .text_prepared_sys(text_prepared_sys),
        .prepared_image_bank_sys(IMAGE_BANK_COUNT>2 ? commit_image_bank_sys:prepared_image_bank_sys),
        .prepared_text_bank_sys(prepared_text_bank_sys),
        .prepared_text_count_sys(prepared_text_count_sys),
        .text_back_bank_sys(text_back_bank_sys),
        .text_back_available_sys(text_back_available_sys),
        .text_commit_req_sys(text_commit_req_sys),
        .text_commit_bank_sys(text_commit_bank_sys),
        .text_commit_count_sys(text_commit_count_sys),
        .text_commit_ack_sys(text_commit_ack_sys),
        .text_commit_busy_sys(text_commit_busy_sys),
        .text_cache_error_sys(text_cache_error_sys),
        .text_commit_pending_pix(text_commit_pending_pix),
        .text_commit_bank_pix(text_commit_bank_pix),
        .text_commit_count_pix(text_commit_count_pix),
        .text_commit_apply_pix(text_commit_apply_pix),
        .text_read_req_pix(cache_read_req),
        .text_read_valid_pix(cache_read_valid),
        .text_front_bank_pix(text_front_bank_pix),
        .text_front_count_pix(text_front_count_pix),
        .safe_commit_window_pix(safe_commit_window_pix),
        .video_de_pix(video_de_pix),
        .old_video_drained_pix(old_video_drained_pix),
        .image_stage_start_allowed_pix(image_stage_start_allowed_pix),
        .image_stage_req_pix(image_stage_req_pix),
        .image_stage_bank_pix(image_stage_bank_pix),
        .image_stage_ready_pix(image_stage_ready_pix),
        .image_applied_pix(image_applied_pix),
        .image_stage_error_pix(image_stage_error_pix||scaler_fault||second_fault),
        .image_front_bank_pix(image_front_bank_pix),
        .image_apply_pix(image_apply_pix),
        .front_image_bank_pix(front_image_bank_pix),
        .front_valid_pix(front_valid_pix),
        .video_output_block_pix(video_output_block_pix),
        .active_image_bank_sys(active_image_bank_sys));
    text_bank_cdc cache(.clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.clk_pix(clk_pix),.rst_pix_n(rst_pix_n),
        .text_write_valid(text_write_valid),.text_write_ready(text_write_ready),.text_write_bank(text_write_bank),
        .text_write_addr(text_write_addr),.text_write_glyph_id(text_write_glyph_id),.text_prepared_sys(text_prepared_sys),
        .text_back_bank_sys(text_back_bank_sys),.text_back_available_sys(text_back_available_sys),
        .text_commit_req_sys(text_commit_req_sys),.text_commit_bank_sys(text_commit_bank_sys),
        .text_commit_count_sys(text_commit_count_sys),.text_commit_ack_sys(text_commit_ack_sys),
        .text_commit_busy_sys(text_commit_busy_sys),.text_cache_error_sys(text_cache_error_sys),
        .text_cache_error_code_sys(text_cache_error_code_sys),.text_recovery_needed_sys(),
        .text_commit_pending_pix(text_commit_pending_pix),.text_commit_bank_pix(text_commit_bank_pix),
        .text_commit_count_pix(text_commit_count_pix),.text_commit_apply_pix(text_commit_apply_pix),
        .text_read_req_pix(cache_read_req),.text_read_addr_pix(cache_read_addr),
        .text_read_valid_pix(cache_read_valid),.text_read_glyph_id_pix(text_read_glyph_id_pix),
        .front_bank_pix(text_front_bank_pix),.front_token_count_pix(text_front_count_pix));
    // Reuse the existing single subtitle read port. Display has priority;
    // caption peeks occur only in blank, outside the main stage/apply/release.
    // The real commit sees ALL requests and returns, so a peek cannot race apply.
    assign caption_lookup_enable=vblank_pix && !image_stage_req_pix &&
        !text_commit_pending_pix && !video_output_block_pix;
    assign caption_lookup_ready=caption_lookup_enable && !text_read_req_pix;
    assign cache_read_req=text_read_req_pix || (caption_lookup_req && caption_lookup_ready);
    assign cache_read_addr=text_read_req_pix ? text_read_addr_pix:caption_lookup_addr;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) caption_read_owner_q<=0;
        else caption_read_owner_q<=caption_lookup_req && caption_lookup_ready;
    end
    assign text_read_valid_pix=cache_read_valid && !caption_read_owner_q;
    assign caption_lookup_valid=cache_read_valid && caption_read_owner_q;
    wire [6:0] caption_visible_count_pix;
    reg [7:0] caption_theme_hold_sys;
    reg caption_request_seen_sys;
    // Capture at the public request, before the transition and main-commit
    // synchronizers. This bundle stays frozen until request release; the text
    // apply samples it after both handshakes, never from a changing loader ID.
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if(!rst_sys_n) begin caption_theme_hold_sys<=0;caption_request_seen_sys<=0;end
        else if(!video_commit_req) caption_request_seen_sys<=0;
        else if(!caption_request_seen_sys) begin
            caption_theme_hold_sys<=commit_theme_sys;caption_request_seen_sys<=1;
        end
    end
    caption_typewriter caption(.clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.skip_pulse_sys(caption_skip_sys),
        .typing_sys(caption_typing_sys),.clk_pix(clk_pix),.rst_pix_n(rst_pix_n),
        .frame_start_pix(vblank_start_pix),.commit_pix(text_commit_apply_pix),.count_pix(text_commit_count_pix),
        .theme_pix(caption_theme_hold_sys),
        .lookup_enable_pix(caption_lookup_enable),.lookup_ready_pix(caption_lookup_ready),
        .lookup_valid_pix(caption_lookup_valid),.lookup_glyph_pix(text_read_glyph_id_pix[7:0]),
        .lookup_req_pix(caption_lookup_req),.lookup_addr_pix(caption_lookup_addr),
        .glyph_read_req_pix(text_read_req_pix),.glyph_read_addr_pix(text_read_addr_pix),
        .visible_count_pix(caption_visible_count_pix),.glyph_toggle_pix(caption_glyph_toggle_pix));
    generate if(WIDESCREEN) begin: wide_display
        media_wide_renderer #(.ENABLE_MENU(MENU_ENABLE),.ENABLE_CACHE_PROGRESS(MENU_ENABLE)) renderer(
            .browse_full_sys(browse_full_sys),.browse_overflow_sys(browse_overflow_sys),
            .current_images_valid_sys(current_images_valid_sys),
            .viewport_request_pix(viewport_desired_pix),.viewport_actual_pix(viewport_actual_pix),
            .second_viewport_actual_pix(second_viewport_actual_pix),
            .viewport_first_row_pix(viewport_first_row_pix),.second_viewport_first_row_pix(second_viewport_first_row_pix),
            .menu_snapshot_sys(menu_snapshot_sys),.menu_safe_pix(safe_commit_window_pix),
            .second_stream_ready(second_stream_ready),.second_source_valid(second_word_valid),.second_front_valid(second_valid_pix),
            .second_display(second_display_pix),
            .second_source_level(second_level),.second_source_word(second_word),.second_source_read(second_pixel_read),
            .effect(effect_pix),.alpha(alpha_pix),.shift(shift_pix),.source_shift(source_shift_pix),
            .backwards(backwards_pix),.animation_live(animation_live_pix),
            .subtitle_valid(subtitle_valid),.subtitle_ready(subtitle_ready),.subtitle_applied(subtitle_applied),
            .subtitle_enable(subtitle_enable),.subtitle_actual(subtitle_actual),
            .brightness_valid(brightness_valid),.brightness_ready(brightness_ready),
            .brightness_applied(brightness_applied),.brightness_level(brightness_level),.brightness_actual(brightness_actual),.clk(clk_pix),.rst_n(rst_pix_n),.clk_calc(clk_sys),.rst_calc_n(rst_sys_n),.de(video_de_pix),.hs(hs),.vs(vs),
            .vblank(vblank_pix),.frame_start(vblank_start_pix),.stream_ready(pixel_stream_ready_pix),
            .source_valid(pixel_word_valid_pix),.front_valid(front_valid_pix),
            .output_block(video_output_block_pix),.backend_fault(backend_fault_pix),
            .source_level(fifo_level_pix),.source_word(pixel_word_pix),.source_read(pixel_read_en_pix),
            .scaler_fault(scaler_fault),.auto_sys(auto_enabled_sys),.play_sys(audio_play_sys),
            .audio_valid(audio_sample_valid_pix),.audio_l(audio_sample_left_pix),.audio_r(audio_sample_right_pix),
            .text_count(caption_visible_count_pix),.text_req(text_read_req_pix),.text_addr(text_read_addr_pix),
            .text_valid(text_read_valid_pix),.text_glyph(text_read_glyph_id_pix),
            .rgb(rgb_out),.de_out(de_out),.hs_out(hs_out),.vs_out(vs_out),.pipeline_idle(osd_pipeline_idle_pix));
    end else begin: legacy_display
        assign subtitle_ready=1'b0;assign subtitle_applied=1'b0;assign subtitle_actual=1'b1;
        assign brightness_ready=1'b0;assign brightness_applied=1'b0;assign brightness_actual=2'd3;
        assign pixel_read_en_pix=video_de_pix;
        assign scaler_fault=1'b0;
    // One pixel clock aligns coordinates/sync with the synchronous FIFO read.
    reg [9:0] pixel_x,pixel_y,x_pipe,y_pipe;
    reg de_pipe,hs_pipe,vs_pipe;
    always @(posedge clk_pix or negedge rst_pix_n) begin
        if(!rst_pix_n) begin pixel_x<=0;pixel_y<=0;x_pipe<=0;y_pipe<=0;
            de_pipe<=0;hs_pipe<=1;vs_pipe<=1;end
        else begin
            x_pipe<=pixel_x;y_pipe<=pixel_y;de_pipe<=video_de_pix;hs_pipe<=hs;vs_pipe<=vs;
            if(vblank_pix) begin pixel_x<=0;pixel_y<=0;end
            else if(video_de_pix) begin
                if(pixel_x==639) begin pixel_x<=0;pixel_y<=pixel_y+1'b1;end
                else pixel_x<=pixel_x+1'b1;
            end
        end
    end
    wire [23:0] rgb_in=(video_output_block_pix || backend_fault_pix || !pixel_word_valid_pix) ?
        24'd0:pixel_word_pix[31:8];
    osd_dynamic_with_font_rom osd(.clk_pix(clk_pix),.rst_pix_n(rst_pix_n),
        .osd_enable_pix(front_valid_pix && !video_output_block_pix && !backend_fault_pix),
        .front_token_count_pix(text_front_count_pix),.x_in(x_pipe),.y_in(y_pipe),.rgb_in(rgb_in),
        .de_in(de_pipe),.hs_in(hs_pipe),.vs_in(vs_pipe),.text_read_req_pix(text_read_req_pix),
        .text_read_addr_pix(text_read_addr_pix),.text_read_valid_pix(text_read_valid_pix),
        .text_read_glyph_id_pix(text_read_glyph_id_pix),.rgb_out(rgb_out),.de_out(de_out),
        .hs_out(hs_out),.vs_out(vs_out),.pipeline_idle_pix(osd_pipeline_idle_pix));
    end endgenerate
    image_video_axis_640x480 #(.HACTIVE(WIDESCREEN ? 1280:640)) axis(.I_clk(clk_pix),.I_rst(!rst_pix_n),.I_vs(vs_out),.I_de(de_out),
        .I_rgb(rgb_out),.O_video_user(axis_user),.O_video_valid(axis_valid),
        .O_video_last(axis_last),.O_video_data(axis_data));
    assign old_video_drained_pix=old_image_drained_pix && osd_pipeline_idle_pix && !axis_valid;
endmodule
