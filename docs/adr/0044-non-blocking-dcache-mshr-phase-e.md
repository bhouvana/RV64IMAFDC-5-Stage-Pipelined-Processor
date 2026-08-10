# ADR 0044: Non-blocking D$ / MSHRs (Generation 4, Phase E)

## Problem

`design/DCache.v` was fully blocking, by construction, since Phase G
(`docs/adr/0023`): a single `state` register meant one outstanding request
at a time — a miss froze `mem_stall`/`pc_stall`, holding PC/reg1/reg2/reg3/
reg4 for the entire multi-cycle fill (and any writeback before it), and
nothing else could be dispatched to the cache until it returned to
`S_IDLE`. Generation 4's own confirmed phase order (`docs/adr/0042`'s own
Problem section) named this the next phase after the memory controller:
victim cache → memory controller → non-blocking/MSHR → L2 → prefetchers.

This phase adds a real `MSHR_ENTRIES`-deep outstanding-load-miss queue to
`DCache.v`, decouples `pc_stall` from a D$ miss when a queue slot is free,
and lets independent instructions (and even a second overlapping miss)
execute while an earlier miss's fill is still draining — the actual,
measurable point of the phase, not just infrastructure.

## Design

**Scope, confirmed via `AskUserQuestion` before any RTL** (most-ambitious
option chosen both times, per this project's own established pattern):
full miss-under-miss (not just hit-under-miss), D$ only (not I$, which owns
a private memory with no bus contention at all and would need an
unrelated, separately-motivated design).

**Loads only, deliberately** — a store, or a load whose address falls in
the same line as an already-outstanding MSHR, always waits for a full
drain first. This sidesteps store-to-load forwarding across MSHRs and
same-line double-fill races entirely; a real, narrow, documented scope cut,
not a silently-dropped one.

**`MSHR_ENTRIES=1` (default) is bit-identical to pre-Phase-E behavior** —
every new dispatch path (`mshr_fresh_load_miss`/`mshr_busy_dispatch_miss`)
is unconditionally gated `MSHR_ENTRIES > 1`, so at the default the module
reduces to exactly its old single-outstanding blocking shape.

**DCache.v's `state` register keeps its exact pre-existing job** (driving
`S_WB`/`S_FILL`/`S_FLUSH_SCAN` bus-service mechanics) — what's new is a
per-entry MSHR array (`mshr_valid`/`mshr_set`/`mshr_way`/`mshr_tag`/
`mshr_base`/`mshr_word_off`/`mshr_byteoff`/`mshr_funct3`/`mshr_dest_reg`/
`mshr_orig_addr`/`mshr_is_write`/`mshr_wdata`/`mshr_early_retired`/
`mshr_need_wb`/`mshr_wb_line`/`mshr_wb_base`) plus a small `mshr_head_r`/
`mshr_tail_r`/`mshr_count_r` FIFO, so `S_WB`/`S_FILL` now read whichever
entry `mshr_head_r` points at instead of the old flat `miss_*_r` registers
they replace. A shared `mshr_alloc` task writes a new entry from either of
two dispatch forks:

- **Fresh dispatch** (`state==S_IDLE`, the same S_IDLE case-block fork that
  already existed) — unchanged bus-service kickoff logic (still driven by
  the live combinational wires, not the array, since the array's own
  non-blocking write isn't visible until next cycle).
- **Busy dispatch** (`state==S_WB`||`S_FILL`, genuinely new) — a load miss
  arriving while the bus is already servicing an earlier entry queues
  without touching `state`; the already-running S_WB/S_FILL completion
  logic notices more work queued and continues without an idle cycle
  between misses.

**Hit-under-miss** falls out cheaply: a read that resolves as a genuine
main-array hit (`hit_main`, NOT a victim-buffer hit — a deliberate,
documented scope cut, see below) while the bus is busy resolves through a
new `hu_pending_r`/`hu_data_r` side-latch, OR'd straight into the existing
`resp_ready`/`resp_rdata` outputs — no new completion port needed, since it
completes with the same ordinary 1-cycle latency any hit-read already has
and the caller is still holding the request (unlike a genuinely queued
miss, whose own caller has already moved on).

**Queued-miss completion is a real out-of-band path**: `mshr_complete`/
`mshr_complete_reg`/`mshr_complete_data`, asserted only for an entry with
`mshr_early_retired` set (early-retired = accepted via `mshr_accept`, i.e.
the caller genuinely isn't holding this request anymore). This required
three new pieces of live pipeline wiring, the real cost this phase's own
design-review step surfaced before writing RTL and confirmed via a second
`AskUserQuestion` round once that cost was concrete:

1. **`Scoreboard.v`** (new standalone module) — tracks which architectural
   registers have a pending MSHR fill, keyed by register number directly
   (not MSHR slot index — the caller's own WAW-stall invariant makes at
   most one MSHR pending per register at a time, a real simplification
   found during design, not carried over from the original sketch
   unexamined). Exposes both a single `check_reg`/`reg_pending` port and a
   flat `pending_mask` bus (riscvpipeline.v needs three simultaneous
   queries a cycle — rs1, rs2, and the new instruction's own rd for WAW —
   and a bus is simpler than three port pairs).
2. **`Register.v`** — a second write port (`we2`/`waddr2`/`wdata2`), driven
   directly off `mshr_complete`/`mshr_complete_reg`/`mshr_complete_data`.
   No arbitration logic: the scoreboard's own WAW stall guarantees the two
   ports never target the same register the same cycle (an `ASSERT_ON`
   check flags a violation loudly if that invariant is ever broken, rather
   than silently dropping a write).
3. **`riscvpipeline.v`** — `mem_stall` gains `&& !dcache_mshr_accept`
   (suppressing the stall the exact cycle a load miss is accepted);
   `scoreboard_stall` (RAW on rs1/rs2, WAW on the new instruction's own
   rd) joins `pc_stall`'s existing OR-chain; a one-stage shadow register
   (`mshr_pending_regwb_r`) mirrors reg3→reg4's own shift timing to
   suppress the normal WB-stage write for a load that retired early with
   its real data still outstanding; fence's own `flush_all` gate gains a
   new `mshr_outstanding` DCache.v output (every MSHR must drain before a
   flush scan starts — a line still mid-fill has no meaningful clean/dirty
   state yet).

## Real bugs/findings

Six real, distinct bugs found by running — every one caught by the
constrained-random cross-check, none by the directed suite alone, matching
this project's own long-established "bugs reveal themselves by running"
pattern, though this phase's own count is unusually high for a single
Gen4 sub-phase (the "wire it live" step is genuinely the biggest
structural change any Gen4 phase has made, and the bug count reflects
that honestly rather than being smoothed over):

1. **`mshr_count_r` sized too narrow.** Declared `[MSHR_IDX_BITS-1:0]`
   (`$clog2(MSHR_ENTRIES)`) — sized for *indexing* 0..MSHR_ENTRIES-1, not
   *counting* up to MSHR_ENTRIES itself. At `MSHR_ENTRIES=2`, `$clog2(2)=1`
   bit, which can only ever hold 0 or 1 — incrementing 1→2 silently
   wrapped back to 0. Fixed with a separate `MSHR_COUNT_BITS =
   $clog2(MSHR_ENTRIES+1)` localparam. Caught by `tb_mshr_unit.v`'s own
   queue-full-reject case (a request was wrongly accepted immediately
   because `mshr_count_r` read back 0 even with both slots genuinely
   occupied).
2. **Mirror-register off-by-one.** The `mshr_pending_regwb_r` shadow
   register was originally mirrored through a redundant extra stage
   (`mshr_pending_regem_r` then `mshr_pending_regwb_r`), on the mistaken
   assumption it needed the same two-stage shift reg3→reg4 itself uses.
   `dcache_mshr_accept` is *already* a regem-stage-equivalent live signal
   (combinational off whichever instruction reg3 currently holds, exactly
   like `regWrite_regem`), not something computed upstream of reg3 — the
   extra stage landed the write-suppression flag on the *following*
   instruction instead of the load itself, silently dropping that
   instruction's own real WB-stage write. Caught by `tb_cache_mshr_e1.v`'s
   own dut2 (`x6`, an independent `addi`, read back 0 instead of 42).
3. **Floating loads never excluded from non-blocking eligibility.**
   `memRead_regem` is also true for `flw` (`OPCODE_LOAD_FP` sets `memRead`
   *and* `fRegWrite`, never `regWrite`) — DCache.v has no notion of
   int-vs-float destination register files at all. Without a gate, an
   `flw` miss got queued as non-blocking and its completion fired
   `mshr_complete` with `mshr_complete_reg` sourced from an F-register
   encoding, silently corrupting whichever *integer* register happened to
   share that same 5-bit number (`flw f31,...` → wrote integer `x31`).
   Fixed with a new `req_int_load` DCache.v input, wired to
   `regWrite_regem` (true exactly for a plain integer load, false for a
   float one) — gates `mshr_fresh_load_miss`/`mshr_busy_dispatch_miss`
   only; hit-under-miss is unaffected, since it resolves through the
   ordinary `resp_ready` path every load already uses regardless of
   destination file. Caught by the constrained-random harness (seed 93).
4. **`mshr_early_retired` re-derived instead of passed through.** The
   `mshr_alloc` task originally computed `(MSHR_ENTRIES>1) && !a_is_write`
   internally — true for *any* read at `MSHR_ENTRIES>1`, including a float
   load that `req_int_load` (finding 3) correctly blocked from ever
   getting `mshr_accept`. Its own MSHR entry still got marked
   early-retired anyway, so its completion fired the side-channel
   `mshr_complete` path instead of the traditional `resp_ready` the caller
   was still actually holding out for — and `mshr_complete_reg` (from an
   F-register encoding) corrupted an unrelated integer register again, via
   a different code path than finding 3. Fixed by passing the real
   accept-consistent condition explicitly into `mshr_alloc` from each call
   site, rather than re-deriving an incomplete approximation inside it.
   Caught by the constrained-random harness (seed 93, same seed, a second
   distinct bug).
5. **Same-cycle complete+alloc coincidence, twice.** When the queue drains
   to its last entry and a new busy-dispatch allocation lands the *same*
   cycle, two related bugs: (a) `mshr_count_after_complete` didn't add back
   the same-cycle allocation, so the S_FILL completion arm wrongly
   concluded "no more work" and sent `state` to `S_IDLE` while the
   freshly-queued entry sat valid but never serviced — a permanent hang,
   deadlocking the scoreboard's own pending bit for that entry's
   destination register forever; (b) even after fixing (a), the
   "continue servicing" logic read `mshr_need_wb[mshr_head_next]` from the
   array the *same* cycle `mshr_alloc`'s own non-blocking write to that
   exact slot was still in flight — a stale, pre-write read. Fixed by (a)
   adding the same-cycle allocation back into `mshr_count_after_complete`,
   and (b) a `mshr_new_head_is_fresh_alloc` wire that switches to the live
   combinational eviction wires (the same ones `mshr_alloc_now`'s own call
   already computes from) instead of the array, specifically for this one
   coincidence. Caught by the constrained-random harness (seed 96, a
   permanent hang/timeout).
6. **The WAW check used the wrong pipeline stage — and separately, `reg2`
   was never told to bubble for a scoreboard stall at all.** Two distinct
   bugs found chasing one failure (seed 96 again, after fix 5, and
   separately seed 44 under `--mmu`):
   - `scoreboard_stall`'s WAW arm checked `regWrite_regde`/
     `write_to_Reg_regde` — reg2's own *output* (the instruction already
     one stage past decode, currently in EX), not the *new* instruction
     `inst_regfd` is about to become. The real WAW hazard (a `sltiu`
     targeting the same register as a still-outstanding `lh`'s own MSHR)
     was never detected at all, since the check was looking at the wrong
     instruction — letting the new instruction dispatch, execute, and
     retire *before* the load's own late (port2) completion, which then
     clobbered the correct value. Fixed to use `regWrite`/
     `inst_regfd[11:7]` — the plain, combinational Control.v-decoded
     signals for the current cycle's `inst_regfd`, the exact wires reg2's
     own `.regWrite`/`.writeReg` input ports already consume.
   - Separately: `scoreboard_stall` was OR'd into `pc_stall` (freezing
     fetch) but never into `reg2`'s own `.flush(...)` input — the same
     front-end-only-interlock category `itlb_miss`/`float_load_use_hazard`/
     `icache_miss`/`imem_wait` already join there, and reg2.v's own header
     comment explicitly documents why: without it, reg2 re-latches the
     *full control fields* of the stalled instruction into EX every single
     stall cycle instead of bubbling exactly once. Caught first via
     `--mmu` (seed 44, a genuinely wrong branch outcome from a stale
     operand), root-caused and fixed by adding `scoreboard_stall` to
     reg2's existing `.flush(...)` OR-chain — the identical bug class this
     file already documents fixing for its own front-end interlocks,
     simply never extended to this phase's own new stall source.

**A methodology note worth keeping**: five of these six were found via a
from-scratch debug harness (a standalone `PIPELINED` instance with
hierarchical `$display` taps on `pc_o`/`m_Register.regWrite`/
`scoreboard_pending_mask`/`mshr_*` state, built fresh for each failing
seed) rather than the project's existing Verilator debug-tap
infrastructure (Generation 3's own `debug_pc`/etc. — not available in this
Icarus-only session). Cycle-by-cycle correlation between `pc_stall`/
`scoreboard_stall`/`pend`/`inst_regfd` and the actual register-file write
ports was what actually isolated each bug; guessing from the symptom alone
did not.

## Alternatives considered

- **Full out-of-order completion with no scope cut** (stores also
  non-blocking, cross-MSHR store-to-load forwarding) — rejected;
  the added ordering complexity isn't motivated by anything concrete for
  this project's own real workloads, and the loads-only cut keeps the
  correctness surface (already large — see the six bugs above) bounded.
- **Hit-under-miss only, no second write port** — the cheaper option
  presented once the real structural cost (second regfile port, scoreboard,
  reg3/reg4 decoupling) became concrete mid-design. Rejected: the user
  confirmed via `AskUserQuestion` to proceed at full scope, matching this
  project's consistent "most ambitious option" pattern across every prior
  phase.
- **MSHR skeleton only (bookkeeping, no live decoupling)** — considered at
  the same design-review point as the two options above; not chosen for
  the same reason.
- **Victim-buffer hit-under-miss** (broadening `mshr_busy_dispatch_hit` to
  also cover `vc_lookup_hit`, not just `hit_main`) — deferred, not
  implemented. A queued-while-busy victim-buffer promote would need its
  own array-indexed bookkeeping (the same shape `mshr_need_wb`/
  `mshr_wb_line`/`mshr_wb_base` already have) since `vc_do_swap`/
  `vc_do_insert` stay gated `state==S_IDLE`; real but narrow, flagged
  below, not silently dropped.

## Validation strategy

Zero-warning `iverilog -Wall -g2005 -DASSERT_ON -I design -I sim/tb
design/*.v` compile. **103/103 directed tests** (up from 99/99 — three new
standalone unit tests: `tb_mshr_unit.v` 28 checks across dut_a
`MSHR_ENTRIES=2` and dut_b `MSHR_ENTRIES=1` regression, `tb_scoreboard_unit.v`
10 checks, `tb_register_unit.v` 6 checks; one new end-to-end directed test,
`tb_cache_mshr_e1.v`, running the *identical* program through two DUTs at
`MSHR_ENTRIES=1` vs `=2` and asserting both the same correct architectural
state *and* a real cycle-count win — 19 vs 25 cycles, ~24% faster, measured
not assumed).

**500/500 constrained-random cross-check** across 5 axis combinations, 100
seeds each: default (`MSHR_ENTRIES=1` regression), `MSHR_ENTRIES=2` plain,
`MSHR_ENTRIES=4` combined with `REPLACEMENT_POLICY=2`(LRU)+`VICTIM_ENTRIES=4`,
`MSHR_ENTRIES=2` combined with `BURST_ENABLE=1`+real `MEM_LATENCY_D`,
`MSHR_ENTRIES=2` combined with `--mmu` (Sv32 translation) — the last two
combos are what actually caught findings 3-6 above; the plain default/MSHR=2
sweeps alone were not sufficient to find them.

`bench_runner.py --compare-mshr`: an honest **zero delta** across
`MSHR_ENTRIES` 1/2/4 on this project's own tiny benchmark kernels (same
"not much to exploit" result every prior Gen4 cache-family phase found —
none of `bench_bubble_sort`/`bench_fib`/`bench_sum_array` happen to have
independent non-memory work immediately following a load miss, the exact
shape needed to show a win). The real, measured proof lives in
`tb_cache_mshr_e1.v`'s own hand-built worked example, not the benchmark
numbers — consistent with the victim cache's own precedent (`docs/adr/0042`).

## Future improvements

- **Victim-buffer hit-under-miss** — deferred, see Alternatives above; a
  real, narrow, flagged gap (a victim-buffer hit arriving while the bus is
  busy currently falls through to the same "must wait" path as a genuine
  miss, rather than resolving immediately).
- **Fence still scans/waits, not skips, drained MSHRs** — `mshr_outstanding`
  correctly gates the flush from *starting* until every MSHR drains, but
  doesn't shorten the flush itself; unrelated to this phase's own scope,
  not revisited.
- **`MemoryController.v`'s own starvation-freedom proof** (`docs/adr/0043`)
  was scoped to the realistic contention patterns the pre-Phase-E pipeline
  could produce. A non-blocking D$ queuing multiple outstanding requests is
  exactly the kind of new concurrent-request-issuing behavior that ADR
  flagged as needing re-examination — not done here; the physical bus
  stays single-master/single-outstanding throughout this phase (fills
  still serialize through the same Wishbone port, confirmed before design),
  so the arbitration proof's own assumptions are unaffected in practice,
  but a future phase adding a genuinely new bus master (a hardware
  prefetcher) should still re-derive it from scratch rather than assume.
- **No standalone assembler mnemonic gap this phase** (unlike several
  prior phases) — `sim/tools/asm.py` already supports every instruction
  this phase's own directed tests needed.

**Generation 4 itself stays open** — L2 and hardware prefetchers remain
fully unscoped, each its own future phase, per the confirmed order.
