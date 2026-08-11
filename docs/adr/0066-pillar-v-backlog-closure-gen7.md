# ADR 0066: Pillar V backlog closure (2/5) — mask-writing compares + scalar-vs-hardware benchmark

## Problem

`docs/adr/0065` closed Pillar V with a documented, honest backlog. User asked to complete that
backlog. This ADR closes the two items `docs/adr/0059`'s own scope literally requires ("comparisons",
and a scalar-vs-hardware benchmark comparison for pillar V specifically) — the other three backlog
items (indexed/strided/segment load-store, EMUL reshaping, vector floating-point/reductions/permutes/
gather-scatter/fixed-point) are real spec completeness beyond `docs/adr/0059`'s own literal bullet
list, not attempted here, still real future work.

## What's real and closed

### Mask-writing compares (`vmseq`/`vmsne`/`vmslt(u)`/`vmsle(u)`/`vmsgt(u)`), LMUL<=1

Real encodings verified against `riscv/riscv-opcodes` (funct6 0x18-0x1f, `funct6[5:3]==011`).
`VALU.v` gained a compare mode: writes ONE BIT per element at bit position `elem_r` (raw,
mask-indexed), not a `SEW`-wide value at `shift_r` — a genuinely different completion shape from
every arithmetic op, as `docs/adr/0065` itself anticipated. `vmsltu`/`vmslt` have no `.vi` form,
`vmsgtu`/`vmsgt` have no `.vv` form (real spec, rejected as illegal, not silently misdecoded).

**Deliberate LMUL>1 restriction**: a compare's destination is always ONE mask register regardless of
source LMUL (real spec) — every crack-op of an LMUL=g group would need to read-modify-write the SAME
physical destination instead of each getting its own fresh one (every other cracked class's own
behavior). Restricting to LMUL<=1 means the crack sequencer never engages for compares at all, so `vd`
needs no special-case offsetting — zero changes needed to `Control.v`, `ReorderBuffer.v`,
`dispatch_stall`, or the dual-issue exclusion lists, since compares are a `funct6` subset of the
already-wired `is_vec_arith` path. Full-LMUL compares are real, scoped future work.

Tests: `tb_valu_cmp_unit.v` (7/7, standalone, all 8 ops + `v0.t` masking), `tb_ooocore_vector_cmp_v6.v`
(5/5, real dispatch/rename/RS/CDB/ROB wiring, `.vv` and `.vx` forms). Committed separately (988c8f9).

### Scalar-vs-hardware-vector benchmark comparison

New `bench_runner.py --compare-vector`: `sim/benchmarks/vector/bench_vecadd_scalar.s` (an 8-element
`C[i]=A[i]+B[i]` scalar loop) vs. `bench_vecadd_vector.s` (the IDENTICAL result via one real
`vle32.v`/`vle32.v`/`vadd.vv`/`vse32.v` sequence, LMUL=1) — both on `OOOCore.v` (the only core with
real vector support), isolating exactly the compute region (fill loops and the final reduction are
byte-identical between the two files). Lives in its own `sim/benchmarks/vector/` subdirectory,
deliberately NOT under the plain `bench_*.s` glob every other `--compare-*` mode and the no-flag
default run both use — `riscvpipeline.v`'s own `Control.v` never decodes `OP-V` at all, so the vector
file would silently misexecute if a generic run ever routed it there.

`sim/tools/iss.py` has zero `OP-V` opcode support (confirmed by direct code read of its `step()`
dispatch chain — any unrecognized opcode traps), so it can validate the SCALAR half only (dynamic
instruction count 208, x10=396, both real ISS output) and cannot provide the usual correctness
cross-check or dynamic-count for the vector half. `bench_ooocore_vector_template.v` (new, alongside
the existing `bench_ooocore_template.v`) instead dumps x10's own final architectural value directly
from the RTL, checked against a hand-computed constant (396 — the real checksum,
11+22+...+88) — the same real, independent, hand-derived precedent `EXPECTED_X10` already
established for the plain-pipeline benchmarks, just read from the RTL instead of the ISS since the ISS
can't run this program. The vector kernel's own dynamic instruction count (141) was derived by
running the scalar kernel through the real ISS (208) and subtracting/adding the two files' own
compute-region instruction counts by construction (76 scalar, 9 vector — both fixed, no loop
ambiguity, directly counted from the file) — exact, not an estimate, since the shared fill/reduction
portions are byte-identical.

**Real, measured result**: vector cycles=269 vs. scalar cycles=246 (+9.3%, vector SLOWER) — a real,
honest finding, not hidden: this core's own `VALU.v`/`VLSU.v` are iterative (one element per cycle,
`docs/adr/0062`/`0064`'s own documented tradeoff, no wide-parallel datapath), and the single-outstanding
`vle`/`vse` gate (`docs/adr/0064`) serializes the two loads — for an array this small (8 elements), that
overhead outweighs the scalar loop's own per-iteration branch/address-increment cost. The infrastructure
is real and correct regardless of which side wins; a larger array or a wider per-cycle datapath (real
future work) would likely flip this result, but that's a hardware question this benchmark now lets
someone actually answer with evidence instead of assumption — exactly `docs/adr/0059`'s own point.

## Two real bugs found by running (not by code review)

Building `--compare-vector` was real, working code from the first commit onward per this project's own
discipline — it immediately found two genuine, pre-existing correctness bugs neither of Pillar V's own
earlier isolated directed tests had ever triggered, because both need REAL mixed scalar+vector traffic
(heavy concurrent integer preg churn, a vector op with a real cross-file dependency) to manifest —
exactly what "this is what building this tooling was for" (`bench_runner.py`'s own Gen6-L4 precedent)
means in practice.

**Bug 1 — cross-namespace CDB tag collision (`ReservationStation.v`).** `cdb_preg0..3` carry plain preg
NUMBERS (0..63) with no namespace tag distinguishing integer/vector/float register files — documented
as a real, flagged, "never observed" risk since Gen6-H (`docs/adr/0062`'s own header comment on
`RS_VALU`/`RS_VLSU`). `RS_VLSU`'s own `vs3` (store-data) source is ALWAYS vector-namespace, but was
snooping all 4 CDB ports including 2 (integer ALU) and 3 (integer load) — a same-numbered, unrelated
INTEGER completion could spuriously mark it ready early. Fixed with a new, additive, default-preserving
`SRC1_PORT_MASK`/`SRC2_PORT_MASK` parameter pair on `ReservationStation.v` (defaults to `4'b1111`, bit-
exact for every pre-existing instantiation that never passes them) — `RS_VLSU` now masks src1 to ports
2/3 only (rs1 is always integer) and src2 to ports 0/1 only (vs3 is always vector); `RS_VALU`'s own src1
(vs2, always vector) is masked to port0 only. `RS_VALU`'s own src2 (genuinely mixed: vector for `.vv`,
integer for `.vx`/`.vi`) can't be statically narrowed the same way — left as the same real, pre-existing,
still-open risk, not silently claimed fixed.

**Bug 2 — wrong PRF read port for a dispatch-time readiness query (`OOOCore.v`).** The REAL root cause
of the observed failure (a `vse32.v` storing zeros): `vlsu_disp_src2_ready` (the dispatch-time query
asking "is vs3 ready yet?") read `prf_v_rvalid3` — but `m_PRF_Vec`'s own `raddr3` is wired to
`issue_src2_preg_valu`, `RS_VALU`'s own ISSUE-time port for a COMPLETELY UNRELATED in-flight entry, not
a dispatch-time query of vs3 at all. A `vse32.v` could dispatch already "ready" (because that unrelated
port happened to read some other valid preg) before `vadd.vv`'s own real result existed, and would then
issue and store immediately using the not-yet-computed (reset-zero) destination register — silently
storing zeros instead of the real computed array. Root-caused by direct cycle-by-cycle tracing (a
throwaway debug testbench, deleted after use) showing `vlsu_start=1` at the exact cycle `vadd.vv`'s own
`valu_complete_valid` was still 0. Fixed by adding a REAL dispatch-time query: a new `m_PRF_Vec` read
port (`raddr6`/`rvalid6`), addressed by `rat_v_rpreg_vs3` — the same preg `disp_src2_preg0` itself uses
— so the query and the value it's supposed to describe finally agree by construction.

Bug 1 alone did NOT fix the observed failure (confirmed by re-running the debug testbench after fixing
only Bug 1 — still zero) — both were real, independent, and both needed fixing. Neither Phase 3's own
isolated `tb_ooocore_vector_ls_v3.v`/`tb_ooocore_vector_mask_v5.v` tests ever exercised concurrent
integer-vector traffic dense enough to trip either one.

**Verification**: 146/146 full directed suite (up from 144), constrained-random clean on all 4 axes
(default, `--xlen 64`, `--ooo`, `--mmu`, 30/30 each) — confirming the `ReservationStation.v` change
(used by `RS_ALU`/`RS_DIV`/`RS_FDIV`/`RS_FALU`/`RS_VALU`/`RS_VLSU`) introduced zero regression to every
pre-existing instantiation via the default-preserving parameter mask.

## Real, honest remaining backlog (unchanged from docs/adr/0065, narrowed by two items)

- Indexed/strided/segment load-store, EMUL reshaping (EEW≠SEW), full-LMUL mask-writing compares —
  real spec, real future work, beyond `docs/adr/0059`'s own literal bullet list.
- Vector floating-point, reductions, permutes, gather/scatter, fixed-point saturating ops — never in
  scope, a real, separate, larger undertaking.
- `RS_VALU`'s own src2 cross-namespace risk (genuinely mixed vector/integer by design) — real,
  pre-existing, still open, not fixed here (see Bug 1 above).

## Alternatives considered

- **Fix only the benchmark infrastructure, treat the resulting failure as a benchmark bug to work
  around (e.g. a bigger `target_retired` margin) rather than a real RTL bug.** Rejected immediately —
  the failure was `x10=0` (a wrong architectural result), not a timeout; treating a correctness failure
  as a tooling quirk would have silently shipped a real, user-visible data-corruption bug (any
  mixed scalar+vector program with a store using an in-flight vector source could hit this).
- **Fix only Bug 2 (the actual root cause) and skip Bug 1 (the CDB mask), since Bug 1 alone didn't
  fix the observed failure.** Rejected — Bug 1 is a real, independent, previously-flagged-but-unfixed
  risk this investigation had already fully root-caused and had a clean, additive fix in hand for;
  leaving it unfixed after finding and understanding it exactly would be reintroducing a known risk
  by choice, not honestly out of scope.

## Future improvements

Full-LMUL mask-writing compares (the read-modify-write-shared-destination mechanism `docs/adr/0065`
originally deferred) and `RS_VALU`'s own src2 cross-namespace risk are the two highest-value remaining
items if a future session revisits Pillar V specifically. Otherwise, per the user's own explicit
direction, next is Pillar K (cryptography), `docs/adr/0059`'s own Generation 7 scope.
