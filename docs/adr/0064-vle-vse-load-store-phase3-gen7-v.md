# ADR 0064: vle/vse unit-stride load/store — Generation 7, Pillar V, Phase 3

## Problem

`docs/adr/0063` closed Phase 2b (full LMUL). This phase closes real vector load/store — `docs/adr/0059`'s
own "load/store" scope bullet — scoped to unit-stride only (`vle8/16/32/64.v`/`vse8/16/32/64.v`);
indexed/strided/segment forms are real spec but deferred.

## Design

`LoadStoreQueue.v` was built for one scalar-shaped access per dispatched instruction, not an internal
multi-element loop — extending it to a real per-element vector inner loop would be invasive to a
heavily-tested, shared module. Instead, `VLSU.v` is a genuinely new, self-contained functional unit — a
3rd requester on the shared `m_DMem` port, alongside `LoadStoreQueue.v`'s own ordinary traffic and
`Ptw39.v`'s own walker traffic, widening the existing 2-way arbitration to 3-way (mirrors `docs/adr/0053`'s
own precedent widening it from 1-way to 2-way). It accumulates a load's own result element-by-element into
a local `VLEN`-wide register exactly like `VALU.v`'s own `result_r` pattern, firing one completion once the
whole physical register's worth of elements is done; a store reads its source register once and issues
elements out to memory over its own multi-cycle run.

Real EEW (effective element width) comes from the instruction's own `funct3` field, independent of
`vtype.SEW` — real spec allows the two to differ via EMUL reshaping. This phase deliberately does not
implement that reshaping (EEW is assumed to match the current `vtype.SEW`, the overwhelmingly common real
usage) — a real, narrow, flagged scope cut, not a silent gap.

`RS_VLSU` reuses the existing `ReservationStation.v` unmodified. `ReorderBuffer.v` gained a 7th completion
port (`complete_en6`/`complete_tag6`) — genuinely independent of `VALU.v`'s own 6th (the two functional
units are separate, single-instance, and can complete the same cycle). `PhysicalRegisterFile.v` gained a
12th and 13th read port — `rs1`'s own base-address value and RS_VALU's own `.vx` scalar value both needed
dedicated issue-time cross-file reads, every prior port already claimed by a real consumer.

## Real bugs/findings

**RS_VLSU's own out-of-order issue selection is unsafe for memory ops.** `ReservationStation.v`'s
established "lowest-ready-index" selection is correct for register-to-register computation (the ROB alone
enforces when a result becomes architecturally visible, regardless of completion order) — but a vector
STORE and a vector LOAD to the same address are a real ordering hazard the ROB's own retire-order guarantee
does nothing to prevent, since both can ISSUE and COMPLETE long before either retires. Found by running the
directed test: `vse32.v`'s own `vs3` operand wasn't ready yet (still waiting on an in-flight `vadd.vi`), so
a later, always-ready `vle32.v` from the same program issued and completed FIRST, reading stale pre-store
memory. Fixed by making `vle`/`vse` single-outstanding (mirrors the `jalr`/`csrrX`/`vsetvli` precedent
exactly) — the same real correctness requirement `LoadStoreQueue.v`'s own in-order/single-outstanding-head
design already exists to provide for ordinary scalar loads/stores.

**The 3-way arbitration mux keyed its selector on `vlsu_busy` (an FSM status bit) instead of a real bus
request.** `VLSU.v`'s own LAST element of a run sets its own final `mem_memWrite`/`mem_address` pulse AND
`state_r<=IDLE` (hence `busy<=0`) in the SAME clock edge — by the time that pulse is externally visible,
`vlsu_busy` already reads 0, silently dropping every `vle`/`vse`'s own LAST element access. Root-caused via
direct memory-content tracing (`data_memory[124]` staying zero despite the write signals appearing
correctly asserted in that same cycle's own debug display) — fixed by keying the mux on
`vlsu_mem_memRead||memWrite` directly (a real request this exact cycle) instead of the status bit.

**`DataMemoryBRAM.v`'s own registered read needs a full extra cycle beyond the first draft's assumption.**
Same class of off-by-one Divider.v-style multi-cycle units are prone to — found by `VLSU.v`'s own
standalone testbench before ever wiring it live (`tb_vlsu_unit.v`'s first run read back all zeros). Fixed
with a genuine 3rd load-phase state (issue → wait → capture) instead of a 2-phase design, after hand-
deriving the exact edge-by-edge signal-visibility timing between `VLSU.v` and `DataMemoryBRAM.v`'s own two
separate `posedge`-triggered blocks.

## Testing

- `tb_vlsu_unit` (standalone, 5/5): a full 3-element `vse32.v`→`vle32.v` round-trip, a masked store
  (`v0.t`) proving a masked-off element's own memory location is genuinely untouched (not just
  written-zero), tail-agnostic zero past `vl`.
- `ooocore_vector_ls_v3` (4/4): full 16-element `vse32.v`+`vle32.v` round-trip through real dispatch/
  rename/RS_VLSU/CDB/ROB-retire, including element 15 — the exact element the arbitration bug above
  silently dropped, so this directed test is also the regression check for that fix.
- 143/143 full directed suite (up from 141 — Phase 2b's own 141 plus this phase's 2 new tests), zero-
  warning compile, 40/40 scalar random cross-check, 40/40 `--ooo`, 30/30 `--mmu` (confirming the widened
  3-way arbitration doesn't disturb the pre-existing PTW/LSQ 2-way path).

## Alternatives considered

- **Extend `LoadStoreQueue.v` itself with a per-element inner loop.** Rejected — LSQ is a heavily-tested,
  shared module (every scalar load/store in every existing test depends on it); a genuinely new,
  self-contained unit reusing the same shared memory PORT (not the same rename/ROB machinery) keeps the
  blast radius of this phase's own work isolated from LSQ's own proven correctness.
- **Route each vector element through LSQ as an ordinary scalar-shaped dispatch.** Rejected — would need N
  real renames/ROB entries per vector load/store element, genuinely heavier than accumulate-then-complete-
  once, and still wouldn't solve the fundamental ordering hazard (the single-outstanding fix would still be
  needed regardless of which mechanism issues the underlying accesses).

## Future improvements

- **Indexed/strided/segment load-store forms** — real spec, genuinely different addressing math, out of
  this phase's own unit-stride-only scope.
- **EMUL reshaping for EEW≠SEW** — real spec-legal, this phase assumes they match.
- **VLSU deferring to a PTW walk that starts mid-run** — a real, narrow, flagged gap (VLSU bypasses
  translation entirely, so this only matters if a future phase adds vector-load translation); no current
  test combines `vle`/`vse` with live Sv39 translation.
- **VLSU/mailbox interaction** — `vle`/`vse` only ever target ordinary RAM in this phase, never the
  mailbox range (Gen6-N).
- **A faster, pipelined memory port** — VLSU's own 2-cycle-per-element load / 1-cycle-per-element store is
  a real, honest, not-maximally-fast tradeoff, not a hidden shortcut.
