# Pillar K (Cryptography) — Design Spec

Date: 2026-08-11
Status: proposed, awaiting user review

## Problem

`docs/adr/0059` scopes Generation 7 as five pillars on top of `design/OOOCore.v`. Pillar V (vector,
`docs/adr/0061-0066`) and Pillar B (bit-manip, `docs/adr/0060`) are closed. This is Pillar K: the RISC-V
scalar cryptography extension (Zk family). User chose the most-ambitious subset: **full Zkn**
(`Zbkb + Zbkc + Zbkx + Zkne + Zknd + Zknh`), single-cycle combinational AES S-box, matching this
project's established pattern of always taking the bigger scope when asked.

`Zks` (SM4/SM3, `Zksed`/`Zksh`) and `Zkr` (`seed` CSR / real entropy-source hardware) stay out of scope —
`Zk` itself (`Zkn + Zkr + Zkt`) never includes `Zks`, and `Zkr` is a different problem domain (TRNG/DRBG,
not an ALU op) that ADR 0059's own wording ("AES/SHA/carry-less-multiply subsets") never named. `Zkt` is
a timing-independence *property* to verify, not an instruction to build.

## Architecture

**Reuse, not new infrastructure — Pillar B is the direct template, not Pillar V.** K-extension ops are
plain integer-register-file R-type/OP-IMM ops, same as B. They ride the existing single `RS_ALU` →
`ALU.v` combinational path (`OOOCore.v:1952 m_RS_ALU`) — no new reservation station, no new CDB port, no
new ROB completion port, no `start`/`done` handshake (confirmed: every K op, including the AES round
functions, is a fixed combinational function of its two operands — no iteration, no variable latency).
This mirrors ADR 0060 exactly: `riscv_defs.vh` (encodings + `ALUCTL_*` defines), `ALUCtrl.v` (decode),
`ALU.v` (compute), done.

**Already-implemented overlap (Zbkb shares these with the earlier Zbb slice from Pillar B — zero new
work)**: `andn`/`orn`/`xnor`/`rol`/`ror`/`rev8` already exist (`riscv_defs.vh:119-133`). Real new Zbkb
work is only `pack`/`packh`/`packw`/`brev8` (RV32-only `zip`/`unzip` excluded, RV64-only target).

**`ALUCtl` width bump, 6→7 bits.** Free 6-bit code space (~9 slots) is short of the ~22 new mnemonics
needed (clmul/clmulh=2, sha256×4, sha512×4, aes64×6, pack/packh/packw/brev8=4, xperm4/xperm8=2). Same
mechanical edit as ADR 0060's own 5→6 bump: `riscv_defs.vh`, `ALUCtrl.v` output width, `ALU.v` case
width, `OOOCore.v`'s `ALUCtl_d`/`ALUCtl_d_1`/`PAYLOAD_BITS`, `riscvpipeline.v`'s parallel wires.

**AES S-box: single-cycle combinational.** A 256-entry substitution table (forward + inverse) as a
synthesizable `case`/function inside `ALU.v`, consumed by `aes64es`/`aes64esm`/`aes64ds`/`aes64dsm`/
`aes64ks1i`. No new execution unit — same single-cycle rung as every other op in this project.
`aes64ks2` needs no S-box at all (pure word XOR).

**Encoding verification is a real implementation step, not assumed from memory.** The research pass
flagged several exact `funct3`/`funct7`/immediate-field bit patterns as unverified recall (especially
`aes64ks1i`'s `rnum` placement, the SHA/`Zbkb` unary funct7 group, `xperm4`/`xperm8`). First implementation
step fetches the real bit patterns from `riscv/riscv-opcodes` (matching every prior pillar's own stated
verification bar — ADR 0060, ADR 0062 both did this) before any RTL is written.

**Control.v**: expected near-zero change, same as B — `OPCODE_R`/`OPCODE_I` already route generically;
real decode happens in `ALUCtrl.v`. Confirmed/adjusted during the encoding-verification step once real
funct7 groupings are known (some K ops may need a new `rs2`-as-subop idiom, matching Zbb's own precedent
for `clz`/`ctz`/`sext.b` disambiguation via the already-added `rs2_c` port).

**ROB/CDB/dispatch/rename**: zero changes — `ReservationStation.v` is opcode-blind/payload-generic by
design, already proven true for all of B's own additions.

## Tooling

- `sim/tools/iss.py`: new `elif` arms in the existing R-type/OP-IMM dispatch chains (same inline-not-
  separate-module shape B used), including real AES S-box + SHA constant tables in Python.
- `sim/tools/random_gen.py`: new `K_R_TYPE`/`K_UNARY`/`K_FIXED` mnemonic lists + `kind == "k_ext"` arm,
  same shape as B's own `B_R_TYPE`/`B_SHAMT`/`B_FIXED`. Check per-mnemonic whether `OOOCore.v`'s
  hardcoded `.wordOp(1'b0)` gap (ADR 0060 finding #6, still open) excludes any K op from the `--ooo`
  fuzzer the way `b_ext_w` is excluded today.
- `sim/tools/asm.py`/`disasm.py`: round-trip case arms per mnemonic, same as B.

## Verification bar

Per ADR 0059: decoding alone doesn't close a pillar, and K specifically needs a scalar-vs-hardware
benchmark (same requirement V just closed in ADR 0066).

- Directed tests per instruction family (clmul/clmulh, SHA256, SHA512, AES encrypt round, AES decrypt
  round, AES key schedule, Zbkb pack/brev8, Zbkx xperm) plus known-answer tests against real FIPS-197
  (AES) / FIPS-180-4 (SHA) test vectors where practical — stronger than an arbitrary-value check, and
  this project hasn't had a spec-known-answer-vector class of test before, worth establishing here.
- OoO integration test(s): real dispatch/rename/RS/CDB/ROB wiring for at least one op per family,
  mirroring `tb_ooocore_vector_cmp_v6.v`'s own shape from Pillar V.
- Constrained-random cross-check against `iss.py`, all 4 existing axes (default/`--xlen 64`/`--ooo`/
  `--mmu`), same 30/30-per-axis bar recent phases used.
- Scalar-vs-hardware benchmark: a real software AES-128 single-block encrypt (or SHA-256 single-block
  compress — whichever is cheaper to hand-verify) implemented as a plain scalar bit-twiddling loop vs.
  the identical result via real `aes64es`/`aes64esm`/`aes64ks1i`/`aes64ks2` (or `sha256sig0/1`/`sum0/1`)
  instruction sequences, both run on `OOOCore.v`, cycle counts compared honestly (same "report what's
  measured, not what's hoped for" discipline ADR 0066 set — K's iterative-free single-cycle ops should
  plausibly win where Pillar V's iterative vector unit didn't, but this gets measured, not assumed).
- Zero-warning compile, full existing directed suite stays green throughout.

## Phasing (numbered steps, ADR written last)

1. **K1 — encoding verification**: pull real Zkn bit patterns (`riscv-opcodes`), resolve every
   `[VERIFY]`-flagged field from the research pass. No RTL yet.
2. **K2 — ALUCtl width bump (6→7 bits)**: parameter/width plumbing only, no new consumers, mirrors ADR
   0060's own isolated first step.
3. **K3 — Zbkc + Zbkb new ops**: `clmul`/`clmulh`, `pack`/`packh`/`packw`/`brev8` — cheap combinational
   wiring, no S-box, lowest risk, proves the decode path before the expensive part.
4. **K4 — Zknh (SHA-256/512)**: `sha256sig0/1`/`sum0/1`, `sha512sig0/1`/`sum0/1` — same risk class as K3.
5. **K5 — Zbkx**: `xperm4`/`xperm8` — combinational crossbar/mux tree.
6. **K6 — Zkne + Zknd (AES)**: the AES S-box + all six `aes64*` ops — highest-risk step, isolated alone,
   same "riskiest step alone" convention every prior phase used (A3/D3/D9/Phase-C's own precedent).
7. **K7 — tooling, benchmark, ADR**: `iss.py`/`random_gen.py`/`asm.py`/`disasm.py` completion, the
   scalar-vs-hardware benchmark, full verification sweep, ADR write-up, `docs/ROADMAP_VISION.md`/
   `handoff.md` narrow updates.

Each step gets its own directed test(s) verified before moving to the next, matching this project's
established per-step verification discipline.

## Risks / honest tradeoffs

- Several encoding fields are genuinely unverified from memory (flagged above) — K1 exists specifically
  to not let that risk reach RTL.
- AES S-box as a `case`-statement ROM is simple but not area-optimal (a Boyar-Peralta boolean-minimized
  circuit exists in real hardware crypto literature); this project is simulation-first (no real FPGA/ASIC
  timing closure has ever gated a prior phase), so area/timing optimization is explicitly deferred, not
  attempted here.
- `RS_VALU`'s cross-namespace CDB risk (ADR 0066) is vector-only and unaffected by K (K stays entirely in
  the integer namespace).

## Backlog (explicitly deferred, not silently dropped)

- `Zksed`/`Zksh` (SM4/SM3) — real spec, real future work, out of `Zkn`'s own scope entirely.
- `Zkr` (`seed` CSR, real entropy source) — different problem domain (TRNG/DRBG + NIST SP 800-90B health
  tests), not an ALU-datapath task.
- `Zkt` timing-independence verification — a property to check (no data-dependent-latency paths in the
  new ops), not an implementation item; worth a documented note in the closing ADR, not a build step.
- RV32-only forms (`zip`/`unzip`, `aes32esi/esmi/dsi/dsmi`) — this project's Pillar K target is RV64.
