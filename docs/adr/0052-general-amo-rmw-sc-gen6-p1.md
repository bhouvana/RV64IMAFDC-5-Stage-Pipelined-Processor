# ADR 0052: General AMO-RMW + SC in OOOCore.v (Gen6-P1)

## Problem

`docs/adr/0049`'s own Future improvements section flagged general AMO-RMW+SC as open. Gen6-J
(`docs/adr/0047`) only wired LR — SC and the nine AMO-RMW ops (ADD/SWAP/XOR/OR/AND/MIN/MAX/MINU/MAXU)
decoded into `isAmo_c` but fell through to whatever `is_mem_op`/`is_amo_lr` missed, i.e. the plain-ALU
bucket, meaning they would have silently mis-executed if ever dispatched. User chose "finish the
backlog first, then close" over closing Gen6 with this gap still open; this is the first of six
sub-phases (P1-P6) that decision requires before a real closure ADR.

## Design

### LoadStoreQueue.v: op_type dispatch interface

`disp_is_store0`/`disp_is_store1` (1-bit) generalized to `disp_op_type0`/`disp_op_type1` (2-bit:
`OP_LOAD`/`OP_STORE`/`OP_SC`/`OP_AMO_RMW`) + new `disp_amo_op0`/`disp_amo_op1` (5-bit, `riscv_defs.vh`'s
own `AMO_F5_*` funct5 encoding passed through directly rather than reinvented). Per-entry storage
mirrors this: `e_is_store` array replaced by `e_op_type`/`e_amo_op` arrays.

### AMO-RMW: 2-phase read-modify-write

An AMO-RMW is not one memory access, it's a read then a write of the *computed* result, with the
instruction's own destination getting the **old** value (per spec) — genuinely different shape from a
plain load or store. Tracked via two new **global** registers (not per-entry — this LSQ's own
pre-existing scope, cut in Gen6-E, is single-outstanding-head-only, so global state is correct here
exactly the way `mem_pending_r` itself is already global): `amo_need_write_r` (which phase the head
entry is in) and `amo_old_value_r` (the captured read result, needed for both the eventual rd value and
the RMW computation itself).

Phase 1 (read) fires like an ordinary load. The read result becomes valid the same edge
`mem_pending_r` first latches 1 (this LSQ's own established timing — `DataMemoryBRAM.v`'s registered
read/write lines up exactly with when `mem_pending_r` becomes externally visible). Phase transition
happens the following edge: `amo_old_value_r <= mem_readData; amo_need_write_r <= 1;` — this is also
where `mem_pending_r` clears, so the entry does *not* retire here (`amo_phase1_just_finished` gates
`complete_valid` low for this one edge specifically). The newly-set `amo_need_write_r` makes
`head_ready` (now via `head_wants_write`) true starting the *next* interval, issuing phase 2's write
combinationally off `amo_new_value` (a continuous-assign ternary chain over `AMO_F5_*`, not an
`always@(*)`+`case` — see Real bugs/findings). Phase 2 completes and retires exactly like any other op.

`complete_data = head_is_sc ? 0 : (head_is_amo ? amo_old_value_r : mem_readData)` — SC always reports
success (0, see below); AMO-RMW reports the pre-write value; a plain load reports the real read.

### SC: single-hart always-succeeds

Reuses `docs/adr/0038`'s own established simplification: no real hart contention is possible in this
core, so SC always succeeds (`rd = 0` unconditionally) and its own store is unconditional too —
mechanically identical to a plain store except for the destination-value semantics below.

### complete_is_load: re-derived, not extended

Original flag literally meant "is this entry a load" (`!e_is_store[head_r]`). Naively extending it to
`head_is_load || head_is_amo` **omits SC** — SC has a real destination register (always 0) that needs
to reach the PRF/ROB same as any other writeback, or its own `rd` preg orphans forever, the same
deadlock class `docs/adr/0049` already found once for `FreeList.v`. Re-derived from the flag's actual
meaning ("does this completion carry a real destination value") instead of its name: `!head_is_store` —
true for LOAD/SC/AMO_RMW, false only for a plain STORE. Found and fixed before writing any test for it,
by re-deriving semantics rather than trusting the name.

### OOOCore.v: decode routing

`is_amo_lr`/new `is_amo_sc`/`is_amo_rmw` classify `isAmo_c` by its own funct5
(`funct7_c[6:2]`); `lsq_op_type0` maps that to the LSQ's own literals (OOOCore.v and
LoadStoreQueue.v deliberately don't share a cross-module parameter for these — kept as a documented
sync-manually comment instead, consistent with how this core already treats `AMO_F5_*` itself).
`is_mem_op` widened from `memRead_c || memWrite_c || is_amo_lr` to `... || isAmo_c` (was only
catching LR, same silent-misexecute gap the Problem section describes). `is_mem_op_1` (slot1's own
copy) needed the identical widening — found proactively, by analogy, before it could cause a real bug:
unwidened, an SC/AMO-RMW landing in slot1 would have stayed eligible for Gen6-K's own dual-issue
(`slot1_is_plain_alu` wouldn't have excluded it), even though slot1 never dispatches into the LSQ at
all. Neither instruction class touches Gen6-O's own forced-A/link-B RS_ALU payload mechanism — SC/AMO
dispatch entirely through the LSQ path, same as LR already did.

## Real bugs/findings

- **`complete_is_load` omitting SC** (see above) — found and fixed before writing any test, by
  re-deriving the flag's true meaning instead of pattern-matching its name onto the new cases.
- **`is_mem_op_1` not widened** — found proactively by analogy with the slot0 fix, before it could
  manifest as a real dual-issue bug.
- **Icarus "sensitive to all N words in array" warning** for an `always@(*)`+`case` reading
  `e_amo_op[head_r]` (a variable-indexed array read inside a procedural block) — same class already
  hit and fixed for `Mailbox.v` earlier this generation; fixed identically, a continuous `assign` with
  a ternary chain instead of `always`+`case`.
- **Two real test-authoring timing bugs, not RTL bugs**, found while getting `tb_lsq_unit.v`'s own new
  cases (SC, AMOADD) to pass:
  - A **pre-existing** bug in case5 (unmodified from Gen6-E, never triggered before): it didn't wait
    for its own load's retire to settle before ending, so the new SC case started dispatching one
    cycle before the queue was actually empty — SC's own entry queued behind the still-resident load
    instead of being immediately processable. Fixed by adding the same retire-settle wait every other
    case already used.
  - The new AMOADD case's own hand-timed check for when `mem_memWrite` (phase 2's write) first becomes
    visible was one edge too early — assumed it coincided with the *same* edge phase 1's own read
    result landed, but `amo_need_write_r` is itself a registered signal, so `head_wants_write` (and
    hence `mem_memWrite`) can only reflect it starting the interval *after* that edge. Root-caused by
    hand-retracing the RTL's own sequential-block edge-by-edge against the observed failure (matching
    every functional/data check in the same case still passing) rather than guessing; fixed the test's
    own check placement, not the RTL — confirmed correct by re-running to 31/31.

## Testing

- `tb_lsq_unit.v`: two new cases (SC.D, AMOADD.D), 31/31 (up from 20, all pre-existing cases
  behavior-preserving through the `disp_is_store0`→`disp_op_type0` rename).
- `tb_ooocore_amo_p1.v`: new OOOCore-level directed test, SC.D then AMOADD.D against the same address —
  proves the new `disp_op_type0`/`is_mem_op`/`is_mem_op_1` decode routing is wired correctly end to end
  through dispatch/RAT/ROB/PRF, not just the standalone LSQ unit in isolation. 5/5 on first run once the
  unit-level mechanism was proven.
- Full directed regression: 130/130 (up from 129), zero-warning `iverilog -Wall -g2005` compile across
  every touched file (`LoadStoreQueue.v`, `OOOCore.v`, both testbenches).

## Alternatives considered

- **Per-entry AMO phase state** (rather than global `amo_need_write_r`/`amo_old_value_r`): rejected —
  this LSQ's own pre-existing scope cut (Gen6-E) already limits in-flight memory access to the head
  entry only, so per-entry state would track something that can structurally never have more than one
  live value at a time. Global state matches `mem_pending_r`'s own existing precedent exactly.
- **Reusing Gen6-O's forced-A/link-B RS_ALU payload mechanism for AMO-RMW's own arithmetic**: rejected
  — AMO-RMW's compute step needs the *memory-read* result as one operand, not a PRF/PC-captured
  constant known at dispatch time; the LSQ's own 2-phase sequencing is the right place for this, RS_ALU
  was never a fit.

## Future improvements

- `docs/adr/0049`'s remaining backlog, now minus this phase: Sv39 MMU + real interrupts for
  `OOOCore.v` (Gen6-P2/P3), rest of F-extension (Gen6-P4), BTB-predicted jalr (Gen6-P5).
- **Widen `random_gen.py`'s own `--ooo` fuzzer** to use LR/SC/AMO-RMW now that all of them are real
  (Gen6-P6) — deferred alongside the lui/auipc/jal/csrrX widening `docs/adr/0051` already deferred, for
  the same reason (a single coordinated fuzzer-widening pass covers more ground than doing it
  piecemeal per phase).
