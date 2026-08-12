# fpga/vivado/scripts/diag_ooo_flatten_none.tcl -- test whether disabling
# whole-design hierarchy flattening (the "Cross Boundary and Area
# Optimization" phase) avoids the OOOCore synthesis hang. Pure synthesis-tool
# option, zero RTL change. docs/adr/0070 bisection step.
source fpga/vivado/build_dir.tcl
set work_dir [vivado_build_dir ooo_flatten_none]
set repo_root [file normalize [file dirname [info script]]/../../..]

file delete -force $work_dir
file mkdir $work_dir
create_project -force diag $work_dir -part xc7k325tffg900-2

add_files -norecurse [glob $repo_root/design/*.v]
add_files -fileset constrs_1 -norecurse $repo_root/fpga/vivado/xdc/constraints_ooo.xdc
set_property top OOOCore [current_fileset]
update_compile_order -fileset sources_1

puts "DIAG_START flatten_hierarchy=none [clock format [clock seconds]]"
synth_design -top OOOCore -part xc7k325tffg900-2 -mode out_of_context -flatten_hierarchy none
puts "DIAG_SYNTH_DONE [clock format [clock seconds]]"
report_utilization -file $work_dir/utilization.rpt
report_utilization -hierarchical -file $work_dir/utilization_hier.rpt
puts "DIAG_OK"
