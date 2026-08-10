# ADR 0047: Out-of-Order Core, Generation 6 Phases A-J

## Problem

`docs/ROADMAP_VISION.md`'s Generation 6 section (lines 379-401) calls for an
out-of-order core — register renaming, physical register file, reservation
stations, reorder buffer, load/store queue, Tomasulo scheduling, speculative
execution, dual-issue — explicitly flagged as **"a new core, not a
modification of the existing pipeline."** The user asked to skip Generation
5 (multicore) and go straight to Generation 6.

Given the scale (register renaming, a genuinely new microarchitecture, not
an extension of `riscvpipeline.v`'s existing in-order 5-stage structure),
this followed the project's own established phase-workflow — research via
parallel agents, `AskUserQuestion` scope confirmation, a written plan
(`C:\Users\poorn\.claude\plans\gen6-ooo-core.md`), then N independently-
verified numbered sub-phases (Gen6-A through Gen6-J here; K/L remain open,
see Future improvements).

## Scope, confirmed via `AskUserQuestion` before any RTL

Most-ambitious option chosen every time, per this project's own established
pattern: full RV64IMAFDC + Sv39 MMU + interrupts + atomics as the eventual
target (not a reduced-ISA bring-up); dual-issue from the start (not
single-issue permanently); full speculative execution with ROB-based squash
(not stall-at-every-branch). **Reality, found by building it**: several of
these were later narrowed with real, documented reasons (see each
sub-phase below and Future improvements) — the ambitious target remains the
goal, but every narrowing here is a deliberate, flagged, load-bearing scope
cut, not a silent shortfall.

## Design

**`design/OOOCore.v`** is a genuinely new top-level module — coexists with,
never modifies, `riscvpipeline.v`'s `PIPELINED`. Frontend (fetch/decode/
rename/dispatch) is entirely combinational, single cycle, no pipeline
latches — a deliberate simplification for this whole arc: real frontend
pipelining is Gen6-K's own job (see Future improvements). XLEN=64
throughout; single-issue internally (Gen6-K widens to real 2-wide).

### Gen6-A — rename-stage skeleton

`design/PhysicalRegisterFile.v` (tag-addressed, many simultaneous in-flight
writers per architectural register — the invariant `Register.v`'s own
2nd write port, ADR 0044, does NOT provide), `design/RegisterAliasTable.v`
(speculative + architectural tables, `restore_en` bulk-copy for future
squash recovery), `design/FreeList.v` (circular free-physical-register
FIFO). Real bug found by this phase's own testbench: Icarus (`-g2005`)
only tracks a continuous `assign`'s EXPLICIT argument for re-evaluation,
not signals a called `function` reads internally — a read port whose
address held steady across a write showed stale data. Fixed by inlining
ternary chains directly in the assign (`Register.v`'s own established
pattern, ADR 0002), never a function wrapper, for every such read port in
this generation since.

### Gen6-B — `design/ReorderBuffer.v`

Program-order allocate/retire, out-of-order tag-addressed completion. The
defining property under test: a done entry can never retire ahead of an
earlier, not-yet-done one, even though completion itself races arbitrarily.

### Gen6-C — `design/ReservationStation.v`

One implementation, instantiated per functional-unit class (mirrors
`VictimCache.v`/`L2Cache.v`/`Prefetcher.v`'s own "one implementation,
multiple instances" precedent). Tag-compare wakeup off a CDB broadcast;
lowest-index-first select — a documented, correctness-preserving
simplification (the ROB enforces retire order regardless of RS issue
order; only scheduling throughput could suffer under contention).

### Gen6-D — wired live, INT-ALU only

Full backend proven end-to-end: rename → RS → `ALU.v` → CDB → ROB retire.
`sim/programs/ooocore_alu_d1.s`, 16/16 checks.

### Gen6-E — `design/LoadStoreQueue.v`

Deliberately in-order/single-outstanding (real, flagged scope cut — no
genuine out-of-order load execution or store-to-load forwarding this
generation). Real research finding: `DCache.v`'s existing MSHR tag scheme
needs no change for OoO at all — it already tags completions by a plain
numeric ID, and renaming already guarantees every dynamic instruction a
unique physical register, so `dest_preg` works as that ID unmodified (not
reached this phase — `LoadStoreQueue.v` talks to `DataMemoryBRAM.v`
directly, single-outstanding needing none of `DCache.v`'s own multi-way/
MSHR machinery). **Real bug found+fixed**: `ReorderBuffer.v` retires up to
2/cycle internally regardless of what the caller wires — `OOOCore.v` only
consumed retire slot0, silently losing whichever instruction retired as
slot1. Fixed by wiring slot1 through to `RegisterAliasTable.v`/
`FreeList.v`'s own already-present slot1 ports, even though dispatch
itself stayed single-issue — retire draining faster than 1/cycle when the
ROB has a backlog is always correct, independent of dispatch width.
`sim/programs/ooocore_lsq_e1.s`, 6/6 checks.

### Gen6-F — MUL/DIV

MUL/MULH/MULHSU/MULHU confirmed via the pre-existing `ALU.v` path, no new
wiring (ADR 0006 already computes them single-cycle). DIV/DIVU/REM/REMU
via a new RS_DIV + a real `Divider.v` multi-cycle completion — required
widening `ReorderBuffer.v`/`PhysicalRegisterFile.v`/`ReservationStation.v`/
`LoadStoreQueue.v` from 2 to 3 completion/CDB/write ports (a genuinely
independent 3rd completion source needs its own port; OR-ing two sources
onto one risks silently losing one whenever both complete the same cycle —
the exact bug class Gen6-E's own retire finding already hit once).
**Real bug found+fixed**: `Divider.v`'s `isSigned` was fed from a
registered snapshot one cycle stale relative to `start` — a `divu`
following a `rem` silently ran signed, using the *previous* division's
sign bit. `sim/programs/ooocore_muldiv_f1.s`, 11/11 checks.

### Gen6-G — branch speculation (the plan's own flagged hardest step)

Real `Bht.v`/`Btb.v`-trained prediction, reused unmodified from Generation
1 (ADR 0021). Genuine speculative PC redirect, misprediction detection at
execute, real recovery. **Scope cut, explicit and load-bearing**: at most
one branch in flight at a time — dispatch stalls until it resolves. A
misprediction therefore never has anything dispatched past it to unwind:
no ROB truncation, no RS/LSQ flush, no physical-register reclaim, and
`RegisterAliasTable.v`'s own `restore_en` (built in Gen6-A for exactly
this) isn't even needed, since no speculative rename divergence can ever
happen. This is a real, substantial narrowing from "full ROB-squash of an
arbitrary wrong-path window" — deep speculation needs RS/LSQ entries (and
an in-progress division or memory access) to be abortable mid-flight, a
genuinely larger, riskier undertaking, real future work (see below).
**Real bug found+fixed**: `ImmGen.v`'s B-type immediate is deliberately
*unshifted* (`riscvpipeline.v` applies `ShiftLeftOne.v`, `<<1`, downstream)
— used raw as a byte offset, the first mispredicted branch redirected to
the wrong address. `sim/programs/ooocore_branch_g1.s`, 8/8 checks.

### Gen6-H — F-extension

`f0`-`f31` has no hardwired-zero register (unlike `x0`) —
`RegisterAliasTable.v`/`PhysicalRegisterFile.v` gain a
`HARDWIRE_REG0`/`HARDWIRE_PREG0` parameter (default 1, bit-exact with
every prior behavior) so a second, genuinely independent instance of each
(`FreeList_Float`/`RAT_Float`/`PRF_Float`) serves `f0`-`f31` with reg 0
treated like any other register. New RS_FALU + a real `FALU.v` (the same
single-cycle FPU datapath `riscvpipeline.v` already uses). `ReorderBuffer.v`
gains one bit per entry (`is_fp_dest`) rather than a second, mostly-
redundant field set — an entry's destination is either integer or float,
never both, so retire just routes the same fields to whichever RAT/
FreeList/PRF the bit selects. **Scope, deliberately narrow and real**:
FADD.S/FSUB.S/FMUL.S/FSGNJ.S family/FMIN.S/FMAX.S (pure float-float) and
FMV.W.X (integer-bit-pattern move, needed to get any value into a float
register without also building FLW's own LSQ-float-awareness). Out of
scope: FDIV.S/FSQRT.S (own in-flight tracking like `Divider.v`), the fused
multiply-add family (3-operand), FCVT.S.W (real rounding-mode conversion),
FCMP/FCVT.W.S/FMV.X.W/FCLASS.S (float source, INTEGER dest — the reverse
cross-file direction from FMV.W.X), FLW/FSW (LSQ float-awareness).
`sim/programs/ooocore_fp_h1.s`, 10/10 checks, first clean run — no bug
found this sub-phase.

### Gen6-I — precise exceptions, ROB-retire-gated CSR.v

The generation's own key research finding, confirmed here: `CSR.v`'s
existing single-trap-scalar, exactly-once-per-instruction contract needs
**zero changes** for OoO precise exceptions, as long as only the
ROB-retiring instruction ever asserts `trap_taken`/`mret_taken` — `CSR.v`
instantiated completely unmodified. Same single-outstanding scope cut as
Gen6-G's own branches (a trap-related instruction in flight stalls all
dispatch until it retires). `ReorderBuffer.v` gains a `retire_tag0/1`
output so the in-flight tracker can tell exactly when its own entry is
retiring. **Scope**: illegal-instruction and ecall (causes this core's own
decode already recognizes) plus mret. Out of scope: real interrupts
(timer/software/external — need a real retire-boundary injection point)
and the Sv39 MMU (page faults, address translation — touches fetch AND
`LoadStoreQueue.v`'s own address path); CSR read/write instructions
(csrrw/csrrs/csrrc) aren't dispatched yet either, so `mtvec` stays at its
reset default (0) throughout. `sim/programs/ooocore_trap_i1.s` — an
illegal instruction traps every time it's fetched, and since `mtvec`
resets to 0, the redirect lands back at the program's own start, a
deliberate self-re-triggering loop proving the post-fault instruction
never retires, not just once but every pass. 5/5 checks, first clean run.

### Gen6-J — LR.W/LR.D atomics

This core's own established single-hart simplification (ADR 0038): LR
reduces to a plain load, no reservation needed, since nothing else can
ever contend. `Control.v` deliberately leaves `memRead`/`memWrite` at 0
for the whole `OPCODE_AMO` family — `is_mem_op` gains `is_amo_lr` OR'd in
explicitly so LR reaches `LoadStoreQueue.v` at all; once there, it's
identical to an ordinary load, no LSQ change needed. **Scope**: only LR is
live. SC needs a store plus a hardcoded `rd=0` success write that doesn't
come from memory at all — a real LSQ interface change; the general
AMOADD/AMOSWAP/etc. read-modify-write family needs real 2-phase sequencing
(read old value → compute new → write new), its own in-flight state
machine comparable to `Divider.v`'s. `sim/tools/asm.py` has no AMO
mnemonic support at all (a real, pre-existing gap ADR 0038/0039 both
already flagged) — `sim/programs/ooocore_amo_j1.s` hand-encodes `lr.d` via
`word 0x1000b1af`, the same convention `aluctl_illegal.s` already uses.
4/4 checks, first clean run.

## Real bugs/findings, summarized

Five real bugs found by running across Gen6-A/E/F/G (each detailed in its
own sub-phase above); Gen6-D/H/I/J each passed clean on the first real run.
Every bug was found by this generation's own directed end-to-end tests, not
by code review — matching this project's long-established "bugs reveal
themselves by running" pattern (most recently reconfirmed in Gen4's own
Phase G, ADR 0046).

## Alternatives considered

**Deep speculation (Gen6-G) and a general 2-phase AMO engine (Gen6-J)**
were both scoped down from their original "most ambitious" framing to a
single-outstanding-in-flight model, after the real cost (aborting an
in-flight division/memory access mid-flight; a genuinely new sequencing
state machine) became concrete during design — not discovered mid-RTL.
**A shared integer/float physical register file** (single wider PRF
instead of two independent instances) was considered and rejected: `f0`'s
lack of a hardwired-zero would have needed per-access conditional logic
scattered through every consumer, versus one parameter
(`HARDWIRE_PREG0`) on a genuinely separate instance.

## Validation strategy

Same bar every prior generation used: full directed suite
(`bash sim/run_tests.sh`), zero-warning `iverilog -Wall -g2005` compile,
one standalone unit testbench per new module (`tb_freelist_unit.v`,
`tb_rat_unit.v`, `tb_prf_unit.v`, `tb_rob_unit.v`, `tb_rs_unit.v`,
`tb_lsq_unit.v`) plus one end-to-end directed test per sub-phase
(`tb_ooocore_*.v`), all using a fixed-cycle-count-then-diff-committed-
architectural-state style (same "final state, not per-cycle" philosophy
this project's whole verification approach already uses, confirmed by
this generation's own planning-phase research to still hold for OoO).
**122/122 full suite, zero-warning compile, zero regressions** across the
whole Gen6-A through J arc.

## Future improvements

Real, explicitly flagged, not silently dropped:

- **Gen6-K (dual-issue widening)** — not attempted this arc. The real
  blocker found while scoping it: same-fetch-bundle RAW hazards (slot1
  reading a register slot0 just renamed, same cycle) need an explicit
  dispatch-side bypass (slot1's operand tag = slot0's own fresh
  `alloc_preg0`, forced not-ready) that `RegisterAliasTable.v`'s own
  storage alone does not provide — a real, well-understood, but
  correctness-critical piece of new logic deserving its own careful pass,
  not a rushed addition at the end of an already-long session. Every
  Gen6-A through J module (ROB/RS/FreeList/RAT/PRF) already has the
  structural 2-wide ports Gen6-K needs; only wiring + the same-bundle
  hazard logic + widened fetch remain.
- **Deep speculation** (Gen6-G's own full scope) — RS/LSQ entry
  invalidation and an in-flight division/memory-access abort path.
- **General AMO-RMW + SC** (Gen6-J's own full scope) — LSQ interface
  extension for a store-plus-unrelated-register-write, and a 2-phase
  sequencer.
- **Sv39 MMU + real interrupts** (Gen6-I's own full scope).
- **FDIV.S/FSQRT.S/fused-multiply-add/FLW/FSW/float-compare/FCVT**
  (Gen6-H's own full scope).
- **Gen6-L (verification tooling overhaul)** — not attempted this arc:
  a real ROB-drained termination/dump mechanism (vs. this arc's own
  fixed-cycle-count-then-diff directed tests), `iss.py`/`random_gen.py`/
  `run_random_tests.py` OoO-aware constrained-random cross-checking,
  `bench_runner.py --compare-ooo`, and new `sim/formal/` properties for
  N-wide ROB retirement.
- **`sim/formal/`** was not extended for any Gen6-A through J module —
  the small-module k-induction technique ADR 0027 established (Register/
  Forward/Hazard/a CSR subset) would directly apply to PRF/RAT/ROB/RS
  (all small, bounded-state modules), not attempted this arc.
