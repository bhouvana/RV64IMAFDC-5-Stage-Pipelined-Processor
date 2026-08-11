# ADR 0067: Pillar K (Cryptography) — Generation 7

## Problem

`docs/adr/0059` scopes Generation 7 as five pillars on `design/OOOCore.v`. Pillar B (bit-manip,
`docs/adr/0060`) and Pillar V (vector, `docs/adr/0061-0066`) are closed. This ADR closes Pillar K: the
RISC-V scalar cryptography extension. Per the user's explicit direction (confirmed via
`AskUserQuestion`, choosing the most-ambitious option as this project's own established pattern), the
target is **full Zkn** — `Zbkb + Zbkc + Zbkx + Zkne + Zknd + Zknh` (22 new instructions) — not the
narrower "AES/SHA/carry-less-multiply subset" ADR 0059's own original wording named.

## Design

**Architecture: Pillar B's own template, not Pillar V's.** Every K instruction is a plain
integer-register-file op. All 22 ride the existing single `RS_ALU` → `ALU.v` combinational path
(`OOOCore.v:1952 m_RS_ALU`) — zero new reservation station, zero new CDB port, zero new ROB completion
port, no `start`/`done` handshake. Even the AES round functions are fixed combinational functions of
their operands (no iteration, no variable latency) — genuinely the same rung as Pillar B's `rol`/`clz`,
not `Divider.v`'s multi-cycle rung.

**`ALUCtl` widened 6→7 bits** (mirrors ADR 0060's own 5→6 bump) — ~9 free 6-bit codes were short of the
22 new codes needed.

**Encodings verified against the real `riscv/riscv-opcodes` repo** (`extensions/rv64_zknh`, `rv_zknh`,
`rv64_zkne`, `rv64_zknd`, `rv_zbkb`, `rv64_zbkb`, `rv_zbkc`, `rv_zbkx`, `rv_zbb`), fetched directly this
session — not from memory, per this project's own "no invented instructions" bar every prior pillar ADR
set.

**AES/SHA semantics verified against the ratified spec's own reference Sail model**
(`riscv/sail-riscv`, `model/riscv_types_kext.sail`, at the exact commit `4feadb75cff594db27ba94c586e0ad6895f9fa50`
`riscv/riscv-crypto`'s own `.gitmodules` pins) — this is the literal ground truth the ratified spec's own
prose is generated from, not a third-party reimplementation. The AES S-box tables, MixColumn GF-multiply
formula, Rcon table, and the RV64 half-state ShiftRows byte-permutation formula were all copied verbatim
from this source into both `design/ALU.v` and `sim/tools/iss.py` (as two independent transcriptions, not
one imported into the other — a real cross-check needs genuinely separate sources).

**AES S-box: single-cycle combinational**, per the user's own explicit choice (`AskUserQuestion`) — a
256-entry ROM (`case`-free array lookup) inside `ALU.v`, not a new multi-cycle execution unit.

**The exact register-half convention for AES (which state/key half plays `rs1` vs `rs2` in each call) is
not fully specified in prose anywhere** — the ratified spec gives the per-instruction pseudocode
precisely, but the *caller's own* convention for splitting a 128-bit AES state/key across two 64-bit
registers across a real multi-round sequence is left to the assembler-writer. This was determined
**empirically, not by hand-derivation**: built a standalone Python model using the exact same S-box/
Rcon/MixColumn/ShiftRows functions this ADR's own RTL uses, brute-force-searched the register-half
layout against the real FIPS-197 Appendix C.1 AES-128 known-answer test until a consistent convention
was found, then transcribed that verified convention into both `design/ALU.v`'s testbench and the
tooling closure below. Hand-derivation was attempted first and repeatedly produced internally-plausible
but factually wrong conventions (documented in the session's own working notes) — this is a real,
worked example of why this project's "verify by running, not by hand-trace alone" precedent
(`docs/adr/0009`) matters even for something as precisely specified as a ratified ISA extension.

## Real bugs/findings

Building this pillar's own verification infrastructure found **3 real bugs**, none by code review alone —
this project's own established pattern (every prior pillar's closure ADR found real bugs exactly this
way, not before):

**1. Missing `ALUCtrl.v` decode arms for the AES R-type ops (Pillar K's own bug).** The AES round/key-
schedule R-type instructions (`aes64esm`/`es`/`dsm`/`ds`/`ks2`) had real `ALU.v` compute logic (Task 6)
but no `ALUCtrl.v` decode arm at all — reachable only by driving `ALUCtl` directly in a unit testbench,
never from a real instruction word. Found while writing the OoO integration test (Task 7), which needs
real decode to exercise anything. Fixed with 5 new `funct7` defines + decode arms, all `funct3=000`,
distinguished purely by `funct7` (verified against `rv64_zkne`/`rv64_zknd`).

**2. `design/ALU.v`'s `ALUCTL_SLLI_UW` (`slli.uw`, Pillar B, `docs/adr/0060`) — real, pre-existing,
found by this pillar's own constrained-random cross-check.** The old implementation computed
`A[31:0] << shamt` into a 32-bit scratch register *before* zero-extending to XLEN, silently truncating
any bit shifted past bit 31. Real spec semantics zero-extend `A[31:0]` to XLEN first, then shift within
that full width. Never triggered by any prior random seed (Pillar B's own coverage apparently never
generated a `shamt >= 32` with a nonzero high bit in play) until Pillar K's own `random_gen.py`
additions shifted the RNG sequence enough to hit it on `--mmu --xlen 64` seed 21.

**3. `design/ImmGen.v`'s `OPCODE_OP_IMM_32` arm — a second, independent, pre-existing bug in the SAME
instruction, found while root-causing bug 2.** `slli.uw` shares `funct3=001` with plain `slliw`, and this
arm gave every `funct3=001` op on this opcode only a 5-bit shamt (`inst[24:20]`) — correct for `slliw`,
but `slli.uw`'s own real shamt is 6 bits (`inst[25:20]`, one bit wider — `riscv_defs.vh`'s own
`FUNCT6_ZBA_SLLIUW` comment already documented this, `ImmGen.v` never implemented it). Silently dropped
the shamt's own top bit for any `slli.uw` with `shamt >= 32`. Fixing bug 2 alone was not sufficient —
confirmed by re-running the same failing seed, still wrong — both were real, independent, and both
needed fixing (same "don't assume one fix covers a compound failure" discipline `docs/adr/0066`'s own
two-bug finding established).

Neither bug 2 nor 3 is a Pillar K correctness issue — both are in `slli.uw`'s own implementation, which
predates this pillar entirely. Fixed here because they were found while building this pillar's own
infrastructure, matching this project's "fix real bugs found by running, don't work around them" bar.

## Validation strategy

- **Directed unit tests**, one per instruction family: `tb_alu_zbkc_zbkb_unit.v` (8 checks) +
  `tb_aluctrl_zbkc_zbkb_unit.v` (9 checks), `tb_alu_zknh_unit.v` (16 checks), `tb_alu_zbkx_unit.v`
  (6 checks), `tb_alu_zkne_zknd_unit.v` (5 checks, including the full AES-128 KAT).
- **A real known-answer test, not just per-instruction spot checks**: the AES-128 FIPS-197 Appendix C.1
  vector (the world's most widely-published AES test vector) runs end-to-end through `ALU.v`'s own
  `aes64ks1i`/`aes64ks2`/`aes64esm`/`aes64es` instruction implementations (10 rounds, real key schedule)
  and matches the published ciphertext exactly — re-run independently through `iss.py`'s own separate
  Python transcription, also matches.
- **OoO integration** (`tb_ooocore_pillar_k_v7.v`): real dispatch/rename/`RS_ALU`/CDB/ROB-retire wiring,
  one instruction per family, through `OOOCore.v` itself (found bug 1 above).
- **Constrained-random cross-check against `iss.py`**: 25/25 clean on all 3 axes any K mnemonic is ever
  generated on (default+`--xlen 64`, `--ooo --xlen 64`, `--mmu --xlen 64` — `random_gen.py`'s own `k_ext`/
  `k_ext_w` kinds are gated to `xlen>=64` only, matching this pillar's real scope, see Alternatives below).
  Found bugs 2 and 3 above.
- **Scalar-vs-hardware benchmark**: real measured cycle counts, `sim/benchmarks/crypto/`. Scalar
  `clmul`-equivalent shift-XOR sequence = 12 cycles; one real `clmul` = 7 cycles (−41.7%). Unlike Pillar
  V's own iterative vector datapath (which *lost* to scalar on its own benchmark, `docs/adr/0066`), K's
  single-cycle combinational ops win here — a real, honestly-measured result, not assumed in advance.
- **Zero-warning compile** (`iverilog -Wall -g2005 -I design -tnull design/*.v`) and **152/152 directed
  suite** (up from 146) throughout every step.

## Alternatives considered

- **Practical core (`Zkne+Zknd+Zknh+Zbkc` only) instead of full Zkn.** Rejected — the user explicitly
  chose the most-ambitious option, matching this project's own established pattern of always picking
  wider scope when asked (Pillar B's own full-`Zba+Zbb+Zbs` choice, Pillar V's own full-LMUL-grouping
  choice).
- **`Zks` (SM4/SM3) and `Zkr` (entropy source).** Rejected — `Zk` itself (`Zkn + Zkr + Zkt`) never
  includes `Zks`, and `Zkr` needs a real TRNG/DRBG (a different problem domain entirely, not an
  ALU-datapath task) — neither was in ADR 0059's own "AES/SHA/carry-less-multiply" wording either.
- **A new multi-cycle AES execution unit** (mirroring `Divider.v`/`RS_DIV`). Rejected per the user's own
  explicit choice — every AES round/key-schedule function is structurally combinational (no iteration),
  so a multi-cycle unit would add real complexity (new RS, new CDB port) for no correctness or
  architectural need this project's simulation-first history has ever demanded.
- **Full scalar-vs-hardware AES-128 benchmark** (matching Pillar V's own vecadd benchmark's scope).
  Considered and scoped down to `clmul` — a general scalar AES-128 reference needs either a software
  S-box loaded from a data section (`asm.py` has no `.byte`/`.data` directive) or a much larger
  boolean-circuit unrolling, neither a small addition. `clmul`'s own scalar reference is a plain
  multi-term shift-XOR sequence needing neither, and is still a real, representative K primitive —
  consistent with this project's own "small, hand-verifiable benchmark kernel" precedent
  (`docs/adr/0066`'s own 8-element `vecadd` kernel). A full AES-128 scalar-vs-hardware benchmark remains
  real, honest future work (see below), not silently dropped.
- **XLEN=32 support for the RV64-only-by-spec encodings that share an opcode with XLEN=32-valid ops**
  (`aes64ks1i`/`aes64im`/`sha512*`, which share `OPCODE_I` with `sha256*`, real at both widths). A real
  `Control.v`-level funct-group XLEN trap (mirroring `OPCODE_OP_32`'s own clean gate) was considered and
  rejected as out of scope for this pass — this project has no existing precedent for that specific
  mechanism (an XLEN gate on a *sub-encoding* sharing an already-XLEN-independent opcode, as opposed to a
  whole separate opcode), and Pillar K's own real target is XLEN=64 throughout (matching Pillar V's own
  RV64 focus). Documented as a known, narrow gap below, not silently unhandled: at XLEN=32 these specific
  encodings would decode and execute with meaningless (not illegal-trapped) results.
  `random_gen.py` never generates them off the `xlen>=64` axis, so the constrained-random harness never
  exercises this gap.

## Future improvements

- `Zksed`/`Zksh` (SM4/SM3) — real spec, real future work, entirely out of `Zkn`'s own scope.
- `Zkr` (`seed` CSR, real entropy source) — different problem domain (TRNG/DRBG + NIST SP 800-90B health
  tests), not an ALU-datapath task.
- `Zkt` timing-independence verification — a property to check (every new op here is a fixed-shape
  combinational function with no data-dependent latency path, so nothing in this pillar's own design
  introduces a violation), not a build item; worth a dedicated timing-side-channel review pass if this
  core is ever targeted at a real threat model where it matters, not attempted here.
- The XLEN=32 decode-trap gap for `aes64ks1i`/`aes64im`/`sha512*` (see Alternatives above).
- A full scalar-vs-hardware AES-128 benchmark (needs `asm.py` `.byte`/`.data` directive support first).
- RV32-only forms (`zip`/`unzip`, `aes32esi/esmi/dsi/dsmi`) — this project's Pillar K target is RV64.

## Consequences

- `docs/ROADMAP_VISION.md`'s Generation 7 pillar-status table updated: Pillar K CLOSED.
- `handoff.md`'s "next: Pillar K" pointer corrected — Generation 7 is now V+B+K closed, H and P remain.
- 152/152 directed suite (up from 146 at Pillar V's own closure), zero-warning compile throughout.
