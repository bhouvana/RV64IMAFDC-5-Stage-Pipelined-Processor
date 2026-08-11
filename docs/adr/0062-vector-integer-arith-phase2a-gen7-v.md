# ADR 0062: Vector integer arithmetic (LMUL=1) — Generation 7, Pillar V, Phase 2a

## Problem

`docs/adr/0061` closed Phase 1 (vsetvli/vsetivli + the vector register-file triad), deferring real
vector arithmetic, full LMUL grouping, masking, and load/store to later phases. This phase closes the
first of those: real integer vector arithmetic/logical ops end-to-end on `design/OOOCore.v`, scoped to
LMUL=1 only (one macro instruction = one physical vector register, no grouping) — the same "prove the
skeleton single-issue/single-register first" staging Gen6-D used before Gen6-K widened to dual-issue.

## Design

`VALU.v` is genuinely new hardware — no wide-parallel datapath exists at VLEN=512 scale, so it iterates
one element per cycle (mirrors `Divider.v`'s own multi-cycle start/busy/done shape), using variable-shift
+ mask instead of indexed part-select (Verilog requires a compile-time-constant width for `[base +:
width]`; SEW is runtime-variable). `RS_VALU` is a plain new instance of the existing `ReservationStation.v`
— zero module changes, its own 4 CDB ports cover self (back-to-back vector chaining) plus the 3 existing
integer completion sources (`.vx`'s scalar operand can be in-flight). `ReorderBuffer.v` gained one
ADDITIVE bit (`alloc_is_vec_dest0/1`/`e_is_vec_dest`/`retire_is_vec_dest0/1`) rather than widening the
existing `e_is_fp_dest` into a shared field — kept every already-shipped int/float retire wire completely
untouched, and a genuinely new 6th completion port (`complete_en5`/`complete_tag5`, mirrors `docs/adr/0055`'s
own 5th-port precedent). `PhysicalRegisterFile.v` gained a 12th read port (`raddr11`) — every one of the
existing 11 was already claimed, and RS_VALU's own `.vx` cross-file scalar read at issue time (mirrors
`FMV.W.X`'s established cross-file pattern, Gen6-H) needed a genuinely new one.

Real mnemonics: `vadd`/`vsub`/`vrsub`/`vand`/`vor`/`vxor`/`vmin`/`vmax`/`vminu`/`vmaxu`, `.vv`/`.vx`/`.vi`
forms, encodings fetched and verified against `riscv/riscv-opcodes` in Phase 1's own research (reused
verbatim). Reserved encodings (no real `vsub.vi`, no real `vrsub.vv`) trap illegal-instruction via a new
`vec_arith_illegal` term folded into the existing `has_exception` — Control.v itself has no funct6 input
port, so this dynamic check lives in `OOOCore.v` directly, the same pattern `vec_cfg_reserved` already
established in Phase 1.

## Real bugs/findings

**`.vi`'s sign-extended immediate was first drafted as a side-channel register outside the RS.** RS_VALU
holds up to 8 entries — a second `.vi` instruction dispatching into a later entry while an earlier one
still waits to issue would have corrupted the earlier entry's own immediate. Found by tracing the RS's own
queueing semantics before trusting the design, not by running. Fixed by carrying the immediate directly in
the RS payload, mirroring `RS_ALU`'s own `imm_d` precedent exactly.

**Every existing `OOOCore.v`-including testbench (22 files) needed a new include of `VALU.v`.** This
project's own testbenches list a flat dependency chain rather than globbing `design/*.v`; `VALU.v` is a
brand-new file none of them knew about. Same bug class this project's own Gen6-N/Phase-U history already
names — found immediately by the first full regression run (118/139), fixed mechanically across all 22
files.

**`slot0_is_plain_alu`/`slot1_is_plain_alu` both needed `is_vec_arith` added to their own exclusion
lists.** Same real bug class Phase 1 already found once for `is_vec_cfg` (Gen6-K dual-issue silently
sweeping a new instruction class into its own vector-unaware payload pack) — fixed proactively this time,
by design, rather than found by running again.

**Flagged, not silently inherited**: `RS_VALU`'s own cross-namespace (vector-preg vs. integer-preg) CDB
tag-collision risk mirrors `RS_FALU`'s own identical `FMV.W.X`-era shape exactly (Gen6-H) — src1 is always
a vector-space tag, `.vx`'s own src2 is an integer-space tag, both share the same 0..63 numeric range with
no namespace bit distinguishing them. A coincidental tag-value collision between an in-flight vector
producer and an unrelated integer completion could theoretically wake the wrong operand early. `RS_FALU`
has carried this exact risk since Gen6-H with no real bug found by extensive constrained-random testing;
inherited here, not introduced fresh, and not silently ignored.

## Testing

- Directed: `ooocore_vector_arith_v2a` (7/7 checks) — chained `.vi`→`.vi`→`.vv` dependency through the
  vector rename stack, cross-file `.vx` read, signed `vmin.vv`.
- `VALU.v` proven standalone first (`tb_valu_unit`, 7/7) — masking, tail-agnostic zero, signed compare,
  all four operand forms — before ever wiring it live, matching this project's own "new module gets its
  own testbench before any real caller" precedent.
- 140/140 full directed suite (up from 138), zero-warning compile, 60/60 scalar default, 60/60 scalar
  `--xlen 64`, 60/60 `--ooo` constrained-random cross-check.

## Future improvements

- Full LMUL grouping (Phase 2b, `docs/adr/0063`).
- `v0.t` masking wiring at the `OOOCore.v` level (proven inside `VALU.v` standalone; not yet exercised by
  an end-to-end directed test through real dispatch/rename).
- `vle`/`vse` unit-stride load/store (Phase 3), needing a 3rd LSQ completion-destination-file route.
- The RS_VALU/RS_FALU shared cross-namespace tag-collision risk, if it ever manifests as a real bug.
