# ADR 0059: Generation 7 scope — Advanced ISA Extensions (expanded from vector-only)

## Problem

`docs/ROADMAP_VISION.md`'s original Generation 7 entry (source material: "Phase K — Vector Processing")
scoped Generation 7 as vector-only: a vector register file, a vector ALU, vector load/store, mask
operations, vector benchmarks. That was written before Generation 6 (`docs/adr/0058`) closed the
out-of-order core. The user, picking the project back up post-Gen6-closure, gave an explicit, detailed
Generation 7 plan that both confirms the OoO/vector boundary already established and substantially
widens Generation 7's own scope beyond vector alone.

Two things needed resolving before any implementation work starts:

- **Where does out-of-order execution live?** Some readings of "Generation 7 adds new execution
  capability" could be misread as introducing a second OoO effort. The user was explicit: Generation 6
  is already the out-of-order generation, closed, not to be reopened or duplicated. Generation 7 builds
  ISA-level capability **on top of** the existing `design/OOOCore.v` microarchitecture (renaming, PRF,
  reservation stations, ROB, LSQ, CDB, speculation), reusing it wherever architecturally appropriate.
- **Is Generation 7 still "Vector Processing"?** No — the user's plan expands it to five pillars, and
  asked explicitly not to merely rename the existing vector-only generation but to widen it into a real
  multi-extension generation.

## Decision

**Generation 7 is renamed and rescoped: Vector Processing (v7.0) → Advanced ISA Extensions (v7.0)**,
covering five pillars, each a real RISC-V (or RISC-V-adjacent) ISA extension integrated with the
Generation 6 OoO core rather than a standalone processor:

1. **V — Vector Processing.** Vector register file, vector configuration/state (`vtype`/`vl`), a vector
   ALU/execution unit, integer arithmetic, logical ops, comparisons, load/store, mask operations,
   decoding, dependency tracking through the existing reservation stations, and retirement through the
   existing ROB.
2. **B — Bit-Manipulation.** The ratified RISC-V B extension (or the specific ratified subsets this
   project targets): bitwise ops, extract/insert, rotates, count-leading/trailing-zero, sign/zero-extend,
   carry-less ops where applicable. No invented instructions unless explicitly flagged as
   project-specific.
3. **K — Cryptography.** The applicable RISC-V K-extension instructions actually implemented (AES/SHA/
   carry-less-multiply subsets) — documented precisely as a subset, not claimed as full K compliance
   unless it is.
4. **H — Hypervisor.** RISC-V H-extension privilege mechanisms, hypervisor CSRs, guest execution/VS-mode
   support, guest/host trap and transition handling, virtualized translation where the implemented scope
   requires it. Implemented functionality clearly distinguished from deferred virtualization work.
5. **P — Packed-SIMD/DSP.** Explicitly labeled **draft/provisional** (the RISC-V P extension is not
   ratified) — never described as a ratified extension, never claimed as full spec compliance unless
   actually verified against the targeted spec version. Packed arithmetic/logical/compare/MAC ops, a
   packed-SIMD execution unit.

**Architectural integration**: all five pillars extend the *same* `design/OOOCore.v` machinery — register
renaming, PRF, reservation stations, ROB, LSQ, speculation, branch prediction, retirement — adding
specialized execution resources (vector unit, crypto unit, packed-SIMD unit) where a pillar needs them,
scheduled and retired through the existing dynamic-scheduling infrastructure. **No new processor is
created per extension**; the target architecture is one core: RV64IMAFDC + Gen6 OoO + BKVHP.

**Generation 6 itself does not change.** It remains closed as "Out-of-Order Core (v6.0)"
(`docs/adr/0058`); this ADR only rescopes the generation that follows it.

**Verification bar, set now so later phases can't quietly skip it**: decoding alone does not close a
pillar. Each of the five needs directed tests, corner-case tests, architectural-state tests, OoO
integration tests, and benchmarks with expected-result comparisons before being called done. V, K, and P
additionally need a scalar-vs-hardware performance comparison; H additionally needs privilege/trap/
guest-state validation. Coverage gaps and known limitations get documented per pillar, the same honesty
standard every Gen6 sub-phase ADR already set.

## Alternatives considered

- **Keep Generation 7 vector-only, push B/K/H/P into new Generations 11-14.** Rejected by the user
  directly — the request was to expand Generation 7 itself, not create a parallel track of new
  generations for the other extensions.
- **Treat each extension as its own standalone core.** Rejected — the user was explicit that all five
  reuse the Generation 6 OoO machinery; a separate processor per extension would duplicate the rename/
  ROB/reservation-station infrastructure Generation 6 already built and closed.

## Consequences

- `docs/ROADMAP_VISION.md`'s Generation 7 section and its evolution-summary table are rewritten to match
  (this same change).
- `handoff.md`'s Gen6-closure pointer ("check Generation 7 (Vector Processing) instead") is corrected to
  "Generation 7 (Advanced ISA Extensions)".
- Real implementation work (V/B/K/H/P, in whatever order gets picked when that work starts) proceeds as
  its own set of sub-phase ADRs, the same pattern Gen6-P1 through P6 used — this ADR is scope-setting
  only, no RTL changes.
