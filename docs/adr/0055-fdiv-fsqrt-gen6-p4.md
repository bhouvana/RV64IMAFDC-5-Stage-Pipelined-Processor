# ADR 0055: fdiv.s/fsqrt.s in OOOCore.v (Gen6-P4, partial)

## Problem

`docs/adr/0049`'s own Future improvements section flagged "rest of F-extension
(FDIV/FSQRT/FMADD/FLW/FSW/FCVT/FCMP)" as open — the fourth of six backlog sub-phases the user's own
"finish the backlog first, then close" directive requires. Gen6-H (`docs/adr/0047`'s own generation)
scoped narrowly on purpose: pure float-float ops (FADD/FSUB/FMUL/FSGNJ/FMINMAX) + FMV.W.X only, with
its own header explicitly listing FDIV/FSQRT/FMADD/FCVT/FCMP/FLW/FSW as "explicitly out of scope, real
future work."

**This phase closes FDIV.S/FSQRT.S only.** FMADD/FMSUB/FNMSUB/FNMADD (needs a 3rd float PRF read port),
FLW/FSW (needs real LSQ float-destination routing — the LSQ only completes into the integer PRF today),
and FCVT.S.W/FCVT.W.S/FMV.X.W/FCLASS.S/FCMP (cross-file-direction int/float wiring, several distinct
sub-cases) remain open, explicitly re-flagged below — a real, honest scope narrowing within one backlog
item, not a silent drop, matching this project's own established precedent for scoping a phase to what's
tractable and correct rather than attempting everything named in a single backlog line at once.

## Design

### FDivider.v/FSqrt.v reused completely unmodified

Both already existed for PIPELINED (Phase C4), with the exact same `start`/`busy`/`done` interlock shape
`Divider.v` established and this core's own Gen6-F integration already proved out for DIV/DIVU/REM/REMU.
Integration, not new hardware design — the same framing `docs/adr/0053` already used for Tlb39.v/Ptw39.v.

### RS_FDIV: one shared reservation station for two real, separate units

Mirrors RS_DIV's own shape exactly (a single entry type serving multiple sub-operations via a payload
bit), but here the payload bit (`is_sqrt`) picks which of two genuinely SEPARATE hardware units gets
`start` — FDivider.v (two operands) and FSqrt.v (one) are mutually exclusive by construction, so their
own `busy`/`done` mux cleanly on the same registered selector the in-flight latch already needs to keep
alive. `fsqrt.s`'s own `rs2` field is unused by spec (must be 0) — its `src2_ready` is tied
always-ready rather than waiting on an operand the instruction never reads.

### ReorderBuffer.v needed a genuine 5th completion port

RS_FALU's own `falu_complete_valid` (single-cycle) and RS_FDIV's own `fdiv_complete_valid`
(multi-cycle) are two real, independent sources that could complete the identical cycle by coincidence
— unlike `docs/adr/0053`'s own `dside_fault_pulse`/`lsq_complete_valid` pairing, which was provably
mutually exclusive by construction, these two cannot safely share one port. `ReorderBuffer.v` gained
`complete_en4`/`complete_tag4` (a small, mechanical, low-risk widening mirroring the existing 4-port
pattern exactly) rather than trying to arbitrate/delay one of two genuinely concurrent sources onto a
shared port.

### RM_DYN resolved once, at dispatch, against `frm_val`

Mirrors PIPELINED's own single `fpu_rm` resolution point (`docs/adr/0019` Phase C8) — `funct3==RM_DYN`
means "use `frm`'s current live value," resolved once at dispatch and captured into the RS entry's own
payload, never re-resolved at issue time (frm can't change while an entry sits queued — the same
"captured once, trusted for the whole in-flight duration" reasoning `docs/adr/0052`'s own AMO-RMW
old-value capture already relies on). `CSR.v`'s own `frm_val` output, previously left open in
OOOCore.v's instantiation, is now wired for real.

## Real bugs/findings

- **A genuine deadlock found by running, root-caused by direct cycle-by-cycle tracing (not guessed)**:
  `RS_FDIV`'s own CDB snoop mirrored every other RS instance's default 3-port shape
  (`issue_valid`/`lsq_complete_valid&&load`/self) — but fdiv.s/fsqrt.s's own operands are ALWAYS float
  pregs, and `flw` doesn't exist yet, so `lsq_complete_valid` can never possibly matter for this RS,
  while `FMV.W.X` (the only way to get a float value from an integer source right now, and this phase's
  own directed test's exact operand path) completes via `RS_FALU`/`falu_complete_valid` instead —
  completely uncovered by any of RS_FDIV's three ports as originally wired. An fdiv.s/fsqrt.s whose
  operand was produced by a JUST-dispatched FMV.W.X (not yet PRF-valid at the divide's own dispatch
  cycle) would never wake up — a permanent deadlock, observed directly as both `f3` and `f4` stuck
  reading their own reset-default identity-mapped preg (rename never committed, meaning retire never
  happened). Fixed by swapping RS_FDIV's own `cdb_valid1` from `lsq_complete_valid` (dead weight for
  this RS, given no flw) to `falu_complete_valid` instead — the port fdiv/fsqrt operands actually need
  coverage from.
- **A genuine test-authoring bug, not an RTL bug**: the first version of the directed test's own program
  had no real halt loop, just `addi x0,x0,0` padding — falling off the end into the zero-filled tail
  (illegal opcode → trap → `mtvec`'s own reset default of 0 → restart) repeatedly re-executed the whole
  program forever within the test's own fixed cycle window, the same class `docs/adr/0048`/`0051`
  already found and fixed more than once. Fixed with the same `beq x0,x0,halt` idiom every other
  Gen6-* directed test now uses.
- **A known, real, bounded gap flagged but NOT fixed this phase (deliberately, not an oversight)**: the
  REVERSE direction — `RS_FALU`'s own CDB snoop still doesn't cover `fdiv_complete_valid` — means a
  FALU op (e.g. a later `fadd.s`) depending on a still-in-flight FDIV/FSQRT result would never wake up
  either. Exactly the same class Gen6-H's own header already flagged for `LoadStoreQueue.v`'s
  completions; this phase's own directed test deliberately avoids the scenario (checks `f3`/`f4`
  directly rather than chaining a FALU op onto them) rather than working around it silently. A real 4th
  CDB port on `ReservationStation.v` itself (affecting every RS instance) is the eventual, correct fix
  for both directions at once — real future work, not attempted here.

## Testing

- `tb_ooocore_fdiv_p4.v`: `6.0f/2.0f=3.0f` (FDIV.S) and `sqrt(2.0f)` (FSQRT.S), both checked by reading
  the float PRF array directly. 4/4 after the CDB-snoop fix above.
- Full directed regression: 134/134 (up from 133), zero-warning `iverilog -Wall -g2005` compile —
  `ReorderBuffer.v`'s own two callers (`tb_rob_unit.v`, `sim/formal/rob_formal.sv`) and every
  `OOOCore.v`-instantiating file needed `complete_en4`/`complete_tag4`/the two new `FDivider.v`/
  `FSqrt.v` includes.

## Alternatives considered

- **A single combined FDivider+FSqrt module** instead of two real, separate units sharing one RS.
  Rejected — both modules already existed, fully built and tested, for PIPELINED; merging them would be
  new, unnecessary, riskier hardware-design work for zero benefit over muxing two proven units on a
  shared payload-selected `start`.
- **Delaying one of RS_FALU/RS_FDIV's own completion by a cycle** to share one ROB completion port
  instead of widening `ReorderBuffer.v` to a 5th port. Rejected — the two really can complete the
  identical cycle (no proof of mutual exclusion the way `docs/adr/0053`'s own case had), and delaying a
  real completion pulse is real, non-trivial added complexity (the delayed source would need its OWN
  buffering to survive one more cycle) for a smaller, cleaner alternative (widening `ReorderBuffer.v`'s
  own already-established 4-port pattern by one more) that was directly available.

## Future improvements

- **FMADD/FMSUB/FNMSUB/FNMADD** — needs a 3rd float PRF read port (`FRegister.v`'s own rename stack
  currently has 2). Real future work, not attempted this phase.
- **FLW/FSW** — needs `LoadStoreQueue.v` widened to route a completion into the float PRF, not just the
  integer one (`docs/adr/0053`'s own D-side MMU integration already touched this LSQ heavily; this is a
  separate, real, additive change). Real future work.
- **FCVT.S.W/FCVT.W.S/FMV.X.W/FCLASS.S/FCMP** — cross-file-direction wiring (int source→float dest for
  the first, float source→int dest for the rest), several distinct sub-cases each needing their own
  decode/routing care. Real future work.
- **RS_FALU's own CDB snoop widened to cover `fdiv_complete_valid`** (the reverse-direction gap flagged
  above) — real future work, likely bundled with a genuine 4th CDB port on `ReservationStation.v` itself
  when the rest of the F-extension above lands and the same class of gap keeps recurring.
- **Widen `random_gen.py`'s own `--ooo` fuzzer** to exercise fdiv.s/fsqrt.s — deferred alongside every
  other fuzzer-widening item already queued for Gen6-P6.
