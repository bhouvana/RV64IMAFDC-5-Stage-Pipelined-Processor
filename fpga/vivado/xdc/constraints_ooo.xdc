# Boardless offline implementation study -- no physical I/O exists to constrain.
# Only the internal processor fabric clock is constrained (see
# docs/superpowers/plans/2026-08-11-vivado-fpga-synthesis-workflow.md Phase 3
# and fpga/vivado/AUDIT.md). 100 MHz baseline: no prior Fmax data existed for
# this design when this file was written, and 100 MHz is a conventional FPGA
# starting point for an unconstrained-I/O internal-fabric study.
#
# This period is rewritten in-place by fpga/vivado/run_implementation.tcl for
# each frequency-sweep point -- the checked-in value below reflects whatever
# the most recent run used, not necessarily 100 MHz; see
# fpga/vivado/reports/SWEEP_LOG.md for the real sequence of values tried.
create_clock -period 10.000 -name clk [get_ports clk]

# Target: OOOCore (design/OOOCore.v). No PACKAGE_PIN/IOSTANDARD constraints
# are added for any other port (rst, mailbox_*, msip_pending/timer_pending/
# ext_pending) -- there is no real board/package pin to assign in a boardless
# study. Vivado will report these as unconstrained I/O timing; that is
# expected and is documented in fpga/vivado/reports/, not silenced.
