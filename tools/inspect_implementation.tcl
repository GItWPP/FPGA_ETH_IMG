set root [file normalize [file join [file dirname [info script]] ..]]
set out [file join $root project_eth build]
open_checkpoint [file join $out eth_img_routed.dcp]
report_bus_skew -file [file join $out bus_skew.rpt]
set handle [open [file join $out bus_skew.rpt] r]
set text [read $handle]
close $handle
if {[string first "VIOLATED" $text] >= 0} { error "CDC bus skew failed" }
puts "PASS implementation review: bundled metadata bus skew constraints met"
close_design
