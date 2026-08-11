# ADR 0063: Full LMUL grouping (crack-into-microops) — Generation 7, Pillar V, Phase 2b

## Problem

`docs/adr/0062` closed Phase 2a scoped to LMUL=1 only. This phase closes the user-confirmed full-LMUL
requirement (`docs/adr/0059`'s own most-ambitious scope choice): a vector instruction with LMUL=g must
touch g real physical vector registers, not one.

## Design

A macro vector instruction with LMUL=g cracks into g independent micro-ops (one per architectural
sub-register in the vd/vs1/vs2 group), dispatched ONE PER CYCLE through the existing single-issue slot0
path — each crack-op gets its own real ROB entry, RS_VALU entry, and VALU.v run, exactly like an ordinary
LMUL=1 instruction Phase 2a already proved. No new dispatch bandwidth, no new functional unit — the
existing single-issue machinery simply runs g times in a row for one macro instruction, `pc_r` held
constant across all g cycles via a new `vec_crack_holds_pc` term folded into the existing PC-advance
block's own ternary chain (fetch/decode keep re-reading the identical `inst_word`, harmless — nothing
about fetch/decode has side effects of its own, the same reasoning this file's own header comment already
establishes for a held branch/trap).

`vlmul_group_count`: real spec's own `vlmul` field is a two's-complement `log2(LMUL)` — `000/001/010/011`
→ LMUL 1/2/4/8; `101/110/111` (fractional LMUL 1/8,1/4,1/2) still touch exactly ONE physical register, so
`group_count=1` for those too; `100` is reserved.

Real vd/vs1/vs2 group-alignment checking (per spec, group operands must be aligned to a multiple of the
real group count) feeds the existing illegal-instruction machinery via a new `vec_unaligned` term folded
into `has_exception`, checked only when starting a fresh macro instruction (not on a continuing crack-op,
which is by construction already base+offset of an already-confirmed-aligned base).

Per-crack-op LOCAL `vl`: real spec `vl` applies to the whole logical vector (elements
`[0, VLMAX)` across the group); each crack-op's own physical register only covers
`[i*elems_per_reg, (i+1)*elems_per_reg)`. `elems_per_reg = VLEN/SEW`, independent of LMUL (a fixed
physical capacity per register, matching `VALU.v`'s own internal `elems_this_sew` formula). This local
`vl` is computed at DISPATCH time (when the crack sequencer's own index is known) and rides the RS_VALU
payload alongside the `.vi` immediate, for the identical reason that value does — a queued entry's own
dispatch-time capture must survive unmolested to its later issue cycle, which could be many cycles later
given VALU.v's own iterative multi-cycle nature and RS_VALU's own queueing.

## Real bugs/findings

**The alignment check included `vs1_areg_raw` unconditionally.** For `.vx`/`.vi` forms that instruction
field is `rs1`'s own register number or the raw 5-bit signed immediate bits, not a vector register at
all. A `.vi` instruction with an odd 5-bit immediate (7, in the directed test) tripped the check every
single time regardless of the real `vd`/`vs2` alignment — found immediately by running the first LMUL=2
directed test (every dispatch flagged `unaligned`, the crack sequencer never started at all). Fixed by
excluding `vs1` from the alignment check whenever the form uses a scalar/immediate operand
(`vec_arith_use_scalar`).

**`m_ROB`'s own `alloc_areg0` was fed the raw `rd_areg` instead of the crack-adjusted `vec_vd_areg`** —
the more subtle and consequential of the two. `rd_areg` is `inst_word[11:7]` directly, identical for
every crack-op of one macro instruction (`inst_word` never changes while `pc_r` is held for the whole
crack sequence), so every crack-op's own ROB entry silently recorded the SAME architectural register
regardless of which physical sub-register it actually targeted. The second crack-op's own retire
overwrote the first crack-op's own retire-time rename in `RegisterAliasTable.v`'s architectural table
instead of writing its own real destination register, which was left permanently stuck at its reset
identity mapping — a real, silent correctness bug (wrong final architectural state, no trap, no compile
warning). Root-caused via direct ROB-retire/RAT-commit cycle tracing (a throwaway debug testbench
watching `rob_retire_valid`/`areg`/`preg` every cycle) after the alignment fix alone didn't resolve the
test's own remaining failures — confirmed by observing both crack-ops retire with the identical `areg=2`
value instead of `2` then `3`. Fixed by conditioning `alloc_areg0` on `is_vec_arith ? vec_vd_areg :
rd_areg`, the same 3-way mux shape `alloc_preg0`/`alloc_old_preg0` already used.

Both bugs were invisible to Phase 2a's own LMUL=1-only testing by construction — LMUL=1 never exercises a
second crack-op, so neither the alignment field's own vs1-for-.vi confusion nor the areg-recording bug
could ever manifest with only one crack-op in flight.

## Testing

- Directed: `ooocore_vector_lmul2_v2b` — one macro `vadd.vi` with LMUL=2 proven to produce TWO real,
  independently-renamed physical vector registers (`v2` and `v3`), each with its own correctly-clamped
  local `vl` (16 and 4 respectively for a `vl=20` config) — including a genuine tail-agnostic-zero
  boundary at element 4 of the second register, the real proof this is per-crack-op clamping and not just
  "the macro instruction ran twice with the same `vl`." 7/7 checks.
- 141/141 full directed suite (up from 140), zero-warning compile, 50/50 scalar random cross-check, 50/50
  `--ooo` random cross-check.

## Alternatives considered

- **A dedicated multi-cycle "dispatch hold" state machine separate from the ordinary single-issue path.**
  Rejected — the existing single-issue slot0 dispatch machinery already does everything a crack-op needs
  (rename, ROB alloc, RS dispatch); the only genuinely new mechanism is holding `pc_r` and offsetting the
  three vector register fields, both small, additive changes to existing wires rather than a parallel
  dispatch path.

## Future improvements

- `v0.t` masking wiring at the `OOOCore.v` level, combined with real LMUL grouping (both proven
  independently now, not yet proven together in one directed test).
- `vle`/`vse` unit-stride load/store (Phase 3) — needs its own crack-awareness for multi-register-group
  memory access, on top of everything this phase already built for the ALU-side case.
- Dual-issue for vector instructions remains explicitly out of scope (mirrors `is_fp_op`'s own exclusion) —
  real future work if profiling ever motivates it.
