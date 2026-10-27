# Run: vivado -mode batch -source tools/build_vivado.tcl
# Optional first argument overrides the output directory; no board is programmed.
set root [file normalize [file join [file dirname [info script]] ..]]
set project_file [file join $root project_eth eth_img.xpr]
set out [file join $root project_eth build]
set resume_route [expr {$argc > 1 && [lindex $argv 1] eq "resume-route"}]
if {$argc > 0} { set out [file normalize [lindex $argv 0]] }
file mkdir $out
if {$resume_route} {
    exec python -E [file join $root tools record_build_sources.py] --check [file join $out build_sources.json]
} else {
    exec python -E [file join $root tools record_build_sources.py] --output [file join $out build_sources.json]
}
file copy -force [file join $root rtl hog_svm_weights.mem] [file join $out hog_svm_weights.mem]
set_param general.maxThreads 4
if {![file exists $project_file]} { error "Missing user project: $project_file" }
open_project $project_file
if {[get_property TOP [current_fileset]] ne "eth_img_top"} { error "Expected eth_img_top" }
if {[get_property PART [current_project]] ne "xczu4ev-sfvc784-2-i"} { error "Wrong ZU4EV part" }
set algorithm_mhz [expr {int(double([get_property CONFIG.CLKOUT2_REQUESTED_OUT_FREQ [get_ips clk_wiz_eth]]))}]
if {$algorithm_mhz ni {50 125}} { error "Unsupported algorithm clock profile" }
# Rebuild an updated clock IP before the parent synthesis consumes its stub/DCP.
set clock_run [get_runs -quiet clk_wiz_eth_synth_1]
if {!$resume_route && [llength $clock_run]} {
    reset_run $clock_run
    launch_runs $clock_run -jobs 4
    wait_on_run $clock_run
    if {[get_property PROGRESS $clock_run] ne "100%"} { error "Clock IP synthesis failed" }
}
if {!$resume_route} {
    reset_run synth_1
    launch_runs synth_1 -jobs 4
    wait_on_run synth_1
}
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} { error "Synthesis failed" }
open_run synth_1
foreach hierarchy {eth_image_core_inst/eth_udp_stack_inst eth_image_core_inst/img_stream_top_inst eth_image_core_inst/eth_image_rx_inst eth_image_core_inst/tx_mailbox_inst eth_rgmii_if_inst} {
    if {[llength [get_cells -quiet $hierarchy]] == 0} { error "Missing planned subsystem: $hierarchy" }
}
report_utilization -hierarchical -file [file join $out utilization_synth.rpt]
close_design
# Vivado 2024.2 on this host crashed in the optional parallel power report.
# Keep required timing/DRC/CDC reports and disable only that power estimate.
set power_report [get_report_configs -quiet -of_objects [get_runs impl_1] impl_1_route_report_power_0]
if {[llength $power_report] != 1} { error "Expected route power report configuration" }
set_property IS_ENABLED false $power_report
if {$resume_route} {
    reset_run impl_1 -from_step route_design
    launch_runs impl_1 -to_step route_design -jobs 4
} else {
    launch_runs impl_1 -to_step route_design -jobs 4
}
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} { error "Implementation failed" }
open_run impl_1
write_checkpoint -force [file join $out eth_img_routed.dcp]
report_utilization -file [file join $out utilization.rpt]
report_timing_summary -delay_type min_max -report_unconstrained -check_timing_verbose -file [file join $out timing_summary.rpt]
report_drc -file [file join $out drc.rpt]
report_cdc -details -file [file join $out cdc.rpt]
report_clock_interaction -file [file join $out clock_interaction.rpt]
report_clocks -file [file join $out clocks.rpt]
report_bus_skew -file [file join $out bus_skew.rpt]
set skew_file [open [file join $out bus_skew.rpt] r]
set skew_text [read $skew_file]
close $skew_file
if {[string first "VIOLATED" $skew_text] >= 0} { error "Bundled CDC bus skew constraint failed" }
if {[string first "No bus skew constraints" $skew_text] >= 0} { error "Gray pointer constraints were not applied" }
set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path [get_timing_paths -delay_type min -max_paths 1]
if {[llength $setup_path] == 0 || [llength $hold_path] == 0} { error "No timed internal paths" }
if {[get_property SLACK $setup_path] < 0 || [get_property SLACK $hold_path] < 0} { error "Timing failed; inspect timing_summary.rpt" }
if {[llength [get_drc_violations -quiet -filter {SEVERITY == Error}]] != 0} { error "DRC errors; inspect drc.rpt" }
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
exec python -E [file join $root tools record_build_sources.py] --check [file join $out build_sources.json]
write_bitstream -force [file join $out eth_img.bit]
set summary [open [file join $out build_summary.txt] w]
puts $summary "PART=xczu4ev-sfvc784-2-i"
puts $summary "APP_CLOCK_HZ=125000000 ALGORITHM_CLOCK_HZ=[expr {$algorithm_mhz * 1000000}] GMII_CLOCK_HZ=125000000"
puts $summary "ALGORITHM_CDC=ASYNC_DESCRIPTOR_FIFOS_AND_DUAL_CLOCK_RAM"
puts $summary "LOCAL_IP=192.168.1.12 UDP_PORT=1234"
puts $summary "TRANSPORT_WINDOW=64 STREAM_BYTES_PER_CLOCK=1"
puts $summary "RGMII_IO_TIMING=REFERENCE_BOARD_DELAYS_NOT_SPECIFIED"
puts $summary "SETUP_SLACK_NS=[get_property SLACK $setup_path]"
puts $summary "HOLD_SLACK_NS=[get_property SLACK $hold_path]"
puts $summary "BITSTREAM=[file join $out eth_img.bit]"
close $summary
puts "PASS build_vivado: internal timing and DRC checked; external RGMII I/O delays still require board signoff"
close_project
