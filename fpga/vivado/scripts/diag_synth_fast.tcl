# fpga/vivado/scripts/diag_synth_fast.tcl -- one-off diagnostic: does synth_1
# for a config complete at all if run with Vivado's fastest/least-effort
# synthesis strategy? Used to isolate whether the ooo (OOOCore) synthesis
# hang (docs/adr/0068) is inherent to the design's scale/width or an
# artifact of the default timing-driven strategy. Not part of the
# documented reproducible flow -- run_synthesis.tcl stays the real one.
# Usage: vivado -mode batch -source fpga/vivado/scripts/diag_synth_fast.tcl -tclargs <config>
if {[llength $argv] < 1} { puts "usage: -tclargs <inorder|ooo|soc>"; exit 1 }
set config [lindex $argv 0]
set repo_root [file normalize [file dirname [info script]]/../../..]
source [file dirname [info script]]/../build_dir.tcl
set build_dir [vivado_build_dir $config]
open_project $build_dir/$config.xpr

set_property flow {Vivado Synthesis 2026} [get_runs synth_1]
set_property strategy Flow_RuntimeOptimized [get_runs synth_1]
set_param general.maxThreads 4

reset_run synth_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1

set progress [get_property PROGRESS [get_runs synth_1]]
set status [get_property STATUS [get_runs synth_1]]
puts "DIAG_SYNTH_RESULT config=$config status=$status progress=$progress"
close_project
