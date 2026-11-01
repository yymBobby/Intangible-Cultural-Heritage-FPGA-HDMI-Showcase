
module top(
    input                       clk,
    input                       rst_n,
    input                       key1,           // physical KEY2: reserved
    input                       key2,           // physical KEY4: pause / resume
    input                       sw0,            // C8: stable edge toggles menu
    input                       knob_a,knob_b,knob_s_n, // J1 pins 25,26,27; near J1.29 3V3
    input                       joy_button,     // J1.28/M16: 0 released, 1 pressed
    input                       reed_do,        // J1.24 / J16; module: magnet=0, absent=1
    output                      buzzer_n,       // H11; inactive high
    input                       key_pause,      // physical KEY3: reserved

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso
);

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// ICHSHOW3 four-theme/four-image media path. Encoder click advances themes,
// KEY4 pauses/resumes independently of the menu. SW0 and external encoder are local UI inputs.
wire sd_card_clk,ext_mem_clk,ext_mem_clk_sft,video_clk,hdmi_5x_clk,audio_mclk,joystick_adc_clk;
wire sys_pll_lock,video_pll_lock,audio_pll_lock;
wire rst_sys_n,rst_mem_n,rst_pix_n,rst_audio_n,rst_tmds_n,run_enable_sys;
wire clocks_locked_async=sys_pll_lock && video_pll_lock && audio_pll_lock;
wire rst_all=!rst_pix_n;
media_sys_pll sys_pll_m0(.refclk(clk),.reset(!rst_n),.extlock(sys_pll_lock),
    .clk0_out(sd_card_clk),.clk1_out(ext_mem_clk),.clk2_out(ext_mem_clk_sft),.clk_adc_out(joystick_adc_clk));
media_video_pll video_pll_m0(.refclk(clk),.reset(!rst_n),.extlock(video_pll_lock),
    .clk0_out(video_clk),.clk1_out(hdmi_5x_clk));
PLL_HDMI_AUDIO u_audio_pll(.refclk(clk),.reset(!rst_n),.extlock(audio_pll_lock),
    .clk0_out(),.clk1_out(),.clk2_out(audio_mclk));
wire ctl_valid,ctl_ready,playback_paused;wire [1:0] ctl_op;wire [7:0] ctl_theme_id;
wire [3:0] state_code;
wire [67:0] menu_snapshot_ui,menu_snapshot_sys;
wire alarm_active,alarm_silenced,alarm_block,alarm_silence_pulse,alarm_tick_ms;
// Alarm lifetime follows external reset/PLL availability, NOT media recovery.
reg [2:0] alarm_release;
always @(posedge sd_card_clk or negedge rst_n)
    if(!rst_n) alarm_release<=0;
    else if(!sys_pll_lock) alarm_release<=0;
    else alarm_release<={alarm_release[1:0],1'b1};
wire alarm_rst_n=alarm_release[2];
wire alarm_ui_inhibit=alarm_block || alarm_silence_pulse;
// Reserved snapshot bit47 transports only the persistent alarm level.
// Renderer synchronizes it separately; ordinary menu mailbox ignores this bit.
assign menu_snapshot_sys={menu_snapshot_ui[67:48],alarm_active,menu_snapshot_ui[46:0]};
exhibit_alarm_control alarm_control(.clk_sys(sd_card_clk),.rst_alarm_n(alarm_rst_n),
    .reed_async(reed_do),.knob_press(knob_click),.joystick_press(joy_click),
    .alarm_active(alarm_active),.silenced(alarm_silenced),.controls_block(alarm_block),
    .silence_pulse(alarm_silence_pulse),.tick_ms(alarm_tick_ms));
wire buzzer_drive_n;
alarm_buzzer alarm_sound(.clk_sys(sd_card_clk),.rst_alarm_n(alarm_rst_n),
    .tick_ms(alarm_tick_ms),.sound_enable(alarm_block),.buzzer_n(buzzer_drive_n));
assign buzzer_n=(!rst_n || !sys_pll_lock || !alarm_rst_n) ? 1'b1:buzzer_drive_n;
reg restore_seen_sys;
always @(posedge sd_card_clk or negedge rst_sys_n)
    if(!rst_sys_n) restore_seen_sys<=0;else restore_seen_sys<=menu_snapshot_sys[44];
wire restore_defaults_sys=menu_snapshot_sys[44]!=restore_seen_sys;
// Local controls go directly to the SYS media handshake. No serial adapter,
// status packet, reply wait, command sequence or duplicated pause state.
theme_key_control #(.DEBOUNCE_CYCLES(800000)) keys(.clk_sys(sd_card_clk),.rst_sys_n(rst_sys_n),
    .key_next_n(1'b1),.key_auto_n(1'b1),.key_pause_n(key2),.playback_paused(playback_paused),
    .restore_defaults(restore_defaults_sys),
    .ctl_valid(ctl_valid),.ctl_ready(ctl_ready),.ctl_op(ctl_op),.ctl_theme_id(ctl_theme_id));
wire sd_init_done,sd_sec_read,sd_sec_read_data_valid,sd_sec_read_end,sd_sec_read_error;
wire [2:0] sd_init_error;wire [31:0] sd_sec_read_addr;wire [7:0] sd_sec_read_data;
// The sole SPI owner. Writes are disabled; CMD58 SDHC/SDXC checks are retained.
sd_card_top #(.SPI_LOW_SPEED_DIV(98),.CMD58_TIMEOUT_CYCLES(40000000)) card(.clk(sd_card_clk),.rst(!rst_sys_n),
    .SD_nCS(sd_ncs),.SD_DCLK(sd_dclk),.SD_MOSI(sd_mosi),.SD_MISO(sd_miso),
    .sd_init_done(sd_init_done),.sd_init_error(sd_init_error),
    .sd_sec_read(sd_sec_read),.sd_sec_read_addr(sd_sec_read_addr),
    .sd_sec_read_data(sd_sec_read_data),.sd_sec_read_data_valid(sd_sec_read_data_valid),
    .sd_sec_read_end(sd_sec_read_end),.sd_sec_read_error(sd_sec_read_error),
    .sd_sec_write(1'b0),.sd_sec_write_addr(32'd0),.sd_sec_write_data(8'd0),
    .sd_sec_write_data_req(),.sd_sec_write_end());
wire audio_valid;wire [23:0] audio_left_data,audio_right_data;
wire acr_valid;wire [19:0] acr_cts,acr_n;
wire acr_valid_raw;wire [19:0] acr_cts_raw,acr_n_raw;
wire [23:0] rgb_out;wire de_out,hs_out,vs_out,Sdr_init_done;
wire SDRAM_CLK,SDR_RAS,SDR_CAS,SDR_WE;wire [1:0] SDR_BA;
wire [10:0] SDR_ADDR;wire [3:0] SDR_DM;wire [31:0] SDR_DQ;
wire knob_cw,knob_ccw,knob_click,key_back_click;
wire joy_rst_adc_n,joy_ready,joy_fault,joy_calibration_error;
wire joy_up,joy_down,joy_left,joy_right,joy_up_repeat,joy_down_repeat,joy_left_repeat,joy_right_repeat,joy_click;
wire pan_mode=!menu_snapshot_sys[0] && menu_snapshot_sys[23:22]>=2;
wire ui_repeat=menu_snapshot_sys[0] || pan_mode;
joystick_reset joystick_adc_reset(.clk(joystick_adc_clk),.reset_n(rst_sys_n),
    .locked(sys_pll_lock),.run_n(joy_rst_adc_n));
joystick_menu_input joystick(.clk_sys(sd_card_clk),.rst_sys_n(rst_sys_n),
    .clk_adc(joystick_adc_clk),.rst_adc_n(joy_rst_adc_n),.joy_button(joy_button),
    .up_press(joy_up),.down_press(joy_down),.left_press(joy_left),.right_press(joy_right),
    .up_repeat(joy_up_repeat),.down_repeat(joy_down_repeat),.left_repeat(joy_left_repeat),.right_repeat(joy_right_repeat),.button_press(joy_click),
    .ready(joy_ready),.fault(joy_fault),.calibration_error(joy_calibration_error));
board_menu_input #(.JOYSTICK_MODE(1),.ENABLE_ALARM_INPUT(1)) local_menu(.alarm_inhibit(alarm_ui_inhibit),.clk_sys(sd_card_clk),.rst_sys_n(rst_sys_n),
    .encoder_a(knob_a),.encoder_b(knob_b),.encoder_s_n(knob_s_n),.key_back_n(1'b1),.sw0_on(sw0),
    .joy_up(joy_up || (ui_repeat && joy_up_repeat)),
    .joy_down(joy_down || (ui_repeat && joy_down_repeat)),
    .joy_left(joy_left || (pan_mode && joy_left_repeat)),.joy_right(joy_right || (pan_mode && joy_right_repeat)),.joy_click(joy_click),
    .menu_snapshot_sys(menu_snapshot_ui),.step_cw(knob_cw),.step_ccw(knob_ccw),.click_press(knob_click),.back_press(key_back_click),
    .inputs_ready(),.invalid_transition(),.confirm_pulse());
wire browse_image_next,browse_image_prev,browse_theme_next;
board_browse_control browse_controls(
    .menu_open(menu_snapshot_sys[0]),.zoom_level(menu_snapshot_sys[23:22]),
    .encoder_next(knob_ccw),.encoder_prev(knob_cw),.encoder_click(knob_click),
    .joy_left(joy_left),.joy_right(joy_right),
    .image_next(browse_image_next),.image_prev(browse_image_prev),.theme_next(browse_theme_next));
media_av_pipeline #(.MENU_ENABLE(1)) media(
    .menu_snapshot_sys(menu_snapshot_sys),
    // Reverse only picture navigation, following the board-tested physical
    // direction. Menu adjustment is corrected separately in board_menu_input.
    .image_next(browse_image_next && !alarm_ui_inhibit),.image_prev(browse_image_prev && !alarm_ui_inhibit),
    .theme_next(browse_theme_next && !alarm_ui_inhibit),.theme_prev(1'b0),
    .music_toggle(1'b0),.auto_toggle(1'b0),
    .clk_ref(clk),.ext_reset_n(rst_n),.clocks_locked_async(clocks_locked_async),
    .clk_sys(sd_card_clk),.clk_mem(ext_mem_clk),.clk_mem_sft(ext_mem_clk_sft),
    .clk_pix(video_clk),.clk_audio(audio_mclk),.clk_tmds(hdmi_5x_clk),
    .rst_sys_n(rst_sys_n),.rst_mem_n(rst_mem_n),.rst_pix_n(rst_pix_n),
    .rst_audio_n(rst_audio_n),.rst_tmds_n(rst_tmds_n),.run_enable_sys(run_enable_sys),
    .ctl_valid(ctl_valid),.ctl_ready(ctl_ready),.ctl_op(ctl_op),.ctl_theme_id(ctl_theme_id),
    // MENU_ENABLE binds brightness/subtitles to the coalescing SYS settings.
    .brightness_valid(1'b0),.brightness_ready(),.brightness_applied(),
    .brightness_level(2'd3),.brightness_actual(),
    .subtitle_valid(1'b0),.subtitle_ready(),.subtitle_applied(),
    .subtitle_enable(1'b1),.subtitle_actual(),
    .playback_paused(playback_paused),
    .auto_inhibit(ctl_valid || menu_snapshot_sys[0] || alarm_ui_inhibit),.theme_commit_pulse(),.audio_gate_applied(),
    .catalog_theme_count(),.display_elapsed_ms(),.underflow_seen(),.audio_error_code(),
    .sd_init_done(sd_init_done),.sd_init_error(sd_init_error),.sd_sec_read(sd_sec_read),
    .sd_sec_read_addr(sd_sec_read_addr),.sd_sec_read_data(sd_sec_read_data),
    .sd_sec_read_data_valid(sd_sec_read_data_valid),.sd_sec_read_end(sd_sec_read_end),
    .sd_sec_read_error(sd_sec_read_error),
    .audio_valid(audio_valid),.audio_left_data(audio_left_data),.audio_right_data(audio_right_data),
    .state_code(state_code),.active_theme_id(),.active_theme_valid(),
    .controller_error_code(),.service_ready(),.service_error(),
    .recovery_req(),.recovery_count_ref(),.recovery_lockout_ref(),
    .audio_play_enable(),.audio_muted(),.auto_enabled(),.audio_ended(),.audio_underflow(),
    .rgb_out(rgb_out),.de_out(de_out),.hs_out(hs_out),.vs_out(vs_out),
    .axis_data(axis_s_data),.axis_valid(axis_s_valid),.axis_user(axis_s_user),.axis_last(axis_s_last),
    .Sdr_init_done(Sdr_init_done),.SDRAM_CLK(SDRAM_CLK),.SDR_RAS(SDR_RAS),.SDR_CAS(SDR_CAS),
    .SDR_WE(SDR_WE),.SDR_BA(SDR_BA),.SDR_ADDR(SDR_ADDR),.SDR_DM(SDR_DM),.SDR_DQ(SDR_DQ));
// Keep valid silence frames to generate a continuous HDMI ACR clock after EOF.
audio_arc_calculate #(.ACR_N(6144)) u_audio_arc_calculate(
    .I_clk(video_clk),.I_rst(!rst_pix_n),.I_audio_valid(audio_valid),
    .O_acr_valid(acr_valid_raw),.O_acr_cts(acr_cts_raw),.O_acr_n(acr_n_raw));
assign acr_valid=rst_pix_n && acr_valid_raw;
assign acr_cts=rst_pix_n ? acr_cts_raw:20'd0;
assign acr_n=rst_pix_n ? acr_n_raw:20'd0;
// Register joystick encoding in SYS, then sample both digit codes in REF.
// All SYS/REF paths retain their derived-clock setup/hold checks. This moves
// the segment decode/mux into one REF cycle, rather than a short interclock gap.
reg [3:0] joy_code_sys;
reg [7:0] segment_codes_ref;
always @(posedge sd_card_clk or negedge rst_sys_n)
    if(!rst_sys_n)joy_code_sys<=0;
    else joy_code_sys<=joy_fault ? 4'he:joy_calibration_error ? 4'hf:joy_ready ? 4'd1:4'd0;
always @(posedge clk or negedge rst_n)
    if(!rst_n)segment_codes_ref<=0;
    else segment_codes_ref<={joy_code_sys,state_code};
// Independent single-bit diagnostic levels; original two status digits stay.
(* async_reg="true" *) reg alarm_meta_ref,alarm_sync_ref,mute_meta_ref,mute_sync_ref;
always @(posedge clk or negedge rst_n)
    if(!rst_n) begin alarm_meta_ref<=0;alarm_sync_ref<=0;mute_meta_ref<=0;mute_sync_ref<=0;end
    else begin alarm_meta_ref<=alarm_active;alarm_sync_ref<=alarm_meta_ref;
        mute_meta_ref<=alarm_silenced;mute_sync_ref<=mute_meta_ref;end
wire [7:0] alarm_digit_a=alarm_sync_ref ? 8'h88:8'hff;
wire [7:0] alarm_digit_0=alarm_sync_ref ? 8'hc0:8'hff;
wire [7:0] alarm_digit_state=alarm_sync_ref ? (mute_sync_ref ? 8'ha4:8'hf9):8'hff;
wire [6:0] seg_data_0;
seg_decoder seg_decoder_m0(.bin_data(segment_codes_ref[3:0]),.seg_data(seg_data_0));
// Leave the media state on its existing digit. Add independent joystick
// status: 0 calibrating, 1 ready, E ADC fault, F invalid centre calibration.
wire [6:0] joy_seg;
seg_decoder joy_seg_decoder(.bin_data(segment_codes_ref[7:4]),.seg_data(joy_seg));
seg_scan seg_scan_m0(.clk(clk),.rst_n(rst_n),.seg_sel(seg_sel),.seg_data(seg_data),
    .seg_data_0({1'b1,joy_seg}),.seg_data_1(alarm_digit_a),.seg_data_2(alarm_digit_0),.seg_data_3(alarm_digit_0),
    .seg_data_4(alarm_digit_state),.seg_data_5({1'b1,seg_data_0}));
// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (rst_all),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 1650        ),
    .HSA                    ( 40         ),
    .HFP                    ( 110         ),
    .HBP                    ( 220         ),
    .HACTIVE                ( 1280        ),
    .VTOTAL                 ( 750        ),
    .VSA                    ( 5          ),
    .VFP                    ( 5         ),
    .VBP                    ( 20         ),
    .VACTIVE                ( 720        ),
    .VIDEO_VIC              ( 4          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 750        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (rst_all),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  (audio_left_data),
    .I_audio_right_data (audio_right_data),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (!rst_tmds_n),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

endmodule
