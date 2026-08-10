# ADR 0054: Real Interrupts in OOOCore.v (Gen6-P3)

## Problem

`docs/adr/0049`'s own Future improvements section flagged "Sv39 MMU + real interrupts for OOOCore.v" as
open; `docs/adr/0053` (Gen6-P2) closed the MMU half. This is the third of six backlog sub-phases the
user's own "finish the backlog first, then close" directive requires. Gen6-I's own header already
flagged the exact gap: illegal-instruction/ecall/mret are all dispatch-time-known causes; "real
interrupts (timer/software/external)... need a real retire-boundary injection point" — genuinely
different from anything the trap machinery built so far, since an interrupt isn't tied to any specific
instruction's own decode at all.

## Design

### Recognized once the ROB drains, not at an arbitrary mid-flight boundary

Real design decision, not the more elaborate option: rather than injecting an interrupt at an arbitrary
in-flight instruction boundary (what a genuinely precise, minimum-latency interrupt implementation
would do), this core takes an interrupt only once the ROB is fully **drained** (`rob_empty`).
`interrupt_pending` (an enabled mei/msi/mti source) folds into `dispatch_stall` — the same
single-outstanding shape every other Gen6-* control-flow source (`br_inflight_valid_r`,
`trap_inflight_valid_r`, `jr_inflight_valid_r`, `csr_inflight_valid_r`, Gen6-P2's own `dtlb_stall`) —
stopping new dispatch the moment it's recognized; everything already in flight drains out through its
own normal retire path first; `interrupt_take = interrupt_pending && rob_empty` fires the actual
redirect the first cycle nothing is left.

This needs **zero new per-instruction tracking** — no `*_inflight_valid_r` register at all, unlike
every prior trap-related mechanism. `rob_empty` already means nothing else could possibly want the
same cycle's redirect mux, so there's no priority/coincidence question to resolve the way
`trap_resolve`/`br_resolve`/`jr_resolve`'s own mutual exclusion needed reasoning through in earlier
phases. RISC-V does not mandate minimum interrupt latency — draining first is a real, legitimate,
spec-compliant recognition point, just a more conservative one than a genuinely precise implementation
would use.

### Scope: mei/msi/mti only, M-mode, no S-mode delegation

Matches PIPELINED's own Phase D8/D9/R baseline, deliberately BEFORE Phase S's later S-mode delegation
work (`ssi`/`sti`, `sstatus.SIE`, software-settable `mip_ssip`) — a real, narrower scope cut: this core
has no `medeleg`/`mideleg` infrastructure at all yet (Gen6-I's own header already flagged this), so
S-mode-targeted interrupt delegation stays out of scope here too, the same "not re-litigated" treatment
`docs/adr/0053` already gave to comparable Sv39 scoping defaults. Priority when more than one source is
pending and enabled matches spec + PIPELINED's own existing convention: external > software > timer.

### New top-level ports, CSR.v ports wired through

Three new OOOCore.v inputs (`msip_pending`/`timer_pending`/`ext_pending`) route straight through to
CSR.v's own already-existing ports of the same name (previously tied 0) — this core has no Timer.v/
Uart.v (CLINT/PLIC-lite) instantiated yet, so a caller (a future SoC integration, or a testbench
directly, as this phase's own directed test does) drives them. CSR.v's own `mstatus_mie`/`mie_msie`/
`mie_mtie`/`mie_meie` outputs (previously left open) feed the new `interrupt_pending` computation.
`trap_taken`/`trap_pc`/`trap_cause`/`trap_is_interrupt` all widened with `interrupt_take` as the
highest-priority mux arm (ordered first for clarity, though it can never genuinely coincide with
`dside_trap_resolve`/`trap_resolve_dispatch` the same cycle — both require something in flight, and
`interrupt_take` only ever fires with `rob_empty`).

## Real bugs/findings

- **A genuine "found by design" catch, before writing any test for it**: the existing PC-advance
  block's own priority chain (`trap_resolve` → `br_resolve && br_mispredict` → `jr_resolve` →
  `do_dispatch`) has no arm that fires for a pure `interrupt_take` at all — `trap_resolve` is keyed to a
  specific retiring `rob_tag`, which an interrupt genuinely has none of. Widening `csr_trap_taken`
  itself to include `interrupt_take` (needed for CSR.v's own trap-entry side effects) does NOT
  automatically make `pc_r` redirect, since the PC-advance block's own `trap_resolve`-gated branch
  never evaluates `csr_trap_taken` unless `trap_resolve` is ALSO true. Left unfixed, `pc_r` would have
  silently frozen forever the instant a real interrupt fired — caught by re-tracing the exact gating
  condition before running anything, the same discipline `docs/adr/0053`'s own four deadlock findings
  used. Fixed with a new, higher-priority `interrupt_take` arm of its own.
- **A real test-authoring assumption, not an RTL bug**: the directed test's own first version expected
  `mcause`'s interrupt bit at bit 63 (RV64's spec-correct `XLEN-1` position). CSR.v's own existing
  update (`mcause <= {trap_is_interrupt, trap_cause[30:0]}`, a 32-bit concat zero-extended into the
  wider register) puts it at bit 31 instead — pre-existing, shared, already-tested behavior from
  PIPELINED's own Phase R, not something this phase changed or should "fix" here. Found immediately by
  running (`0x80000007` vs. the test's own wrong expectation), fixed by correcting the test's own
  expected value, not the RTL.

## Testing

- `tb_ooocore_int_p3.v`: enables `mie.MTIE`+`mstatus.MIE`, sets `mtvec`, spins in a tight self-branch
  loop (the loop itself is what lets `rob_empty` genuinely toggle true between iterations); the
  testbench asserts the DUT's own real `timer_pending` port partway through, with no further help from
  the program — a marker instruction at the handler proves the redirect actually happened. 4/4, first
  real run (after the mcause-encoding test-expectation fix above).
- Full directed regression: 133/133 (up from 132), zero-warning `iverilog -Wall -g2005` compile — every
  `OOOCore.v`-instantiating file (all `tb_ooocore_*.v`, `HeteroSoC.v`, `bench_ooocore_template.v`,
  `dump_regs_ooocore_template.v`) needed the three new ports tied off.

## Alternatives considered

- **A genuinely precise, arbitrary-mid-flight-boundary interrupt injection** (check for a pending,
  enabled interrupt at every possible retire, redirect immediately regardless of what else is still in
  flight, squashing younger in-flight work). Rejected for this phase — real, substantially larger
  undertaking (needs the same class of ROB-truncation/RS-flush machinery Gen6-G's own branch-speculation
  header already flagged as deliberately out of scope for "deep speculation"), for a latency improvement
  this core's own test/benchmark workloads have no evidence of needing yet. The `rob_empty`-gated
  approach is a real, correct, much smaller mechanism that reuses zero new per-instruction state.
- **Building a real Timer.v/Uart.v (CLINT/PLIC-lite) peripheral for OOOCore.v this phase**, matching
  PIPELINED's own. Rejected — out of scope for "the interrupt-taking MECHANISM works correctly," which
  is what Gen6-I's own header actually flagged as missing; a real peripheral is a separate, additive
  SoC-integration concern (mirrors Gen6-N's own Mailbox.v precedent: build the mechanism, let a future
  SoC phase wire a real source to it).

## Future improvements

- `docs/adr/0049`'s remaining backlog, now minus this phase: rest of F-extension (Gen6-P4), BTB-predicted
  jalr (Gen6-P5).
- **A real Timer.v/Uart.v instantiation** for OOOCore.v or a future HeteroSoC-level interrupt source —
  the mechanism this phase built is ready to receive one; `HeteroSoC.v`'s own three new ports are tied 0
  for exactly this reason.
- **S-mode interrupt delegation** (`mideleg`, `sstatus.SIE`, `ssi`/`sti`) — real future work, alongside
  the `medeleg`/S-mode trap-delegation infrastructure this core doesn't have at all yet.
- **A genuinely precise (non-drained) interrupt injection point** — real future work if profiling ever
  shows the drain-based latency costing real cycles on an interrupt-heavy workload.
- **Widen `random_gen.py`'s own `--ooo` fuzzer** to exercise interrupts — deferred alongside every other
  fuzzer-widening item already queued for Gen6-P6.
