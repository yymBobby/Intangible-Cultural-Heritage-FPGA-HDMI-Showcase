set project $::env(MEDIA_TD_PROJECT)
set out $::env(MEDIA_TD_REPORTS)
cd [file dirname $project]
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project -single_run $project
    set_param -run phy_1 place effort high
    set_param -run phy_1 place opt_timing high
    set_param -run phy_1 place post_place_opt high
    set_param -run phy_1 place pr_strategy 2
    set_param -run phy_1 place seed 11
    set_param -run phy_1 place hfn_opt_effort medium
    set_param -run phy_1 place pack_mode auto
    set_param -run phy_1 place macro_performance auto
    set_param -run phy_1 route effort routability
    set_param -run phy_1 route timing greedy
    set_param -run phy_1 route post_route_opt high
    set_param -run phy_1 route fix_hold on
    # Apply actual runtime mapping/packing parameters in this direct-step flow.
    set_param rtl resource_sharing auto
    set_param rtl shifter_style shifter_reg
    set_param gate add_map_lut_struct high
    set_param gate map_mode area_prior
    set_param gate map_strategy 1
    set_param gate pack_effort high
    set_param gate multi_thread_mapping partition
    report_param -detail -stage rtl -file [file join $out rtl_parameters.txt]
    report_param -detail -stage gate -file [file join $out gate_parameters.txt]
    elaborate -top top
    read_adc ../user_source/constraints_source/pin.adc
    optimize_rtl
    read_sdc ../user_source/constraints_source/timing.sdc
    read_sdc -ip wfifo_32_32_512 ../user_source/hdl_source/IP/afifo_16_32_256.tcl
    read_sdc -ip rfifo_32_32_512 ../user_source/hdl_source/IP/afifo_32_16_256.tcl
    if {$::env(MEDIA_TD_OVERLAY) eq "1"} {read_sdc timing_overlay.sdc}
    export_db [file join $out rtl.db]
    # Keep compact macros and the area-optimized LUT mapper, but disable the
    # optional wide-LUT structure expansion. It otherwise overfills MSLICEs.
    map_macro
    export_db [file join $out macro.db]
    set_param gate map_mode area_prior
    set_param gate opt_area high
    set_param gate add_map_lut_struct off
    map
    pack
    report_param -detail -stage rtl -file [file join $out rtl_parameters_after.txt]
    report_param -detail -stage gate -file [file join $out gate_parameters_after.txt]
    legalize_phy_inst
    read_sdc ../user_source/constraints_source/timing.sdc
    read_sdc -ip wfifo_32_32_512 ../user_source/hdl_source/IP/afifo_16_32_256.tcl
    read_sdc -ip rfifo_32_32_512 ../user_source/hdl_source/IP/afifo_32_16_256.tcl
    if {$::env(MEDIA_TD_OVERLAY) eq "1"} {read_sdc timing_overlay.sdc}
    report_area -file [file join $out gate.area]
    export_db [file join $out gate.db]
    # Match the tested high-effort physical packing AFTER the mapped netlist
    # is frozen; leave the mapped-area synthesis recipe unchanged.
    set_param gate pack_effort high
    report_param -detail -stage gate -file [file join $out packing_parameters.txt]
    # -run updates the saved project; direct step execution also needs the
    # runtime settings. report_param proves what place/route will actually use.
    set_param place effort high
    set_param place hfn_opt_effort medium
    set_param place pack_mode auto
    set_param place macro_performance ram_crit_path
    set_param place opt_timing ultra
    set_param place post_place_opt high
    set_param place pr_strategy 2
    # Match the reverse-slide fix's qualified frozen-gate physical build.
    # Frequencies, board constraints and SDRAM phase stay unchanged.
    set_param place seed 11
    set_param route effort routability
    set_param route timing greedy
    set_param route post_route_opt high
    set_param route fix_hold on
    # Tighten only physical optimization. certify_td.tcl reloads the unchanged
    # production SDC in a fresh process and must pass before BIT generation.
    set margin_file [file join $out implementation_margin.sdc]
    set margin_handle [open $margin_file w]
    puts $margin_handle {set_clock_uncertainty -setup 1.5 [get_clocks {video_clk sd_card_clk}]}
    close $margin_handle
    read_sdc $margin_file
    report_param -detail -stage place -file [file join $out physical_parameters.txt]
    report_param -stage route -file [file join $out route_parameters.txt]
    place
    export_db [file join $out place.db]
    update_timing -mode manhattan
    report_timing_summary -ep_num 40 -file [file join $out place.timing]
    route
    # At >90% slice occupancy TD can skip route's automatic hold step.
    # Explicit post-route fix_hold closes the remaining register -> BRAM paths.
    fix_hold
    export_db [file join $out route.db]
    update_timing -mode final
    report_area -file [file join $out route.area]
    report_timing_summary -ep_num 30 -file [file join $out full.timing]
    report_route_status -drc
    report_clock_intersection -file [file join $out clocks.timing]
    report_timing_exception -file [file join $out exceptions.timing]
    report_timing_ignored -file [file join $out ignored.timing]
    write_verilog [file join $out routed_netlist.v]
    close_project
    puts "PASS: media TD route"
} message]} {
    puts "FAIL: media TD route: $message"
    exit 1
}
exit

