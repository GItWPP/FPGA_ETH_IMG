# Create only this new project's dedicated XPR; never force-overwrite a project.
set root [file normalize [file join [file dirname [info script]] ..]]
set algorithm_mhz 125
if {$argc > 0} { set algorithm_mhz [lindex $argv 0] }
if {$algorithm_mhz ni {50 125}} { error "Algorithm clock must be 50 or 125 MHz" }
set project_dir [file join $root project_eth]
set project_file [file join $project_dir eth_img.xpr]
file mkdir $project_dir
if {[file exists $project_file]} {
    open_project $project_file
    if {[get_property PART [current_project]] ne "xczu4ev-sfvc784-2-i"} { error "Unexpected existing project part" }
} else {
    create_project eth_img $project_dir -part xczu4ev-sfvc784-2-i
}
set_property target_language Verilog [current_project]
set_property XPM_LIBRARIES {XPM_MEMORY XPM_FIFO} [current_project]

proc image_rtl_files {directory} {
    set result [glob -nocomplain -directory $directory *.v]
    foreach child [glob -nocomplain -type d -directory $directory *] {
        set result [concat $result [image_rtl_files $child]]
    }
    return $result
}
set new_sources [list]
foreach source_file [image_rtl_files [file join $root rtl]] {
    if {[file tail $source_file] in {uart_img_top.v uart_rx.v uart_tx.v}} { continue }
    if {[llength [get_files -quiet $source_file]] == 0} { lappend new_sources $source_file }
}
if {[llength $new_sources]} { add_files -norecurse $new_sources }
set weights [file join $root rtl hog_svm_weights.mem]
if {[llength [get_files -quiet $weights]] == 0} { add_files -norecurse $weights }
set_property file_type {Memory Initialization Files} [get_files $weights]
set constraints [file join $root eth_img.xdc]
if {[llength [get_files -quiet $constraints]] == 0} { add_files -fileset constrs_1 -norecurse $constraints }
set cdc_constraints [file join $root eth_cdc.xdc]
if {[llength [get_files -quiet $cdc_constraints]] == 0} { add_files -fileset constrs_1 -norecurse $cdc_constraints }
set_property used_in_synthesis false [get_files $cdc_constraints]
set_property AUTO_INCREMENTAL_CHECKPOINT 0 [get_runs synth_1]

if {[llength [get_ips -quiet clk_wiz_eth]] == 0} {
    file mkdir [file join $project_dir ip]
    create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 -module_name clk_wiz_eth -dir [file join $project_dir ip]
}
# Explicitly update the existing clock IP when the transport domain is added.
    set_property -dict [list \
        CONFIG.PRIM_IN_FREQ {125.000} \
        CONFIG.PRIM_SOURCE {No_buffer} \
        CONFIG.NUM_OUT_CLKS {3} \
        CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {125.000} \
        CONFIG.CLKOUT1_REQUESTED_PHASE {210.000} \
        CONFIG.CLKOUT2_USED {true} \
        CONFIG.CLKOUT2_REQUESTED_OUT_FREQ $algorithm_mhz \
        CONFIG.CLKOUT2_REQUESTED_PHASE {0.000} \
        CONFIG.CLKOUT3_USED {true} \
        CONFIG.CLKOUT3_REQUESTED_OUT_FREQ {125.000} \
        CONFIG.CLKOUT3_REQUESTED_PHASE {0.000} \
        CONFIG.RESET_TYPE {ACTIVE_HIGH}] [get_ips clk_wiz_eth]
generate_target all [get_ips clk_wiz_eth]
set_property top eth_img_top [current_fileset]
update_compile_order -fileset sources_1
puts "PASS setup_project: [get_property PART [current_project]] / [get_property TOP [current_fileset]] / algorithm=${algorithm_mhz}MHz"
close_project
