# Frequency sweep log

Real Vivado 2026.1 batch results, `xc7k325tffg900-2`, out-of-context synthesis
(`fpga/vivado/create_project.tcl`; see that file's own comment for why OOC
mode -- boardless, no top-level I/O to place). Bisection strategy per
`docs/superpowers/plans/2026-08-11-vivado-fpga-synthesis-workflow.md`: start
at 100 MHz, step based on pass/fail, cap at 4 points per config. Every row
below is read directly from `fpga/vivado/reports/<config>/<label>/summary.txt`
(`STATS.WNS`/`STATS.TNS` off the routed `impl_1` run) -- nothing hand-typed.

| Config | Period (ns) | Target | WNS (ns) | TNS (ns) | Met? | Notes |
|---|---:|---:|---:|---:|:---:|---|
| inorder | 10.000 | 100 MHz | +3.984258 | 0.000000 | ✅ | first real point, comfortable margin |
| inorder | 6.667  | 150 MHz | +1.428120 | 0.000000 | ✅ | still meets |
| inorder | 5.000  | 200 MHz | +0.306298 | 0.000000 | ✅ | still meets, margin thin |
| inorder | 4.444  | 225 MHz | +0.518957 | 0.000000 | ✅ | 4-point cap reached, still meets |

**inorder (PIPELINED, RV32 in-order): did not locate the real Fmax boundary
within the 4-point cap.** All four attempted points (100/150/200/225 MHz)
met timing with positive WNS. The 225 MHz point's slack (+0.519ns) is
larger than 200 MHz's (+0.306ns) -- not a monotonic trend, which is
expected: each frequency point is an independent synth+place+route run, and
Vivado's heuristic placer/router can land on a different, non-comparable
local optimum per run, not a smooth curve. **Honest statement: this design's
real maximum frequency on this device is higher than 225 MHz; the exact
value was not determined**, since finding it would need more sweep points
than this plan's own cap allows. Given more budget, the next point to try
would be higher still (e.g. 250-300 MHz) to keep bisecting toward the real
failure boundary.

## ooo (OOOCore)

**Not completed.** `synth_design` hangs reproducibly partway through
elaboration -- confirmed independently twice (once overnight, ~7.5 hours,
CPU pegged, zero log progress; once the next morning after moving the
build directory off a nearly-full C: drive, ~35 min, same pattern). Disk
space, thread count, and synthesis strategy were each ruled out as the
cause (see `fpga/vivado/AUDIT.md`'s own addendum for the full diagnostic
trail). No WNS/TNS/utilization data exists for this config. Real,
documented failure, not silently dropped.

## soc (HeteroSoC)

**Not attempted.** `HeteroSoC` instantiates `OOOCore` internally, so it
would hit the identical elaboration hang; not worth burning more time
confirming the same failure a third time.
