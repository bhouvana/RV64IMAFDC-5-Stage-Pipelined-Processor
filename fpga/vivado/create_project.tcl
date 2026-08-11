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

# Boardless study (Phase 2/3 -- no physical I/O exists to place these
# top-level ports against). A normal (non-OOC) synth_design run tries to
# place a real I/O buffer + package pin for every top-level port, including
# the clock -- which failed here on the first real attempt with "IO Clock
# Placer failed" (Place 30-99), since none of PIPELINED/OOOCore/HeteroSoC's
# many debug_*/mailbox_*/uart_* ports have a PACKAGE_PIN and there is no
# board to give them one. `-mode out_of_context` (Vivado's standard flow for
# implementing a design fragment without top-level physical I/O -- UG901)
# skips I/O buffer insertion entirely, which is exactly right for this
# study's own stated objective: analyze the internal processor fabric, not
# a bitstream-ready top-level chip design.
set_property -name {STEPS.SYNTH_DESIGN.ARGS.MORE OPTIONS} -value {-mode out_of_context} -objects [get_runs synth_1]

puts "PROJECT_CREATED build_dir=$build_dir top=$top_of($config) part=$part_name"
close_project
