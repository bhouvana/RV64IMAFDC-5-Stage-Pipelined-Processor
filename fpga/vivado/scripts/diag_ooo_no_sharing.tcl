# fpga/vivado/scripts/diag_ooo_no_sharing.tcl -- test whether disabling
# Vivado's resource-sharing search (a documented source of synthesis-time
# blowup on designs with many logically-similar wide muxes/comparators --
# exactly this design's per-read-port write-bypass comparison logic across
# 13 ports) avoids the OOOCore hang. Pure synthesis option, zero RTL change.
# docs/adr/0070 bisection step.
source fpga/vivado/build_dir.tcl
set work_dir [vivado_build_dir ooo_no_sharing]
set repo_root [file normalize [file dirname [info script]]/../../..]

file delete -force $work_dir
file mkdir $work_dir
create_project -force diag $work_dir -part xc7k325tffg900-2

add_files -norecurse [glob $repo_root/design/*.v]
add_files -fileset constrs_1 -norecurse $repo_root/fpga/vivado/xdc/constraints_ooo.xdc
set_property top OOOCore [current_fileset]
update_compile_order -fileset sources_1

puts "DIAG_START resource_sharing=off [clock format [clock seconds]]"
synth_design -top OOOCore -part xc7k325tffg900-2 -mode out_of_context -resource_sharing off
puts "DIAG_SYNTH_DONE [clock format [clock seconds]]"
report_utilization -file $work_dir/utilization.rpt
puts "DIAG_OK"
