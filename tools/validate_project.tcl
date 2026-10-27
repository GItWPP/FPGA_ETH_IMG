# Read-only portability check; does not synthesize or create/overwrite a project.
set root [file normalize [file join [file dirname [info script]] ..]]
open_project -read_only [file join $root project_eth eth_img.xpr]
if {[get_property TOP [current_fileset]] ne "eth_img_top"} { error "Unexpected project top" }
if {[get_property PART [current_project]] ne "xczu4ev-sfvc784-2-i"} { error "Unexpected FPGA part" }
foreach source_file [get_files -compile_order sources -used_in synthesis] {
    if {![file exists $source_file]} { error "Missing source: $source_file" }
}
puts "PASS portable Vivado project: [get_property NAME [current_project]]"
close_project
