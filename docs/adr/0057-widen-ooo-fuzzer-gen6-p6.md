# ADR 0057: Widen the `--ooo` Fuzzer (Gen6-P6)

## Problem

`docs/adr/0049`'s own Future improvements section flagged widening `random_gen.py`'s own `--ooo`
constrained-random generator to exercise the instruction classes Gen6-O/P1/P4/P5 made real in
`OOOCore.v` since Gen6-L originally scoped it — the sixth and last of six backlog sub-phases before a
real Gen6 closure ADR. `gen_program(ooo=True)`'s own instruction pool had stayed frozen at its Gen6-L
scope (r/i/shift/load/store/branch + a restricted float pool) even as `jal`, `csrrX`, and `fdiv.s`/
`fsqrt.s` all became real, correctly-executing OOOCore.v instructions across this generation's own
later phases.

## Design

### Widened, confirmed against the ISS first

Before touching `random_gen.py`'s own weights, `sim/tools/iss.py` (the reference model this generator's
whole RTL-vs-ISS cross-check depends on) was checked by direct code read for each candidate class:
`jal`/`jalr`/`lui`/`auipc`/SYSTEM(csrrX)/OP-FP `fdiv.s`/`fsqrt.s` are all already fully modeled (used
by the non-`ooo` corpus and MMU/interrupt modes already). **AMO (LR/SC/AMO-RMW) has zero ISS support at
all** — confirmed, not assumed — meaning widening the generator to include AMO would produce spurious
cross-check failures unrelated to real RTL bugs; deliberately NOT attempted this phase, real future
work (a separate, substantial ISS change).

`ooo=True`'s own pool gained: `jal` (generic forward-only-target code already shared with non-`ooo`
mode, needed zero new logic), `csr` (restricted to `mscratch` only, mirroring interrupt mode's own
established "genuinely inert, no control-flow role" safety net — `mstatus`/`mtvec`/`mepc`/`mcause` stay
excluded, same divergence risk that restriction already guards against), and `fp_sqrt`/full `fp_arith`
(fdiv.s no longer truncated out of the pool). `jalr` stays excluded from EVERY mode this generator has
ever had — not ooo-specific, a random register-dependent target was never safe to fuzz for any core.

### Three real, independent bugs found by running — all fixed, all pre-existing, all newly EXPOSED by this phase's own widening

1. **A restart-race in the OOO harness's own trailer**, latent since Gen6-L. The trailer (32 flat `nop`s,
   sized as "2x ROB_ENTRIES" fetch-ahead margin) assumed the gap between an instruction's dispatch and
   its retirement stays bounded by the ROB's own depth — true for single-cycle-dominant instruction
   mixes, but `fdiv.s`/`fsqrt.s`'s own genuine multi-cycle latency (tens of cycles each, and
   back-to-back ones on the shared unit serialize) can exceed that margin easily. OOOCore.v's frontend
   dispatches ahead freely, ungated by a slow in-flight instruction's own completion — so fetch can run
   clean off the end of the nop padding into the zero-filled tail before the program's real last
   instruction retires, illegal-opcode-trapping and restarting the ENTIRE program from `mtvec`'s reset
   default of 0, corrupting whatever hadn't retired yet with a later pass's own value. Root-caused by
   direct cycle tracing (not guessed): the exact same PC repeating every ~64 cycles, the unmistakable
   signature of this restart loop. **Fixed at the root, not widened**: the trailer is now a genuine
   `jal x0,self` infinite loop (unreachable for Gen6-L in OOOCore.v at the time; Gen6-O3 made `jal` real
   since), matching this generator's own non-`ooo` mode idiom exactly — once reached, PC can never
   advance past it again, eliminating the race outright rather than just enlarging a margin a slow
   enough instruction chain could always eventually beat again.
2. **A genuine RTL bug in `OOOCore.v`'s own dual-issue decode**, found only once this phase's widened
   pool put `fdiv.s`/`fsqrt.s` into slot1 for the first time. `is_fp_op_1` (slot1's own float
   classification, gating `slot1_is_plain_alu`) was never widened when Gen6-P4 added `FUNCT5_FDIV`/
   `FUNCT5_FSQRT` support — slot0's own `is_fp_op` (and the new `is_fp_multicycle`) correctly excludes
   them from dual-issue, but slot1's own copy still only recognized FADD/FSUB/FMUL/FSGNJ/FMINMAX/
   FMV.W.X. An `fdiv.s`/`fsqrt.s` landing in slot1 was silently classified as neither memory, div, FP,
   branch, trap-related, nor lui/auipc/jal/jalr/csr — falling into the SAME "plain ALU" default bucket
   every prior phase's own analogous gap did (csrrX in `docs/adr/0051`, AMO in `docs/adr/0052`) —
   dispatching through RS_ALU instead of RS_FDIV, never computing its real result, silently leaving the
   destination register holding whatever it held before. Root-caused by direct dispatch-stream tracing:
   PC visibly skipped straight from one instruction's own address to the one two slots later, the
   unmistakable signature of an unwanted dual-issue bundle. **Fixed by widening `is_fp_op_1`'s own
   whitelist** to include `FUNCT5_FDIV`/`FUNCT5_FSQRT`, mirroring `docs/adr/0055`'s own `is_fp_multicycle`
   exactly.

3. **A genuine, reproducible hang**, closing exactly the gap `docs/adr/0055`'s own Future improvements
   section already named as "the eventual, correct fix": an ordinary FALU op (e.g. `fmin.s`) depending
   on a still-in-flight FDIV/FSQRT result. RS_FALU's own 3 CDB ports were all already spoken for by
   real, still-needed coverage (self, plus ALU- and DIV-completion coverage for FMV.W.X's own possible
   integer source) — none could be safely repurposed for `fdiv_complete_valid` without breaking existing,
   working wakeup paths. A 100-seed volume sweep (run specifically to gain confidence after the first two
   fixes) surfaced it: seed 29's own program chains `fsqrt.s f26,f12` → `fmin.s f27,f26,f12` →
   `fsqrt.s f8,f27`, and the middle `fmin.s` — dispatched before `f26`'s own multi-cycle fsqrt had
   finished — never woke up, timing out at only 30/41 instructions retired. **Fixed with a genuine 4th
   CDB port on `ReservationStation.v` itself** (`cdb_valid3`/`cdb_preg3`, mechanically mirroring the
   existing 3-port pattern in every readiness check and the wakeup loop, plus `ReorderBuffer.v`'s own
   analogous P4 widening to a 5th port) — tied 0 for RS_ALU/RS_DIV/RS_FDIV (none of their own operands
   can ever originate from RS_FALU's completion path) and wired to `fdiv_complete_valid` for RS_FALU,
   the one instance that actually needed it.

All three bugs are genuinely pre-existing (the trailer race dates to Gen6-L, the dual-issue gap and the
missing RS_FALU wakeup both to Gen6-P4) — this phase's own widening is what finally exercised the code
paths that exposed them, exactly the value a fuzzer exists to provide.

## Real bugs/findings

The three findings under Design above. No further divergences or timeouts found across a fresh 100-seed
volume sweep after all three fixes landed.

## Testing

- `--ooo --count 15`: 0/15 (compile failure — `Tlb39.v`/`Ptw39.v` missing from
  `bench_ooocore_template.v`/`dump_regs_ooocore_template.v`'s own include lists, a real gap dating to
  `docs/adr/0053` that never got exercised until this phase actually ran the OOO harness again) →
  14/15 (the trailer restart-race, seed 9) → 15/15 (after fixing `is_fp_op_1`).
- `--ooo --count 100`: 99/100 (seed 29's own genuine RS_FALU hang, timeout) → 100/100 after the 4th
  CDB port fix.
- Full directed regression: 135/135, zero-warning `iverilog -Wall -g2005` compile across every touched
  file (`ReservationStation.v`, its own two callers `tb_rs_unit.v`/`OOOCore.v`, `ReorderBuffer.v`'s
  callers unaffected this phase).

## Alternatives considered

- **Just widen `OOO_TRAILER_NOP_COUNT` further** (e.g. 128) instead of switching to a real self-loop.
  Rejected — treats the symptom, not the cause; any FIXED margin can always be beaten by a long enough
  chain of slow multi-cycle instructions (more `fdiv.s`/`fsqrt.s` back to back, or a future even-slower
  unit), while a genuine self-loop eliminates the race class entirely, at LOWER cost (1 instruction vs.
  32+).
- **Widen the fuzzer to include AMO despite the ISS gap**, tolerating known-spurious failures. Rejected
  outright — a fuzzer whose own failures don't reliably mean "found a real RTL bug" is actively harmful,
  eroding trust in every other real finding it reports.

## Future improvements

- **Teach `sim/tools/iss.py` the A-extension (LR/SC/AMO-RMW)** — a real, separate, substantial ISS
  change; only then does widening `--ooo`'s own pool to include AMO become safe. Real future work.
- **`jalr`** — still excluded from every mode; a bounded/safe random-target scheme (if one is ever
  designed) would need real, careful thought before this generator could safely include it anywhere.
- **`csr` pool widened past `mscratch`** — real future work if a future phase's own MMU/interrupt-mode
  CSR-safety analysis ever extends to cover `mstatus`/`mtvec`/`mepc`/`mcause` for ooo mode specifically.
- **Combine `ooo` with `mmu`/`interrupt`** — a genuinely new, separate integration this generator has
  never attempted for OOOCore.v; both concepts are real in the RTL now (`docs/adr/0053`, `0054`), but
  combining them into one generator mode is real, substantial, additional future work.

## Gen6 backlog: closed

This was the last of the six sub-phases (`docs/adr/0052`-`0057`) the user's own "finish the backlog
first, then close" directive named before a real Gen6 closure ADR. That closure ADR follows next.
