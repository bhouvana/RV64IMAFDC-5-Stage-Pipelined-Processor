# ADR 0043: Memory Controller (Generation 4, Phase D)

## Problem

Generation 4, Phase C closed (`docs/adr/0042`, victim cache). `docs/ROADMAP_VISION.md`'s Generation 4 bullet
for the memory controller reads, in full: *"Memory controller — burst transfers, improved arbitration."*
No further detail exists anywhere in `docs/ROADMAP.md`/`docs/ROADMAP_VISION.md`. Confirmed via
`AskUserQuestion` (most-ambitious options): real Wishbone B3 CTI/BTE burst signaling (not a simplified
custom side-band), and a real standalone `MemoryController.v` module (not an in-place extension of the
existing inline mux).

**A real course-correction, found and surfaced before implementing anything**: the initial framing ("bursts
force arbitration hardening, since a multi-cycle transaction now needs the existing priority gates extended
to hold for the whole duration") does not hold up. `dcache_m_cyc` already stays asserted for the *entire*
multi-word fill/writeback today, not per-word — so lower-priority requesters are already correctly excluded
for the whole operation regardless of whether it's a burst or a sequence of classic cycles. Two prior ADRs
(`docs/adr/0022`, `0023`) already proved a real arbiter isn't motivated by any genuine concurrent contention
in this design, and that's still true. Re-confirmed via `AskUserQuestion` before writing any RTL: proceed
on the corrected basis — `MemoryController.v` is real architectural value (a clean, testable module boundary
replacing scattered inline mux logic, plus a starvation-freedom check), not a new scheduling policy nothing
motivates; the real, measurable "burst transfers" deliverable is amortizing fixed per-access latency across
a whole line fill (a genuine, always-applicable win, unlike the victim cache's own honest zero-delta).

## Design

**`design/MemoryController.v`** (new): extracts the existing `riscvpipeline.v` `gen_bus_mux_none`/
`gen_bus_mux_cached` inline mux logic verbatim into a real module — confirmed bit-identical by direct
comparison against the code it replaces before writing it, not a redesign. Priority stays `dcache > ptw >
lsu`, the same relative order both pre-existing generate branches already used. `ptw`'s own select condition
is `ptw_busy` (a signal distinct from `ptw_cyc` itself), preserved exactly as the original code used it;
`dcache`'s select is its own `dcache_cyc` directly, also unchanged. New: `m_cti` (a real Wishbone B3
cycle-type-identifier, 3-bit side-band, `` `WB_SEL_WIDTH ``'s own precedent for "not part of the bare signal
list, added because a real consumer needs it") passes through whichever requester currently owns the bus —
only `dcache` ever drives non-classic values; `ptw`/`lsu` are tied to `` `CTI_CLASSIC `` at the call site,
since neither a page-table walk (each level's own address depends on the previous level's fetched data, so
it's inherently non-contiguous) nor the raw LSU ever bursts. BTE (burst-type extension) is a fixed constant
wherever consumed, not a runtime port — only one burst mode (linear incrementing) is ever used.

**`DCache.v`**: new `BURST_ENABLE` parameter (0=disabled default, bit-exact). The existing `S_FILL`/`S_WB`
engine — which already holds `cyc` across the whole multi-word transfer and already computes
`fill_is_last_word` — drives real `m_cti`: `CTI_INCR_BURST` for every beat but the last, `CTI_END_OF_BURST`
on the last, `CTI_CLASSIC` whenever disabled. `S_WB` and `S_FILL` (and a chained victim-buffer writeback,
which reuses `fill_word_r` the same way, `docs/adr/0042`) are each their own independent burst.

**`MemoryLatencyModel.v`'s D-side wrapper** (in `riscvpipeline.v`): new `MEM_LATENCY_D_BURST` parameter
(default 0). Two separate `MemoryLatencyModel` instances (one per latency value) rather than a runtime
latency-select input to that module — the existing primitive stays untouched, proven, and simple. A new
`burst_in_progress_r` tracks whether the *previous* serviced beat's own `m_cti` said "more beats coming"
(`CTI_INCR_BURST`); if so, the current beat is a genuine continuation and pays `MEM_LATENCY_D_BURST` instead
of the full `MEM_LATENCY_D` — modeling a real DRAM row-buffer-hit (the fixed per-access latency cost is paid
once per burst, not once per word).

## Real bugs/findings

**Two real, deep, previously-invisible pre-existing correctness bugs found while building this phase's own
burst-CTI unit test — neither caused by burst/CTI itself, both in the plain classic-cycle D$ fill path that
existed since Phase G/Phase I:**

1. **`RamWishboneAdapter.v`'s own read ack was a stuck level, not a per-transaction pulse.**
   `mem_read_pending_r <= mem_read` was a plain 1-cycle-delayed *copy* of "is a read currently requested" —
   since `DCache.v`/`Ptw.v` hold `cyc`/`stb` continuously across a multi-word sequence (changing only the
   *address* between words), `mem_read` never actually dropped, so once the ack first fired it stayed high
   every subsequent cycle. `DCache.v`'s own `S_FILL` loop (`if (m_ack) ...`, a plain level check with no edge
   detection of its own) advanced `fill_word_r` and committed data on *every* remaining cycle using that one
   stale, reused ack — meaning every word after the first silently received the *previous* word's stale
   `raw_word_r` content instead of its own. **Invisible in every existing test before this phase**, all of
   which only ever exercise fresh, zero-initialized lines where every word already happens to be 0. Confirmed
   directly by tracing `tb_dcache_unit.v`'s own pre-existing, unmodified `dut2` LRU sub-test cycle-by-cycle
   *before* touching any RTL — the same "stuck ack, second word reused the first word's data" pattern was
   already there, unrelated to anything this phase changed. Fixed with real per-request edge-detection: track
   the `(address, we)` actually being serviced and only pulse a fresh ack when that genuinely changes (or
   this is the very first request) — mirroring the *already-correct* `is_new_request` idiom
   `riscvpipeline.v`'s own `MEM_LATENCY_D` wrapper has used since Phase I2 (that wrapper never had this bug;
   `RamWishboneAdapter.v`'s own simpler ack scheme just hadn't been given the same treatment).
2. **The first fix's own first attempt introduced a second, narrower regression, caught immediately by the
   full suite, not shipped**: clearing the "request outstanding" tracking only when the bus went fully idle
   (`!mem_read && !mem_write`) meant two *different*, back-to-back instructions that happen to target the
   exact same address (e.g. `lb` immediately followed by `lbu` at the same byte — `tb_mem_bytes.v`'s own
   test) were wrongly treated as "still the same outstanding repeat," since neither the address nor `we`
   changed between them. Fixed by clearing the tracking the *instant* a request's own ack is delivered
   (not waiting for bus idle) — so the very next cycle's access, same address or not, is correctly treated as
   fresh, while a request still genuinely waiting for its own not-yet-delivered ack continues to be
   recognized correctly.
3. **A third bug, found only once the first was fixed and finally exposed** (perfectly masked by bug #1
   before that): `DCache.v`'s `resp_rdata` S_FILL-completion arm always returned `fill_value` — the *last
   word fetched* — regardless of which word within the line was actually requested. A fill always starts at
   word 0 of the line (`miss_base_r` masks off the offset entirely) regardless of which word was requested,
   so "last word fetched" only equals "the word actually requested" when a line is exactly 1 word, or the
   request happened to target the line's own last word. Bug #1 masked this perfectly: it caused every word to
   receive word 0's own stale value anyway, which — for word 0 requests specifically — coincidentally matched
   the *correct* answer. Once bug #1 was fixed and each word's own real data genuinely started propagating,
   this became visible (`tb_dcache_unit.v`'s own dut2 LRU-D refill check: expected `0xcccc0000`, got
   `0x00000000`). Fixed by reading the *specifically-requested* word (`miss_word_off_r`) from `data_arr`
   instead of trusting whichever word happened to be fetched last — with one care needed: if the requested
   word IS the one committing this exact cycle, `data_arr`'s own write for it is still in-flight (a
   non-blocking assignment scheduled for this same edge), so that specific case still uses the fresh
   `fill_value` directly rather than reading the not-yet-updated array. `ICache.v` was confirmed unaffected —
   its own `inst` output already continuously reads `data_arr` at the real `word_off`, never a
   transient last-fetched value.
4. **A real, expected timing-budget consequence, not a bug**: `tb_perf_cache_j5.v`'s own fixed `#300` wait
   was tuned against the *old, artificially fast* (buggy) fill timing. With bug #1 fixed, real multi-word
   fills now correctly take more cycles (paying real per-word latency instead of reusing one stale ack), so
   the old budget cut off before the program's own last instruction's effects were fully counted
   (`icache_miss`/`dcache_hit` both landed one short). Widened to `#600`, generous margin not tuned.

Real measured cycle-count data (`bench_runner.py --compare-burst`, at `MEM_LATENCY_D=5`): **-8.1%**
(`bench_bubble_sort`) and **-18.3%** (`bench_sum_array`) — real, substantial, honest wins, unlike the victim
cache's own zero-delta, because this benefit doesn't depend on any specific eviction/thrash pattern, just on
having more than one D$ miss to amortize latency across. `bench_fib` shows 0% — it has zero D$ misses at all
on this kernel, confirmed via the existing I$/D$ miss counters, so there's nothing for the discount to apply
to. A standalone end-to-end directed test (`tb_memctrl_burst_d1.v`) proves the same mechanism in isolation:
59 cycles (classic) vs. 32 cycles (burst) for one single-line fill at `MEM_LATENCY_D=10`/
`MEM_LATENCY_D_BURST=1`.

## Alternatives considered

**A real bus arbiter with a new scheduling policy** (round-robin, fairness rotation, etc.). Rejected, see
Problem above — no genuine concurrent contention exists in this design for a policy to improve on; two prior
ADRs already proved this and re-confirming it before writing RTL avoided building something nothing
motivates.

**A runtime latency-select input added directly to `MemoryLatencyModel.v`** (instead of two separate
instances at the call site). Rejected: the existing module's `start`/`busy`/`done` contract is simple and
already proven across every prior phase that uses it (`Divider.v`/`Ptw.v`'s own shape); two instances plus a
mux at the one call site that needs burst-awareness keeps that primitive untouched.

**A simplified, non-standard burst side-band signal** instead of real Wishbone B3 CTI/BTE (mirroring this
core's own precedent of pragmatic protocol deviation, e.g. `funct3`). Rejected via `AskUserQuestion`: real
CTI/BTE is a precisely-specified, real standard to implement against, more credible for a research/education
platform, and constant-address-burst mode fits a line fill exactly regardless.

## Validation strategy

`iverilog -Wall -g2005 -I design -tnull design/*.v` (via `/c/iverilog/bin`): zero-warning at every step.
Full directed suite (`bash sim/run_tests.sh`): **99/99** — up from 97/97 at the start of this phase (1 new
test, `memorycontroller_unit`, 12/12 checks; 1 new end-to-end test, `memctrl_burst_d1`, 3/3 checks;
`dcache_unit` extended to 30 checks, `perf_cache_j5`'s own timing budget widened). **400/400 constrained-
random cross-check** across 4 sweeps: default (regression), burst-enabled with a real nonzero
`MEM_LATENCY_D_BURST`, burst combined with `REPLACEMENT_POLICY=2`/`VICTIM_ENTRIES=4` (every Gen4 cache-family
feature at once), and burst combined with `--mmu` (confirming `Ptw.v`'s own bus traffic, sharing
`MemoryController.v`'s same arbitration, is unaffected). Real measured data via `bench_runner.py
--compare-burst` (see Real bugs/findings above).

## Future improvements

Non-blocking cache/MSHRs, L2, and hardware prefetchers remain fully unscoped, each its own future phase, per
this session's own confirmed order. `MemoryController.v`'s own starvation-freedom is confirmed for the
realistic contention patterns this pipeline can actually produce (proven via `tb_memorycontroller_unit.v`'s
own directed scenarios), not as an unbounded general proof for an arbitrary future requester mix — a future
phase adding a genuinely new bus master (e.g. a hardware prefetcher issuing its own speculative requests)
should re-examine this. The two real bugs found this phase (RamWishboneAdapter's stuck ack, DCache's
last-word-not-requested-word `resp_rdata`) were both in the *classic*, non-burst D$ fill path and are now
fixed unconditionally (not gated on `BURST_ENABLE`) — but their long, invisible history (masking each other
perfectly since at least Phase G) is worth remembering: **if a future session finds ANOTHER D$ multi-word
correctness bug, check whether it too is being masked by a second, compensating bug before trusting a single
fix in isolation** — that's exactly the shape both of these had.
