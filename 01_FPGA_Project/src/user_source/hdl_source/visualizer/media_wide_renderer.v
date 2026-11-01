`timescale 1ns/1ps
// Passive PCM monitor and 16:9 composition; shared resource clients unchanged.
module media_wide_renderer #(parameter integer ENABLE_MENU=0,parameter integer USE_VIEWPORT=ENABLE_MENU,parameter integer ENABLE_CACHE_PROGRESS=0,parameter integer ENABLE_ALARM=ENABLE_MENU)(
    input wire [67:0] menu_snapshot_sys,
    input wire [3:0] current_images_valid_sys,
    input wire browse_full_sys,browse_overflow_sys,
    output wire [21:0] viewport_request_pix,
    input wire [21:0] viewport_actual_pix,second_viewport_actual_pix,
    input wire [8:0] viewport_first_row_pix,second_viewport_first_row_pix,
    input wire menu_safe_pix,
    input wire subtitle_valid,subtitle_enable,
    output wire subtitle_ready,subtitle_applied,subtitle_actual,
    input wire brightness_valid,
    output wire brightness_ready,brightness_applied,
    input wire [1:0] brightness_level,
    output wire [1:0] brightness_actual,
    input wire clk,rst_n,de,hs,vs,vblank,frame_start,
    input wire clk_calc,rst_calc_n,
    input wire second_stream_ready,second_source_valid,second_front_valid,second_display,
    input wire [8:0] second_source_level,input wire [31:0] second_source_word,
    output wire second_source_read,
    input wire [1:0] effect,input wire [8:0] alpha,
    input wire [9:0] shift,source_shift,input wire backwards,animation_live,
    input wire stream_ready,source_valid,front_valid,output_block,backend_fault,
    input wire [8:0] source_level,input wire [31:0] source_word,
    output wire source_read,scaler_fault,
    input wire auto_sys,play_sys,audio_valid,
    input wire [23:0] audio_l,audio_r,
    input wire [6:0] text_count,
    output wire text_req,output wire [5:0] text_addr,
    input wire text_valid,input wire [15:0] text_glyph,
    output wire [23:0] rgb,output reg de_out,hs_out,vs_out,
    output wire pipeline_idle
);
    // Bit47 is a persistent alarm level, not a menu commit payload. Apply
    // at the next frame even while an image animation is in flight.
    (* async_reg="true" *) reg alarm_meta_pix,alarm_sync_pix;
    reg alarm_frame_pix;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin alarm_meta_pix<=0;alarm_sync_pix<=0;alarm_frame_pix<=0;end
        else begin alarm_meta_pix<=ENABLE_ALARM && menu_snapshot_sys[47];
            alarm_sync_pix<=alarm_meta_pix;
            if(frame_start)alarm_frame_pix<=alarm_sync_pix;end
    end
    reg [10:0] x;reg [9:0] y;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin x<=0;y<=0;end
        else if(vblank) begin x<=0;y<=0;end
        else if(de) begin
            if(x==1279) begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
        end
    end
    wire [23:0] raw_rgb,composite_rgb;reg [23:0] scaled_rgb;wire raw_de,raw_hs,raw_vs;
    reg composite_de,composite_hs,composite_vs;
    wire [10:0] raw_x;wire [9:0] raw_y;
    reg scaled_de,scaled_hs,scaled_vs;reg [10:0] scaled_x;reg [9:0] scaled_y;
    wire enabled=front_valid && (!output_block || (animation_live && effect!=3)) && !backend_fault;
    reg enabled_q;
    wire osd_alarm_cover,osd_alarm_ink;
    reg alarm_cover_pre,alarm_cover_q,alarm_ink_pre,alarm_ink_q;
    wire subtitle_pix;
    video_brightness #(.ENABLE_ALARM(ENABLE_ALARM)) brightness(.alarm_ink_pix(alarm_ink_q),
        .subtitle_valid_sys(subtitle_valid),.subtitle_enable_sys(subtitle_enable),.subtitle_ready_sys(subtitle_ready),
        .subtitle_applied_sys(subtitle_applied),.subtitle_actual_sys(subtitle_actual),.subtitle_enable_pix(subtitle_pix),.clk_sys(clk_calc),.rst_sys_n(rst_calc_n),
        .request_valid_sys(brightness_valid),.request_ready_sys(brightness_ready),
        .request_level_sys(brightness_level),.applied_pulse_sys(brightness_applied),.actual_level_sys(brightness_actual),
        .clk_pix(clk),.rst_pix_n(rst_n),.apply_safe_pix(vblank && pipeline_idle && !raw_de && !scaled_de),
        .rgb_in(composite_rgb),.rgb_out(rgb),.level_pix());
    // Retain the pre-OSD RGB/coordinate stage. Gain is applied once, AFTER
    // the final image/menu/subtitle/sidebar composition, at the screen output.
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin scaled_rgb<=0;scaled_de<=0;scaled_hs<=0;scaled_vs<=0;scaled_x<=0;scaled_y<=0;enabled_q<=0;end
        else begin
            scaled_rgb<=raw_rgb;
            scaled_de<=raw_de;scaled_hs<=raw_hs;scaled_vs<=raw_vs;scaled_x<=raw_x;scaled_y<=raw_y;
            enabled_q<=enabled && !scaler_fault;
        end
    end
    wire [23:0] primary_rgb,secondary_rgb,blend_rgb;
    wire primary_de,primary_hs,primary_vs,secondary_fault,primary_fault;
    wire [10:0] primary_x,blend_x;wire [9:0] primary_y,blend_y;
    wire blend_de,blend_hs,blend_vs;
    wire sliding=effect==2;
    wire [10:0] cut=11'd960-{1'b0,shift};
    wire [10:0] old_begin=sliding && backwards ? {1'b0,shift}:11'd0;
    wire [10:0] old_end=sliding && !backwards ? cut:11'd960;
    wire [9:0] old_start=sliding && !backwards ? source_shift:10'd0;
    wire [10:0] new_begin=sliding && !backwards ? cut:11'd0;
    wire [10:0] new_end=sliding && backwards ? {1'b0,shift}:11'd960;
    wire [9:0] new_start=sliding && backwards ? 10'd640-source_shift:10'd0;
    wire primary_scaler_idle,secondary_scaler_idle;
    generate if(USE_VIEWPORT) begin: viewport_scaling
    image_viewport_scaler scaler(.clk(clk),.rst_n(rst_n),.stream_ready(stream_ready),
        .source_valid(source_valid),.source_word(source_word),.source_level(source_level),
        .transform(viewport_actual_pix),.first_row(viewport_first_row_pix),
        .front_valid(front_valid),.de(de),.hs(hs),.vs(vs),.vblank(vblank),.x(x),.y(y),
        .show_begin(old_begin),.show_end(old_end),.view_shift(sliding ? {1'b0,shift}:11'd0),.subtract_shift(sliding && backwards),
        .source_read(source_read),.rgb(primary_rgb),.de_q(primary_de),.hs_q(primary_hs),.vs_q(primary_vs),
        .x_q(primary_x),.y_q(primary_y),.underflow(primary_fault),.pipeline_idle(primary_scaler_idle));
    image_viewport_scaler #(.LINE_RAM_IMPLEMENT("9K")) second_scaler(
        .clk(clk),.rst_n(rst_n),.stream_ready(second_stream_ready),
        .source_valid(second_source_valid),.source_word(second_source_word),.source_level(second_source_level),
        .transform(second_viewport_actual_pix),.first_row(second_viewport_first_row_pix),
        .front_valid(second_front_valid && second_display),.de(de),.hs(hs),.vs(vs),.vblank(vblank),.x(x),.y(y),
        .show_begin(new_begin),.show_end(new_end),.view_shift(sliding ? cut:11'd0),.subtract_shift(sliding && !backwards),
        .source_read(second_source_read),.rgb(secondary_rgb),.de_q(),.hs_q(),.vs_q(),.x_q(),.y_q(),
        .underflow(secondary_fault),.pipeline_idle(secondary_scaler_idle));
    end else begin: legacy_scaling
    assign primary_scaler_idle=!primary_de;assign secondary_scaler_idle=1'b1;
    image_line_scaler scaler(.clk(clk),.rst_n(rst_n),.stream_ready(stream_ready),
        .source_valid(source_valid),.source_word(source_word),.source_level(source_level),
        .front_valid(front_valid),.de(de),.hs(hs),.vs(vs),.vblank(vblank),.x(x),.y(y),
        .start_column(old_start),.show_begin(old_begin),.show_end(old_end),
        .source_read(source_read),.rgb(primary_rgb),.de_q(primary_de),.hs_q(primary_hs),.vs_q(primary_vs),
        .x_q(primary_x),.y_q(primary_y),.underflow(primary_fault));
    image_line_scaler #(.LINE_RAM_IMPLEMENT("9K")) second_scaler(.clk(clk),.rst_n(rst_n),.stream_ready(second_stream_ready),
        .source_valid(second_source_valid),.source_word(second_source_word),.source_level(second_source_level),
        .front_valid(second_front_valid && second_display),.de(de),.hs(hs),.vs(vs),.vblank(vblank),.x(x),.y(y),
        .start_column(new_start),.show_begin(new_begin),.show_end(new_end),
        .source_read(second_source_read),.rgb(secondary_rgb),.de_q(),.hs_q(),.vs_q(),.x_q(),.y_q(),.underflow(secondary_fault));
    end endgenerate
    assign scaler_fault=primary_fault || secondary_fault;
    wire [67:0] snapshot_pix;
    wire choose_new=sliding && (backwards ? primary_x<{1'b0,shift}:primary_x>=cut);
    wire [23:0] first_rgb=choose_new ? secondary_rgb:primary_rgb;
    // Contrast precedes fading: 75% lifts source black to gray, but the
    // fade target must remain literal black. Both crossfade images agree.
    wire [1:0] contrast_level=ENABLE_MENU ? snapshot_pix[46:45]:2'd1;
    wire [23:0] contrast_rgb,contrast_second_rgb;
    wire contrast_de,contrast_hs,contrast_vs,contrast_idle,contrast_second_idle;
    wire [10:0] contrast_x;wire [9:0] contrast_y;
    image_contrast contrast_primary(.clk(clk),.rst_n(rst_n),.level(contrast_level),.rgb_in(first_rgb),
        .de(primary_de),.hs(primary_hs),.vs(primary_vs),.x(primary_x),.y(primary_y),
        .rgb_out(contrast_rgb),.de_q(contrast_de),.hs_q(contrast_hs),.vs_q(contrast_vs),
        .x_q(contrast_x),.y_q(contrast_y),.pipeline_idle(contrast_idle));
    image_contrast contrast_secondary(.clk(clk),.rst_n(rst_n),.level(contrast_level),.rgb_in(secondary_rgb),
        .de(primary_de),.hs(primary_hs),.vs(primary_vs),.x(primary_x),.y(primary_y),
        .rgb_out(contrast_second_rgb),.de_q(),.hs_q(),.vs_q(),.x_q(),.y_q(),.pipeline_idle(contrast_second_idle));
    reg [1:0] contrast_effect_s0,contrast_effect_s1;
    reg [8:0] contrast_alpha_s0,contrast_alpha_s1;
    reg [3:0] contrast_blend_active;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            contrast_effect_s0<=0;contrast_effect_s1<=0;
            contrast_alpha_s0<=0;contrast_alpha_s1<=0;contrast_blend_active<=0;
        end else begin
            contrast_effect_s0<=effect;contrast_effect_s1<=contrast_effect_s0;
            contrast_alpha_s0<=effect==1 || effect==3 ? alpha:9'd0;
            contrast_alpha_s1<=contrast_alpha_s0;
            contrast_blend_active<={contrast_blend_active[2:0],contrast_de};
        end
    end
    wire [23:0] next_rgb=contrast_effect_s1==1 ? contrast_second_rgb:
        contrast_effect_s1==3 ? 24'd0:contrast_rgb;
    image_crossfade blend(.clk(clk),.rst_n(rst_n),.old_rgb(contrast_rgb),.new_rgb(next_rgb),
        .alpha(contrast_alpha_s1),
        .de(contrast_de),.hs(contrast_hs),.vs(contrast_vs),.x(contrast_x),.y(contrast_y),
        .rgb(blend_rgb),.de_q(blend_de),.hs_q(blend_hs),.vs_q(blend_vs),.x_q(blend_x),.y_q(blend_y));
    assign viewport_request_pix={snapshot_pix[67:58],snapshot_pix[57:48],snapshot_pix[23:22]};
    // Show the ACCEPTED frame settings, not a newer un-applied request.
    wire [67:0] displayed_snapshot={viewport_actual_pix[21:12],viewport_actual_pix[11:2],
        snapshot_pix[47:24],viewport_actual_pix[1:0],snapshot_pix[21:0]};
    // values[15:14] is the menu's fifth image item (filter), not scaling.
    image_filter filter(.clk(clk),.rst_n(rst_n),.mode(snapshot_pix[35:34]),.rgb_in(blend_rgb),
        .de(blend_de),.hs(blend_hs),.vs(blend_vs),.x(blend_x),.y(blend_y),
        .rgb_out(raw_rgb),.de_q(raw_de),.hs_q(raw_hs),.vs_q(raw_vs),.x_q(raw_x),.y_q(raw_y));
    wire [23:0] osd_rgb;wire osd_de,osd_hs,osd_vs,osd_idle;
    generate if(ENABLE_MENU) begin: menu_display
        // Complete held bundle commits only in the drained frame window.
        menu_snapshot_cdc #(.WIDTH(68),.RESET_SNAPSHOT(68'd1 << 45)) mailbox(.clk_sys(clk_calc),.rst_sys_n(rst_calc_n),
            .snapshot_sys({menu_snapshot_sys[67:48],1'b0,menu_snapshot_sys[46:0]}),.ready_sys(),.applied_sys(),.clk_pix(clk),.rst_pix_n(rst_n),
            .apply_safe_pix(menu_safe_pix && pipeline_idle && !animation_live),.snapshot_pix(snapshot_pix),.applied_pix());
        osd_menu_with_subtitles #(.ENABLE_ALARM(ENABLE_ALARM)) osd(.alarm_active_pix(alarm_frame_pix),
            .alarm_cover_out(osd_alarm_cover),.alarm_ink_out(osd_alarm_ink),.clk_pix(clk),.rst_pix_n(rst_n),.snapshot_pix(displayed_snapshot),
            .subtitle_enable_pix(enabled_q&&subtitle_pix),.front_token_count_pix(text_count),
            .x_in(scaled_x),.y_in(scaled_y),.rgb_in(enabled_q ? scaled_rgb:24'd0),
            .de_in(scaled_de),.hs_in(scaled_hs),.vs_in(scaled_vs),
            .text_read_req_pix(text_req),.text_read_addr_pix(text_addr),.text_read_valid_pix(text_valid),
            .text_read_glyph_id_pix(text_glyph),.rgb_out(osd_rgb),.de_out(osd_de),.hs_out(osd_hs),.vs_out(osd_vs),
            .pipeline_idle_pix(osd_idle));
    end else begin: caption_display
        assign snapshot_pix=68'd0;
        assign osd_alarm_cover=1'b0;assign osd_alarm_ink=1'b0;
        osd_dynamic_with_font_rom #(.TEXT_X(408),.TEXT_Y(552),.HS_IDLE(0),.VS_IDLE(0)) osd(
            .clk_pix(clk),.rst_pix_n(rst_n),.osd_enable_pix(enabled_q&&subtitle_pix&&scaled_x<960),
            .front_token_count_pix(text_count),.x_in(scaled_x[9:0]),.y_in(scaled_y),
            .rgb_in(enabled_q ? scaled_rgb:24'd0),.de_in(scaled_de),.hs_in(scaled_hs),.vs_in(scaled_vs),
            .text_read_req_pix(text_req),.text_read_addr_pix(text_addr),.text_read_valid_pix(text_valid),
            .text_read_glyph_id_pix(text_glyph),.rgb_out(osd_rgb),.de_out(osd_de),.hs_out(osd_hs),.vs_out(osd_vs),
            .pipeline_idle_pix(osd_idle));
    end endgenerate
    reg [10:0] x0,x1,x2;reg [9:0] y0,y1,y2;reg side_de0,side_de1;
    (* async_reg="true" *) reg auto_meta_pix,auto_sync_pix,play_meta_pix,play_sync_pix;
    reg auto_frame;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin x0<=0;x1<=0;x2<=0;y0<=0;y1<=0;y2<=0;
            auto_meta_pix<=0;auto_sync_pix<=0;play_meta_pix<=0;play_sync_pix<=0;auto_frame<=0;side_de0<=0;side_de1<=0;end
        else begin
            x0<=scaled_x;x1<=x0;x2<=x1;y0<=scaled_y;y1<=y0;y2<=y1;side_de0<=scaled_de;side_de1<=side_de0;
            auto_meta_pix<=auto_sys;auto_sync_pix<=auto_meta_pix;
            play_meta_pix<=play_sys;play_sync_pix<=play_meta_pix;
            if(frame_start) auto_frame<=auto_sync_pix;
        end
    end
    wire [7:0] bar_height,bar_peak,bar_height_next,bar_peak_next;wire bar_read;wire [4:0] bar_address;
    wire [7:0] level_l,level_r,peak_l,peak_r;
    wire [7:0] calc_level_l,calc_level_r,calc_peak_l,calc_peak_r;
    wire clip_l,clip_r,phase_dot,calc_clip_l,calc_clip_r;wire signed [1:0] phase_trend,calc_trend;
    wire [3:0] display_state_calc;
    wire [11:0] phase_address;wire phase_read;
    // One PCM mailbox per 20.8us sample; data remains stable until the next
    // toggle. Frame snapshots remain stable for a complete display frame.
    reg [31:0] sample_hold_pix;reg sample_toggle_pix,frame_toggle_pix;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin sample_hold_pix<=0;sample_toggle_pix<=0;frame_toggle_pix<=0;end
        else begin
            if(audio_valid) begin sample_hold_pix<={audio_l[23:8],audio_r[23:8]};sample_toggle_pix<=!sample_toggle_pix;end
            if(frame_start) frame_toggle_pix<=!frame_toggle_pix;
        end
    end
    (* async_reg="true" *) reg sample_meta_sys,sample_sync_sys,frame_meta_sys,frame_sync_sys;
    reg sample_seen_sys,frame_seen_sys,sample_tick_sys,frame_pending_sys;
    reg [31:0] sample_data_sys;
    reg [39:0] metrics_hold_sys;
    reg metrics_toggle_sys;
    wire frame_tick_sys=frame_sync_sys!=frame_seen_sys;
    always @(posedge clk_calc or negedge rst_calc_n) begin
        if(!rst_calc_n) begin
            sample_meta_sys<=0;sample_sync_sys<=0;frame_meta_sys<=0;frame_sync_sys<=0;
            sample_seen_sys<=0;frame_seen_sys<=0;sample_tick_sys<=0;sample_data_sys<=0;
            frame_pending_sys<=0;metrics_hold_sys<=0;metrics_toggle_sys<=0;
        end else begin
            sample_meta_sys<=sample_toggle_pix;sample_sync_sys<=sample_meta_sys;
            frame_meta_sys<=frame_toggle_pix;frame_sync_sys<=frame_meta_sys;
            sample_tick_sys<=sample_sync_sys!=sample_seen_sys;
            if(sample_sync_sys!=sample_seen_sys) begin sample_seen_sys<=sample_sync_sys;sample_data_sys<=sample_hold_pix;end
            frame_seen_sys<=frame_sync_sys;
            frame_pending_sys<=frame_tick_sys;
            if(frame_pending_sys) begin
                metrics_hold_sys<={calc_level_l,calc_level_r,calc_peak_l,calc_peak_r,calc_clip_l,calc_clip_r,calc_trend,display_state_calc};
                metrics_toggle_sys<=!metrics_toggle_sys;
            end
        end
    end
    (* async_reg="true" *) reg metrics_meta_pix,metrics_sync_pix;
    reg metrics_seen_pix;reg [39:0] metrics_pix;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin metrics_meta_pix<=0;metrics_sync_pix<=0;metrics_seen_pix<=0;metrics_pix<=0;end
        else begin
            metrics_meta_pix<=metrics_toggle_sys;metrics_sync_pix<=metrics_meta_pix;
            if(metrics_sync_pix!=metrics_seen_pix) begin metrics_seen_pix<=metrics_sync_pix;metrics_pix<=metrics_hold_sys;end
        end
    end
    assign {level_l,level_r,peak_l,peak_r,clip_l,clip_r,phase_trend}=metrics_pix[39:4];
    audio_visualizer_compact #(.USE_BAND_READ(1)) monitor(.clk(clk_calc),.rst_n(rst_calc_n),.clear(!play_sys),.running(play_sys),
        .clk_display(clk),.display_state_pix(metrics_pix[3:0]),.display_state_calc(display_state_calc),
        .frame_start(frame_tick_sys),.sample_valid(sample_tick_sys),.sample_l(sample_data_sys[31:16]),.sample_r(sample_data_sys[15:0]),
        .phase_address(phase_address),.phase_read_enable(phase_read),.phase_dot(phase_dot),
        .bar_read(bar_read),.bar_address(bar_address),.bar_height(bar_height),.bar_peak(bar_peak),
        .bar_height_next(bar_height_next),.bar_peak_next(bar_peak_next),
        .level_l(calc_level_l),.level_r(calc_level_r),.peak_l(calc_peak_l),.peak_r(calc_peak_r),
        .clip_l(calc_clip_l),.clip_r(calc_clip_r),.phase_trend(calc_trend),.fft_busy(),.skipped_samples());
    wire side_valid;wire [23:0] side_rgb;
    sidebar_layer sidebar(.clk(clk),.rst_n(rst_n),.de(side_de1),.x(x1),.y(y1),
        .auto_enabled(auto_frame),.running(play_sync_pix),.bar_height(bar_height),.bar_peak(bar_peak),
        .bar_height_next(bar_height_next),.bar_peak_next(bar_peak_next),
        .bar_address(bar_address),.bar_read(bar_read),
        .level_l(level_l),.level_r(level_r),.peak_l(peak_l),.peak_r(peak_r),.clip_l(clip_l),.clip_r(clip_r),
        .phase_dot(phase_dot),.phase_trend(phase_trend),.phase_address(phase_address),.phase_read(phase_read),
        .valid(side_valid),.rgb(side_rgb));
    // Keep the sidebar aligned: caption 3+4 stages, menu 5+2 stages.
    // The first/last active pixel and the x=960 composition boundary agree.
    reg [23:0] picture_pre,picture_mid0,picture_mid1,picture_q;
    reg picture_de_pre,picture_hs_pre,picture_vs_pre;
    reg picture_de_mid0,picture_hs_mid0,picture_vs_mid0;
    reg picture_de_mid1,picture_hs_mid1,picture_vs_mid1;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            alarm_cover_pre<=0;alarm_cover_q<=0;alarm_ink_pre<=0;alarm_ink_q<=0;
            picture_pre<=0;picture_mid0<=0;picture_mid1<=0;picture_q<=0;
            picture_de_pre<=0;picture_hs_pre<=0;picture_vs_pre<=0;
            picture_de_mid0<=0;picture_hs_mid0<=0;picture_vs_mid0<=0;
            picture_de_mid1<=0;picture_hs_mid1<=0;picture_vs_mid1<=0;
            composite_de<=0;composite_hs<=0;composite_vs<=0;
        end else begin
            alarm_cover_pre<=osd_alarm_cover;alarm_cover_q<=alarm_cover_pre;
            alarm_ink_pre<=osd_alarm_ink;alarm_ink_q<=alarm_ink_pre;
            picture_pre<=osd_rgb;picture_de_pre<=osd_de;picture_hs_pre<=osd_hs;picture_vs_pre<=osd_vs;
            picture_mid0<=picture_pre;picture_de_mid0<=picture_de_pre;picture_hs_mid0<=picture_hs_pre;picture_vs_mid0<=picture_vs_pre;
            picture_mid1<=picture_mid0;picture_de_mid1<=picture_de_mid0;picture_hs_mid1<=picture_hs_mid0;picture_vs_mid1<=picture_vs_mid0;
            if(ENABLE_MENU) begin
                picture_q<=picture_pre;composite_de<=picture_de_pre;composite_hs<=picture_hs_pre;composite_vs<=picture_vs_pre;
            end else begin
                picture_q<=picture_mid1;composite_de<=picture_de_mid1;composite_hs<=picture_hs_mid1;composite_vs<=picture_vs_mid1;
            end
        end
    end
    // Display-only cache feedback. Each bit reports a completed, validated
    // image, not bytes received or elapsed time. Never controls admission.
    wire progress_cover,progress_yellow,browse_busy_cover;
    generate if(ENABLE_CACHE_PROGRESS) begin: cache_progress
        (* async_reg="true" *) reg [3:0] valid_meta_pix,valid_sync_pix;
        reg [3:0] valid_frame;
        reg [7:0] fill_units; // Eight pixels/unit, full width = 160 units.
        wire [2:0] complete_count={2'd0,valid_sync_pix[0]}+{2'd0,valid_sync_pix[1]}+
            {2'd0,valid_sync_pix[2]}+{2'd0,valid_sync_pix[3]};
        wire [7:0] target_units={complete_count,5'b0}+{2'b0,complete_count,3'b0};
        reg [6:0] cover_pipe,yellow_pipe;
        (* ASYNC_REG="TRUE" *) reg [1:0] browse_meta,browse_sync;
        reg [1:0] browse_frame;reg [3:0] browse_blink;
        reg [6:0] browse_pipe;reg browse_on;
        always @* begin
            browse_on=0;
            if(browse_frame[0])browse_on=1;
            if(browse_frame[1])browse_on=browse_blink[3];
        end
        always @(posedge clk or negedge rst_n) begin
            if(!rst_n) begin
                valid_meta_pix<=0;valid_sync_pix<=0;valid_frame<=0;fill_units<=0;
                cover_pipe<=0;yellow_pipe<=0;
                browse_meta<=0;browse_sync<=0;browse_frame<=0;browse_blink<=0;browse_pipe<=0;
            end else begin
                valid_meta_pix<=current_images_valid_sys;valid_sync_pix<=valid_meta_pix;
                browse_meta<={browse_overflow_sys,browse_full_sys};browse_sync<=browse_meta;
                if(frame_start) begin
                    browse_frame<=browse_sync;browse_blink<=browse_blink+1'b1;
                    valid_frame<=valid_sync_pix;
                    if(fill_units>target_units)fill_units<=target_units;
                    else if(fill_units<target_units)fill_units<=fill_units+1'b1;
                end
                // Seven stages: menu/captions five, final picture alignment two.
                cover_pipe<={cover_pipe[5:0],scaled_de && scaled_y>=718 && scaled_y<720 && !((&valid_frame) && fill_units==160)};
                yellow_pipe<={yellow_pipe[5:0],scaled_x[10:3]<fill_units};
                // Small amber busy mark; overflow blinks until queued work drains.
                browse_pipe<={browse_pipe[5:0],browse_on && scaled_de &&
                    scaled_x>=900 && scaled_x<948 && scaled_y>=8 && scaled_y<12};
            end
        end
        assign progress_cover=cover_pipe[6];assign progress_yellow=yellow_pipe[6];
        assign browse_busy_cover=browse_pipe[6];
    end else begin: no_cache_progress
        assign progress_cover=1'b0;assign progress_yellow=1'b0;
        assign browse_busy_cover=1'b0;
    end endgenerate
    assign composite_rgb=composite_de ? (alarm_cover_q ? picture_q:browse_busy_cover ? 24'hd7ac58:progress_cover ?
        (progress_yellow ? 24'h40c0ff:24'h203040):(side_valid ? side_rgb:picture_q)):24'd0;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin de_out<=0;hs_out<=0;vs_out<=0;end
        else begin de_out<=composite_de;hs_out<=composite_hs;vs_out<=composite_vs;end
    end
    assign pipeline_idle=primary_scaler_idle&&secondary_scaler_idle&&contrast_idle&&contrast_second_idle&&!(|contrast_blend_active)&&!raw_de&&!scaled_de&&osd_idle&&!picture_de_pre&&!composite_de&&!de_out &&
        (ENABLE_MENU || (!picture_de_mid0&&!picture_de_mid1));
endmodule
