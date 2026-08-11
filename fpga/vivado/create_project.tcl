# fpga/vivado/create_project.tcl -- reproducible project generation for the
# Vivado FPGA synthesis/implementation/timing/power workflow
# (docs/superpowers/plans/2026-08-11-vivado-fpga-synthesis-workflow.md,
# fpga/vivado/AUDIT.md).
#
# Usage:
#   vivado -mode batch -source fpga/vivado/create_project.tcl -tclargs <config> [part]
# <config>: inorder | ooo | soc
# [part]:   Vivado part (default xc7k325tffg900-2, a Kintex-7 325T -- boardless
#           offline study, chosen for headroom over the OoO+vector core; see
#           fpga/vivado/AUDIT.md for the component inventory that motivated
#           picking a larger device than fpga/build.tcl's existing Artix-7
#           35T target).

if {[llength $argv] < 1} {
    puts "usage: vivado -mode batch -source fpga/vivado/create_project.tcl -tclargs <inorder|ooo|soc> \[part\]"
    exit 1
}
set config [lindex $argv 0]
set part_name [expr {[llength $argv] >= 2 ? [lindex $argv 1] : "xc7k325tffg900-2"}]

array set top_of {inorder PIPELINED ooo OOOCore soc HeteroSoC}
array set xdc_of {inorder constraints_inorder.xdc ooo constraints_ooo.xdc soc constraints_soc.xdc}

if {![info exists top_of($config)]} {
    puts "error: unknown config '$config' -- must be inorder, ooo, or soc"
    exit 1
}

set repo_root [file normalize [file dirname [info script]]/../..]
set build_dir $repo_root/fpga/vivado/build/$config

file delete -force $build_dir
file mkdir $build_dir
create_project -force $config $build_dir -part $part_name

add_files -norecurse [glob $repo_root/design/*.v]
add_files -fileset constrs_1 -norecurse $repo_root/fpga/vivado/xdc/$xdc_of($config)

set_property top $top_of($config) [current_fileset]
set_property target_language Verilog [current_project]
update_compile_order -fileset sources_1

puts "PROJECT_CREATED build_dir=$build_dir top=$top_of($config) part=$part_name"
close_project
