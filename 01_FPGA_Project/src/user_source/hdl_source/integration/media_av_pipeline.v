`timescale 1ns/1ps
// Shared raw-image resource path, real A/B clients and coordinated reset.
// B delivered parser/FIFO/player are imported unchanged; no second SD owner.
module media_av_pipeline #(parameter integer RESET_HOLD_CYCLES=50000, parameter integer MENU_ENABLE=0) (
    input wire [67:0] menu_snapshot_sys,
    input wire subtitle_valid,subtitle_enable,
    output wire subtitle_ready,subtitle_applied,subtitle_actual,
    input wire brightness_valid,
    output wire brightness_ready,brightness_applied,
    input wire [1:0] brightness_level,
    output wire [1:0] brightness_actual,
    input wire clk_ref,
    input wire ext_reset_n,
    input wire clocks_locked_async,
    input wire clk_sys,
    input wire clk_mem,
    input wire clk_mem_sft,
    input wire clk_pix,
    input wire clk_audio,
    input wire clk_tmds,
    input wire ctl_valid,
    input wire image_next,image_prev,theme_next,theme_prev,music_toggle,auto_toggle,
    input wire playback_paused,
    input wire auto_inhibit,
    output wire theme_commit_pulse,audio_gate_applied,
    output wire [7:0] audio_error_code,
    output wire [4:0] catalog_theme_count,
    output wire [31:0] display_elapsed_ms,
    output wire underflow_seen,
    input wire sd_init_done,
    input wire sd_sec_read_data_valid,
    input wire sd_sec_read_end,
    input wire sd_sec_read_error,
    input wire [1:0] ctl_op,
    input wire [7:0] ctl_theme_id,
    input wire [2:0] sd_init_error,
    input wire [7:0] sd_sec_read_data,
    output wire rst_sys_n,
    output wire rst_mem_n,
    output wire rst_pix_n,
    output wire rst_audio_n,
    output wire rst_tmds_n,
    output wire run_enable_sys,
    output wire ctl_ready,
    output wire sd_sec_read,
    output wire audio_valid,
    output wire service_ready,
    output wire recovery_req,
    output wire recovery_lockout_ref,
    output wire active_theme_valid,
    output wire audio_play_enable,
    output wire audio_muted,
    output wire auto_enabled,
    output wire audio_ended,
    output wire audio_underflow,
    output wire de_out,
    output wire hs_out,
    output wire vs_out,
    output wire axis_valid,
    output wire axis_user,
    output wire axis_last,
    output wire Sdr_init_done,
    output wire SDRAM_CLK,
    output wire SDR_RAS,
    output wire SDR_CAS,
    output wire SDR_WE,
    output wire [31:0] sd_sec_read_addr,
    output wire [23:0] audio_left_data,
    output wire [23:0] audio_right_data,
    output wire [7:0] active_theme_id,
    output wire [7:0] controller_error_code,
    output wire [7:0] service_error,
    output wire [3:0] state_code,
    output wire [31:0] recovery_count_ref,
    output wire [23:0] rgb_out,
    output wire [23:0] axis_data,
    output wire [1:0] SDR_BA,
    output wire [10:0] SDR_ADDR,
    output wire [3:0] SDR_DM,
    inout wire [31:0] SDR_DQ
);
    wire recovery_busy_ref;
    wire [2:0] recovery_state_ref;
    wire [4:0] clock_alive_ref;
    wire [4:0] last_reason_ref;
    wire controller_ctl_valid;
    wire controller_ctl_ready;
    wire resource_recovery_req;
    wire [7:0] catalog_error;
    wire boot_ready,service_recovery_req;
    // v3 metadata comes from one validated catalog query.
    wire [7:0] query_theme_id,query_image_index;
    wire [7:0] query_image_resource_id,query_audio_resource_id,query_text_resource_id;
    wire [7:0] img_load_image_index;
    wire pic_load_valid,pic_load_ready,pic_prepared,pic_idle,pic_commit_req,pic_commit_ack;
    wire pic_rsp_valid,pic_stop_req,pic_recovery_req;
    wire [2:0] pic_rsp_status;
    wire [7:0] pic_error_code,pic_load_theme_id,pic_load_image_index,current_image_index;
    wire [31:0] task_display_time_ms;
    wire [3:0] picture_state;
    wire query_valid;
    wire [31:0] query_display_time_ms;
    wire [31:0] query_image_bytes;
    wire [31:0] query_audio_bytes;
    wire [31:0] query_text_bytes;
    wire [31:0] font_set_id;
    wire [31:0] glyph_count;
    wire img_load_valid;
    wire img_load_ready;
    wire [7:0] img_load_theme_id;
    wire [7:0] img_load_resource_id;
    wire [7:0] img_load_text_resource_id;
    wire [31:0] img_load_file_bytes;
    wire [31:0] img_load_text_file_bytes;
    wire [31:0] img_load_font_set_id;
    wire [15:0] img_load_glyph_count;
    wire img_stop_req;
    wire img_idle;
    wire img_prepared;
    wire img_error;
    wire [7:0] img_error_code;
    wire img_recovery_needed;
    wire aud_load_valid;
    wire aud_load_ready;
    wire [7:0] aud_load_theme_id;
    wire [7:0] aud_load_resource_id;
    wire [31:0] aud_load_file_bytes;
    wire aud_stop_req;
    wire aud_idle;
    wire aud_prepared;
    wire aud_error;
    wire [7:0] aud_error_code;
    assign audio_error_code=aud_error_code;
    wire video_commit_req;
    wire video_commit_ack;
    wire video_commit_error_sys;
    wire video_recovery_needed_sys;
    // Display timing belongs to the media controller.
    // Underflow diagnostics belong to the audio/media path.
    wire img_req_valid;
    wire img_req_ready;
    wire [7:0] img_req_resource_id;
    wire [31:0] img_req_block_index;
    wire img_data_valid;
    wire img_data_ready;
    wire [7:0] img_data;
    wire img_data_last;
    wire img_file_last;
    wire img_rsp_valid;
    wire img_rsp_ready;
    wire [2:0] img_rsp_status;
    wire aud_req_valid;
    wire aud_req_ready;
    wire [7:0] aud_req_resource_id;
    wire [31:0] aud_req_block_index;
    wire aud_data_valid;
    wire aud_data_ready;
    wire [7:0] aud_data;
    wire aud_data_last;
    wire aud_file_last;
    wire aud_rsp_valid;
    wire aud_rsp_ready;
    wire [2:0] aud_rsp_status;
    wire audio_urgent;
    wire sec_req_ready;
    wire sec_req_valid;
    wire [31:0] sec_req_lba;
    wire sec_data_valid;
    wire [7:0] sec_data;
    wire sec_done;
    wire sec_error;
    wire sector_fault;
    wire [1:0] img_error_stage;
    wire [7:0] img_prepared_theme_id;
    wire video_load_allowed_sys;
    wire text_back_available_sys;
    wire text_back_bank_sys;
    wire [2:0] active_image_bank_sys;
    wire [2:0] img_prepared_image_bank_sys;
    wire img_prepared_text_bank_sys;
    wire [6:0] img_prepared_text_count_sys;
    wire text_prepared_sys;
    wire joint_image_prepared_sys;
    wire text_write_valid;
    wire text_write_bank;
    wire text_write_ready;
    wire [5:0] text_write_addr;
    wire [15:0] text_write_glyph_id;
    wire image_write_start_sys;
    wire image_write_abort_sys;
    wire image_write_start_ready_sys;
    wire image_write_abort_ack_sys;
    wire [2:0] image_write_bank_sys;
    wire image_write_data_valid_sys;
    wire [31:0] image_write_data_sys;
    wire image_write_data_ready_sys;
    wire image_write_busy_sys;
    wire image_prepared_sys;
    wire [2:0] prepared_image_bank_sys;
    wire image_write_error_sys;
    wire prepared_text_bank_sys;
    wire [6:0] prepared_text_count_sys;
    wire upstream_error_sys;
    wire video_commit_busy_sys;
    wire [7:0] video_commit_error_code_sys;
    wire [7:0] image_write_error_code_sys;
    wire O_i2s_BCLK;
    wire O_i2s_LRCK;
    wire O_i2s_DOUT;
    wire audio_raw_valid;
    wire [23:0] audio_raw_left,audio_raw_right;
    // Request the latest menu level only when the existing one-in-flight
    // business mailbox is ready. Fast detents coalesce instead of queueing.
    wire menu_brightness_request=brightness_ready && brightness_actual!=menu_snapshot_sys[21:20];
    wire menu_subtitle_request=subtitle_ready && subtitle_actual!=menu_snapshot_sys[39];
    reg restore_seen_sys;
    always @(posedge clk_sys or negedge rst_sys_n)
        if(!rst_sys_n) restore_seen_sys<=0;else restore_seen_sys<=menu_snapshot_sys[44];
    wire restore_defaults_sys=MENU_ENABLE!=0 && menu_snapshot_sys[44]!=restore_seen_sys;

    wire background_enable,background_active,background_valid,background_stop;
    wire second_front_valid_sys;wire [2:0] second_front_slot_sys;
    wire [2:0] background_slot,foreground_slot;
    wire [7:0] background_theme,background_image,background_image_id,background_text_id;
    wire [31:0] background_image_bytes,background_text_bytes,background_font_id;
    wire [15:0] background_glyph_count;
    wire foreground_ready,foreground_hit,foreground_was_hit;
    wire foreground_animation_ready;
    wire loader_ready,loader_idle,loader_prepared,loader_error;
    wire task_pic_idle,task_pic_load_ready;
    wire loader_load_valid=background_valid || (!background_active && img_load_valid && foreground_ready);
    wire loader_stop=background_active ? background_stop:img_stop_req;
    wire [5:0] cache_valid_slots;wire [3:0] current_images_valid;
    assign img_load_ready=foreground_ready;
    assign pic_idle=task_pic_idle && !background_active;
    assign pic_load_ready=task_pic_load_ready && !background_active;
    image_cache_scheduler cache_scheduler(
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.service_ready(service_ready),
        .background_enable(background_enable),.video_load_allowed(video_load_allowed_sys),
        .current_theme(active_theme_id[1:0]),.current_image(current_image_index[1:0]),.current_valid(active_theme_valid),
        .active_slot(active_image_bank_sys),.second_valid(second_front_valid_sys),.second_slot(second_front_slot_sys),
        .foreground_valid(img_load_valid),.foreground_stop(img_stop_req),
        .foreground_key({img_load_theme_id[1:0],img_load_image_index[1:0]}),
        .foreground_ready(foreground_ready),.foreground_hit(foreground_hit),.foreground_slot(foreground_slot),
        .foreground_was_hit(foreground_was_hit),
        .foreground_animation_ready(foreground_animation_ready),
        .loader_ready(loader_ready),.loader_idle(img_idle),.loader_prepared(img_prepared),.loader_error(img_error),
        .loader_prepared_slot(img_prepared_image_bank_sys),
        .background_active(background_active),.background_valid(background_valid),.background_stop(background_stop),
        .background_slot(background_slot),.background_theme(background_theme),.background_image(background_image),
        .background_image_id(background_image_id),.background_text_id(background_text_id),
        .background_image_bytes(background_image_bytes),.background_text_bytes(background_text_bytes),
        .background_font_id(background_font_id),.background_glyph_count(background_glyph_count),
        .query_valid(query_valid),.query_image_id(query_image_resource_id),.query_text_id(query_text_resource_id),
        .query_image_bytes(query_image_bytes),.query_text_bytes(query_text_bytes),.font_id(font_set_id),.glyph_count(glyph_count),
        .current_images_valid(current_images_valid),.valid_slots(cache_valid_slots),.cache_hits(),.cache_misses());
    assign catalog_theme_count=5'd4;
    assign resource_recovery_req=service_recovery_req || sector_fault || sd_init_error!=0 || catalog_error!=0;
    assign upstream_error_sys = service_error!=0 || resource_recovery_req || img_recovery_needed;
    // Old task errors clear on the next accepted load; do not block that load.
    assign prepared_text_bank_sys = img_prepared_text_bank_sys;
    assign prepared_text_count_sys = img_prepared_text_count_sys;
    wire caption_typing_sys,caption_glyph_toggle_pix;
    wire caption_enabled_sys=MENU_ENABLE ? menu_snapshot_sys[39]:subtitle_enable;
    wire caption_blocking_sys=caption_enabled_sys && caption_typing_sys;
    wire caption_skip_sys=caption_blocking_sys && (theme_next || theme_prev ||
        (ctl_valid && ctl_ready && ctl_op<3));
    assign controller_ctl_valid = ctl_valid && run_enable_sys && !(caption_blocking_sys && ctl_op<3);
    assign ctl_ready = controller_ctl_ready && run_enable_sys;
    av_recovery_manager #(.HOLD_CYCLES(RESET_HOLD_CYCLES)) reset_manager (
        .clk_ref(clk_ref),
        .ext_reset_n(ext_reset_n),
        .clocks_locked_async(clocks_locked_async),
        .clk_sys(clk_sys),
        .clk_mem(clk_mem),
        .clk_pix(clk_pix),
        .clk_audio(clk_audio),
        .clk_tmds(clk_tmds),
        .recovery_req_sys(recovery_req),
        .rst_sys_n(rst_sys_n),
        .rst_mem_n(rst_mem_n),
        .rst_pix_n(rst_pix_n),
        .rst_audio_n(rst_audio_n),
        .rst_tmds_n(rst_tmds_n),
        .run_enable_sys(run_enable_sys),
        .recovery_busy_ref(recovery_busy_ref),
        .recovery_lockout_ref(recovery_lockout_ref),
        .recovery_state_ref(recovery_state_ref),
        .clock_alive_ref(clock_alive_ref),
        .recovery_count_ref(recovery_count_ref),
        .last_reason_ref(last_reason_ref)
    );

    wire browse_safe_sys,browse_full_sys,browse_overflow_sys;
    wire [1:0] transition_speed_sys;
    resource_v3_runtime #(.MENU_DWELL_CONTROL(MENU_ENABLE),.ORDERED_BROWSE(MENU_ENABLE)) control (
        .browse_safe_sys(browse_safe_sys),.browse_full_sys(browse_full_sys),.browse_overflow_sys(browse_overflow_sys),
        .transition_speed_sys(transition_speed_sys),
        .background_enable(background_enable),
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.service_ready(service_ready),.service_error(service_error),
        .resource_recovery_req(resource_recovery_req),
        .ctl_valid(controller_ctl_valid),.ctl_ready(controller_ctl_ready),.ctl_op(ctl_op),.ctl_theme_id(ctl_theme_id),
        .image_next(image_next),.image_prev(image_prev),
        .theme_next(theme_next && !caption_blocking_sys),.theme_prev(theme_prev && !caption_blocking_sys),
        .music_toggle(music_toggle),.auto_toggle(auto_toggle),.auto_config(menu_snapshot_sys[36]),
        .dwell_level(menu_snapshot_sys[43:42]),.restore_defaults_sys(restore_defaults_sys),
        .menu_open(auto_inhibit),.pause_playback(playback_paused),
        .pic_load_valid(pic_load_valid),.pic_load_ready(pic_load_ready),
        .pic_load_theme_id(pic_load_theme_id),.pic_load_image_index(pic_load_image_index),
        .pic_prepared(pic_prepared),.pic_idle(pic_idle),.pic_commit_ack(pic_commit_ack),
        .pic_rsp_valid(pic_rsp_valid),.pic_commit_req(pic_commit_req),.pic_stop_req(pic_stop_req),.pic_rsp_ready(),
        .pic_rsp_status(pic_rsp_status),.pic_error_code(pic_error_code),.pic_recovery_req(pic_recovery_req),
        .current_valid(active_theme_valid),.current_theme_id(active_theme_id),.current_image_index(current_image_index),
        .metadata_valid(img_load_valid && query_valid),.metadata_audio_id(query_audio_resource_id),
        .metadata_audio_bytes(query_audio_bytes),.metadata_dwell_ms(task_display_time_ms),
        .aud_load_valid(aud_load_valid),.aud_load_ready(aud_load_ready),.aud_load_theme_id(aud_load_theme_id),
        .aud_load_resource_id(aud_load_resource_id),.aud_load_file_bytes(aud_load_file_bytes),
        .aud_stop_req(aud_stop_req),.aud_idle(aud_idle),.aud_prepared(aud_prepared),.aud_error(aud_error),
        .aud_error_code(aud_error_code),.audio_ended(audio_ended),.audio_underflow(audio_underflow),
        .audio_play_enable(audio_play_enable),.audio_muted(audio_muted),.auto_enabled(auto_enabled),
        .theme_commit_pulse(theme_commit_pulse),.recovery_req(recovery_req),.underflow_seen(underflow_seen),
        .controller_error_code(controller_error_code),.display_elapsed_ms(display_elapsed_ms),.state_code(state_code)
    );
    // Raw parser diagnostics and task statuses are different namespaces.
    wire [2:0] image_task_error_status=img_error_code==4 ? 3'd4 :
        img_error_code==3 ? 3'd3 : (img_error_stage==0 && img_error_code==1) ? 3'd1 : 3'd6;
    resource_v3_picture_task #(.COMMIT_TIMEOUT_CYCLES(80000000)) picture_task (
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.service_ready(service_ready),.service_error(service_error),
        .resource_recovery_req(resource_recovery_req),.pic_load_valid(pic_load_valid && !background_active),.pic_load_ready(task_pic_load_ready),
        .pic_load_theme_id(pic_load_theme_id),.pic_load_image_index(pic_load_image_index),
        .pic_prepared(pic_prepared),.pic_commit_req(pic_commit_req),.pic_commit_ack(pic_commit_ack),
        .pic_rsp_valid(pic_rsp_valid),.pic_rsp_ready(1'b1),.pic_rsp_status(pic_rsp_status),.pic_error_code(pic_error_code),
        .pic_stop_req(pic_stop_req),.pic_idle(task_pic_idle),.current_theme_id(active_theme_id),
        .current_image_index(current_image_index),.current_valid(active_theme_valid),.recovery_req(pic_recovery_req),
        .query_theme_id(query_theme_id),.query_image_index(query_image_index),.query_valid(query_valid),
        .query_image_resource_id(query_image_resource_id),.query_audio_resource_id(query_audio_resource_id),
        .query_text_resource_id(query_text_resource_id),.query_image_bytes(query_image_bytes),
        .query_audio_bytes(query_audio_bytes),.query_text_bytes(query_text_bytes),.query_display_time_ms(query_display_time_ms),
        .font_set_id(font_set_id),.glyph_count(glyph_count),
        .a_load_valid(img_load_valid),.a_load_ready(img_load_ready),.a_load_theme_id(img_load_theme_id),
        .a_load_image_index(img_load_image_index),.a_load_resource_id(img_load_resource_id),
        .a_load_text_resource_id(img_load_text_resource_id),.a_load_file_bytes(img_load_file_bytes),
        .a_load_text_file_bytes(img_load_text_file_bytes),.a_load_font_set_id(img_load_font_set_id),
        .a_load_glyph_count(img_load_glyph_count),.task_display_time_ms(task_display_time_ms),
        .a_idle(img_idle),.a_prepared(joint_image_prepared_sys),.a_error_valid(img_error),
        .a_error_status(image_task_error_status),.a_error_code(img_error_code),
        .a_recovery_req(img_recovery_needed || video_recovery_needed_sys),.a_stop_req(img_stop_req),
        .a_commit_req(video_commit_req),.a_commit_ack(video_commit_ack),.a_commit_error(video_commit_error_sys),
        .state_code(picture_state)
    );
    resource_v3_backend backend (
        .clk_sys(clk_sys),.rst_sys_n(rst_sys_n),.service_ready(service_ready),.service_error(service_error),
        .recovery_req(service_recovery_req),.sd_init_done(sd_init_done),.sd_init_error(sd_init_error),
        .boot_ready(boot_ready),.boot_error(catalog_error),
        .query_theme_id(background_active ? background_theme:query_theme_id),.query_image_index(background_active ? background_image:query_image_index),.query_valid(query_valid),
        .query_image_resource_id(query_image_resource_id),.query_audio_resource_id(query_audio_resource_id),
        .query_text_resource_id(query_text_resource_id),.query_image_bytes(query_image_bytes),
        .query_audio_bytes(query_audio_bytes),.query_text_bytes(query_text_bytes),.query_display_time_ms(query_display_time_ms),
        .font_set_id(font_set_id),.glyph_count(glyph_count),
        .img_req_valid(img_req_valid),
        .img_req_ready(img_req_ready),
        .img_req_resource_id(img_req_resource_id),
        .img_req_block_index(img_req_block_index),
        .img_data_valid(img_data_valid),
        .img_data_ready(img_data_ready),
        .img_data(img_data),
        .img_data_last(img_data_last),
        .img_file_last(img_file_last),
        .img_rsp_valid(img_rsp_valid),
        .img_rsp_ready(img_rsp_ready),
        .img_rsp_status(img_rsp_status),
        .aud_req_valid(aud_req_valid),
        .aud_req_ready(aud_req_ready),
        .aud_req_resource_id(aud_req_resource_id),
        .aud_req_block_index(aud_req_block_index),
        .aud_data_valid(aud_data_valid),
        .aud_data_ready(aud_data_ready),
        .aud_data(aud_data),
        .aud_data_last(aud_data_last),
        .aud_file_last(aud_file_last),
        .aud_rsp_valid(aud_rsp_valid),
        .aud_rsp_ready(aud_rsp_ready),
        .aud_rsp_status(aud_rsp_status),
        .audio_urgent(audio_urgent),
        .sec_req_valid(sec_req_valid),
        .sec_req_ready(sec_req_ready),
        .sec_req_lba(sec_req_lba),
        .sec_data_valid(sec_data_valid),
        .sec_data(sec_data),
        .sec_done(sec_done),
        .sec_error(sec_error)
    );

    sd_sector_adapter sector (
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n),
        .sd_init_done(sd_init_done),
        .sd_init_error(sd_init_error),
        .sd_sec_read(sd_sec_read),
        .sd_sec_read_addr(sd_sec_read_addr),
        .sd_sec_read_data(sd_sec_read_data),
        .sd_sec_read_data_valid(sd_sec_read_data_valid),
        .sd_sec_read_end(sd_sec_read_end),
        .sd_sec_read_error(sd_sec_read_error),
        .sec_req_ready(sec_req_ready),
        .sec_req_valid(sec_req_valid),
        .sec_req_lba(sec_req_lba),
        .sec_data_valid(sec_data_valid),
        .sec_data(sec_data),
        .sec_done(sec_done),
        .sec_error(sec_error),
        .fault(sector_fault)
    );

    image_text_loader #(.RESOURCE_VERSION(3),.BANK_BITS(3),.IMAGE_BANK_COUNT(6),.CACHE_CONTROL(1)) loader (
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n),
        .service_ready(service_ready),
        .service_error(service_error),
        .cache_hit(!background_active && foreground_hit),.cache_only(background_active),
        .cache_slot(background_active ? background_slot:foreground_slot),
        .img_load_valid(loader_load_valid),
        .img_load_ready(loader_ready),
        .img_load_theme_id(background_active ? background_theme:img_load_theme_id),.img_load_image_index(background_active ? background_image:img_load_image_index),
        .img_load_resource_id(background_active ? background_image_id:img_load_resource_id),
        .img_load_text_resource_id(background_active ? background_text_id:img_load_text_resource_id),
        .img_load_file_bytes(background_active ? background_image_bytes:img_load_file_bytes),
        .img_load_text_file_bytes(background_active ? background_text_bytes:img_load_text_file_bytes),
        .img_load_font_set_id(background_active ? background_font_id:img_load_font_set_id),
        .img_load_glyph_count(background_active ? background_glyph_count:img_load_glyph_count),
        .img_stop_req(loader_stop),
        .img_idle(img_idle),
        .img_error(img_error),
        .img_prepared(img_prepared),
        .img_recovery_needed(img_recovery_needed),
        .img_error_code(img_error_code),
        .img_error_stage(img_error_stage),
        .img_prepared_theme_id(img_prepared_theme_id),
        .video_load_allowed_sys(video_load_allowed_sys),
        .text_back_available_sys(text_back_available_sys),
        .text_back_bank_sys(text_back_bank_sys),
        .active_image_bank_sys(active_image_bank_sys),
        .img_prepared_image_bank_sys(img_prepared_image_bank_sys),
        .img_prepared_text_bank_sys(img_prepared_text_bank_sys),
        .img_prepared_text_count_sys(img_prepared_text_count_sys),
        .text_prepared_sys(text_prepared_sys),
        .joint_image_prepared_sys(joint_image_prepared_sys),
        .img_req_valid(img_req_valid),
        .img_req_ready(img_req_ready),
        .img_req_resource_id(img_req_resource_id),
        .img_req_block_index(img_req_block_index),
        .img_data_valid(img_data_valid),
        .img_data_ready(img_data_ready),
        .img_data(img_data),
        .img_data_last(img_data_last),
        .img_file_last(img_file_last),
        .img_rsp_valid(img_rsp_valid),
        .img_rsp_ready(img_rsp_ready),
        .img_rsp_status(img_rsp_status),
        .text_write_valid(text_write_valid),
        .text_write_bank(text_write_bank),
        .text_write_ready(text_write_ready),
        .text_write_addr(text_write_addr),
        .text_write_glyph_id(text_write_glyph_id),
        .image_write_start_sys(image_write_start_sys),
        .image_write_abort_sys(image_write_abort_sys),
        .image_write_start_ready_sys(image_write_start_ready_sys),
        .image_write_abort_ack_sys(image_write_abort_ack_sys),
        .image_write_bank_sys(image_write_bank_sys),
        .image_write_data_valid_sys(image_write_data_valid_sys),
        .image_write_data_sys(image_write_data_sys),
        .image_write_data_ready_sys(image_write_data_ready_sys),
        .image_write_busy_sys(image_write_busy_sys),
        .image_prepared_sys(image_prepared_sys),
        .prepared_image_bank_sys(prepared_image_bank_sys),
        .image_write_error_sys(image_write_error_sys)
    );

    image_sdram_video_pipeline #(.BANK_BITS(3),.IMAGE_BANK_COUNT(6),.IMAGE_WRITE_BOTTOM_UP(1),.WIDESCREEN(1),.MENU_ENABLE(MENU_ENABLE)) video (
        .browse_safe_sys(browse_safe_sys),.browse_full_sys(browse_full_sys),.browse_overflow_sys(browse_overflow_sys),
        .transition_speed_sys(transition_speed_sys),
        .current_images_valid_sys(current_images_valid),
        .caption_skip_sys(caption_skip_sys),.caption_typing_sys(caption_typing_sys),
        .commit_theme_sys(img_prepared_theme_id),
        .animation_allowed_sys(foreground_animation_ready && !background_active && !image_write_busy_sys),
        .caption_glyph_toggle_pix(caption_glyph_toggle_pix),
        .target_cached_sys(foreground_was_hit),
        .backwards_sys(img_load_theme_id==active_theme_id ? img_load_image_index[1:0]==current_image_index[1:0]-2'd1 :
            img_load_theme_id[1:0]==active_theme_id[1:0]-2'd1),
        .second_front_valid_sys(second_front_valid_sys),.second_front_slot_sys(second_front_slot_sys),
        .commit_image_prepared_sys(joint_image_prepared_sys),.commit_image_bank_sys(img_prepared_image_bank_sys),
        .menu_snapshot_sys(menu_snapshot_sys),
        .subtitle_valid(MENU_ENABLE ? menu_subtitle_request:subtitle_valid),.subtitle_ready(subtitle_ready),.subtitle_applied(subtitle_applied),
        .subtitle_enable(MENU_ENABLE ? menu_snapshot_sys[39]:subtitle_enable),.subtitle_actual(subtitle_actual),
        .brightness_valid(MENU_ENABLE ? menu_brightness_request:brightness_valid),.brightness_ready(brightness_ready),
        .brightness_applied(brightness_applied),.brightness_level(MENU_ENABLE ? menu_snapshot_sys[21:20]:brightness_level),.brightness_actual(brightness_actual),
        // Visualizer observes music PCM before the caption mixer; pause leaves
        // the serial sample clock running with silence, so caption cues can play.
        .auto_enabled_sys(auto_enabled),.audio_play_sys(audio_play_enable),.audio_sample_valid_pix(audio_raw_valid),
        .audio_sample_left_pix(audio_raw_left),.audio_sample_right_pix(audio_raw_right),
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n),
        .clk_mem(clk_mem),
        .clk_mem_sft(clk_mem_sft),
        .rst_mem_n(rst_mem_n),
        .clk_pix(clk_pix),
        .rst_pix_n(rst_pix_n),
        .image_write_start_sys(image_write_start_sys),
        .image_write_abort_sys(image_write_abort_sys),
        .image_write_abort_ack_sys(image_write_abort_ack_sys),
        .image_write_bank_sys(image_write_bank_sys),
        .image_write_start_ready_sys(image_write_start_ready_sys),
        .image_write_data_valid_sys(image_write_data_valid_sys),
        .image_write_data_sys(image_write_data_sys),
        .image_write_data_ready_sys(image_write_data_ready_sys),
        .image_write_busy_sys(image_write_busy_sys),
        .image_prepared_sys(image_prepared_sys),
        .prepared_image_bank_sys(prepared_image_bank_sys),
        .text_write_valid(text_write_valid),
        .text_write_bank(text_write_bank),
        .text_write_addr(text_write_addr),
        .text_write_glyph_id(text_write_glyph_id),
        .text_write_ready(text_write_ready),
        .text_prepared_sys(text_prepared_sys),
        .prepared_text_bank_sys(prepared_text_bank_sys),
        .prepared_text_count_sys(prepared_text_count_sys),
        .text_back_bank_sys(text_back_bank_sys),
        .text_back_available_sys(text_back_available_sys),
        .video_commit_req(video_commit_req),
        .upstream_error_sys(upstream_error_sys),
        .video_commit_ack(video_commit_ack),
        .video_commit_busy_sys(video_commit_busy_sys),
        .video_load_allowed_sys(video_load_allowed_sys),
        .video_commit_error_sys(video_commit_error_sys),
        .video_recovery_needed_sys(video_recovery_needed_sys),
        .video_commit_error_code_sys(video_commit_error_code_sys),
        .active_image_bank_sys(active_image_bank_sys),
        .image_write_error_sys(image_write_error_sys),
        .image_write_error_code_sys(image_write_error_code_sys),
        .rgb_out(rgb_out),
        .axis_data(axis_data),
        .de_out(de_out),
        .hs_out(hs_out),
        .vs_out(vs_out),
        .axis_valid(axis_valid),
        .axis_user(axis_user),
        .axis_last(axis_last),
        .Sdr_init_done(Sdr_init_done),
        .SDRAM_CLK(SDRAM_CLK),
        .SDR_RAS(SDR_RAS),
        .SDR_CAS(SDR_CAS),
        .SDR_WE(SDR_WE),
        .SDR_BA(SDR_BA),
        .SDR_ADDR(SDR_ADDR),
        .SDR_DM(SDR_DM),
        .SDR_DQ(SDR_DQ)
    );

    wav_pcm_player #(.RESOURCE_VERSION(3)) player (
        .clk_sys(clk_sys),
        .rst_sys_n(rst_sys_n),
        .I_mclk(clk_audio),
        .rst_audio_n(rst_audio_n),
        .service_ready(service_ready),
        .service_error(service_error),
        .aud_load_valid(aud_load_valid),
        .aud_load_ready(aud_load_ready),
        .aud_load_theme_id(aud_load_theme_id),
        .aud_load_resource_id(aud_load_resource_id),
        .aud_load_file_bytes(aud_load_file_bytes),
        .aud_req_valid(aud_req_valid),
        .aud_req_ready(aud_req_ready),
        .aud_req_resource_id(aud_req_resource_id),
        .aud_req_block_index(aud_req_block_index),
        .aud_data_valid(aud_data_valid),
        .aud_data_ready(aud_data_ready),
        .aud_data(aud_data),
        .aud_data_last(aud_data_last),
        .aud_file_last(aud_file_last),
        .aud_rsp_valid(aud_rsp_valid),
        .aud_rsp_ready(aud_rsp_ready),
        .aud_rsp_status(aud_rsp_status),
        .aud_stop_req(aud_stop_req),
        .audio_play_enable(audio_play_enable),
        .aud_idle(aud_idle),
        .aud_prepared(aud_prepared),
        .aud_error(aud_error),
        .aud_error_code(aud_error_code),
        .audio_urgent(audio_urgent),
        .audio_ended(audio_ended),
        .audio_underflow(audio_underflow),
        .audio_gate_applied(audio_gate_applied),
        .O_i2s_BCLK(O_i2s_BCLK),
        .O_i2s_LRCK(O_i2s_LRCK),
        .O_i2s_DOUT(O_i2s_DOUT)
    );

    i2s_frame_receiver receiver (
        .clk_pixel(clk_pix),
        .rst_pixel_n(rst_pix_n),
        .bclk(O_i2s_BCLK),
        .lrck(O_i2s_LRCK),
        .dout(O_i2s_DOUT),
        .audio_valid(audio_raw_valid),
        .left24(audio_raw_left),
        .right24(audio_raw_right)
    );
    wire mixed_valid;wire [23:0] mixed_left,mixed_right;
    caption_square_tone caption_tone(.clk(clk_pix),.rst_n(rst_pix_n),
        .glyph_toggle_pix(caption_glyph_toggle_pix),.enabled_sys(caption_enabled_sys && active_theme_valid && run_enable_sys),
        .valid_in(audio_raw_valid),.left_in(audio_raw_left),.right_in(audio_raw_right),
        .valid_out(mixed_valid),.left_out(mixed_left),.right_out(mixed_right));
    audio_volume volume(.clk_sys(clk_sys),.rst_sys_n(rst_sys_n),
        .level_sys(MENU_ENABLE ? menu_snapshot_sys[41:40]:2'd3),
        .clk_pix(clk_pix),.rst_pix_n(rst_pix_n),.valid_in(mixed_valid),
        .left_in(mixed_left),.right_in(mixed_right),
        .valid_out(audio_valid),.left_out(audio_left_data),.right_out(audio_right_data));
endmodule
