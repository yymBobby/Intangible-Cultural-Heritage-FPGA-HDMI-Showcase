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
    # Alarm extension: stop before placement if resource capacity is exceeded.
    set f [open [file join $out gate.area] r]
    set area_text [read $f]
    close $f
    foreach {kind maximum} {lut 19600 reg 19600 bram9k 64 bram32k 16 dsp 29} {
        set pattern [format {^\s*#%s\s+(\d+)} $kind]
        if {![regexp -line $pattern $area_text all used]} {error "Missing mapped resource count: $kind"}
        puts "ALARM_RESOURCE $kind=$used capacity=$maximum"
        if {$used>$maximum} {error "RESOURCE_LIMIT: $kind=$used exceeds $maximum; human approval required before scope changes"}
    }
    export_db [file join $out gate.db]
    close_project
    puts "PASS: release package project synthesis"
} message]} {
    puts "FAIL: release package synthesis: $message"
    exit 1
}
exit
