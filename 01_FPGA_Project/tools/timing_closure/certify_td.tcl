# Run in a NEW TD process: remove implementation-only margins before signoff.
set project $::env(MEDIA_TD_PROJECT)
set out $::env(MEDIA_TD_REPORTS)
cd [file dirname $project]
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    open_project -single_run $project
    import_db [file join $out route.db]
    clear_sdc
    read_sdc ../user_source/constraints_source/timing.sdc
    read_sdc -ip wfifo_32_32_512 ../user_source/hdl_source/IP/afifo_16_32_256.tcl
    read_sdc -ip rfifo_32_32_512 ../user_source/hdl_source/IP/afifo_32_16_256.tcl
    read_sdc timing_overlay.sdc
    update_timing -mode final
    report_timing_summary -ep_num 30 -file [file join $out independent_timing.rpt]
    report_route_status -drc
    report_clock_intersection -file [file join $out independent_clocks.rpt]
    report_timing_exception -file [file join $out independent_exceptions.rpt]
    report_timing_ignored -file [file join $out independent_ignored.rpt]
    export_db [file join $out route.db]
    close_project
    puts "PASS: independent production-constraint STA"
} message]} {
    puts "FAIL: independent STA: $message"
    exit 1
}
exit
