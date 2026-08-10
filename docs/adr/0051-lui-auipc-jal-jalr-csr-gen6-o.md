# ADR 0051: lui/auipc/jal/jalr/csrrX in OOOCore.v (Gen6-O)

## Problem

`docs/adr/0048`/`0050` documented a real, confirmed gap: `jump_c`/`jalr_c`/`lui_c`/`auipc_c`/`isCsr_c`
are decoded (`design/Control.v`) but never consumed anywhere in `design/OOOCore.v` — every one of
these instructions either silently mis-executed or quietly no-op'd. User asked directly for this
closed: "complete jal/jalr/lui/auipc/csrrX... not in progress anymore."

## Design

### RS_ALU payload extension (shared infrastructure)

None of these five instruction classes compute their destination value from a normal two-PRF-operand
ALU op the way R/I-type instructions do:
- **lui**: rd = 0 + imm
- **auipc**: rd = this instruction's own PC + imm
- **jal/jalr (link)**: rd = this instruction's own PC + 4
- **csrrX**: rd = the CSR's own current value

`ReservationStation.v`'s own payload gained two new fields, captured once at dispatch (when the real
value is known) and carried through exactly like `ALUSrc`/`imm` already are:
- `use_forced_a` + `forced_a_value` (XLEN-wide): overrides `alu_a` (normally `prf_rdata2`) with a
  captured constant — 0 for lui, this instruction's own `pc_r` for auipc/jal/jalr, the CSR's own
  captured old value for csrrX.
- `use_link_b`: overrides `alu_b` with the literal 4 (jal/jalr's own link-value computation).

`PAYLOAD_BITS` widened from `1+5+XLEN` to `1+1+XLEN+1+5+XLEN`; extraction bit positions updated to
match. All five classes are excluded from Gen6-K's own dual-issue eligibility (`slot0_is_plain_alu`/
`slot1_is_plain_alu`) — a real, deliberate scope cut, not an oversight: jalr/csrrX specifically need
their own single-outstanding speculative-resolution state, and extending that to a hypothetical slot1
doubles Gen6-K's own already-real same-bundle hazard concerns for instruction classes real code uses
far less densely than plain ALU ops.

### lui/auipc (Gen6-O2)

Purely additive to the payload mechanism above — no dispatch_stall change, no PC-redirect change.
`needs_dest` (already `regWrite_c && rd!=0`) already correctly triggers renaming for both. Dispatches
through the ordinary single-issue RS_ALU path.

### jal (Gen6-O3)

**Real research finding, not assumed**: jal's target (`pc + J-type immediate`) is known
*unconditionally at decode* — no register dependency, unlike a conditional branch or jalr. This means
jal needs **no speculation at all**: the PC-advance block redirects immediately the same cycle jal
dispatches (`pc_r <= pc_r + (imm_d << 1)`, the same `<<1` treatment `br_inflight_imm_r` already
established, since ImmGen.v's own J-type case deliberately outputs the pre-shift value). The link value
(PC+4) is computed via the same forced-A/link-B payload mechanism as auipc.

### jalr (Gen6-O4)

jalr's target (`(rs1+imm) & ~1`) *is* register-dependent — genuinely unknowable at decode. **Real
design decision, not the more elaborate option**: rather than a full BTB-predicted speculative window
(the same shape `br_inflight_*` already built for conditional branches), jalr reuses the simpler
**single-outstanding, stall-and-wait** scope cut `trap_inflight_valid_r` (Gen6-I) already established:
dispatch of everything else blocks while a jalr is in flight; `pc_r` simply holds still (no
speculative advance, no "mispredict" concept needed) until the jalr's own RS_ALU entry actually issues
(`jr_resolve`, mirroring `br_resolve`'s exact timing), at which point `pc_r` redirects for real. The
real target is computed from `prf_rdata2` (rs1's own raw PRF read, untouched by this same entry's own
`use_forced_a` override, which only ever affects the link-value `alu_out`) + the captured immediate,
low bit masked. A genuine BTB-predicted jalr is real future work if profiling ever shows this stall
costing real cycles on a function-pointer/return-heavy workload — jalr is rare enough in typical code
that the simpler mechanism was the right first cut.

### csrrw/csrrs/csrrc(+i) (Gen6-O5)

Same single-outstanding shape as jalr, but the resolved side effect is a CSR write instead of a PC
redirect. **Real design decision, confirmed correct before writing RTL**: the READ (rd's own old-value
writeback) and the WRITE (the actual CSR mutation) do NOT need to happen at the same pipeline moment.
Because the single-outstanding scope cut already guarantees nothing else (no other csrrX, no trap/
mret — every one of these scope cuts blocks the others mutually exclusively via `dispatch_stall`) can
touch any CSR state between this instruction's own dispatch and its own resolve, reading `csr_rdata`
combinationally *at dispatch time* (captured into the payload's `forced_a_value`, same mechanism as
lui/auipc/jal/jalr) is provably identical to reading it again at resolve time. The write itself needs
the real operand value (rs1's PRF read for the register forms, or the captured 5-bit uimm for the `*i`
forms — `inst[19:15]`, the same bit position `rs1_areg` already reads), which may not be ready at
dispatch time, so it fires at resolve (`csr_write_fire`, mirroring `jr_resolve`'s exact timing).
`CSR.v` itself needed zero changes — it already exposes a general `csr_addr`/`csr_op`/`csr_wdata`/
`csr_rdata`/`csr_write_en` interface (confirmed already used by `sim/formal/csr_formal.sv`), the same
"ROB-retire-gated CSR.v needs zero changes" pattern `docs/adr/0047`'s own precise-exceptions research
already found.

## Real bugs/findings

- **A real bug found by running, not anticipated in the plan**: the first csrrX directed test's own
  `x2` check (the CSR's value *before any writes at all*) failed — got 9 (the final value), expected
  0 (the reset default). Root-caused via direct cycle-by-cycle signal tracing (not guessed): the test
  program's own tail was plain nop padding, not a real halt — OOOCore.v's frontend fell off the end
  into the zero-filled tail, hit an illegal opcode, trapped, and (mtvec never leaves its own reset
  default of 0) restarted the entire program from address 0 well within the directed test's own
  200-cycle window. Every *other* check in that same test (and every other Gen6-O test) happened to be
  idempotent across multiple passes (recomputing the identical value each time) — only a check
  comparing against *persistent, cross-pass* state (a CSR, exactly like `docs/adr/0048`'s own
  `bench_sum_array.s` finding for `DataMemoryBRAM`) is vulnerable to this class of bug. Fixed with the
  same real, working idiom `docs/adr/0050`'s own `hetero_ooo_n1.s` established:
  `halt: beq x0, x0, halt` (always taken, x0==x0) — a genuine infinite loop using only a branch,
  unlike the jal-based trailer every other test uses (which still doesn't loop in OOOCore.v — jal
  itself now works, per Gen6-O3, but the *shared* `random_gen.py`/directed-test trailer convention was
  never revisited here; this fix is local to the one test that actually needed it).
- **jal/jalr/lui/auipc/csrrX all passed their own first directed test on the first real attempt** once
  the payload mechanism itself was proven (by lui/auipc) — the csrrX bug above was a test-hygiene
  issue, not an RTL bug in the new dispatch/resolve logic itself.

## Testing

Four new directed tests, one per remaining sub-phase (lui/auipc share one):
- `tb_ooocore_lui_auipc_o1.v`: 3/3.
- `tb_ooocore_jal_o2.v`: 3/3 — proves the two skipped instructions between jal and its target never
  retire.
- `tb_ooocore_jalr_o3.v`: 4/4 — same proof, register-dependent target.
- `tb_ooocore_csr_o4.v`: 6/6 — all 6 csrrw/csrrs/csrrc(+i) forms, old-value and new-value both checked
  independently at every step.

Full directed regression 129/129 (up from 125), zero-warning `iverilog -Wall -g2005` compile across
every touched testbench. `run_random_tests.py --ooo` (15/15) and `bench_runner.py --compare-ooo` (both
kernels, unaffected) re-confirmed clean — `random_gen.py`'s own `--ooo` generator subset was NOT
widened to include these newly-supported classes this phase (see Future improvements).

## Alternatives considered

- **BTB-predicted jalr** (matching conditional branches' own speculative window): rejected for this
  phase — real future work, not the right first cut given jalr's relative rarity and the
  single-outstanding mechanism's own proven simplicity/low risk (same pattern already validated twice,
  Gen6-I traps and this phase's own jalr).
- **Dual-issue eligibility for lui/auipc** (genuinely ALU-like, no control-flow effect): rejected —
  would require mirroring the full forced-A/link-B mechanism for slot1 too, real added complexity for
  unproven benefit; jal/jalr/csrrX's own single-outstanding state makes them structurally ineligible
  regardless, so excluding all five uniformly was the simpler, consistent choice.

## Future improvements

- **Widen `random_gen.py`'s own `--ooo` mode** to include lui/auipc/jal/csrrX (jalr and general
  csrrX-with-arbitrary-CSR are riskier to fuzz safely — real design work, not just re-enabling a
  kind) now that OOOCore.v actually executes them correctly — would strengthen Gen6-L's own
  constrained-random cross-check meaningfully.
- **BTB-predicted jalr**, if profiling ever shows the stall-and-wait cost mattering on a real
  workload.
- **`hetero_ooo_n1.s`/other Gen6-N worker programs** could now use real lui/jal/jalr/csrrX instead of
  the chunked-addi/`beq x0,x0,label` workarounds Gen6-N needed — not revisited this phase (those
  programs still work correctly as-is).
- Everything `docs/adr/0049`'s own Future improvements section still lists (deep speculation, general
  AMO-RMW+SC, Sv39 MMU+interrupts, FDIV/FSQRT/FMADD/FLW/FSW/FCVT/FCMP) remains open.
