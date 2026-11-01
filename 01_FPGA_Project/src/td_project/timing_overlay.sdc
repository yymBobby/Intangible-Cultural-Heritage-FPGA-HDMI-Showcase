# Supplemental constraints for explicitly reviewed asynchronous entry stages.
# No clock frequency, SDRAM I/O timing, or ordinary logic path is relaxed.
# A single-bit synchronizer tolerates unrelated edge phase at its first stage;
# bound its physical route to less than the fastest receiving period (13.33 ns).
# TD SWUG105: datapath_only with -from also disables the unrelated hold check.
# TD broad *_meta_* matches combinational aliases as well as synchronizers.
# Enumerate reviewed RTL first stages exactly, including flattened '$' hierarchy;
# ordinary producer logic and all synchronizer second stages remain timed.
# The list was audited against the board-passed baseline database before use.
set_max_delay -datapath_only -from [get_clocks {*}] \
    -to [get_regs -nowarn {media/reset_manager/req_meta_ref media/reset_manager/release_meta_ref[*] media/reset_manager/run_meta_sys media/reset_manager/sys_clock/toggle_meta media/reset_manager/mem_clock/toggle_meta media/reset_manager/pix_clock/toggle_meta media/reset_manager/audio_clock/toggle_meta media/reset_manager/tmds_clock/toggle_meta media/video/front_meta_sys media/video/second_valid_meta_sys media/video/second_bank_meta_sys[*] media/video/backend_fault_meta_pix media/video/backend/cancel_meta_mem media/video/backend/cancel_done_meta_sys media/video/backend/req_meta_mem media/video/backend/done_meta_sys media/video/backend/fault_meta_sys media/video/adapter/req_meta_mem media/video/adapter/ack_meta_pix media/video/adapter/reset_meta_pix media/video/adapter/reset_meta_mem media/video/adapter/done_meta_pix media/video/adapter/error_meta_pix media/video/adapter/error_meta_mem media/video/second_adapter/req_meta_mem media/video/second_adapter/ack_meta_pix media/video/second_adapter/reset_meta_pix media/video/second_adapter/reset_meta_mem media/video/second_adapter/done_meta_pix media/video/second_adapter/error_meta_pix media/video/second_adapter/error_meta_mem media/video/controller/request_meta_pix media/video/controller/fault_meta_pix media/video/controller/ack_meta_sys media/video/controller/pixel_fault_meta_sys media/video/cache/req_meta_pix media/video/cache/fault_meta_pix media/video/cache/ack_meta_sys media/video/animation/request_meta_pix media/video/animation/ack_meta_pix media/video/animation/prepare_meta_sys media/video/animation/finish_meta_sys media/video/caption/force_meta_pix media/video/caption/ack_meta_sys media/video/caption/typing_meta_sys media/video/wide_display$renderer/auto_meta_pix media/video/wide_display$renderer/play_meta_pix media/video/wide_display$renderer/sample_meta_sys media/video/wide_display$renderer/frame_meta_sys media/video/wide_display$renderer/metrics_meta_pix media/video/wide_display$renderer/cache_progress$valid_meta_pix[*] media/video/wide_display$renderer/brightness/request_meta_pix media/video/wide_display$renderer/brightness/ack_meta_sys media/video/wide_display$renderer/menu_display$mailbox/request_meta_pix media/video/wide_display$renderer/menu_display$mailbox/ack_meta_sys media/caption_tone/enabled_meta_pix media/volume/gain_mailbox/request_meta_pix media/volume/gain_mailbox/ack_meta_sys media/receiver/b_sync[0] media/receiver/l_sync[0] media/receiver/d_sync[0] joystick/fault_meta joystick/mailbox/ack_meta joystick/mailbox/request_meta}] 13.0

# B FIFO Gray buses: retain a real route bound, rather than false-pathing them.
set_max_delay -datapath_only -from [get_regs {media/player/fifo/wgray[*]}] \
    -to [get_regs {media/player/fifo/wg1[*]}] 9.7
set_max_delay -datapath_only -from [get_regs {media/player/fifo/rgray[*]}] \
    -to [get_regs {media/player/fifo/rg1[*]}] 9.7
set_max_delay -datapath_only -from [get_clocks {*}] \
    -to [get_regs {media/player/clear_a1 media/player/play_a1 media/player/task_a1 media/player/ack_s1 media/player/task_s1 media/player/ended_s1 media/player/under_s1}] 9.7

# Only the async control pins of reset-release synchronizers are exempt.
# Their Q -> next local stage paths and ordinary reset-release paths stay timed.
# Use the raw release nets: TD can rename/merge a stage under another instance,
# so filtering synthesized stage names alone misses audio/TMDS SR endpoints.
# These nets feed ONLY av_reset_release's asynchronous reset inputs in RTL.
set_false_path -through [get_nets {media/reset_manager/leaf_release_n media/reset_manager/sys_release_n}]
# The vendor FIFO reset circuits also synchronize local deassertion internally.
set_false_path -to [get_pins -nowarn {media/video/*/*_fifo/asy_*_rst*.sr}]
# With the local fifo_run_mem/pix guards, this raw reset now feeds only async
# reset pins (those guards + vendor read-FIFO reset-release circuits).
set_false_path -through [get_nets {media/video/adapter/fifo_reset_mem}]

# TD get_regs resolves RTL register names, including mapped/merged aliases.
# PCM changes only once per audio sample. The receiver captures it after the
# two-stage toggle synchronizer; include mapped arithmetic aliases in the bound.
set_max_delay -datapath_only -from [get_regs {*sample_hold_pix*}] -to [get_clocks {sd_card_clk}] 24.7
# The 40-bit metrics bundle is published once per frame after calculation.
# The pixel side captures only after its two-stage toggle; RAM bank changes
# occur during vblank, before either display RAM is read again.
set_max_delay -datapath_only -from [get_regs {*metrics_hold_sys*}] -to [get_clocks {video_clk}] 13.0

# Existing A four-phase descriptors: each bundle is frozen before req is
# synchronized, then captured in P_CAPTURE after two local sync stages.
# Bound only these explicitly frozen source registers, retaining local timing.
set_max_delay -datapath_only -from [get_regs {media/video/cache/count_hold_sys[*] media/video/cache/bank_hold_sys media/video/cache/req_hold_sys}] -to [get_clocks {video_clk}] 13.0
set_max_delay -datapath_only -from [get_regs {media/video/controller/descriptor_count_sys[*] media/video/controller/descriptor_image_bank_sys[*] media/video/controller/descriptor_text_bank_sys media/video/controller/request_hold_sys}] -to [get_clocks {video_clk}] 13.0
# MEM captures the frozen pixel bank after the request synchronizer and capture
# state, and the pixel side holds it through ACK release.
set_max_delay -datapath_only -from [get_regs {media/video/adapter/command_bank_pix[*] media/video/second_adapter/command_bank_pix[*]}] -to [get_clocks {ext_mem_clk}] 19.7
# Cropped-row span is part of the SAME frozen four-phase descriptor. PIX
# latches before req, holds through ACK release; MEM captures after two sync
# stages plus M_CAPTURE. No per-bit synchronizers or false paths.
set_max_delay -datapath_only -from [get_regs {media/video/adapter/command_words_pix[*] media/video/adapter/command_offset_pix[*] media/video/second_adapter/command_words_pix[*] media/video/second_adapter/command_offset_pix[*]}] -to [get_clocks {ext_mem_clk}] 19.7

# Stage-2 animation descriptors are held until both four-phase handshakes
# release. The PIX capture state follows the two request synchronizer stages.
set_max_delay -datapath_only -from [get_regs {media/video/animation/descriptor_sys[*]}] -to [get_clocks {video_clk}] 13.0
# Explicit first-stage ACK endpoint: TD's broad wildcard omitted this merged
# alias in effects03. This is a real two-flop level synchronizer, not an
# ordinary datapath exception; its second stage remains locally timed.
set_max_delay -datapath_only -from [get_clocks {*}] -to [get_regs {media/video/animation/ack_meta_pix}] 13.0
# The writer holds its slot before the MEM request/capture sequence and until
# completion. Preserve a physical bound within the new 50 MHz MEM period.
set_max_delay -datapath_only -from [get_regs {media/video/backend/prepared_image_bank_sys[*]}] -to [get_clocks {ext_mem_clk}] 19.7
# Second-front ownership is used only after animation/drain has completed;
# writes stay inhibited throughout that interval, giving these stages time
# to settle before the cache allocator can replace any slot.
set_max_delay -datapath_only -from [get_clocks {*}] -to [get_regs {media/video/second_bank_meta_sys[*]}] 13.0
# Like the primary read FIFO, the second FIFO synchronizes reset release.
set_false_path -through [get_nets {media/video/second_adapter/fifo_reset_mem}]

# Audio gate feedback was only observed by the removed serial transaction
# adapter. Its unused SYS synchronizer is optimized out in this top.

# Local menu now issues brightness/subtitle transactions. These payloads are
# frozen until ACK, and PIX captures after a two-flop request synchronizer.
# Limit only held bundles and first synchronizer stages, keeping ordinary
# gain/metadata and synchronizer stage-two paths fully timed.
set_max_delay -datapath_only -from [get_regs {*renderer/brightness/level_hold_sys[*] *renderer/brightness/subtitle_hold_sys}] -to [get_clocks {video_clk}] 13.0
set_max_delay -datapath_only -from [get_clocks {*}] -to [get_regs {*renderer/brightness/request_meta_pix *renderer/brightness/ack_meta_sys media/volume/gain_mailbox/request_meta_pix media/volume/gain_mailbox/ack_meta_sys}] 13.0
# The volume mailbox also freezes its two gain bits until PIX acknowledges.
set_max_delay -datapath_only -from [get_regs {media/volume/gain_mailbox/held_sys[*]}] -to [get_clocks {video_clk}] 13.0

# Contact inputs drive only first-stage SYS synchronizers; downstream is timed.
set_false_path -from [get_ports {knob_a knob_b knob_s_n sw0 key2}]
# Menu has a held bundle and two-stage request/ACK synchronizers.
# TD flattens generate hierarchy with '$'; match both RTL '/' and mapped '$'.
set_max_delay -datapath_only -from [get_clocks {*}] -to [get_regs {*menu_display*mailbox/request_meta_pix *menu_display*mailbox/ack_meta_sys}] 13.0
set_max_delay -datapath_only -from [get_regs {*menu_display*mailbox/held_sys[*]}] -to [get_clocks {video_clk}] 13.0

# Caption theme is frozen at public request before both commit synchronizers.
set_max_delay -datapath_only -from [get_regs {media/video/caption_theme_hold_sys[*]}] -to [get_clocks {video_clk}] 13.0

# Ordered browse: reviewed single-bit frame-ready synchronizer and two
# independent, display-only busy/overflow level synchronizers. Their local
# second stages remain timed. Animation speed uses the frozen descriptor above.
set_max_delay -datapath_only -from [get_clocks {*}] -to [get_regs {media/video/browse_guard/ready_meta media/video/wide_display$renderer/cache_progress$browse_meta[*]}] 13.0

# Alarm additions ONLY: asynchronous sensor to first synchronizer stage.
set_false_path -from [get_ports {reed_do}]
# Persistent single-bit levels; second stages and all local datapaths timed.
set_max_delay -datapath_only -from [get_clocks {*}] -to [get_regs {media/video/wide_display$renderer/alarm_meta_pix}] 13.0
set_max_delay -datapath_only -from [get_clocks {*}] -to [get_regs {alarm_meta_ref mute_meta_ref}] 19.7
