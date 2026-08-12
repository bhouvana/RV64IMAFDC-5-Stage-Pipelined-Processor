# fpga/vivado/run_synthesis.tcl -- Phase 4 baseline synthesis-only run.
# Usage: vivado -mode batch -source fpga/vivado/run_synthesis.tcl -tclargs <config>
if {[llength $argv] < 1} { puts "usage: -tclargs <inorder|ooo|soc>"; exit 1 }
set config [lindex $argv 0]
set repo_root [file normalize [file dirname [info script]]/../..]
source [file dirname [info script]]/build_dir.tcl
set build_dir [vivado_build_dir $config]
open_project $build_dir/$config.xpr

reset_run synth_1
launch_runs synth_1 -jobs [get_param general.maxThreads]
wait_on_run synth_1

set progress [get_property PROGRESS [get_runs synth_1]]
set status [get_property STATUS [get_runs synth_1]]
puts "SYNTH_RESULT config=$config status=$status progress=$progress"
if {$progress != "100%"} {
    puts "SYNTHESIS FAILED for $config -- see $build_dir/$config.runs/synth_1/runme.log"
    close_project
    exit 1
}

open_run synth_1
file mkdir $build_dir/reports
report_utilization -file $build_dir/reports/synth_utilization.rpt
report_timing_summary -file $build_dir/reports/synth_timing_summary.rpt -max_paths 1
puts "SYNTHESIS_OK config=$config"
close_project
