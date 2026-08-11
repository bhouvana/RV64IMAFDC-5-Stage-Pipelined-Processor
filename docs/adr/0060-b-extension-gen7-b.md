# ADR 0060: B extension — Zba+Zbb+Zbs (Generation 7, Pillar B)

## Problem

`docs/adr/0059` scoped Generation 7 as five ISA-extension pillars (V/B/K/H/P) built on top of the existing
`design/OOOCore.v` machinery, with the pillar order left open ("in whatever order gets picked when that
work starts"). The user picked **B — Bit-Manipulation** first: pure scalar ALU ops, no new register file
or execution unit, the fastest real path to prove "a new ISA extension rides OOOCore.v's existing
reservation stations/ROB without new plumbing" before betting on the much larger V pillar.

Scope, confirmed via `AskUserQuestion`: the **full ratified B extension** — Zba (address-generation
shift-add), Zbb (basic bit-manipulation), Zbs (single-bit) — not a curated subset. All encodings verified
against the real, authoritative `riscv/riscv-opcodes` repo (`extensions/rv_zba`, `rv_zbb`, `rv_zbs`,
`rv32_zbb`, `rv64_zbb`, `rv64_zba`, `rv32_zbs`, `rv64_zbs`), not from memory alone — per `docs/adr/0059`'s
own "no invented instructions" bar.

**`zext.h` is explicitly out of scope.** The ratified spec defines it as a pseudo-op of Zbkb's `pack`
instruction (a different, crypto-adjacent extension this project hasn't selected) — not a real Zbb
encoding. Inventing a standalone encoding for it would itself violate the "no invented instructions" bar.
Deferred to whichever future pillar picks up Zbkb (likely alongside K/cryptography), not silently dropped.

## Design

### Reuse, not a new execution unit

Every one of the ~39 mnemonics (23 base + 16 RV64-only word-variants) decodes through the SAME shared
`Control.v` → `ALUCtrl.v` → `ALU.v` path both `design/riscvpipeline.v` (the older in-order core) and
`design/OOOCore.v` (the Gen6 OoO core) already use — zero new reservation station, zero new ROB
completion port, zero new CDB snoop port, zero new dual-issue exclusion. This is the same rung the
existing custom `ctz` op already proved (see Real bugs/findings below for why `ctz` itself moved).
Because `ALUCtrl.v`/`ALU.v`/`riscv_defs.vh` are genuinely shared files, both cores gained the whole
extension from the same edit — not extra scope, just a structural consequence of touching shared decode.

### `ALUCtl` widened 5→6 bits

Only 4 free 5-bit codes existed (`riscv_defs.vh`'s own `ALUCTL_*` table); B needed ~26 new codes. Widened
uniformly across `riscv_defs.vh`, `ALUCtrl.v`, `ALU.v`, and every consumer wire in `OOOCore.v`
(`ALUCtl_d`/`ALUCtl_d_1`, `PAYLOAD_BITS`, the packed-payload slice indices) and `riscvpipeline.v`
(the `ALUCtl` wire, the `` `ifdef COVERAGE `` functional-coverage array). A single mechanical width
change, not a new encoding scheme.

### `ALUCtrl.v` gained a `rs2_c` input (`inst[24:20]`)

Most B-ext I-type ops discriminate via `funct6` (`funct7[6:1]`) — the same idiom the existing SRL/SRA
split already established (RV64's 6-bit shamt eats what would be funct7's low bit at RV32). But
`clz`/`ctz`/`cpop`/`sext.b`/`sext.h` share ONE `funct6`+`funct3` combination and differ only in this
rs2-like field — the exact "rs2 field doubles as a sub-op selector" idiom `riscvpipeline.v:1579` already
documents for F-extension's `fcvt.w.s`/`fcvt.wu.s`. Wired from the already-existing `rs2_areg`
(`OOOCore.v`) / `readReg2_regde` (`riscvpipeline.v`) wires — no new extraction needed, just a new
`ALUCtrl` port.

### RV64-only word variants: reuse via `wordOp`, not dedicated codes, wherever possible

`clzw`/`ctzw`/`cpopw`/`rolw`/`rorw`/`roriw` share their base op's `ALUCtl` code, disambiguated purely by
the existing `wordOp` signal — the exact pattern `addw` already established for `ALUCTL_ADD`. Only
`add.uw` and `slli.uw` got their own dedicated codes (`ALUCTL_ADD_UW`/`ALUCTL_SLLI_UW`): their semantics
(zero-extend the SOURCE before computing, not truncate-then-sign-extend the RESULT) are genuinely
different from `wordOp`'s existing meaning, and their encodings don't collide with anything else, so a
dedicated code is both necessary and free. `sh1add.uw`/`sh2add.uw`/`sh3add.uw` do NOT get dedicated codes —
see Real bugs/findings.

## Real bugs/findings

**1. `ctz` retired from its custom opcode — it now collides with real `andn`.** This core's existing
`ctz` lived at `OPCODE_CUSTOM` (`0001011`), `FUNCT7_ALT`+`funct3=111` — but `ALUCtrl.v`'s R-type case table
is opcode-blind (keyed only on `{funct7,funct3}` once `ALUOp==RTYPE`, which BOTH `OPCODE_R` and
`OPCODE_CUSTOM` produce). Real Zbb `andn` uses `OPCODE_R` with the EXACT same `{FUNCT7_ALT,111}` bit
pattern — a real, silent collision if both encodings stayed live. Fixed at the root: `ctz` moved to its
real Zbb I-type slot (shared with `clz`/`cpop`/`sext.b`/`sext.h`), `Control.v`'s `OPCODE_CUSTOM` arm
deleted entirely (falls to the existing `default: illegalOpcode=1`, correctly reserved per spec), and
`sim/tools/{iss,asm,disasm}.py` all had their custom-ctz special cases removed and real-encoding paths
added. Caught by direct code reading before writing any RTL, not by running.

**2. `ALUCTL_CTZ` had no `wordOp` branch at all.** Harmless while `ctz` was reachable only via the retired
custom opcode (no W-suffixed sibling ever existed to need one) — `ctzw` (this phase's own addition) shares
the same `ALUCtl` code with `wordOp=1` and needs the 32-bit-only count, not the full-XLEN one.
`ctzw x18,x0` (all-zero input) silently gave 64 instead of 32. Found by `run_random_tests.py --xlen 64`
(55/60 → 60/60 after fix), mirrors `ALUCTL_CLZ`/`ALUCTL_CPOP`'s already-correct `wordOp` split.

**3. `add.uw` had no `ALUCtrl.v` decode arm at all.** Its `funct7` (`0000100`) doesn't collide with
anything — the R-type case arm was simply never written. Every `add.uw` trapped illegal-instruction.
Found the same random-test run; root-caused by isolating a 2-instruction minimal repro
(`add.uw`+`orc.b`) against a throwaway testbench reading `CSR.v`'s own `mcause`/`mepc` directly — `mcause=2`
(illegal instruction) at the `add.uw`'s own PC confirmed the trap before touching any fix.

**4. `sh1add.uw`/`sh2add.uw`/`sh3add.uw` share `funct7`/`funct3` bit-for-bit with `sh1add`/`sh2add`/
`sh3add` by real spec design** (opcode alone disambiguates OP-32 from OP — `ALUCtrl.v` has no opcode
visibility). The three dedicated `ALUCTL_SH*ADD_UW` codes this phase originally wrote were consequently
unreachable — every `sh*add.uw` silently decoded and executed as the plain register-width form, a wrong
VALUE (not a trap), the more dangerous class of bug. Fixed by retiring the three dedicated codes;
`ALU.v`'s existing `SH1ADD`/`SH2ADD`/`SH3ADD` cases are now `wordOp`-aware instead, mirroring exactly how
`addw` already reuses `ALUCTL_ADD`.

**5. `slli.uw` had no decode arm either** — fell through to plain `slli`, silently sign-extending instead
of zero-extending. Same class as #3, fixed the same way (added the missing `funct6`-keyed arm).

**6. `OOOCore.v`'s single `ALU` instantiation hardcodes `.wordOp(1'b0)`.** A real, PRE-EXISTING gap this
phase's own testing exposed but does not fix (architecturally out of scope for a B-extension phase) — word-
truncated ALU results were never actually wired live in the OoO core at all, the same root cause
`random_gen.py`'s own long-standing comment already flags for why the plain `rw`/`iw` (`addw`/`sllw`/etc)
family stays excluded from the `--ooo` fuzzer regardless of XLEN. This phase's new `b_ext_w` kind
(`clzw`/`ctzw`/`cpopw`/`rolw`/`rorw`/`roriw`/`add.uw`/`sh*add.uw`/`slli.uw`) hit the exact same wall
(`--ooo --xlen 64`: 53/60 before exclusion) and was excluded from the `--ooo` fuzzer to match, with a
comment pointing at the real root cause for whoever picks this up. The plain (non-`w`) `b_ext` kind is
unaffected — `wordOp=0` is exactly correct for those, confirmed by 60/60 at `--ooo --xlen 64` after the
exclusion.

**7. `run_random_tests.py --mmu --xlen 64` needs its own default `--mem-size` (16384), not a hand-picked
smaller one.** A real self-inflicted verification-invocation mistake, not an RTL bug: passing
`--mem-size 512` (needed to fit larger `--xlen 64` non-MMU programs past the default 128-byte budget)
into the SAME command for the `--mmu` axis broke Sv39's own page-table layout, producing catastrophic,
identical-looking failures (0/60) that traced back to `run_random_tests.py`'s own documented real default
(`16384` for `--xlen 64 --mmu`, `docs/adr/0033`'s own Sv39 sizing) — omitting the override and letting the
tool pick its own correct default gave 60/60 immediately. Recorded here so a future session doesn't
re-diagnose the same red herring.

## Testing

- Full directed suite: **137/137** (up from 135/135 — 2 new tests: `bext_b10` on the scalar core,
  `ooocore_bext_b10` on the OoO core, each 25 hand-derived-then-ISS-cross-checked checks covering every
  base, non-`w` mnemonic).
- Zero-warning full-design compile: `iverilog -Wall -g2005 -I design -tnull design/*.v`.
- `sim/tools/iss.py` unit-verified directly (Python, no RTL) against hand-computed values for `andn`/
  `rori`/`ctz`/`clz`/`cpop`/`min`/`sh1add`/`bset`/`rev8` before trusting it in the harness.
- `sim/tools/asm.py`/`disasm.py` round-trip verified (assemble → disassemble → compare mnemonic) for all
  28 base mnemonics.
- Constrained-random cross-check (`sim/tools/run_random_tests.py`), every axis: scalar default 100/100,
  scalar `--xlen 64` 60/60, `--ooo` default 60/60, `--ooo --xlen 64` 60/60, Sv32-MMU 60/60, Sv39-MMU
  60/60 — all after the fixes in Real bugs/findings #2–#6 above (the `--xlen 64` axes were the ones that
  actually caught them; the directed tests and the default-XLEN random sweep both passed clean from the
  first run, underscoring why the RV64-only word-variant coverage mattered).
- No scalar-vs-hardware benchmark comparison — not required for pillar B by `docs/adr/0059` (only V/K/P
  need it); `sim/tools/bench_runner.py`'s existing `--compare-*` flags are all swappable-RTL-parameter
  comparisons, not software-sequence-vs-instruction ones, so a real comparison would need new tooling
  infrastructure this phase didn't build — flagged honestly below, not silently skipped.

## Alternatives considered

- **Zbb-only subset, deferring Zba/Zbs.** Presented via `AskUserQuestion`; user picked full B (most
  ambitious, consistent with this project's own established pattern of choosing the more ambitious option
  every time this question has come up).
- **Keep the custom-opcode `ctz` alongside a real Zbb `ctz` as two separate encodings for the same op.**
  Rejected — needless duplication once the real encoding exists, and the custom opcode's own R-type slot
  is needed for real `andn` anyway (see finding #1); no reason to keep two paths to identical semantics.
- **Give `ALUCtrl.v` real opcode visibility (a new input) to resolve the OP-32-vs-OP funct7/funct3 sharing
  properly, instead of the `wordOp`-reuse pattern.** Rejected as unnecessary scope growth — the existing
  `addw`/`ALUCTL_ADD` precedent already establishes `wordOp`-based disambiguation as this codebase's own
  convention for exactly this situation; introducing a parallel, second disambiguation mechanism
  (opcode-awareness) alongside the existing one (`wordOp`) would be two ways to solve the same problem for
  no real gain.

## Future improvements

- **`zext.h`** — real spec pseudo-op of Zbkb's `pack`, deferred to whichever future pillar implements
  Zbkb (likely bundled with K/cryptography, since Zbkb/Zbkc/Zbkx are the crypto-adjacent bit-manip
  extensions). Not silently dropped — flagged here and in the Problem section above.
- **`OOOCore.v`'s hardcoded `wordOp=1'b0`** (finding #6) — a real, pre-existing gap spanning the ENTIRE
  word-suffixed family (`addw`/`sllw`/... and now this phase's own `b_ext_w` kind), not something this
  phase's own scope should fix. Wiring real `wordOp` derivation into `OOOCore.v`'s single-issue `m_ALU`
  path (and confirming the dual-issue slot doesn't need its own copy) is real, scoped future work — likely
  worth its own small phase given it currently blocks correctness for an entire pre-existing instruction
  family in the OoO core, not just B-extension's new additions.
- **Scalar-vs-hardware B-extension benchmark** — genuinely useful (e.g. `cpop` vs. a software
  shift-and-count loop, `rol`/`ror` vs. shift-or hashing) but needs new `bench_runner.py` comparison-mode
  infrastructure (instruction-substitution, not swappable-RTL-parameter comparison) this phase didn't
  build, and isn't required by `docs/adr/0059` for pillar B specifically.
