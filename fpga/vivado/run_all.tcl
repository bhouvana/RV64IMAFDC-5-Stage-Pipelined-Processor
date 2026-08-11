# fpga/vivado/run_all.tcl -- Phases 4-8 for one config at one clock period:
# implement (synth+opt+place+phys_opt+route via run_implementation.tcl) then
# generate every report (run_reports.tcl). Single entry point per sweep
# point; fpga/vivado/create_project.tcl must have already been run once for
# this config.
# Usage: vivado -mode batch -source fpga/vivado/run_all.tcl -tclargs <config> <period_ns> <label>
if {[llength $argv] < 3} { puts "usage: -tclargs <inorder|ooo|soc> <period_ns> <label>"; exit 1 }
set script_dir [file dirname [info script]]
set rc_config [lindex $argv 0]
set rc_period [lindex $argv 1]
set rc_label  [lindex $argv 2]

# run_implementation.tcl and run_reports.tcl each read $argv directly by
# fixed index (they're standalone entry points too, see Task 5) -- rebind it
# per sourced script rather than duplicating their logic here.
set argv [list $rc_config $rc_period]
source $script_dir/run_implementation.tcl

set argv [list $rc_config $rc_label]
source $script_dir/run_reports.tcl
