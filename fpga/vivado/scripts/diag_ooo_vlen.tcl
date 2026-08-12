# fpga/vivado/scripts/diag_ooo_vlen.tcl -- full OOOCore synthesis with VLEN
# overridden via generic, to bisect whether the vector-register width (not
# merely the vector unit's presence) is what triggers the synthesis hang.
# docs/adr/0070 controlled-reduction step. Zero RTL change.
# Usage: set DIAG_VLEN env var before invoking, or edit the default below.
if {[info exists ::env(DIAG_VLEN)]} {
    set vlen $::env(DIAG_VLEN)
} else {
    set vlen 64
}
source fpga/vivado/build_dir.tcl
regsub -all {[^0-9A-Za-z]} $vlen "_" vlen_label
set work_dir [vivado_build_dir ooo_vlen_$vlen_label]
set repo_root [file normalize [file dirname [info script]]/../../..]

file delete -force $work_dir
file mkdir $work_dir
create_project -force diag $work_dir -part xc7k325tffg900-2

add_files -norecurse [glob $repo_root/design/*.v]
add_files -fileset constrs_1 -norecurse $repo_root/fpga/vivado/xdc/constraints_ooo.xdc
set_property top OOOCore [current_fileset]
update_compile_order -fileset sources_1
set_property generic "VLEN=$vlen" [current_fileset]

puts "DIAG_START VLEN=$vlen [clock format [clock seconds]]"
synth_design -top OOOCore -part xc7k325tffg900-2 -mode out_of_context -generic VLEN=$vlen
puts "DIAG_SYNTH_DONE VLEN=$vlen [clock format [clock seconds]]"
report_utilization -file $work_dir/utilization.rpt
puts "DIAG_OK VLEN=$vlen"
