# Probe by default; pass "program" to download this project's bitstream.
set root [file normalize [file join [file dirname [info script]] ..]]
set do_program [expr {$argc>0 && [lindex $argv 0] eq "program"}]
open_hw_manager
connect_hw_server -url localhost:3121
set targets [get_hw_targets]
if {[llength $targets]!=1} { error "Expected exactly one JTAG target, found [llength $targets]; inspect manually" }
open_hw_target [lindex $targets 0]
set devices [get_hw_devices -quiet -filter {PART =~ xczu4*}]
puts "ETH_IMG_TARGETS=$targets"
puts "ETH_IMG_DEVICES=[get_hw_devices]"
if {$do_program} {
    if {[llength $devices]!=1} { error "Expected exactly one xczu4ev device; no board programmed" }
    set bit [file join $root project_eth build eth_img.bit]
    if {$argc > 1} { set bit [file normalize [lindex $argv 1]] }
    if {![file exists $bit]} { error "Missing bitstream: $bit" }
    set device [lindex $devices 0]
    current_hw_device $device
    refresh_hw_device $device
    set_property PROGRAM.FILE $bit $device
    program_hw_devices $device
    refresh_hw_device $device
    puts "PASS hardware: programmed $device with $bit"
}
close_hw_target
disconnect_hw_server
close_hw_manager
