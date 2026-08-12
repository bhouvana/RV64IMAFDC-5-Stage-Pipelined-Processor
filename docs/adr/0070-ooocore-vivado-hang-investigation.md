# ADR 0070: `OOOCore` Vivado synthesis hang — root-cause investigation (unresolved)

## Problem

`docs/adr/0069` closed the Vivado FPGA workflow phase with `OOOCore` (Gen6 OoO + Gen7 B/V/K)
undiagnosed beyond "hangs reproducibly, disk/threads/strategy ruled out." The user explicitly asked for
real root-cause work instead: hierarchy isolation, module-level synthesis, controlled parameter
reductions, and — if a synthesis-friendly refactor can fix it without changing architecture — implement
and verify it. This ADR is that investigation's real record, including its real, honest outcome: **the
triggering construct was not conclusively isolated**, and no refactor attempted resolved the hang. That
is reported here in full rather than dressed up as a fix.

## Method

Two new pieces of reproducible tooling, both under `fpga/vivado/scripts/`:

- **`diag_module_synth.tcl`** — synthesizes exactly one named module standalone (real parameters,
  `-mode out_of_context`, same part), for isolating a single sub-block's own synthesis cost independent
  of everything else in `OOOCore.v`.
- **`run_diag_timeout.ps1` / `run_generic_timeout.ps1`** — PowerShell wrappers that hard-kill the Vivado
  process tree after a fixed wall-clock budget, so every experiment below has a real, bounded time cost
  instead of risking another open-ended hang. This is what made systematic bisection practical at all.

Plus three throwaway diagnostic Tcl scripts for whole-`OOOCore` experiments
(`diag_ooo_flatten_none.tcl`, `diag_ooo_vlen.tcl`, `diag_ooo_no_sharing.tcl`, `diag_ooo_plain.tcl`),
kept under `fpga/vivado/scripts/` for reproducibility even though none of them resolved the hang.

## Investigation timeline — every real result

### Standalone module isolation (Phase 1: is any ONE sub-block disproportionately expensive?)

| Module | Real parameters | Result | Cells | Time |
|---|---|---|---:|---:|
| `VALU` | `VLEN=512` (default, matches `m_VALU`) | Clean, 0 errors | 5,052 | 1m29s |
| `VLSU` | `VLEN=512, XLEN=64` (default, matches `m_VLSU`) | Clean, 0 errors | 3,278 | 52s |
| `PhysicalRegisterFile` | `XLEN=512, NUM_PREGS=64, HARDWIRE_PREG0=0` (matches `m_PRF_Vec`) | Clean, 0 errors — but disproportionately huge | **306,091** | 10m53s |

`PhysicalRegisterFile` at the vector instance's real parameters is 60-100x larger than `VALU`/`VLSU`
despite being "just" a register file — real RTL Component Statistics from this run: **13 read ports ×
512 bits wide, 167 separate 2-input 512-bit muxes, 64 × 512-bit registers**. This module
(`design/PhysicalRegisterFile.v`) grew organically from 4 read ports (Gen6-A) to 13 (Gen7 Pillar V
Phase 3) without ever being restructured for the new scale — a real, honest finding on its own, whether
or not it turns out to be the hang's trigger. **Important: this test proves the module is disproportionately
large, not that it's the hang** — 11 minutes standalone is slow but finite, nothing like the multi-hour
whole-design hang.

### Whole-`OOOCore` experiments (Phase 2: does any single lever avoid the hang?)

Every one of the following hangs at the **identical point**: right after
`INFO: [Synth 8-802] inferred FSM for state register 'state_reg' in module 'Ptw39'`, during the second
(post-elaboration, RTL-optimization) synthesis pass — note this is *after* the first pass's own
module-by-module walk, which (confirmed via the `-flatten_hierarchy none` run's full log) completes
successfully for every single module in `OOOCore.v`, `PhysicalRegisterFile` (all three parameterizations)
included. The hang is not in per-module elaboration; it is in whatever Vivado does next.

| Experiment | Change | Result |
|---|---|---|
| Original (`docs/adr/0069`) | Default `maxThreads=2`, default strategy, build dir on (then-nearly-full) C: | Hung **7.5 hours**, zero log progress, confirmed real CPU (not I/O-blocked) |
| Disk relocation | Build dir moved to D: (354GB free) | Hung again, **~35 min** confirmed reproduction, same point |
| `-flatten_hierarchy none` | Skip whole-hierarchy flattening before cross-boundary optimization | Hung, 30min hard timeout, same point |
| `VLEN=64` (vs 512) | 8x narrower vector datapath, `-generic` override, same architecture | Hung, 30min hard timeout, **same point** — conclusively rules out vector *width* as the trigger |
| `-resource_sharing off` | Disable Vivado's cross-port shareable-logic search | Hung, 30min hard timeout, same point, **higher peak memory** (12.3GB vs ~9-10GB baseline) |
| `PhysicalRegisterFile.v` storage replication (see below) | 13 independent register-array copies instead of 1 shared array, one per read port | Hung, 30min hard timeout, same point, similarly high memory |

Peak process memory across these runs: 8.6-12.3GB (system has 31.8GB, 8.1GB free when checked mid-run) —
not memory-exhaustion/thrashing; the stuck process accumulates real CPU time continuously (confirmed
1333s+ CPU time on a single `vivado.exe` while `Responding: True`), consistent with genuine sustained
computation, not an I/O-blocked or swap-thrashing stall.

### The one RTL refactor actually implemented and verified (then reverted — no measurable benefit)

`PhysicalRegisterFile.v`'s 13 read ports all combinationally index the *same* `regs[]` array
(`assign rdataN = <write-bypass priority chain> : regs[raddrN]`), each with its own priority-encoded
write-bypass logic against all 3 write ports. Working theory: Vivado's synthesis optimizer has to jointly
reason about all 13 ports sharing one array, and that joint analysis — not the array's raw size — is
what's expensive.

**Fix attempted**: replicate `regs[]` into 13 independent, identically-written copies (`regs0`..`regs12`),
one dedicated per read port — the standard, well-established technique real multi-read-port register
files use in silicon to avoid N-way port-sharing analysis. Implementation:

```verilog
reg [XLEN-1:0] regs0  [0:NUM_PREGS-1];
...
reg [XLEN-1:0] regs12 [0:NUM_PREGS-1];
// every write port writes ALL 13 copies identically, every cycle
// every read port reads ONLY its own dedicated copy
```

**Behaviorally verified as a pure implementation change, not an architecture change**: every copy is
written identically every cycle by the same 3 write ports, so every reader sees exactly the value it
would have read from one shared array — same values, same cycle, same timing.
`sim/run_tests.sh`: **152/152, identical to baseline.** `make random-test ARGS="--count 100 --ooo"`:
**100/100, matched the independent ISS reference model.** (30 testbench files needed their own fix
alongside this — several use a simulation-only hierarchical backdoor, `dut.m_PRF.regs[preg]`, to peek
register values directly for verification, bypassing the module's own read ports entirely; these were
mechanically repointed at `regs0`, always identical to every other copy.)

**Result: no measurable effect, at any scale tested.** RTL Component Statistics for the standalone
`PhysicalRegisterFile` test were byte-for-byte identical before and after (167 muxes, 64×512-bit
registers) — the replicated version needs exactly as many 64:1-mux-equivalents as the shared version,
because each read was *already* logically independent even sharing one array (13 independent `regs[raddrN]`
expressions is not fewer or simpler muxing than 13 independent `regsN[raddrN]` expressions — replicating
storage does not reduce read-side mux count, only whether that muxing shares a physical array).
Full-`OOOCore` synthesis with this fix in place: same hang, same point, same timescale. **Reverted** —
`git checkout -- design/PhysicalRegisterFile.v sim/tb/*.v` — since it adds real cost (13x storage,
touches 30 files) with zero demonstrated benefit, and this project's own standard is to keep RTL changes
that earn their keep, not ones that merely seem plausible.

## What this investigation actually establishes

1. **Not disk space, not thread count, not synthesis strategy** (`docs/adr/0069`'s own findings, held).
2. **Not vector-register width** — VLEN=64 hangs identically to VLEN=512, a result that directly
   contradicts the standing "512-bit vector unit" hypothesis from `docs/adr/0069`. That hypothesis is
   retracted by this ADR.
3. **Not `PhysicalRegisterFile`'s multi-port read structure in isolation** — the module synthesizes
   (slowly, ~11 min, but successfully) completely on its own, and restructuring its storage changed
   nothing about the whole-design hang.
4. **Not resource-sharing search** (a real, documented Vivado synthesis-time cost mechanism, ruled out
   directly).
5. **The hang is specifically in Vivado's second (post-elaboration) synthesis pass**, triggered at a
   consistent point immediately downstream of `Ptw39`'s per-module processing, in every single
   configuration tried. The first pass — real per-module RTL elaboration/synthesis for all ~25 instances
   in `OOOCore.v`, `PhysicalRegisterFile` (all 3 parameterizations) included — completes successfully
   every time, confirmed directly from the `-flatten_hierarchy none` run's full log
   (`done synthesizing module 'OOOCore'` appears, followed by real, further optimization-phase log lines,
   before the hang).
6. **Not memory exhaustion or thrashing** — confirmed via direct process/OS memory inspection mid-hang;
   the process is genuinely CPU-bound, not I/O-stalled.

**What remains a real, untested next step**: fully stubbing out the vector-unit sub-hierarchy
(`m_VALU`, `m_VLSU`, `m_PRF_Vec`, `m_RAT_Vec`, `m_FreeList_Vec`, `m_RS_VALU`, `m_RS_VLSU`) from a
throwaway `OOOCore.v` copy, to test *presence* of the vector subsystem (as opposed to its *width*,
already ruled out) as the trigger. Not attempted this session — the vector unit's wiring is deeply
integrated (cross-file port sharing between `RS_VALU`/`RS_VLSU` on `PhysicalRegisterFile` ports 11/12,
dispatch-mux exclusion logic, mask-forwarding paths across `Control.v`/`ALUCtrl.v`), and a rushed stub
risks introducing a *different*, uninformative synthesis error rather than a clean signal. Doing this
correctly needs more session time than remained available; flagged here as the concrete next diagnostic
step rather than dropped silently.

## Decision

**Close this investigation without a resolution**, per the same integrity standard the rest of this
project's Vivado work holds itself to: a real, thorough, honestly-reported bisection trail — six
independent hypotheses tested with real timeout data, one real RTL refactor implemented and rigorously
verified before being found ineffective and reverted — is the deliverable, not a fabricated fix.
`docs/adr/0069`'s own working hypothesis (vector width) is retracted here with real evidence; no
replacement hypothesis has been confirmed. `OOOCore`/`HeteroSoC` remain outside this project's real
Vivado results, exactly as `docs/adr/0069` already stated, now for reasons this ADR has actually
investigated rather than merely asserted.

## Real, honest remaining backlog

- **Vector-subsystem stub-out experiment** (above) — the concrete, well-scoped next step, not attempted
  this session due to time and risk-of-confounding-error.
- **Whatever comes immediately after `Ptw39` in Vivado's second-pass processing order** was never
  directly identified (Vivado's log doesn't print per-module progress in that pass the way it does in
  the first). Isolating that specific module/interaction (rather than testing broad design-wide levers)
  is a real, different next avenue.
- **Xilinx support engagement** — six ruled-out hypotheses plus a confirmed-CPU-bound (not I/O-stalled)
  hang at a specific, reproducible point is exactly the evidence a real Xilinx support case would need;
  not pursued here (no support contract confirmed available in this environment).

## Alternatives considered

- **Keep the storage-replication fix even though it didn't resolve the hang**, on the theory it's
  "probably still a reasonable hardening." Rejected — it has a real area cost (13x one register file's
  storage) and touches 30 testbench files, with zero demonstrated benefit toward the actual goal. Keeping
  unproven-beneficial RTL changes around is exactly the kind of complexity this project's own standards
  (and the user's own repeated instructions this session) push back against.
- **Attempt the vector-subsystem stub-out anyway, accepting the risk of a confounding error.** Considered
  and deferred, not abandoned — flagged explicitly above as the real next step, given remaining session
  time constraints made doing it carefully (rather than rushed) impractical.
- **Report "fixed" based on the standalone module test's success.** Would have been dishonest — the
  standalone module always finished (slowly) even before any fix; it was never actually reproducing the
  real hang, a fact only established by testing the fix in the full-design context too, which is the
  entire reason that second round of testing happened rather than stopping at the isolated-module result.
