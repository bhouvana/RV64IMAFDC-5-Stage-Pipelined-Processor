# ADR 0061: Vector config + register-file triad — Generation 7, Pillar V, Phase 1

## Problem

`docs/adr/0059` scoped Generation 7's Pillar V (RISC-V Vector) as config/vtype-vl state, a vector
ALU, integer arithmetic/logical/compare, load/store, and masking, all riding `design/OOOCore.v`'s
existing OoO machinery. User confirmed the most-ambitious options across the board via
`AskUserQuestion`: VLEN=512, full LMUL (fractional + grouped), and a V1 breadth of
config+integer-arith+unit-stride-load/store+masking.

Research (this session, three parallel Explore agents against the real RTL/tooling/ADR precedent)
found that reaching that full V1 breadth needs a genuinely novel micro-op-cracking dispatch
sequencer (an LMUL-group vector instruction crosses N architectural sub-registers, N independent
ROB/RS entries), an iterative per-element vector ALU (VLEN=512 has no honest wide-parallel
datapath at this project's scale), a ROB destination-class widening (3rd mutually-exclusive
register-file class), a new CDB/completion port, and LSQ vector-completion routing — real,
substantial work that cannot be written as complete, placeholder-free RTL in one sitting alongside
the register-file-class addition itself.

**Decision, made explicit in the implementation plan
(`C:\Users\poorn\.claude\plans\gen7-v-vector-phase1.md`) before any RTL**: split Pillar V into
staged phases, mirroring exactly how Generation 6 itself was never one plan but A-through-P. This
is Phase 1 only — config instructions (`vsetvli`/`vsetivli`) and the vector register-file triad.
Vector arithmetic (the crack sequencer + `VALU.v`), masking, and `vle`/`vse` load/store are
explicitly deferred to Phase 2/3, not silently dropped. This is scope *sequencing*, not scope
*reduction* — the full V1 breadth the user picked is still the target across all phases.

## Design

### `vtype`/`vl`/`vstart`/`vcsr` CSR scaffolding (`CSR.v`)

New storage (`vstart`/`vtype_fields`/`vill`/`vl`/`vxrm`/`vxsat`) follows this file's own established
3-part idiom exactly: a case-based read-mux arm, an independent write-chain arm. `vstart` is an
ordinary csrrX-writable CSR; `vtype`/`vl` are written ONLY through a new dedicated side-channel port
(`vec_cfg_write_en`/`vec_cfg_new_vtype`/`vec_cfg_new_vill`/`vec_cfg_new_vl`), mirroring this file's
own existing precedent of trap-entry CSRs (`mepc`/`mcause`) having dedicated write ports separate
from the generic `csr_write_en` mux — real spec technically allows plain `csrrw` to `vl`/`vtype`
too, deliberately not built this phase (flagged below, not silently missing).

### Vector register-file triad (`FreeList_Vec`/`RAT_Vec`/`PRF_Vec`)

Reuses `FreeList.v`/`RegisterAliasTable.v`/`PhysicalRegisterFile.v` completely unmodified — all
three confirmed genuinely width/`HARDWIRE_REG0`-agnostic by direct read before writing any RTL.
Mirrors Gen6-H's own float triad (`docs/adr/0047`) exactly: `HARDWIRE_REG0`/`HARDWIRE_PREG0`=0
since v0 is the real, addressable RVV mask register, not hardwired-zero. `PhysicalRegisterFile.v`
instantiated with `XLEN(VLEN)` — it was already parameterized generically enough that a 512-bit
vector register file needed zero module changes, a real structural gift confirmed by reading the
module before assuming. No dispatch wiring yet (`alloc_en0`/`wen0`/etc. all tied 0) — dead hardware
until Phase 2's own crack sequencer.

### `vsetvli`/`vsetivli`: real computation, reusing `RS_ALU`

Encodings fetched and confirmed against the real `riscv/riscv-opcodes` repo (`extensions/rv_v`)
this session, not from memory, per `docs/adr/0060`'s own "no invented instructions" bar. Both forms
place `{vma,vta,vsew[2:0],vlmul[2:0]}` at the identical instruction bit positions (hand-derived and
verified: `vsetvli`'s `zimm11=inst[30:20]` and `vsetivli`'s `zimm10=inst[29:20]` both put that 8-bit
pattern at `inst[27:20]`).

`vl = min(AVL, VLMAX)` reuses the existing `RS_ALU` dispatch/wait/issue/CDB path exactly like
`lui`/`auipc`/`jal`/`jalr`/`csrrX` (Gen6-O, `docs/adr/0051`) — zero new reservation station, zero
new ROB port, zero new CDB port. `VLMAX` is computed combinationally from the instruction's own
immediate bits at dispatch (`VLEN >> ((3+vsew) - $signed(vlmul))`, hand-derived and verified against
5 worked examples before trusting it in RTL — `$signed(vlmul)` directly gives the real spec's
two's-complement `log2(LMUL)` exponent) and packed directly into the payload's existing `imm` slot,
overriding `ImmGen.v`'s own (irrelevant, always-0-for-this-opcode) decode — no `ImmGen.v` change
needed at all. A new 1-bit payload field (`is_vsetvl`) selects a `min(a,b)` override of `alu_out` at
issue time instead of `ALU.v`'s own (harmless, discarded) result — `ALUCtrl.v`/`ALU.v`/`Control.v`'s
`ALUOp` encoding are completely untouched, avoiding the fully-saturated 2-bit `ALUOp` field entirely.

`rs1==x0`'s two real spec special cases (`rd!=x0`: AVL=VLMAX; `rd==x0`: AVL=current `vl`) reuse the
SAME forced-operand-A mechanism Gen6-O's own `lui`/`auipc`/`jal`/`jalr`/`csrrX` already established.

Single-outstanding (mirrors `csr_inflight_valid_r` exactly) — dispatch of everything else stalls
until a `vsetvli`/`vsetivli` resolves. The CSR write fires at ISSUE, not retire, mirroring
`csr_write_fire`'s own exact timing: nothing else can dispatch until this entry retires regardless
(the new `vec_cfg_inflight_valid_r` term in `dispatch_stall`), so firing the moment the real result
is known changes nothing observable and needs no extra latch for the `vl` value itself.

`vsetvl` (register-sourced vtype, `inst[31:25]==7'b1000000`) is explicitly deferred — it needs a
second PRF register read for `rs2`'s own vtype value, not an immediate-decode path, and is
genuinely disjoint from every legal `vsetvli`/`vsetivli` encoding. A `vsetvl` instruction traps
illegal-instruction (real, correct behavior for a recognized-but-unimplemented encoding region),
never silently misdecodes.

## Real bugs/findings

**Gen6-K's own dual-issue slot1 had no `vsetvli` awareness at all.** A `vsetvli` landing in the
`pc+4` slot alongside a plain-ALU slot0 was silently swept into slot1's own vsetvli-unaware payload
pack (`rs_disp_payload1` has no `is_vec_cfg` override, no VLMAX substitution) — producing
`AND(AVL,0)=0` for both directed-test cases regardless of AVL, since `ImmGen.v` has no real decode
for `OPCODE_V` and slot1's own payload pack falls through to `imm_d_1`'s default-0. Root-caused via
direct `pc_r`/`inst_word`/`is_vec_cfg` cycle tracing (dual-issue advanced `pc_r` by 8 in one cycle,
skipping the `vsetvli`'s own dispatch as an independent step entirely) — fixed by adding
`isVecCfg_c_1` to slot1's own Control.v instance and excluding it from `slot1_is_plain_alu`, the
exact same treatment Gen6-O already gives `lui`/`auipc`/`jal`/`jalr`/`csrrX` there. Found by running
the directed test before trusting it, not shipped silently broken.

Two Icarus unsized-parameter-override width warnings (same class of bug `docs/adr/0048`'s own
`SP_INIT` finding already named): `m_PRF_Vec`'s own `SP_INIT` override and the new `VLEN` module
parameter's own unsized default both self-determined 32-bit width regardless of the real 512-bit
context, corrupting a bit-select in `vec_cfg_vlmax`. Fixed at the root (explicit width on both)
before either could matter functionally, not just silenced.

## Testing

- Full directed suite: **138/138** (up from 137/137 — new `ooocore_vsetvli_v1` test, 2/2 checks,
  hand-encoded via `sim/tools/asm.py`'s existing `word` raw-encoding directive since `asm.py` has no
  `vsetvli`/`vsetivli` mnemonic support yet, same precedent `ooocore_amo_j1.s` already established
  for `lr.d`).
- Zero-warning full-design compile: `iverilog -Wall -g2005 -I design -tnull design/*.v` (the only
  warnings are expected dangling new `CSR.v` ports at `riscvpipeline.v`'s own instantiation, which
  intentionally does not get Pillar V — matches `docs/adr/0050`'s own established "unconnected new
  port at a non-target instantiation site" precedent).
- Constrained-random cross-check, confirming zero regression to the shared dual-issue/payload
  plumbing this phase touched: scalar default 60/60, scalar `--xlen 64` 60/60, `--ooo` default
  60/60 (the axis that actually would have caught the dual-issue bug above, had it not already been
  found by the directed test first).

## Alternatives considered

- **Attempt the full V1 breadth (config+arith+load/store+masking) in one plan/session.** Rejected
  after the research phase's own honest cost estimate — the crack sequencer, iterative VALU, ROB
  widening, and LSQ integration are each real, substantial, novel design work; attempting all of it
  alongside the register-file-class addition with zero placeholders in one sitting would have
  produced either an unreviewable mega-diff or shipped genuinely unverified RTL. Staging matches
  Generation 6's own A-through-P precedent directly.
- **Give `vsetvli` its own dedicated ALUOp/ALUCtl encoding.** Rejected — `ALUOp` is a fully
  saturated 2-bit field (all 4 values already used); the existing forced-operand escape hatch
  (Gen6-O) already solves exactly this class of problem with zero encoding-space cost.
- **Fire the CSR write at retire instead of issue.** Considered, then rejected once traced through:
  single-outstanding already blocks all future dispatch until retire regardless, so firing earlier
  (at issue, the moment the real value is known) is observably identical and avoids an unnecessary
  extra latch for the `vl` value.

## Future improvements

- **Phase 2**: the vector-crack dispatch sequencer, `RS_VALU`/`VALU.v` (iterative, one element/cycle,
  reusing `Divider.v`'s own multi-cycle start/busy/done shape), ROB destination-class widening
  (1-bit `is_fp_dest` → 2-bit `dest_class`), a new 6th CDB/completion port, real integer
  arithmetic/logical ops (`vadd`/`vsub`/`vrsub`/`vand`/`vor`/`vxor`/`vmin`/`vmax`/`vminu`/`vmaxu`,
  `.vv`/`.vx`/`.vi` forms — all real encodings already fetched and verified this session) with
  `v0.t` masking.
- **Phase 3**: `vle`/`vse` unit-stride load/store through `LoadStoreQueue.v` (needs a 3rd
  completion-destination-file route and a genuine multi-element inner loop) — deferred out of
  Phase 2 too, mirroring Gen6-H's own `FLW`/`FSW` deferral precedent.
- **`vsetvl`** (register-sourced vtype) — real spec instruction, deferred as noted above.
- **Plain `csrrw`/`csrrs`/`csrrc` to `vl`/`vtype` directly** (bypassing `vsetvli`) — real spec-legal
  but not generated by this core's own dispatch path in any phase's current scope; flagged, not
  silently unsupported.
- **`vxrm`/`vxsat`** — real storage exists (this phase), but no fixed-point op reads or writes them
  meaningfully yet; a real future consumer once/if the P (packed-SIMD) or a fixed-point V subset
  lands.
