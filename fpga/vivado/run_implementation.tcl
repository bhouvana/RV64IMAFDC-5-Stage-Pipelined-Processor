# fpga/vivado/run_implementation.tcl -- Phase 5 implementation + Phase 6
# timing at a given clock period (bisection sweep driver, Phase 6). Rewrites
# the project's checked-in XDC's create_clock period in place for this sweep
# point (period changes require re-synth, since timing-driven synthesis reads
# the constraint -- not just re-implementation), then runs synth_1 through
# route_design.
# Usage: vivado -mode batch -source fpga/vivado/run_implementation.tcl -tclargs <config> <period_ns>
if {[llength $argv] < 2} { puts "usage: -tclargs <inorder|ooo|soc> <period_ns>"; exit 1 }
set config [lindex $argv 0]
set period [lindex $argv 1]
set repo_root [file normalize [file dirname [info script]]/../..]
set build_dir $repo_root/fpga/vivado/build/$config
open_project $build_dir/$config.xpr

set xdc_file [lindex [get_files -of_objects [get_filesets constrs_1]] 0]
set fh [open $xdc_file r]
set xdc_text [read $fh]
close $fh
set new_text [regsub {create_clock -period [0-9.]+} $xdc_text "create_clock -period $period"]
set fh [open $xdc_file w]
puts -nonewline $fh $new_text
close $fh

reset_run synth_1
launch_runs synth_1 -jobs [get_param general.maxThreads]
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "SYNTHESIS FAILED for $config @ ${period}ns -- see $build_dir/$config.runs/synth_1/runme.log"
    close_project
    exit 1
}

reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs [get_param general.maxThreads]
wait_on_run impl_1

set status [get_property STATUS [get_runs impl_1]]
set progress [get_property PROGRESS [get_runs impl_1]]
puts "IMPL_RESULT config=$config period_ns=$period status=$status progress=$progress"
if {$progress != "100%"} {
    puts "IMPLEMENTATION FAILED for $config @ ${period}ns -- see $build_dir/$config.runs/impl_1/runme.log"
    close_project
    exit 1
}
puts "IMPLEMENTATION_OK config=$config period_ns=$period"
close_project
