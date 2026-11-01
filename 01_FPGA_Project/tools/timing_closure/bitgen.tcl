cd [file dirname $::env(MEDIA_TD_PROJECT)]
if {[catch {
    import_device eagle_s20.db -package EG4S20BG256
    # TD 6.2 requires the project context for complete ASCII bit output.
    open_project -single_run $::env(MEDIA_TD_PROJECT)
    import_db $::env(MEDIA_TD_DB)
    # TD 6.2 aborts when writing a bitstream to this workspace's long path.
    # Generate at a short, unique TEMP filename, then copy the complete file.
    set short_bit [file join $::env(TEMP) media_timing_[pid]_[clock seconds].bit]
    if {[file exists $short_bit]} {error "Temporary bitstream name already exists"}
    bitgen -bit $short_bit
    if {![file exists $short_bit] || [file size $short_bit] < 100000} {
        error "Incomplete bitstream output"
    }
    file mkdir [file dirname $::env(MEDIA_TD_BIT)]
    file copy -force $short_bit $::env(MEDIA_TD_BIT)
    file delete $short_bit
    close_project
    puts "PASS: timing-qualified bitgen"
} message]} {
    puts "FAIL: timing-qualified bitgen: $message"
    exit 1
}
exit
