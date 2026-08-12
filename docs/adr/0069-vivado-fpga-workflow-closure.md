# ADR 0069: Vivado FPGA synthesis/implementation/timing/power workflow — closure

## Problem

Every generation of this project has been verified by simulation and formal methods, but never against
a real vendor synthesis toolchain (`fpga/README.md`'s own long-standing "scaffolding only... none of it
has been run against a real vendor toolchain" framing, `docs/adr/0012-fpga-readiness.md`). The user asked
for a complete, reproducible, Tcl-driven AMD Vivado workflow — synthesis, implementation, timing,
utilization, power — covering the in-order core, the Gen6 OoO core, and Gen7 B/V/K, with an explicit,
repeated, non-negotiable rule: every number traces to a real Vivado run, nothing fabricated, nothing
estimated and presented as measured.

Vivado 2026.1 turned out to be actually installed in this environment (`D:\2026.1\Vivado`, confirmed via
`vivado -version`, valid BASIC license through 2027-08-11) — unlike every prior FPGA-adjacent phase in
this project's history, this one could run for real, not just be written to compile cleanly.

## What shipped

**Phase 1 audit** (`fpga/vivado/AUDIT.md`): read all 63 `design/*.v` files against Vivado's synthesizable
subset before creating a project, not after. Found every simulation-only construct (`$display`/`$finish`)
correctly gated behind `` `ifdef ASSERT_ON ``/`` `ifdef COVERAGE ``, compiling out cleanly by default —
and found the one real, load-bearing limitation: B and K (Gen7 bit-manipulation and cryptography) share
the scalar `ALU.v`/`ALUCtrl.v` case-statement logic with no `` `ifdef `` guard anywhere in `OOOCore.v`,
making them structurally inseparable from base-ISA integer ops or from each other — confirmed by `grep`,
not assumed.

**Phases 2-6, reproducible Tcl flow** (`fpga/vivado/`): `create_project.tcl` (parameterized by config —
`inorder`/`ooo`/`soc` — and part, defaults to `xc7k325tffg900-2`, a Kintex-7 325T chosen for headroom
over the OoO+vector core and confirmed installed via `get_parts` before selection), `run_synthesis.tcl`,
`run_implementation.tcl` (bisection-sweep driver, rewrites the XDC's clock period in place per sweep
point), `run_reports.tcl`, `run_all.tcl`. Boardless XDC constraints (`fpga/vivado/xdc/`) — clock only, no
invented physical I/O.

**Three real, load-bearing RTL compatibility fixes found and fixed, all documented in `docs/adr/0068`**,
each user-approved before any file was touched, each verified by an identical `sim/run_tests.sh` 152/152
diff before/after: bare ports needing explicit `wire` under `` `default_nettype none `` (578 declarations,
48 files — Vivado's strict IEEE-1364 elaborator rejects what Icarus/Verilator silently default to `wire`),
a `genvar` used before its own declaration line in `DCache.v` (order-sensitive in Vivado, not in Icarus),
and `ALU.v`'s AES64* (Pillar K) case arms hardcoding 64-bit part-selects that are a static width violation
at XLEN=32 — fixed with always-64-bit zero-extended shadow wires, not a runtime guard (confirmed a plain
`if (XLEN==64)` does not avoid Vivado's elaboration-time part-select bounds check). Two infrastructure
fixes with no RTL impact: `-mode out_of_context` synthesis (a normal top-level run tried to place a real
I/O buffer for every debug/mailbox port including the clock and failed — "IO Clock Placer failed" — since
there's no board and no package pins to give them), and moving the Vivado build/run directory off the
repo's own C: drive to `D:/tmp_build/` after the C: drive filled to 376MB free overnight during a run.

**One real, complete, routed result: `PIPELINED` (in-order RV32)** on `xc7k325tffg900-2` — 4-point
bisected frequency sweep (100/150/200/225 MHz), all four met timing, re-run from a clean project state
reproduced identical WNS/TNS/WHS confirming determinism, 215 LUTs / 556 registers / 0 BRAM / 0 DSP
(0.11%/0.14% utilization), 0.166-0.178 W vectorless power estimate across the sweep. Real reports under
`fpga/vivado/reports/inorder/`, real charts generated from them by `fpga/vivado/scripts/generate_graphs.py`
under `docs/images/vivado/`.

**One real, documented, unresolved failure: `OOOCore` (Gen6 OoO + Gen7 B/V/K) synthesis hangs.** Not a
fabricated "it works" and not a silently-dropped scope item — confirmed independently twice: once
overnight (~7.5 hours, CPU pegged near 100% continuously, zero `runme.log` progress), once the next
morning (~35 minutes, same pattern) after ruling out disk space (moved the build dir to a drive with
354GB free — hang reproduced identically), thread count (reproduced at both `maxThreads` 2 and 4), and
synthesis strategy (reproduced at both the default and Vivado's `Flow_RuntimeOptimized`, its fastest
option). Working hypothesis at the time, not confirmed: the 512-bit vector unit and/or the wide crypto
ALU case-block triggering a known class of Vivado optimizer pathological-runtime behavior on very wide
combinational logic. **Retracted by `docs/adr/0070`'s follow-up investigation**: `VLEN=64` hangs
identically to `VLEN=512`, ruling out vector width directly; six hypotheses tested with real timeout data
and a verified RTL refactor found no fix. Root cause not further isolated — doing so would need either deep Vivado-internals debugging or a
throwaway RTL edit to bisect which sub-block triggers it, and the user's own call (presented directly via
`AskUserQuestion`, given 7+ hours already spent) was to stop retrying and close with this documented as a
real gap rather than keep spending session time chasing it. `HeteroSoC` was never attempted standalone
(it instantiates `OOOCore` internally and would hit the identical wall).

**Consequences that follow honestly from the `OOOCore` gap**, each stated plainly rather than worked
around: no Gen6/Gen7 utilization, timing, or power data exists (Phase 9's generation-comparison table and
Phase 10's extension-cost analysis are not populated with any `ooo`-derived numbers, real or otherwise —
`fpga/vivado/reports/COMPONENT_BREAKDOWN.md` states this directly). GUI screenshots (Phase 11) were
attempted via Vivado's batch-scriptable `show_schematic`/`write_schematic` commands (no mouse/keyboard
automation tool is available in this environment) — `write_schematic` returns success but produces no
file in pure batch mode, confirming it needs a live interactive rendering session that batch mode doesn't
provide; dropped rather than faked, real `.rpt` data and the 4 generated charts stand as the evidence
instead.

## Decision

**Close this phase now, with the `OOOCore`/`HeteroSoC` gap documented as real, unresolved future work** —
the lighter of this project's own two closure precedents (matching Gen2's compliance-suite closure,
`docs/adr/0029`, rather than Gen6's "finish the backlog first" precedent, `docs/adr/0058`) — the user's own
explicit choice this time, made directly via `AskUserQuestion` after seeing the real diagnostic trail, not
assumed.

The in-order core's Vivado results are real, reproducible, and traceable to checked-in reports at every
step. The `OOOCore` hang is a real, honestly-diagnosed-as-far-as-practical limitation, not a fabricated
result — exactly the standard the user's own spec demanded throughout: "if something fails, document the
failure and diagnose the real cause," not "make it look complete."

## Real, honest remaining backlog — not silently dropped

- **`OOOCore`/`HeteroSoC` synthesis hang, root cause not confirmed.** Bisecting further (does the vector
  unit alone trigger it? does the crypto ALU block alone? does a `RS_ALU_ENTRIES`/`ROB_ENTRIES` size
  reduction avoid it?) would need either a throwaway RTL edit (needs sign-off) or deeper Vivado-support
  engagement than fits this session.
- **No Gen6/Gen7 (OoO/B/V/K) hardware cost data of any kind** — utilization, timing, or power. This
  project's own simulation-based verification of these features (`docs/adr/0047`-`0067`) stands
  unaffected; only the *hardware-realization* evidence is missing.
- **B and K were never independently isolable even in principle**, regardless of whether `OOOCore` had
  synthesized — no `` `ifdef `` guard, shared `ALU.v` case-statement logic with base-ISA integer ops.
  Measuring either one's incremental cost would need an RTL restructuring this workflow deliberately did
  not do (`fpga/vivado/AUDIT.md`'s own finding, carried through consistently).
- **No GUI screenshots.** Batch-mode `write_schematic` doesn't render without a live interactive session;
  no mouse/keyboard automation tool exists in this environment to drive one. Real `.rpt` data and 4
  generated charts are the visual evidence instead.
- **`fpga/build.tcl`/`fpga/top.v`/`fpga/constraints_template.xdc`** (the pre-existing, separate,
  board-targeted scaffolding from `docs/adr/0012`) remain genuinely unrun — this ADR's own workflow is a
  boardless internal-fabric study using a different Tcl tree (`fpga/vivado/`), not a validation of that
  earlier board-bring-up path.

## Alternatives considered

- **Keep retrying `OOOCore` with more tuning knobs** (different strategies, thread counts, memory limits).
  Two independent confirmations already ruled out the three most likely infrastructure causes (disk,
  threads, strategy); a third blind retry without a new hypothesis was judged unlikely to pay off for the
  time cost, and the user agreed directly when asked.
- **Strip the vector unit and/or crypto logic from a throwaway `OOOCore` copy to bisect the hang.** Real
  diagnostic value, but is itself an RTL change requiring the same sign-off standard `docs/adr/0068`
  established for touching `design/*.v` — not pursued this session; a real, available next step if
  revisited.
- **Present the in-order-only result as if it represented the whole project's hardware cost.** Rejected
  outright — would misrepresent Gen6/Gen7 (the parts of this project's own scope statement most worth
  measuring) as validated when they aren't. The README says plainly, at the top of its own FPGA section,
  which config the numbers below it actually cover.
