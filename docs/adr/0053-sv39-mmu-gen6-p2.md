# ADR 0053: Sv39 MMU in OOOCore.v (Gen6-P2)

## Problem

`docs/adr/0049`'s own Future improvements section flagged "Sv39 MMU + real interrupts for OOOCore.v"
as open — the second of six sub-phases the user's own "finish the backlog first, then close" directive
requires before Gen6 gets a real closure ADR (`docs/adr/0052`, Gen6-P1, closed the first). Unlike
`docs/adr/0032` (Phase P, PIPELINED's own Sv39 MMU), this phase is **integration**, not new
translation-hardware design: `Tlb39.v`/`Ptw39.v` already exist, fully built and unit-tested. The real
work is wiring them into a structurally different core — dispatch/OOO-shaped, not a classic 5-stage
pipeline — which turned out to need substantially more new plumbing than "reuse the existing modules"
implied at first glance.

## Design

### Research finding: OOOCore.v's own I-side/D-side memory are already numerically unified

A real, load-bearing question resolved before any RTL changed: PIPELINED's own Sv39 wiring has code
(`InstructionMemory.v`) and data (`DataMemoryBRAM.v`/Wishbone) as two physically SEPARATE arrays that
behave AS IF unified only because both are consistently pre-loaded from the same program image
(`INIT_FILE` for I-side, `DATA_INIT_FILE` for D-side). OOOCore.v's own `m_DMem` never gets a
`DATA_INIT_FILE` at all (confirmed by reading, not assumed) — every existing test already builds its
own data at runtime via `addi`+`sd`, meaning code and data numerically share the SAME low address range
across two disjoint arrays by the SAME convention, just with D-side starting zero-filled instead of
pre-loaded. This meant page tables (built at runtime, exactly like ordinary program data already is)
naturally belong in D-side memory, and the walker's own PTE reads route there — no new memory
unification work needed, matching PIPELINED's own precedent exactly.

### Tlb39.v/Ptw39.v reused completely unmodified

Both already expose the exact shape this core needs: `Tlb39.v` is unified with independent
fetch-side/load-store-side query ports (one instance serves both `m_Tlb`); `Ptw39.v`'s own
`start`/`busy`/`done`/`fault` interlock shape matches `Divider.v`'s precedent this core already relies
on elsewhere. Neither module is XLEN=32-aware (Sv39 doesn't exist there), matching this whole
generation's own RV64-only scope — no OOOCore.v test has ever used XLEN=32.

### Ptw39's Wishbone-master port adapted to DataMemoryBRAM.v's simpler shape

PIPELINED's own Ptw.v/Ptw39.v share a real Wishbone bus with the D-side LSU (a genuine master/master
arbiter). OOOCore.v's own D-side memory is a plain synchronous-read array, not Wishbone — Ptw39's
`m_cyc`/`m_stb`/`m_we`/`m_addr`/`m_data_o` adapt to `memRead`/`memWrite`/`address`/`writeData` directly;
`m_ack`/`m_data_i` are driven back at `DataMemoryBRAM.v`'s own documented fixed 1-cycle registered-read
latency (confirmed by reading its `always` block, not assumed) via a single delayed register
(`ptw_m_ack_r`). `funct3` is forced to `F3_LOAD_LD` while the walker holds the port — Sv39 PTEs are 8
bytes, the same finding `docs/adr/0032` P3 made for `RamWishboneAdapter.v`.

### I-side: fetch address translation, dispatch-time trap

`imem_phys_addr` mirrors PIPELINED's own P3 pattern exactly: `{itlb_ppn[19:0], pc_r[11:0]}` on a hit,
raw `pc_r` otherwise (X-avoidance — a stale/never-filled TLB entry's data fields are meaningless without
a qualifying hit, same reasoning `docs/adr/0032` P3 already established). `itlb_miss` folds into
`dispatch_stall` (freezes `pc_r`, same "single-outstanding stall-and-wait" shape `br_inflight_valid_r`/
`trap_inflight_valid_r`/`jr_inflight_valid_r`/`csr_inflight_valid_r` already use) for the walk's whole
duration; the exact cycle it concludes with a fault, `inst_word` is forced to the all-zero
"illegal instruction" encoding `InstructionMemory.v` already documents for out-of-bounds reads — every
other decode wire (`needs_dest`, `is_mem_op`, ...) falls out safely 0 for free, and
`itlb_fault_this_cycle` folds directly into Gen6-I's EXISTING dispatch-time-only trap machinery
unmodified (an ITLB fault is fully resolved BEFORE dispatch, exactly like illegal-instruction/ecall
already are — no new injection path needed for this side).

### D-side: a genuinely new late-injection trap path

A D-side page fault does **not** fit Gen6-I's dispatch-time shape — the faulting load/store was already
dispatched, its own `rob_tag` already allocated, well before its translation resolves (the LSQ's own
strictly-in-order head may take many cycles to reach it). New machinery, latched separately:

- `LoadStoreQueue.v` gained four new outputs (`head_want_access`, `head_want_write`, `head_rob_tag`,
  `head_pc`) — the head's own pre-stall identity, unconditionally valid whenever present (not gated by
  `mem_pending_r` the way `complete_*` is), needed because a permanently-stalled head never asserts
  `complete_valid` on its own. `disp_pc0`/`disp_pc1` + a new `e_pc` array thread the dispatching
  instruction's own PC through, purely so a page fault (discovered well after dispatch) can still supply
  `mepc` the real faulting PC.
- `dtlb_needed`/`ls_perm_ok`/`dtlb_hit_fault`/`dtlb_miss`/`dtlb_page_fault` mirror PIPELINED's own P3
  shape, keyed off `lsq_head_want_write` to pick R vs. W permission.
- `dside_fault_valid_r`/`dside_fault_pc_r`/`dside_fault_cause_r`/`dside_fault_rob_tag_r`: latched the
  cycle `dtlb_page_fault` first fires, resolved against retire via a SECOND, independent comparison
  (`dside_trap_resolve`) — mutually exclusive with the dispatch-time `trap_resolve` by construction,
  since a single ROB entry can never be tracked by both mechanisms at once. `trap_resolve`/
  `csr_trap_taken`/CSR.v's own `trap_pc`/`trap_cause` ports all widened to mux between the two latches.

### Two deadlock/correctness gaps found by design, before writing any test

1. **A permanently-stalled LSQ head never signals ROB completion.** `mem_stall_ext` holds a
   DTLB-faulted head frozen forever (`ls_hit` can never become true for a translation already known to
   fault) — meaning `ReorderBuffer.v`'s own "done" bit for that entry would never set via the normal CDB
   path, meaning `rob_retire_valid0` would never fire for it, meaning `dside_trap_resolve` could never
   fire either: a real deadlock. Fixed by injecting a **synthetic** one-cycle completion into the ROB's
   own existing `complete_en1`/`complete_tag1` port (the same port `lsq_complete_valid` already uses),
   carrying `head_rob_tag` instead — deliberately NOT touching `lsq_complete_valid` itself, so
   `PhysicalRegisterFile.v`'s own CDB write-enable correctly never fires (a faulting load must never
   actually write its destination).
2. **The ROB entry still needs to actually leave the LSQ**, decoupled from the synthetic ROB pulse
   above — marking the ROB "done" doesn't clear the LSQ's own internal `e_valid`/`head_r` state, which
   would otherwise stay permanently "occupied" by one phantom entry even after the fault's own trap has
   redirected execution entirely away from it — eventually deadlocking the WHOLE LSQ (`lsq_full`) once
   later, unrelated instructions fill the remaining entries. Fixed with a new `force_retire_ext` input
   on `LoadStoreQueue.v`: a one-cycle pulse (fired the same cycle as the synthetic completion above)
   that silently retires the head — no memory touched, no `complete_valid` asserted a second time.
3. **A committing register-file write on a faulting retire.** A faulting LOAD still has `needs_dest=1`
   (unlike illegal-instruction/ecall, which naturally have `regWrite_c=0` and so never faced this) —
   letting its own retire proceed through the ORDINARY RAT-commit/FreeList-free path would commit a
   never-really-loaded garbage value into the architectural register AND free the OLD preg while the RAT
   mapping still pointed to it (a live-value corruption, not just a garbage read). Fixed by gating the
   INTEGER `FreeList`/`RegisterAliasTable`'s own `free_en0`/`cwen0` on `!dside_trap_resolve` (FP paths
   untouched — a D-side fault is always an integer-dest load/store/AMO in this core's current scope).
4. **Wrong-path stores can actually touch memory before an older fault is discovered.** Unlike RS_ALU
   results (never architecturally visible until retire), this LSQ's own stores commit to real memory the
   moment they ISSUE (Gen6-E's own design, unrelated to this phase) — NOT gated on retirement at all.
   Without blocking dispatch, a younger store dispatched while an older load's own DTLB translation is
   still unresolved could write memory before the older instruction's fault is even known, a genuine
   precise-exception violation. Fixed by folding `dtlb_stall`/`dside_fault_valid_r` into `dispatch_stall`
   itself (matching `itlb_miss`'s own existing inclusion) — held through to the fault's own eventual
   retire/redirect, not just its initial detection.

All four were caught by re-deriving what each mechanism actually needed to guarantee, before writing
any RTL for it (the same discipline `docs/adr/0052`'s own `complete_is_load` fix used) — not found by
running.

### Dual-issue excluded while translation is live

`try_dual_issue` gained `&& !translate_enable` — a real, deliberate scope cut in the same category as
every other Gen6-K exclusion (jalr/csrrX/lui/auipc/jal/AMO). `m_IMem1`'s own speculative fetch at
`pc_r+4` stays untranslated regardless — harmless, since slot1 never actually dispatches while
`translate_enable=1`, so nothing downstream ever consumes its result that cycle.

### sfence.vma: wired, narrowly scoped

`isSfenceVma_c` (decoded since `docs/adr/0038`, never consumed until now) fires `Tlb39.v`'s own
`flush_all` pulse the same cycle it dispatches (this core's frontend is purely combinational, no
separate EX-stage delay the way PIPELINED's `reg2_hold`-gated version needs) and folds a U-mode privilege
violation into the same dispatch-time trap path `itlb_fault_this_cycle` already uses (falls to
`MCAUSE_ILLEGAL_INSTRUCTION` by default, matching `docs/adr/0032`'s own treatment). Deliberately NOT
independently directed-tested this phase — `flush_all`'s own mechanism is translation-scheme-agnostic
and already covered by `Tlb39.v`'s own unit test, so the marginal risk of leaving it unverified at this
integration layer is low; flagged honestly rather than silently assumed complete.

## Real bugs/findings

- The four deadlock/correctness gaps under Design above, all caught by design.
- **A real test-program bug, not an RTL bug**, found while building the D-side fault directed test: the
  first version reused `ooocore_mmu_p2b.s`'s own read+execute-only gigapage PTE (`0x1B`, no W bit) for a
  test whose own `recovery` code needed to WRITE through that same mapping — `recovery`'s own `sw`
  genuinely, correctly page-faulted too (a legitimate `MCAUSE_STORE_PAGE_FAULT`, not a bug), silently
  overwriting the FIRST fault's own already-correct `MCAUSE_LOAD_PAGE_FAULT` before the check ran.
  Root-caused by direct cycle-by-cycle tracing of `dside_fault_cause_r`/`ls_hit`/`lsq_head_want_write`
  (not guessed) — the trace showed the mechanism computing BOTH causes correctly, in the right order,
  for two genuinely different faults; the test's own PTE choice was what was wrong. Fixed by widening
  the PTE to `0x1F` (adds W).

## Testing

- `tb_ooocore_mmu_p2b.v` (I-side only): a real 1GB gigapage identity mapping, `mret` into the translated
  region, a marker instruction proving the translated fetch landed exactly at the expected physical
  address — deliberately exercises Ptw39's own GIGAPAGE leaf-reconstruction path (untested by
  PIPELINED's own `mmu_translate_sv39_p3.s`, which only ever reaches a level-0 4KB leaf). 4/4, first run.
- `tb_ooocore_mmu_p2d.v` (D-side): the same gigapage mapping, a genuine D-side page fault (an unmapped
  VPN2 slot, `MCAUSE_LOAD_PAGE_FAULT`), correct redirect to `mtvec`, and — the real point of
  `force_retire_ext` — a SECOND `mret` back into the same still-live translated region proving an
  ordinary store+load round-trips correctly right after, i.e. the LSQ did NOT deadlock. 5/5 after the
  PTE-permission test-program fix above.
- Full directed regression: 132/132 (up from 130), zero-warning `iverilog -Wall -g2005` compile across
  every touched file (`LoadStoreQueue.v`, `OOOCore.v`, `sim/tools/asm.py`, both new testbenches, and
  every pre-existing `tb_ooocore_*.v`/`tb_hetero_soc_n1.v`, which all needed `` `include "Tlb39.v"``/
  `` `include "Ptw39.v"`` added to their own flat dependency lists once OOOCore.v started
  unconditionally instantiating both).
- `sim/tools/asm.py` gained a `satp` CSR mnemonic (`0x180`, standard RISC-V address) — a small,
  necessary addition to write it directly in test programs without hand-encoding.

## Alternatives considered

- **Gate the whole D-side page-fault mechanism behind a simpler "just stall forever, no trap" scope
  cut** (i.e., don't build the late-injection ROB path at all, accept that a D-side fault just hangs).
  Rejected — MMU permission/fault handling is explicitly a security-adjacent correctness property this
  project's own working discipline treats as never-simplify-away, and a full I-side-only MMU without any
  D-side fault handling would be a poor foundation for anything resembling real OS/user-mode isolation,
  the whole point of building Sv39 at all.
- **A Wishbone-shaped bus for OOOCore.v's own D-side**, mirroring PIPELINED's exact P3 arbitration
  instead of adapting Ptw39's port to `DataMemoryBRAM.v` directly. Rejected — a much larger, unrelated
  structural change (this core's entire memory topology) for no benefit this phase actually needs; the
  adapter approach reuses `Ptw39.v` completely unmodified while staying scoped to just this integration.

## Future improvements

- `docs/adr/0049`'s remaining backlog, now minus this phase: rest of F-extension (Gen6-P4), BTB-predicted
  jalr (Gen6-P5). Real interrupts (Gen6-P3, next) were originally bundled with this phase in the
  backlog's own framing but are being sequenced as their own sub-phase given this phase's own real size.
- **`sfence.vma`'s own dedicated directed test** (flush + refill, a stale mapping actually invalidated) —
  deliberately not built this phase (see Design's own sfence.vma section); worth adding if a future
  phase's work depends on runtime page-table mutation specifically.
- **Selective ASID invalidation, SUM/MXR, A/D auto-set, `mstatus.MPRV`** — all inherited unchanged from
  `docs/adr/0032`'s own Sv32/Sv39 scoping defaults, not re-litigated here.
- **Dual-issue while translation is live** — real future work if profiling ever shows the single-issue
  fallback costing real cycles on an MMU-heavy workload (same "flag it, don't chase it speculatively"
  treatment `docs/adr/0051`'s own BTB-jalr deferral already used).
- **Widen `random_gen.py`'s own `--ooo` fuzzer** to build a real Sv39 identity mapping the way its
  PIPELINED-side `--mmu --xlen 64` counterpart already does (`docs/adr/0032` P5) — deferred alongside
  every other fuzzer-widening item already queued for Gen6-P6, for the same reason (one coordinated pass
  covers more ground than doing it piecemeal per phase).
