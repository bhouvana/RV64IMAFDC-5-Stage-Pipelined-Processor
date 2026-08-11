# fpga/vivado/run_reports.tcl -- Phase 5/6/7/8 report generation against an
# already-routed run.
# Usage: vivado -mode batch -source fpga/vivado/run_reports.tcl -tclargs <config> <label>
# <label>: subdirectory name under fpga/vivado/reports/<config>/<label>/, e.g.
# "100mhz" -- lets the bisection sweep keep each frequency point's reports.
if {[llength $argv] < 2} { puts "usage: -tclargs <inorder|ooo|soc> <label>"; exit 1 }
set config [lindex $argv 0]
set label [lindex $argv 1]
set repo_root [file normalize [file dirname [info script]]/../..]
set build_dir $repo_root/fpga/vivado/build/$config
set out_dir $repo_root/fpga/vivado/reports/$config/$label
file mkdir $out_dir

open_project $build_dir/$config.xpr
open_run impl_1

report_utilization -file $out_dir/impl_utilization.rpt
report_utilization -hierarchical -file $out_dir/impl_utilization_hierarchical.rpt
report_timing_summary -file $out_dir/timing_summary.rpt -max_paths 10
report_timing -sort_by group -max_paths 1 -path_type full -input_pins -file $out_dir/critical_path.rpt
report_clock_utilization -file $out_dir/clock_utilization.rpt
report_power -file $out_dir/power.rpt

set wns "n/a"
set tns "n/a"
set whs "n/a"
catch { set wns [get_property STATS.WNS [get_runs impl_1]] }
catch { set tns [get_property STATS.TNS [get_runs impl_1]] }
catch { set whs [get_property STATS.WHS [get_runs impl_1]] }

set fh [open $out_dir/summary.txt w]
puts $fh "config=$config"
puts $fh "label=$label"
puts $fh "wns_ns=$wns"
puts $fh "tns_ns=$tns"
puts $fh "whs_ns=$whs"
close $fh

puts "REPORTS_WRITTEN out_dir=$out_dir wns_ns=$wns tns_ns=$tns"
close_project
