# fpga/vivado/scripts/diag_module_synth.tcl -- standalone synth_design of ONE
# module in isolation, for bisecting the OOOCore synthesis hang (docs/adr/0070).
# Not part of the documented reproducible flow.
# Usage: vivado -mode batch -source fpga/vivado/scripts/diag_module_synth.tcl \
#          -tclargs <module_name> [generic=value ...]
# e.g.: -tclargs VALU
#       -tclargs PhysicalRegisterFile XLEN=512 NUM_PREGS=64 HARDWIRE_PREG0=0
if {[llength $argv] < 1} { puts "usage: -tclargs <module_name> [generic=value ...]"; exit 1 }
set module_name [lindex $argv 0]
set generics [lrange $argv 1 end]
set repo_root [file normalize [file dirname [info script]]/../../..]
set work_dir D:/tmp_build/riscv-fpga-vivado/diag_$module_name

file delete -force $work_dir
file mkdir $work_dir
create_project -force diag $work_dir -part xc7k325tffg900-2

add_files -norecurse [glob $repo_root/design/*.v]
set_property top $module_name [current_fileset]
update_compile_order -fileset sources_1

if {[llength $generics] > 0} {
    set_property generic $generics [current_fileset]
}

puts "DIAG_START module=$module_name generics=$generics [clock format [clock seconds]]"
synth_design -top $module_name -part xc7k325tffg900-2 -mode out_of_context
puts "DIAG_SYNTH_DONE module=$module_name [clock format [clock seconds]]"
report_utilization -file $work_dir/utilization.rpt
puts "DIAG_OK module=$module_name"
