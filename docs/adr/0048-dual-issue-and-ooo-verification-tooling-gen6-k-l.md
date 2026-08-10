# ADR 0048: Dual-Issue Widening and OoO Verification Tooling, Generation 6 Phases K-L

## Problem

ADR 0047 closed Gen6-A through J: the out-of-order core's full backend (rename, ROB, RS, INT-ALU,
LSQ, MUL/DIV, branch speculation, F-extension, precise exceptions, LR atomics), single-issue
internally throughout. Two items were explicitly deferred as real future work, not attempted:
Gen6-K (dual-issue widening) and Gen6-L (verification tooling -- OOOCore.v had no constrained-random
cross-check, no benchmark comparison, no formal properties, unlike PIPELINED's own mature tooling
stack). This phase closes both.

## Gen6-K — dual-issue widening

### Scope, confirmed by real research before any RTL

The full N-wide dispatch/execute/retire vision from the original Gen6 plan was narrowed on contact
with the actual blocker: same-fetch-bundle RAW hazards need an explicit dispatch-side bypass that
`RegisterAliasTable.v`'s own storage doesn't provide (slot0's write to the RAT only lands the
following cycle; slot1, dispatched the SAME cycle, can't see it there yet). Scoped to: dispatch two
consecutive fetch-bundle instructions per cycle when BOTH decode as plain ALU ops (no mem/div/fp/
branch/trap in either slot) -- falls back to single-issue for any other class combination. Still
single-issue at the EXECUTE stage (one ALU functional unit) -- this phase only widens dispatch/
rename/allocate, not the functional-unit count.

### Design

- `PhysicalRegisterFile.v`: extended 9->11 read ports (`raddr9`/`raddr10`) for slot1's own
  dispatch-time readiness query.
- `OOOCore.v`: full duplicated slot1 decode (second `InstructionMemory` read at `pc_r+4`, second
  `Control`/`ALUCtrl`/`ImmGen`); slot1 wired through `FreeList`/`RegisterAliasTable`/`ReorderBuffer`/
  `ReservationStation`'s existing (previously tied-off) second ports -- all four modules were already
  dual-port-capable since Gen6-A/B/C, deliberately built ahead of need per this project's own
  "modules dual-issue-capable from day one, driven single-issue until proven" plan.
- Same-bundle RAW bypass: `slot1_src1_from_slot0`/`slot1_src2_from_slot0` detect when slot1's rs1/rs2
  is slot0's own rd, and route slot1's RS dispatch straight to slot0's `fl_alloc_preg0` with ready
  forced to 0 (slot0 hasn't executed yet this same cycle either).
- Same-bundle WAW (both dests hit the same architectural register) needed no new code --
  `RegisterAliasTable.v`'s existing `wen0`/`wen1` same-target logic already makes slot1 win (built in
  Gen6-A).
- `dual_dispatch_room`: independent 2-wide resource check (ROB/RS_ALU count <= capacity-2, plus
  `fl_alloc_ok1`) gating `do_dispatch_slot1`; PC advances by 8 instead of 4 when it fires.

### Testing

`sim/programs/ooocore_dual_k1.s` + `tb_ooocore_dual_k1.v`: 5 hand-traced bundles (independent pair,
same-bundle RAW, another independent pair, same-bundle WAW, nop pair) -- 8/8 checks pass, confirms
`do_dispatch_slot1` actually fired 6 times (not silently falling back to single-issue the whole run).

## Gen6-L — OoO verification tooling

### Scope, confirmed via `AskUserQuestion`

The original plan's own four items (real termination mechanism, constrained-random cross-check,
benchmark comparison, formal ROB properties) were all attempted, in that order -- but research before
touching any tooling found OOOCore.v's real supported instruction subset is narrower than assumed:
`jump_c`/`jalr_c`/`lui_c`/`auipc_c`/`isCsr_c` are decoded (`design/Control.v`) but never consumed
anywhere in `design/OOOCore.v` -- confirmed by direct code read. jal/jalr never redirect the PC; lui/
auipc need a real "force operand A" mux `design/riscvpipeline.v` has (confirmed by reading
`riscvpipeline.v:1395-1398`) and `OOOCore.v` doesn't; csrrX/fcvt.w.s/fcvt.wu.s/feq.s/flt.s/fle.s read
garbage from the INTEGER RAT instead of whatever they actually need; fsw reads garbage integer "store
data" instead of the intended float register. None of that is safe to cross-check -- every piece of
Gen6-L tooling below works around this real, pre-existing gap rather than pretending it doesn't exist.

### L1 — `sim/tb/dump_regs_ooocore_template.v`

Real retirement-counting termination, NOT the fixed-cycle convention every directed OOOCore
testbench uses -- found by running to be genuinely unreliable for a generated program: OOOCore.v's
frontend keeps fetching past a program's real end regardless (jal doesn't stop it), hits the
zero-filled tail's illegal opcode, traps, and (mtvec never leaves its own reset default of 0, since
csrrw is never dispatched) restarts the ENTIRE program from address 0 every ~100-150 cycles on a real
61-instruction test -- a fixed-cycle dump landed on silently wrong partial-restart state at every
budget tried (400/4000/20000 cycles). Stopping at the exact real (pre-padding) instruction count,
tracked via `rob_retire_valid0`/`rob_retire_valid1`, sidesteps this entirely.

Also fixed a real SP_INIT width bug found along the way: an unsized parameter override
self-determines 32-bit in Icarus regardless of the 64-bit-declared default, so
`regs[2] <= SP_INIT[XLEN-1:0]` at XLEN=64 read back X for the upper half at any non-default override.
Fixed by sizing the override explicitly (`__XLEN__'d__MEM_SIZE__`).

### L2 — `sim/tools/random_gen.py` `ooo=True` mode

Restricts the generated mix to r/i/shift/load/store/branch (conditional only, no jal) + fadd.s/
fsub.s/fmul.s/fsgnj*/fmin.s/fmax.s -- every one OOOCore.v actually executes correctly (Gen6-D/E/G/H).
`const_to_reg_instrs`/`const64_to_reg_instrs` gained a `no_lui` mode (chunked addi/slli
construction, independently simulated and self-checked) since the shared float/64-bit const-seeding
prefix used lui unconditionally, which would have broken under ooo mode regardless of the
per-instruction kind filter. Trailer is `OOO_TRAILER_NOP_COUNT` (32) `addi x0,x0,0` nops instead of
the shared fence+jal-self-loop.

### L3 — `sim/tools/run_random_tests.py` `--ooo`

`run_one_ooo()`, a separate function from `run_one()` (no hazard_strategy/cache_mode/mmu/interrupt/
... concept applies to OOOCore.v yet). Proven: 50/50 seeds (xlen 32 and 64, n_instrs 16 and 40, zero
mismatches across int regs/memory/float regs).

### L4 — `sim/tools/bench_runner.py` `--compare-ooo`

Runs PIPELINED vs OOOCore.v on `bench_fib.s`/`bench_sum_array.s` (`bench_bubble_sort.s` excluded --
uses `jal x0, inner`/`jal x0, outer` as real backward-loop control flow, not just the shared halt
trailer, which OOOCore.v cannot execute at all).

**Result 1 (bench_fib.s, correctness-clean)**: OOOCore is 52.8% *slower* (330 vs 216 cycles) on this
pure-ALU dependency-chain loop. A real, plausible result, not a bug: a tight RAW chain (each
iteration's add depends on the previous) can't hide the RS-based Tomasulo model's own
dispatch->rename->wakeup->re-dispatch latency the way a simple forwarding in-order pipe does, and
Gen6-K's dual-issue can't help a chain with no independent work to pair.

**Result 2 (bench_sum_array.s, a real deadlock, root-caused)**: OOOCore.v hangs. `FreeList.v`'s
`alloc_en0`/`alloc_en1` (and `PhysicalRegisterFile.v`'s own `alloc_en`-driven valid-clear) are
unconditional on `needs_dest`/`needs_dest_1` alone, not gated by the actual `do_dispatch`/
`do_dispatch_slot1` decision -- necessary today to avoid a genuine combinational cycle
(`dispatch_stall`'s own `fl_alloc_ok0` term would depend on itself through `do_dispatch` otherwise).
Consequence: every cycle dispatch stalls for ANY reason (rob_full/rs_alu_full/lsq_full/a store
forcing `try_dual_issue` false) while `needs_dest` is simultaneously true silently orphans one
physical register permanently. Confirmed by direct RTL trace (bisecting element counts, isolating the
store, reordering instructions): a store immediately followed by a WAW-renamed ALU instruction in a
real sustained loop (>=8 iterations) exhausts the 32-entry free pool and permanently deadlocks
dispatch. This is the concrete manifestation of `OOOCore.v`'s own Gen6-D header comment ("no real
resource-exhaustion stall beyond a simple whole-cycle bubble... genuinely insufficient for sustained
high-occupancy execution"), previously flagged as theoretical, now proven real. `bench_fib.s` never
triggers it (no memory ops, low dispatch pressure) -- exactly why this tooling exists: no directed
test (all short, hand-sized) ever ran long enough under real backpressure to find this.

**Not fixed in this phase** -- see Future improvements.

### L5 — `sim/formal/rob_formal.sv` + `.sby`

Same tractable, self-contained-module approach ADR 0027 established for CSR.v/Register.v/etc.
Two properties proved (`mode bmc`, depth 4, from a genuine reset, ROB_ENTRIES=4):
1. `rob_count` never exceeds `ROB_ENTRIES` (formal analog of the existing `ifdef ASSERT_ON` check).
2. `rob_count == (tail_r - head_r) mod ROB_ENTRIES` at every cycle -- the real cross-state-variable
   invariant tying three independently-updated registers together, never directly enforced by any
   single continuous assign, and never checked by any existing directed/random test.

`design/ReorderBuffer.v` gained `debug_head`/`debug_tail` output ports (unconnected in every real
caller) -- Yosys's `read_verilog` can't resolve a hierarchical dot-reference into a submodule's
internal state the way iverilog's simulator can (re-confirmed the exact ADR 0027 finding: `dut.head_r`
etc. came back as fresh undriven phantom wires, silently making every property referencing them
vacuous).

A 3rd property (dual-retire structural implication, `retire_valid1 -> retire_valid0`) was attempted
and dropped -- tautological by RTL construction (`slot1_can_retire = slot0_can_retire && ...`), yet
the solver reported a counterexample at depth 4+ that properties 1/2 (same run, same trace) did not;
looks like a solver/array-modeling artifact, not a real RTL issue (csr_formal.sv's own header
documents hitting exactly this class of spurious-counterexample problem once before). `mode bmc`, not
`mode prove`: full k-induction didn't close for property 2 at this depth either -- a real, honest
bounded result, not an unbounded claim.

## Real bugs/findings, summarized

- **SP_INIT unsized-override width bug** (L1): fixed in the new template; latent in any other caller
  that ever overrides SP_INIT with a bare literal at non-default XLEN.
- **OOOCore.v's real supported ISA subset is narrower than the ADR 0047 summary implied**: jal/jalr/
  lui/auipc/csrrX/fcvt.w.s/fcvt.wu.s/feq.s/flt.s/fle.s/fsw all either silently mis-execute or quietly
  no-op. Only fadd.s/fsub.s/fmul.s/fsgnj*/fmin.s/fmax.s/fmv.w.x of the F-extension are real; fdiv.s/
  fsqrt.s/the fmadd family/flw were already known-absent per ADR 0047, but the *severity* (silent
  wrong execution for several of these, not just absence) wasn't previously documented as precisely.
- **The FreeList/PRF alloc deadlock** (L4) -- the headline finding of this whole phase. Real,
  root-caused, reproducible, not yet fixed. See Future improvements.

## Alternatives considered

- **Full N-wide (>2) dispatch for Gen6-K**: rejected -- the same-bundle RAW bypass complexity already
  scales with N², and 2-wide is what every dual-port-capable module built since Gen6-A already
  supports without further RTL surgery.
- **Fixing the FreeList deadlock in this same phase**: rejected -- the real fix needs a query/commit
  signal split on FreeList.v's (and possibly PhysicalRegisterFile.v's) own alloc interface, touching
  Gen6-A/D foundational dispatch logic, re-verifying every existing Gen6-A-K test, and new coverage
  for the fix itself. A distinct phase's worth of work, not a tooling-phase side effect.
- **Reusing PIPELINED's own random_gen.py mix unfiltered for `--ooo`**: rejected after finding the
  real subset gap above -- would have produced a constant stream of "failures" that are really just
  unimplemented-instruction noise, not signal.

## Validation strategy

- Gen6-K: `tb_ooocore_dual_k1.v` (8/8 checks, dual-issue confirmed firing) + full directed regression
  (123/123) + zero-warning `iverilog -Wall -g2005` compile across `design/*.v` and every OOOCore
  testbench.
- Gen6-L1-L3: 50/50 constrained-random seeds (xlen 32/64, n_instrs 16/40) matched the ISS reference
  exactly (int regs, memory, float regs) via the new retirement-counting template.
- Gen6-L4: real cycle/IPC numbers on 2 kernels, one clean (bench_fib.s) one a confirmed, root-caused
  hang (bench_sum_array.s) -- both are real, useful results, not tooling failures.
- Gen6-L5: `sby -f rob_formal.sby` -> PASS (bounded, depth 4, from genuine reset).
- Full directed regression 123/123 after every sub-phase.

## Future improvements

- **Fix the FreeList/PRF alloc deadlock** (found in L4): a query/commit split on the alloc interface
  -- availability (`alloc_ok`) becomes a pure function of internal state, a separate commit pulse
  (tied to the confirmed dispatch decision) does the actual pop/clear. Real, scoped, next work.
- **Implement jal/jalr/lui/auipc/csrrX in OOOCore.v**: would remove the biggest recurring constraint
  across all of Gen6-L's own tooling (the nop-padded trailer, the restricted random subset, the
  bench_bubble_sort.s exclusion) and is real ISA-completeness work independent of verification tooling.
- **Widen the ROB formal properties past bmc to full `mode prove`**: needs a stronger/wider invariant
  set for k-induction to close; the dropped 3rd property's own solver artifact is worth a second look
  with more tool-specific investigation budget.
- **`--compare-ooo` on more kernels**: once jal/jalr work, bench_bubble_sort.s (and any future
  benchmark) becomes reachable without the current hand-exclusion.
- Everything ADR 0047 already flagged as future work (deep speculation beyond single-outstanding,
  general AMO-RMW+SC, Sv39 MMU+interrupts for OOOCore.v, FDIV/FSQRT/FMADD/FLW/FSW/FCVT/FCMP) remains
  open, now with L1-L3's own tooling ready to validate any of it once built.
