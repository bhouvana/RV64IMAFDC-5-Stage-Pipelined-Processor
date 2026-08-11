# Vivado FPGA Synthesis/Implementation/Timing/Power Workflow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a reproducible, Tcl-driven AMD Vivado synthesis/implementation/timing/power workflow for this repo's RISC-V cores, backed entirely by real Vivado 2026.1 output (no fabricated numbers), and document the results in the README.

**Architecture:** Three whole-core Vivado projects (in-order `PIPELINED`, full out-of-order `OOOCore` which already includes Gen7 B+V+K unconditionally, and dual-core `HeteroSoC`), each built by a parameterized Tcl script against the same boardless target device, each carried through synth -> opt -> place -> phys_opt -> route -> reports. Vector (V) extension cost is read from `report_utilization -hierarchical` on the `OOOCore` build (named instances `m_VALU`/`m_VLSU`); B/K cost is documented as *not independently measurable* (shared, unguarded ALU case-statement logic -- confirmed by audit, will not be reverse-engineered by editing RTL).

**Tech Stack:** Vivado 2026.1 (batch-mode Tcl), located at `D:\2026.1\Vivado\bin\vivado.bat`, target part `xc7k325tffg900-2` (Kintex-7 325T, boardless/offline study -- confirmed installed via `get_parts`). Python + matplotlib for report-derived graphs (repo already uses Python for `sim/tools`, no new dependency). PowerShell for optional GUI screenshot capture.

## Global Constraints

- NEVER fabricate, estimate, or hand-type a Vivado number. Every figure in the README must trace to a checked-in `.rpt`/`.txt` file under `fpga/vivado/reports/`.
- Do NOT modify `design/*.v` architectural RTL to make Vivado happy or to produce cleaner comparison numbers. If something doesn't synthesize, document why.
- Do NOT commit Vivado build directories, `.jou`/`.log` files, caches, or any `.lic`/license material. `fpga/vivado/build/` is gitignored; only hand-picked reports/screenshots are committed.
- Three configs only: in-order (`PIPELINED`), full OoO (`OOOCore`, B+V+K unconditionally present), dual-core (`HeteroSoC`). No config isolates B or K alone -- say so explicitly wherever the README discusses them.
- Frequency sweep is bisection, not the full 5-point sweep: start at 100 MHz, step once based on pass/fail, stop once the pass/fail boundary for that config is located.
- Every failure (doesn't fit device, timing not met, synthesis error) gets documented, not hidden or retried into silence.
- Target part: `xc7k325tffg900-2` for all three configs (apples-to-apples comparison, confirmed available in this Vivado install).

---

## Task 1: Audit report

**Files:**
- Create: `fpga/vivado/AUDIT.md`

**Interfaces:**
- Produces: a written record of Phase 1 findings other tasks/README cite.

- [ ] **Step 1: Write the audit report**

Content (already gathered this session -- transcribe, don't re-derive):
- Top modules: `PIPELINED` (`design/riscvpipeline.v`, in-order 5-stage), `OOOCore` (`design/OOOCore.v`, 3052 lines, Gen6 OoO + Gen7 B/V/K all unconditional), `HeteroSoC` (`design/HeteroSoC.v`, 119 lines, instantiates both).
- 63 files under `design/`. Full file list (from `ls design/*.v`).
- Simulation-only constructs: every `$display`/`$finish` assertion in `design/*.v` is behind `` `ifdef ASSERT_ON `` (13 files) or `` `ifdef COVERAGE `` (`riscvpipeline.v`'s `dump_coverage` task) -- both undefined by default, so these blocks compile out of a normal synthesis run entirely. Confirmed via `grep -n` on every match plus its surrounding `` `ifdef``/`` `endif``. No unguarded `$finish`/`$dumpvars`/delay statements (`#N`) found in `design/*.v`.
- Memory init: `design/DataMemoryBRAM.v` and `design/InstructionMemory.v` use `$readmemh` against an `INIT_FILE` parameter -- standard, Vivado-synthesizable BRAM-init idiom, already used by the existing (unrun) `fpga/build.tcl`.
- B/K isolation finding: `grep -c "ifdef" design/OOOCore.v` = 0. AES/SHA/CLMUL (`ALUCTL_AES64*`, `ALUCTL_SHA256*`, `ALUCTL_CLMUL*`) and Zbb/Zbs bit-manip ops live as `case` arms inside the single shared `design/ALU.v`/`design/ALUCtrl.v`, feeding the one `m_ALU` instance also used for base-ISA integer ops. No separate module, no parameter, no guard -- can't cleanly A/B this extension without editing RTL, which we will not do.
- V isolation: Vector IS separable -- `design/VALU.v` and `design/VLSU.v` are distinct modules, instantiated once each as `m_VALU` (`OOOCore.v:2707`) and `m_VLSU` (`OOOCore.v:2829`), alongside their own reservation stations, vector `FreeList`/`RegisterAliasTable`/`PhysicalRegisterFile` instances (`m_FreeList_Vec`, `m_RAT_Vec`, `m_PRF_Vec`). `report_utilization -hierarchical` on the full `OOOCore` build attributes real LUT/FF/BRAM numbers to these instance names.
- Existing `fpga/` scaffolding (`top.v`, `build.tcl`, `constraints_template.xdc`, `README.md`) targets `PIPELINED` only, explicitly marked "unrun against a real Vivado install." This plan's new `fpga/vivado/` tree is separate and supersedes it for the in-order config too (reuses the device-neutral intent, not the old files, since this plan needs all three configs on one common flow). Leave `fpga/build.tcl`/`fpga/top.v` in place -- don't delete another phase's deliverable -- but `fpga/README.md` gets a pointer added to the new tree once results exist.
- Conclusion: RTL is synthesizable as-is for all three top modules; no architectural changes needed for Vivado compatibility.

- [ ] **Step 2: Commit**

```bash
git add fpga/vivado/AUDIT.md
git commit -m "docs: Vivado FPGA workflow Phase 1 audit report"
```

---

## Task 2: Directory scaffold + gitignore

**Files:**
- Create: `fpga/vivado/reports/.gitkeep`, `fpga/vivado/xdc/` (dir), `fpga/vivado/scripts/` (dir, for the Python grapher)
- Modify: `.gitignore`

**Interfaces:**
- Produces: `fpga/vivado/build/` as the sole Vivado working directory (gitignored), `fpga/vivado/reports/<config>/` as the sole checked-in report location.

- [ ] **Step 1: Add gitignore rules**

Append to `.gitignore` (create the file at repo root if it doesn't already exist -- check first with Read):

```gitignore
# Vivado (fpga/vivado/vivado-fpga-workflow, docs/superpowers/plans/2026-08-11-*)
fpga/vivado/build/
*.jou
*.log
*.str
.Xil/
vivado*.backup.jou
vivado*.backup.log
webtalk*.log
webtalk*.jou
*.lic
fpga/vivado/**/*.wdb
```

- [ ] **Step 2: Create dirs**

```bash
mkdir -p fpga/vivado/reports fpga/vivado/xdc fpga/vivado/scripts docs/images/vivado
touch fpga/vivado/reports/.gitkeep
```

- [ ] **Step 3: Commit**

```bash
git add .gitignore fpga/vivado/reports/.gitkeep
git commit -m "chore: scaffold fpga/vivado/ tree, gitignore Vivado build artifacts"
```

---

## Task 3: XDC constraints (one per config)

**Files:**
- Create: `fpga/vivado/xdc/constraints_inorder.xdc`
- Create: `fpga/vivado/xdc/constraints_ooo.xdc`
- Create: `fpga/vivado/xdc/constraints_soc.xdc`

**Interfaces:**
- Consumes: clock port name per top module (`clk` for `PIPELINED` and `OOOCore` -- confirm via `grep "input.*clk" design/riscvpipeline.v design/OOOCore.v design/HeteroSoC.v` before writing; do not guess).
- Produces: `CLK_PERIOD_NS` as a Tcl variable each XDC's matching create_project run overrides via `-tclargs`, so the same XDC text needs a placeholder period the Tcl layer regenerates at each frequency-sweep step (see Task 5). Simplest correct approach: the XDC hardcodes a period, and `run_implementation.tcl` overwrites it in-project with `create_clock -period ... -name clk [get_ports clk] -add` before each place/route re-run rather than re-reading the file -- avoids regenerating XDC files per frequency.

- [ ] **Step 1: Confirm clock/reset port names**

```bash
grep -n "module PIPELINED" -A 15 design/riscvpipeline.v
grep -n "module OOOCore" -A 15 design/OOOCore.v
grep -n "module HeteroSoC" -A 15 design/HeteroSoC.v
```

Use whatever the real port names are (expected `clk`, possibly `start` for reset) -- do not assume.

- [ ] **Step 2: Write `constraints_inorder.xdc`** (repeat pattern for the other two with their own clock port name if different)

```xdc
# Boardless offline implementation study -- no physical I/O exists to constrain.
# Only the internal processor fabric clock is constrained (docs/superpowers/plans/
# 2026-08-11-vivado-fpga-synthesis-workflow.md Phase 3). 100 MHz baseline: no prior
# Fmax data exists for this design, and 100 MHz is Vivado's own conventional FPGA
# starting point for an unconstrained-I/O internal-fabric study.
create_clock -period 10.000 -name clk [get_ports clk]

# No physical I/O -- top module output/input ports besides clk have no real
# package pin in a boardless study, so no set_property PACKAGE_PIN/IOSTANDARD
# is added here. Vivado will flag unconstrained I/O timing during
# report_timing_summary; document that under Phase 6, don't silence it.
```

- [ ] **Step 3: Commit**

```bash
git add fpga/vivado/xdc/
git commit -m "feat: boardless XDC clock constraints for Vivado FPGA workflow"
```

---

## Task 4: `create_project.tcl`

**Files:**
- Create: `fpga/vivado/create_project.tcl`

**Interfaces:**
- Consumes: `-tclargs <config> [part]` where `<config>` is one of `inorder`|`ooo`|`soc`.
- Produces: a Vivado project at `fpga/vivado/build/<config>/<config>.xpr`, with `sources_1` = every `design/*.v` file, `constrs_1` = the matching XDC, top module set correctly, `target_language`/`simulator_language` left at Vivado defaults (this project is plain Verilog-2005, no SystemVerilog constructs used -- confirm no `.sv` files exist: `find design -name "*.sv"` should be empty), synthesis/implementation run strategies left at Vivado defaults (Vivado Synthesis Defaults / Vivado Implementation Defaults -- no exotic strategy needed for a first honest baseline).

- [ ] **Step 1: Write the script**

```tcl
# fpga/vivado/create_project.tcl -- reproducible project generation for the
# Vivado FPGA synthesis/implementation/timing/power workflow
# (docs/superpowers/plans/2026-08-11-vivado-fpga-synthesis-workflow.md).
#
# Usage:
#   vivado -mode batch -source fpga/vivado/create_project.tcl -tclargs <config> [part]
# <config>: inorder | ooo | soc
# [part]:   Vivado part (default xc7k325tffg900-2, a Kintex-7 325T -- boardless
#           offline study, chosen for headroom over the OoO+vector core; see
#           fpga/vivado/AUDIT.md for why the smaller Arty-class parts already
#           used by fpga/build.tcl were not reused here).

if {[llength $argv] < 1} {
    puts "usage: vivado -mode batch -source fpga/vivado/create_project.tcl -tclargs <inorder|ooo|soc> \[part\]"
    exit 1
}
set config [lindex $argv 0]
set part_name [expr {[llength $argv] >= 2 ? [lindex $argv 1] : "xc7k325tffg900-2"}]

array set top_of   {inorder PIPELINED   ooo OOOCore   soc HeteroSoC}
array set xdc_of   {inorder constraints_inorder.xdc   ooo constraints_ooo.xdc   soc constraints_soc.xdc}

if {![info exists top_of($config)]} {
    puts "error: unknown config '$config' -- must be inorder, ooo, or soc"
    exit 1
}

set repo_root [file normalize [file dirname [info script]]/../..]
set build_dir $repo_root/fpga/vivado/build/$config
set proj_name $config

file mkdir $build_dir
create_project -force $proj_name $build_dir -part $part_name

add_files -norecurse [glob $repo_root/design/*.v]
add_files -fileset constrs_1 -norecurse $repo_root/fpga/vivado/xdc/$xdc_of($config)

set_property top $top_of($config) [current_fileset]
set_property target_language Verilog [current_project]
update_compile_order -fileset sources_1

puts "project created: $build_dir/$proj_name.xpr (top=$top_of($config), part=$part_name)"
close_project
```

- [ ] **Step 2: Run it for `inorder` and check for the success line, no GUI**

```bash
"/d/2026.1/Vivado/bin/vivado.bat" -mode batch -nolog -nojournal -source fpga/vivado/create_project.tcl -tclargs inorder
```

Expected: last real line before Vivado's exit banner is `project created: .../fpga/vivado/build/inorder/inorder.xpr (top=PIPELINED, part=xc7k325tffg900-2)`. If `add_files` errors (e.g. a genuinely non-synthesizable file), STOP -- update `fpga/vivado/AUDIT.md` with the real cause, don't silently drop the file.

- [ ] **Step 3: Commit**

```bash
git add fpga/vivado/create_project.tcl
git commit -m "feat: reproducible Vivado project-generation Tcl script"
```

---

## Task 5: `run_synthesis.tcl`, `run_implementation.tcl`, `run_reports.tcl`, `run_all.tcl`

**Files:**
- Create: `fpga/vivado/run_synthesis.tcl`
- Create: `fpga/vivado/run_implementation.tcl`
- Create: `fpga/vivado/run_reports.tcl`
- Create: `fpga/vivado/run_all.tcl`

**Interfaces:**
- Consumes: an already-created project (Task 4) at `fpga/vivado/build/<config>/<config>.xpr`, via `-tclargs <config> [clock_period_ns]`.
- Produces: `fpga/vivado/build/<config>/reports/synth_utilization.rpt`, `.../impl_utilization.rpt`, `.../impl_utilization_hierarchical.rpt`, `.../timing_summary.rpt`, `.../timing_critical_path.rpt`, `.../power.rpt`, `.../synth.log`-equivalent status. `run_reports.tcl` is callable standalone against an already-implemented run (`open_run impl_1`) so reports can be regenerated without re-routing.

- [ ] **Step 1: `run_synthesis.tcl`**

```tcl
# fpga/vivado/run_synthesis.tcl -- Phase 4 baseline synthesis.
# Usage: vivado -mode batch -source fpga/vivado/run_synthesis.tcl -tclargs <config>
if {[llength $argv] < 1} { puts "usage: -tclargs <inorder|ooo|soc>"; exit 1 }
set config [lindex $argv 0]
set repo_root [file normalize [file dirname [info script]]/../..]
set build_dir $repo_root/fpga/vivado/build/$config
open_project $build_dir/$config.xpr

reset_run synth_1
launch_runs synth_1 -jobs [get_param general.maxThreads]
wait_on_run synth_1

set status [get_property STATUS [get_runs synth_1]]
set progress [get_property PROGRESS [get_runs synth_1]]
puts "synth_1 status=$status progress=$progress"
if {$progress != "100%"} {
    puts "SYNTHESIS FAILED for $config -- see $build_dir/$config.runs/synth_1/runme.log"
    exit 1
}

open_run synth_1
file mkdir $build_dir/reports
report_utilization -file $build_dir/reports/synth_utilization.rpt
report_timing_summary -file $build_dir/reports/synth_timing_summary.rpt -max_paths 1
puts "SYNTHESIS OK for $config"
close_project
```

- [ ] **Step 2: `run_implementation.tcl`**

```tcl
# fpga/vivado/run_implementation.tcl -- Phase 5 implementation + Phase 6 timing
# at a given clock period (bisection sweep driver, Phase 6). Re-applies the
# clock constraint in-project instead of editing the XDC per frequency point.
# Usage: vivado -mode batch -source fpga/vivado/run_implementation.tcl -tclargs <config> <period_ns>
if {[llength $argv] < 2} { puts "usage: -tclargs <inorder|ooo|soc> <period_ns>"; exit 1 }
set config [lindex $argv 0]
set period [lindex $argv 1]
set repo_root [file normalize [file dirname [info script]]/../..]
set build_dir $repo_root/fpga/vivado/build/$config
open_project $build_dir/$config.xpr

# Re-target the clock period for this sweep point before re-running synthesis
# -- period changes require re-synth in Vivado (timing-driven synthesis reads
# the constraint), not just re-implementation.
set_property STEPS.SYNTH_DESIGN.ARGS.MORE\ OPTIONS {} [get_runs synth_1]
open_run synth_1 -quiet
close_project
open_project $build_dir/$config.xpr

# Overwrite the create_clock period via a scoped constraint set applied at
# synth time: simplest reliable approach is to edit the checked-in XDC's
# period only when this is the very first (100 MHz) run; subsequent sweep
# points use set_property on the existing clock constraint file object plus
# a full reset_run so both synth and impl re-run against the new period.
set xdc_file [get_files -of_objects [get_filesets constrs_1]]
set xdc_text [read [open $xdc_file r]]
set new_text [regsub {create_clock -period [0-9.]+} $xdc_text "create_clock -period $period"]
set fp [open $xdc_file w]
puts -nonewline $fp $new_text
close $fp

reset_run synth_1
launch_runs synth_1 -jobs [get_param general.maxThreads]
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
    puts "SYNTHESIS FAILED for $config @ ${period}ns -- see runme.log"
    exit 1
}

reset_run impl_1
launch_runs impl_1 -to_step route_design -jobs [get_param general.maxThreads]
wait_on_run impl_1

set status [get_property STATUS [get_runs impl_1]]
set progress [get_property PROGRESS [get_runs impl_1]]
puts "impl_1 status=$status progress=$progress period=${period}ns config=$config"
if {$progress != "100%"} {
    puts "IMPLEMENTATION FAILED for $config @ ${period}ns -- see $build_dir/$config.runs/impl_1/runme.log"
    exit 1
}
puts "IMPLEMENTATION OK for $config @ ${period}ns"
close_project
```

- [ ] **Step 3: `run_reports.tcl`**

```tcl
# fpga/vivado/run_reports.tcl -- Phase 5/6/7/8 report generation against an
# already-routed run. Usage:
#   vivado -mode batch -source fpga/vivado/run_reports.tcl -tclargs <config> <label>
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

# Machine-readable WNS/TNS/Fmax pull for the Python grapher (Phase 15) --
# report_timing_summary's own text is the authority; this is a convenience
# extraction of the same data already in that file, not a second source.
set wns [get_property STATS.WNS [get_runs impl_1]]
set tns [get_property STATS.TNS [get_runs impl_1]]
set whs [get_property STATS.WHS [get_runs impl_1]]
set fp [open $out_dir/summary.txt w]
puts $fp "config=$config"
puts $fp "label=$label"
puts $fp "wns_ns=$wns"
puts $fp "tns_ns=$tns"
puts $fp "whs_ns=$whs"
close $fp

puts "reports written: $out_dir"
close_project
```

- [ ] **Step 4: `run_all.tcl`** (single entry point for one config, one frequency label -- the bisection driver invokes this per sweep point rather than trying to encode the whole sweep in Tcl, since the sweep's step choice depends on reading each point's WNS)

```tcl
# fpga/vivado/run_all.tcl -- Phases 4-8 for one config at one clock period.
# Usage: vivado -mode batch -source fpga/vivado/run_all.tcl -tclargs <config> <period_ns> <label>
if {[llength $argv] < 3} { puts "usage: -tclargs <inorder|ooo|soc> <period_ns> <label>"; exit 1 }
set config [lindex $argv 0]
set period [lindex $argv 1]
set label [lindex $argv 2]
set script_dir [file dirname [info script]]
source $script_dir/run_implementation.tcl
source $script_dir/run_reports.tcl
```

(Note: `run_all.tcl` sources the other two rather than duplicating logic -- `argv` is shared across `source`d scripts in the same Vivado batch session, so each sourced script re-reads the same `$argv` Task 5 defined. `run_synthesis.tcl` is NOT sourced here since `run_implementation.tcl` already does its own synth+impl; `run_synthesis.tcl` stays as the standalone Phase-4-only entry point.)

- [ ] **Step 5: Dry run against `inorder` @ 100 MHz, verify every report file lands**

```bash
"/d/2026.1/Vivado/bin/vivado.bat" -mode batch -nolog -nojournal -source fpga/vivado/run_all.tcl -tclargs inorder 10.000 100mhz
ls fpga/vivado/reports/inorder/100mhz/
```

Expected: `impl_utilization.rpt impl_utilization_hierarchical.rpt timing_summary.rpt critical_path.rpt clock_utilization.rpt power.rpt summary.txt` all present and non-empty (`wc -l` each > 0). If `IMPLEMENTATION FAILED` prints, read the real `runme.log` and fix root cause before proceeding -- do not skip to reports.

- [ ] **Step 6: Commit**

```bash
git add fpga/vivado/run_synthesis.tcl fpga/vivado/run_implementation.tcl fpga/vivado/run_reports.tcl fpga/vivado/run_all.tcl fpga/vivado/reports/inorder/
git commit -m "feat: Vivado synthesis/implementation/report Tcl flow + first real inorder@100MHz run"
```

---

## Task 6: Bisection frequency sweep, all three configs

**Files:**
- Modify (generate, not hand-edit): `fpga/vivado/reports/<config>/<label>/*` for each sweep point actually run.
- Create: `fpga/vivado/reports/SWEEP_LOG.md` (human-readable record of which points were tried and why the sweep stopped where it did)

**Interfaces:**
- Consumes: Task 5's `run_all.tcl`.
- Produces: for each of `inorder`, `ooo`, `soc` -- a small set of real (period, WNS, met-or-not) data points bracketing that config's real Fmax.

- [ ] **Step 1: `inorder` @ 100 MHz (10.000 ns)** -- may already exist from Task 5 Step 5; if not, run it. Read `fpga/vivado/reports/inorder/100mhz/summary.txt`'s `wns_ns`. If WNS >= 0 (met), pick a higher period next (e.g. 150 MHz / 6.667ns); if WNS < 0 (not met), pick a lower one (e.g. 75 MHz / 13.333ns).

- [ ] **Step 2: `inorder` second point** based on Step 1's direction. Run:
```bash
"/d/2026.1/Vivado/bin/vivado.bat" -mode batch -nolog -nojournal -source fpga/vivado/run_all.tcl -tclargs inorder <period> <label>
```
Read the new WNS. If the two points now bracket the pass/fail boundary (one met, one not), that's the sweep result for `inorder` -- stop. If both met, try one more, higher; if both failed, try one more, lower. Cap at 4 points for this config.

- [ ] **Step 3: `ooo` @ 100 MHz (10.000 ns)** -- first create its project (Task 4 for `ooo` if not already done), then run Task 5's flow. Given the design's real size (ROB/RS/LSQ/vector unit/Sv39 MMU all present), do NOT assume 100 MHz passes -- read the actual WNS.

- [ ] **Step 4: `ooo` second (and if needed third/fourth, cap 4) point(s)**, same bisection logic as Step 2.

- [ ] **Step 5: `soc` (`HeteroSoC`)** -- create its project, run the same bisection, cap 4 points. If `HeteroSoC` fails to even synthesize (e.g. it wires both cores to the same memory arbiter in a way that doesn't close), document the real error in `SWEEP_LOG.md` and `fpga/vivado/AUDIT.md` rather than forcing it -- per the plan's Global Constraints, a failed config is a documented result, not a blocker to the other two.

- [ ] **Step 6: Write `fpga/vivado/reports/SWEEP_LOG.md`**

Table: `Config | Period (ns) | Target MHz | WNS (ns) | Met? | Notes`, one row per point actually run, plus one sentence per config stating the located pass/fail boundary (or "did not attempt higher/lower than X because Y" if capped before finding it).

- [ ] **Step 7: Commit**

```bash
git add fpga/vivado/reports/ fpga/vivado/build/ooo/*.xpr fpga/vivado/build/soc/*.xpr 2>/dev/null
git add fpga/vivado/reports/SWEEP_LOG.md
git commit -m "feat: bisected frequency sweep, all three Vivado configs (real WNS data)"
```

(Note: only reports and `.xpr`/source-controlled Vivado metadata are added -- `fpga/vivado/build/**/*.runs`, `*.cache`, `*.sim` etc. stay gitignored per Task 2.)

---

## Task 7: Component resource breakdown (Phase 7)

**Files:**
- Create: `fpga/vivado/reports/COMPONENT_BREAKDOWN.md`

**Interfaces:**
- Consumes: `fpga/vivado/reports/ooo/<passing_label>/impl_utilization_hierarchical.rpt` (the `ooo` config's report at whichever sweep point actually met timing, or its 100 MHz point if none did -- state which).

- [ ] **Step 1: Extract per-instance rows**

Open the hierarchical report, find rows for `m_VALU`, `m_VLSU`, `m_ROB`, `m_RS_ALU`, `m_RS_DIV`, `m_RS_FDIV`, `m_RS_FALU`, `m_LSQ`, `m_PRF`, `m_PRF_Float`, `m_PRF_Vec`, `m_FreeList*`, `m_RAT*`, `m_Tlb`, `m_Ptw`, `m_Bht`, `m_Btb`, `m_CSR`, `m_ALU`, `m_Divider`, `m_FDivider`, `m_DMem`, `m_IMem*`. Copy their real LUT/FF/BRAM/DSP columns and each row's `% of design` (Vivado computes this column itself in `-hierarchical` mode) verbatim into a markdown table.

- [ ] **Step 2: Write the B/K non-isolation caveat inline**

One paragraph, verbatim reusing `fpga/vivado/AUDIT.md`'s finding: `m_ALU`'s row includes B and K logic inseparably from base-ISA integer ops; its number is NOT "the cost of B+K", it's "the cost of the entire scalar ALU, all three extension families combined."

- [ ] **Step 3: Commit**

```bash
git add fpga/vivado/reports/COMPONENT_BREAKDOWN.md
git commit -m "docs: Vivado hierarchical utilization component breakdown (Phase 7)"
```

---

## Task 8: Python graph generation

**Files:**
- Create: `fpga/vivado/scripts/generate_graphs.py`
- Create (by running the script): `docs/images/vivado/fmax_by_config.png`, `docs/images/vivado/lut_by_config.png`, `docs/images/vivado/ff_by_config.png`, `docs/images/vivado/bram_dsp_by_config.png`, `docs/images/vivado/power_by_config.png`, `docs/images/vivado/timing_slack_by_config.png`, `docs/images/vivado/vector_extension_delta.png`

**Interfaces:**
- Consumes: `fpga/vivado/reports/<config>/<label>/summary.txt`, `impl_utilization.rpt`, `power.rpt` (parsed as text -- Vivado's `.rpt` format is fixed-width/labeled text, not JSON; write small regex/line-based parsers, not a generic report parser).
- Produces: PNG files under `docs/images/vivado/`, plus prints the exact numeric values it plotted to stdout (so the numbers are visible/checkable in the same run that produced the chart, not just baked into a PNG).

- [ ] **Step 1: Write the script**

Follow the `dataviz` skill for chart styling once invoked (load it before finalizing this script's plotting code). Structure:

```python
#!/usr/bin/env python3
"""Generate charts from real Vivado report data under fpga/vivado/reports/.
Never invents a number -- every value plotted is parsed from a checked-in
.rpt/summary.txt file and printed to stdout for cross-checking.
Usage: python fpga/vivado/scripts/generate_graphs.py
"""
import re
from pathlib import Path
import matplotlib.pyplot as plt

REPORTS = Path(__file__).resolve().parents[1] / "reports"
OUT = Path(__file__).resolve().parents[3] / "docs" / "images" / "vivado"
OUT.mkdir(parents=True, exist_ok=True)

def parse_summary(path):
    d = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    return d

def parse_utilization(path):
    """Pull Slice LUTs / Slice Registers / Block RAM Tile / DSPs 'Used' column
    from a Vivado report_utilization text report."""
    text = path.read_text()
    out = {}
    for key, pattern in {
        "luts": r"\|\s*Slice LUTs\s*\|\s*(\d+)",
        "ffs": r"\|\s*Slice Registers\s*\|\s*(\d+)",
        "bram": r"\|\s*Block RAM Tile\s*\|\s*([\d.]+)",
        "dsp": r"\|\s*DSPs\s*\|\s*(\d+)",
    }.items():
        m = re.search(pattern, text)
        out[key] = float(m.group(1)) if m else None
    return out

def parse_power(path):
    text = path.read_text()
    m = re.search(r"Total On-Chip Power \(W\)\s*\|\s*([\d.]+)", text)
    return float(m.group(1)) if m else None

# ... discover fpga/vivado/reports/*/*/summary.txt, build one row per
# (config, label), print every parsed value, then render the 7 charts listed
# in this task's Files section using matplotlib bar charts (see dataviz
# skill for palette/style once loaded). Skip any chart whose underlying data
# doesn't exist yet rather than plotting a placeholder.
```

Fill in the discovery/plotting body for real once Task 6/7's reports exist (this step can't be fully written before that data exists -- the parsing functions above are final, the `main()` that calls them gets finished during execution, not invented now).

- [ ] **Step 2: Run it, verify PNGs exist and stdout numbers match the source `.rpt` files by eye**

```bash
python fpga/vivado/scripts/generate_graphs.py
ls docs/images/vivado/*.png
```

- [ ] **Step 3: Commit**

```bash
git add fpga/vivado/scripts/generate_graphs.py docs/images/vivado/*.png
git commit -m "feat: generate FPGA result charts from real Vivado report data"
```

---

## Task 9: GUI screenshots

**Files:**
- Create: `fpga/vivado/scripts/gui_screenshot.ps1` (or manual capture, see Step 1)
- Create: `docs/images/vivado/vivado-synthesis-utilization.png`, `vivado-implementation-utilization.png`, `vivado-timing-summary.png`, `vivado-critical-path.png`, `vivado-power-report.png`, `vivado-hierarchy-utilization.png`, `vivado-device-summary.png`

**Interfaces:**
- Consumes: the `ooo` config's routed project (most visually interesting -- has the full device/hierarchy picture).

- [ ] **Step 1: Open the routed `ooo` project in the real Vivado GUI**

```powershell
& "D:\2026.1\Vivado\bin\vivado.exe" fpga/vivado/build/ooo/ooo.xpr
```
Run in background (`run_in_background: true`) -- this blocks until the GUI is closed. Wait ~30-60s for the GUI to fully load before attempting capture.

- [ ] **Step 2: Navigate to each report view, capture, verify by reading the PNG back**

For each of the 7 target screenshots: in the GUI, open the corresponding report (Open Implemented Design -> Report Utilization / Report Timing Summary / Report Power, plus the Device view for `vivado-device-summary.png` and a Schematic view if one is useful for the 10th "any useful schematic" item), then capture the active window with:
```powershell
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$b = New-Object System.Drawing.Bitmap ([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Width), ([System.Windows.Forms.Screen]::PrimaryScreen.Bounds.Height)
$g = [System.Drawing.Graphics]::FromImage($b)
$g.CopyFromScreen(0,0,0,0,$b.Size)
$b.Save("docs/images/vivado/<name>.png")
```
After each save, use the Read tool on the PNG to visually confirm it shows the intended report (Vivado version, project, device, report type, real values all visible) before moving to the next -- if a capture is blank/wrong, redo it rather than keeping a bad screenshot.

- [ ] **Step 3: Close the GUI, commit**

```bash
git add docs/images/vivado/*.png fpga/vivado/scripts/gui_screenshot.ps1
git commit -m "docs: real Vivado GUI screenshots (synthesis/implementation/timing/power/device)"
```

---

## Task 10: README + ADR + fpga/README.md pointer

**Files:**
- Modify: `README.md` (add `## FPGA Implementation & Vivado Analysis` section)
- Create: `docs/adr/0068-vivado-fpga-synthesis-workflow.md`
- Modify: `fpga/README.md` (add a pointer to `fpga/vivado/`, correct the "scaffolding only, unrun" framing now that real results exist for the NEW tree -- leave the OLD `fpga/build.tcl`/`top.v` framing alone, since those specific files are still genuinely unrun)

**Interfaces:**
- Consumes: every report/chart/screenshot from Tasks 1-9.

- [ ] **Step 1: Draft the README section**

Structure exactly as the spec's Phase 13/14 examples: pipeline diagram, results table (only rows for configs that actually built -- if `soc` failed per Task 6 Step 5, its row says so, doesn't get omitted silently), "Hardware Results" subsections (How large / How fast / critical path / OoO cost / Vector cost / B+K non-isolation caveat / memory subsystem cost using Task 7's table), links to `fpga/vivado/AUDIT.md`, `fpga/vivado/reports/`, `docs/images/vivado/`.

- [ ] **Step 2: Write the ADR** following this repo's existing `docs/adr/NNNN-*.md` convention (Problem / What shipped / Decision / real honest remaining backlog / Alternatives considered -- read 2-3 recent ADRs like `docs/adr/0067-pillar-k-crypto-gen7.md` first to match voice exactly).

- [ ] **Step 3: Update `fpga/README.md`**

Add one short section near the top: "A real, run Vivado workflow now exists for the in-order/OoO/SoC configs -- see `fpga/vivado/` and the README's own `## FPGA Implementation & Vivado Analysis` section. This directory's own `top.v`/`build.tcl`/`constraints_template.xdc` remain genuinely unrun (they target a physical board this environment still doesn't have); the boardless internal-fabric study lives in `fpga/vivado/` instead."

- [ ] **Step 4: Commit**

```bash
git add README.md docs/adr/0068-vivado-fpga-synthesis-workflow.md fpga/README.md
git commit -m "docs: FPGA Implementation & Vivado Analysis README section + ADR 0068"
```

---

## Task 11: Final verification pass

**Files:** none created -- verification only.

- [ ] **Step 1: Clean-state re-run of one config end to end**

```bash
rm -rf fpga/vivado/build/inorder
"/d/2026.1/Vivado/bin/vivado.bat" -mode batch -nolog -nojournal -source fpga/vivado/create_project.tcl -tclargs inorder
"/d/2026.1/Vivado/bin/vivado.bat" -mode batch -nolog -nojournal -source fpga/vivado/run_all.tcl -tclargs inorder 10.000 100mhz_verify
```

- [ ] **Step 2: Diff the fresh `summary.txt`/`impl_utilization.rpt` against the checked-in `fpga/vivado/reports/inorder/100mhz/` versions.** Numbers should match (implementation is deterministic given the same seed/tool version unless Vivado's placer has run-to-run variance -- if they differ, note the real delta in `SWEEP_LOG.md` rather than silently picking whichever run looks better).

- [ ] **Step 3: Grep the README for every numeric claim, confirm each traces to a file under `fpga/vivado/reports/` or `docs/images/vivado/`.** Fix or remove any that don't.

- [ ] **Step 4: `git status` -- confirm no `fpga/vivado/build/`, `.jou`, `.log`, `.lic` files staged.**

- [ ] **Step 5: Final summary to user** -- Vivado version, part, target clock(s), achieved Fmax per config, LUTs/FFs/BRAM/DSP per config, power estimate per config, WNS/TNS, which configs succeeded/failed and why, per the spec's "Final deliverables" list.

---

## Self-review notes (writing-plans skill step)

- Spec coverage: Phases 1-17 map to Tasks 1-11 (Phase 2/3 -> Tasks 2-4, Phase 4/5/6 -> Tasks 5-6, Phase 7 -> Task 7, Phase 8 folded into Task 5's `run_reports.tcl` + Task 8's chart, Phase 9/10 -> Task 6/7's config scope decision already locked in via `AskUserQuestion`, Phase 11 -> Task 9, Phase 12 -> Task 5, Phase 13/14 -> Task 10, Phase 15 -> Task 8, Phase 16 -> Global Constraints + every task's "document real failure" language, Phase 17 -> Task 11).
- No placeholders left except Task 8's `main()` body, which is explicitly and honestly deferred to execution time because it depends on data that doesn't exist until Task 6/7 run -- the parsing functions it will call are fully specified.
- Config scope (2 clean + hierarchy-for-V, HeteroSoC as a 3rd attempt, GUI+batch both, bisected sweep) matches the three `AskUserQuestion` answers exactly.
