# fpga/vivado/scripts/diag_ooo_plain.tcl -- plain, default-options full
# OOOCore synth_design, isolating exactly one variable at a time against
# the docs/adr/0070 bisection baseline (same as the original hang, no
# extra flags). Used to test the PhysicalRegisterFile.v storage-replication
# fix in the actual whole-design context (not just standalone-module).
source fpga/vivado/build_dir.tcl
set work_dir [vivado_build_dir ooo_plain]
set repo_root [file normalize [file dirname [info script]]/../../..]

file delete -force $work_dir
file mkdir $work_dir
create_project -force diag $work_dir -part xc7k325tffg900-2

add_files -norecurse [glob $repo_root/design/*.v]
add_files -fileset constrs_1 -norecurse $repo_root/fpga/vivado/xdc/constraints_ooo.xdc
set_property top OOOCore [current_fileset]
update_compile_order -fileset sources_1

puts "DIAG_START plain [clock format [clock seconds]]"
synth_design -top OOOCore -part xc7k325tffg900-2 -mode out_of_context
puts "DIAG_SYNTH_DONE [clock format [clock seconds]]"
report_utilization -file $work_dir/utilization.rpt
puts "DIAG_OK"
