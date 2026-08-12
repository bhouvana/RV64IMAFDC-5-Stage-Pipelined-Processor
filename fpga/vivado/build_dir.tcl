# fpga/vivado/build_dir.tcl -- single source of truth for where Vivado
# project/run working directories live. NOT under the repo (C: drive on the
# machine this was developed on filled to 376MB free overnight during the
# ooo/OOOCore run -- see docs/adr/0068's own disk-space note -- because
# Vivado's .runs/.cache/.gen churn for a design this size is multiple
# hundred MB to low GB per config, on top of whatever else was already using
# that drive). D: has 354GB free and already hosts this machine's Vivado
# install. fpga/vivado/reports/ (the small, checked-in .rpt/summary.txt
# files) is unaffected -- only the regenerable multi-GB build/run directory
# moved.
proc vivado_build_dir {config} {
    return D:/tmp_build/riscv-fpga-vivado/$config
}
