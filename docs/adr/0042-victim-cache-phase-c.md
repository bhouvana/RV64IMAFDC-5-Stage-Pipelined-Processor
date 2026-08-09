# ADR 0042: Victim Cache (Generation 4, Phase C)

## Problem

Generation 4, Phase B closed (`docs/adr/0041`, replacement policy). `docs/ROADMAP_VISION.md`'s Generation 4
"Advanced cache hierarchy" bullet still lists victim cache, L2, hardware prefetchers, non-blocking
cache/MSHRs, and the memory controller as unscoped. Confirmed via `AskUserQuestion` (order of the 5
remaining items, then this phase's own 3 scope decisions, ambitious option chosen each time, matching every
prior phase's own pattern): victim cache first (small, self-contained, no dependency on the others — the
memory controller, non-blocking cache, and prefetchers all lean on real bus arbitration this phase doesn't
need); both I$ and D$ get one (mirrors every prior cache-family phase's own symmetric-treatment convention);
a new swappable `VICTIM_ENTRIES` parameter (default 4, 0=disabled) joins the existing family rather than a
fixed constant; and a hit promotes the line back into the main array (the real, faithful victim-cache
design), not a serve-only path that never recovers a repeatedly-thrashed line into the fast set.

`docs/ROADMAP_VISION.md`/`docs/adr/0041` never specced victim cache beyond the one-line mention — no
sizing, associativity, or hit-semantics detail existed anywhere before this phase's own scoping pass.

## Design

New standalone module, `design/VictimCache.v` — a small, fully-associative buffer shared by both caches
(`ENTRIES` slots, `WITH_DIRTY` toggling dirty tracking off for I$/on for D$, one implementation not two).
Deliberately its own module (mirrors `Tlb.v`/`Bht.v`'s own "small associative array, combinational read
port" shape) rather than inlined into each cache. Three ports: a passive combinational `lookup` (always
reflects the current `lookup_tag`, the requested line's combined set+tag — a buffer entry can come from any
set, so there's no separate set index); a one-cycle `swap` pulse for a promote-hit (replaces whichever entry
`lookup_tag` currently matches with the line being displaced from the main array — the module already knows
which slot matched, so the caller doesn't need to tell it); and a one-cycle `insert` pulse for a genuine
backing-store-miss eviction (picks the next FIFO slot, surfacing whatever it's about to overwrite
combinationally the SAME cycle, before the clock edge, so the caller can write it back if dirty). Internal
replacement among the buffer's own few entries is plain FIFO — mirrors `docs/adr/0041`'s own documented
`POLICY_ROUND_ROBIN`/`POLICY_FIFO` equivalence at small associativity; a separate LRU-among-victim-entries
scheme would be real extra RTL for a benefit nothing has shown matters at this scale.

**Naming**: every internal signal uses `vc_`/`fifo_` prefixes, never a bare `victim` identifier — confirmed
by research before writing any RTL that `ICache.v`/`DCache.v` already have a live signal literally named
`victim[]` (the existing per-set round-robin fill pointer, unrelated to this module). A real, deliberately
avoided naming collision, not an oversight.

**Wiring — a same-cycle combinational extension of `hit`, not a new FSM state.** The original plan (written
before implementation, in the session's own plan file) called for a dedicated `S_VICTIM_SWAP` FSM state.
Tracing the actual consequence before writing it found a better design: a victim-buffer hit needs no
backing-store access at all — the data is already resident in on-chip registers, available combinationally
the same cycle. `riscvpipeline.v`'s own `icache_miss` term is purely `!icache_hit`, so broadening `ICache.v`'s
`hit` output itself (`hit = hit_main | vc_lookup_hit`) resolves a promote in the exact same cycle an ordinary
hit would, at zero extra stall cost — no new state needed at all. `DCache.v`'s `hit` (an internal wire, not
a port) broadens the same way, automatically fixing `access_hit`/`access_miss`/the `S_IDLE` dispatch fork for
free, since all three already meant "resolvable without a bus access," which a victim-buit promote genuinely
is too. A write-promote resolves same-cycle in `S_IDLE`, exactly like an ordinary write-hit; a read-promote
still goes through the pre-existing `S_HIT_RD` staging, exactly like an ordinary read-hit — no dedicated
victim-cache latency path exists anywhere, it just reuses whatever path a real hit already takes.

**A real, hand-derived invariant, checked before trusting `do_swap` unconditional on `vc_lookup_hit`** (no
extra validity guard needed there, unlike `do_insert` below): `victim_target_way` (the way about to be
displaced) can only ever point at a still-invalid, never-filled way during a set's own cold ramp-up —
during which nothing could have been evicted FROM that set into the victim buffer either (round-robin and
LRU both provably exhaust every way at least once before ever re-selecting one, confirmed by tracing
`lru_touch`'s own aging rule: an untouched way's age only ever increases past its reset value once IT
becomes the touched way). So `vc_lookup_hit` being true for a given set and `victim_target_way` pointing at
an invalid way in that same set are mutually exclusive by construction. `do_insert`, by contrast, IS
explicitly gated on `valid[...]` — an ordinary cold-start miss (the common, reachable case) legitimately
targets a still-empty way with nothing worth preserving.

**D$-specific complexity, the real new piece beyond I$**: a dirty evicted line goes into the victim buffer
via `insert_dirty`, carrying its real dirty bit through. If the victim buffer is already full, its own
FIFO-oldest entry gets kicked out to make room — if THAT entry is dirty, its data needs a real writeback
too, latched in `S_IDLE` (`vwb_pending_r`/`vwb_tag_r`/`vwb_data_r` — the combinational `evict_out_*` signals
are only valid the exact cycle `do_insert` fires, so by the time `S_WB` could get to it, `fifo_next_r` has
already moved on) and chained through the EXISTING `S_WB` state (a new `vwb_active_r` flag selects, at
`S_WB`'s own completion check and at the `m_data_o` mux, whether this pass is writing back the primary
miss's own evicted line or the victim buffer's own kicked-out one) rather than adding a second dedicated
writeback state. `access_hit_way`/`access_hit_set` (Phase B's own LRU-touch site) needed the same fix
`ICache.v`'s `lru_touch` call needed: without it, a write-promote would have silently touched way 0 of every
set's own age-tracking instead of `victim_target_way`, since `hit_line_idx` is all-zero when `hit_main` is 0
— found and fixed by tracing before running, not by a failing test.

**A deliberate design choice, not an oversight, worth being explicit about**: the primary miss's own
outgoing line, if dirty, is written back to the real backing store IMMEDIATELY and UNCONDITIONALLY, exactly
as before this phase — even when it's ALSO captured into the victim buffer via `do_insert` (a real,
accepted redundancy: the same data ends up written to RAM once and cached in the victim buffer once, rather
than deferring the RAM write until the victim buffer itself later evicts that entry). The alternative —
skip the immediate writeback whenever the victim buffer successfully captured the line — was considered and
rejected: `fence`'s own whole-cache-flush completeness guarantee only ever scans the main array's `dirty[]`
bits, not the victim buffer's. Deferring the writeback would mean a line sitting only in the victim buffer
at the moment `fence` runs never reaches real backing storage, silently weakening `fence`'s own pre-existing
guarantee for no gain unless `fence` itself is taught to scan the victim buffer too — a real, separate piece
of work, not attempted this phase (see Future improvements). The eager, redundant choice keeps `fence`'s
observable behavior bit-for-bit identical to before this phase.

## Real bugs/findings

1. **A real bug in this phase's OWN new testbench, not the RTL**: `tb_victimcache_unit.v`'s FIFO-wraparound
   sub-test sampled `evict_out_valid` AFTER the clock edge (using the already-advanced `fifo_next_r`)
   instead of before, for 4 of 5 insert checks — coincidentally still passing for the first three inserts
   (the post-edge slot happened to also be empty at those points) and only surfacing as a real failure once
   the FIFO actually wrapped. `VictimCache.v` itself was already correct against its own documented
   contract ("surfaced combinationally THIS SAME CYCLE, before being overwritten"); the test's own sampling
   point was wrong. Fixed by moving every insert-side check to before its own clock edge, matching the
   swap-side check (which was already correct — that one HAD been written pre-edge from the start).
2. **A project-wide, pre-existing-shape bug found across 15 files, same root cause and same fix pattern
   Phase W's own `` `include "CompressedExpander.v" `` gap established**: any file compiling the pipeline
   via its own `` `include `` chain (not the `design/*.v` glob `sim/run_tests.sh` uses) needs EVERY module a
   `generate` branch references textually available at elaboration, even in the branch that isn't taken at
   that file's own parameterization. `DCache.v`'s new `generate if (VICTIM_ENTRIES==0) ... else ...
   VictimCache #(...) m_victim(...) ...` means every file that already `` `include``s `DCache.v` (14
   testbenches/templates, all found via a project-wide `grep` before assuming the list, plus the 2 new
   files this phase itself added) needed `` `include "VictimCache.v" `` added too, or Icarus fails
   elaboration with "Unknown module type: VictimCache" — confirmed live by running `run_random_tests.py
   --victim-entries 4` before this fix, exactly the failure mode this same bug class produced in Phase W.
   `sim/formal/`'s own frozen Phase-L-era copies deliberately left untouched, matching every prior phase's
   established precedent for that pre-existing, separately-tracked gap.
3. **Zero RTL bugs found by running** — every wiring step (`ICache.v`, then `DCache.v`, the more complex of
   the two) compiled zero-warning and passed every hand-derived check (including a fully hand-traced 7-write
   round-robin sequence with exact expected byte values for the FIFO-overflow-writeback proof, and an exact
   hand-computed sub-word merge result for the write-promote proof) on the first real run. Attributable to
   the same discipline `docs/adr/0009` established and Phase O/P3 repeated: hand-deriving the actual
   consequences (the invariant above, the `access_hit_way` fix, the same-cycle redesign) before writing RTL,
   not after a test failed.

Real measured cycle-count data (`bench_runner.py --compare-victim-cache`, this project's own 3 benchmark
kernels): **zero difference** between `VICTIM_ENTRIES=0` and `=4`. Honest, not fabricated — the same "not
much pressure to exploit" result `docs/adr/0040`/`docs/adr/0041` both already found on these identical small
kernels. The real victim-cache proof is unambiguous in the forced-thrash unit tests (`tb_victimcache_unit.v`
standalone; `tb_icache_unit.v`'s `dut4`, a repeatable 2-way ping-pong recovery; `tb_dcache_unit.v`'s `dut3`,
a 7-write hand-traced sequence proving both promote-read/write-merge correctness AND the victim buffer's own
FIFO-overflow writeback) and the end-to-end directed test (`tb_cache_victim_c1.v`) — that's where this
phase's own correctness claim actually rests, not the benchmark numbers.

## Alternatives considered

**A dedicated `S_VICTIM_SWAP` FSM state** (the original plan). Rejected once actually tracing the
consequences: a victim-buffer hit needs no bus access, so resolving it inside the existing `S_IDLE`/`S_HIT_RD`
paths costs zero extra states and zero extra latency, strictly better than adding a state that would have
cost at least one cycle per promote for no benefit.

**Serve-only, no promotion** (a victim-cache hit answers the request without moving anything back into the
main array). Rejected via `AskUserQuestion`: a repeatedly-thrashed line would keep missing the main array
forever, only ever hitting the victim buffer — the full swap-promote design recovers it into the fast path,
proven repeatable (not a one-shot fluke) by `tb_icache_unit.v`'s own 2-round ping-pong check.

**Deferring the primary miss's own writeback whenever the victim buffer captures the line** (avoiding the
redundant immediate RAM write documented in Design above). Rejected: would silently weaken `fence`'s own
pre-existing whole-cache-flush completeness guarantee, since `fence` never scans the victim buffer. The
eager, occasionally-redundant write keeps `fence`'s observable behavior unchanged from before this phase.

**LRU-among-victim-entries** instead of plain FIFO for the buffer's own internal replacement. Rejected for
now, same "not shown to matter at this small a scale" reasoning `docs/adr/0041` used for round-robin vs.
FIFO in the main caches — flagged below if a future forced-thrash benchmark ever shows otherwise.

## Validation strategy

`iverilog -Wall -g2005 -I design -tnull design/*.v` (via `/c/iverilog/bin`): zero-warning at every step.
Full directed suite (`bash sim/run_tests.sh`): **97/97** — up from 95/95 at the start of this phase (2 new
tests: `victimcache_unit`, 19/19 checks; `cache_victim_c1`, 4/4 checks; plus `icache_unit` extended to 52
checks and `dcache_unit` extended to 28 checks, both up from Phase B's own counts). **100/100
constrained-random cross-check** at the default (`VICTIM_ENTRIES=0`, regression) and at `VICTIM_ENTRIES=4`
combined with each of the 3 `REPLACEMENT_POLICY` values (400/400 total across the 4 sweeps), confirming
`sim/tools/iss.py` needed zero changes — the ISS is architecturally cache-blind by design (confirmed by
direct grep before assuming it, same category as `fence`/branch prediction/every prior cache-family knob).
Real measured data via `bench_runner.py --compare-victim-cache` (see Real bugs/findings above).

## Future improvements

L2, hardware prefetchers, non-blocking cache/MSHRs, and the memory controller remain fully unscoped, each
its own future phase, per this session's own confirmed order (victim cache → memory controller →
non-blocking/MSHR → L2 → prefetchers). Two real, narrow gaps flagged above, not silently dropped: (1)
`fence` does not flush the victim buffer's own dirty lines — a line sitting only in the victim buffer at
the moment `fence` runs is invisible to it (mitigated, not eliminated, by this phase's own deliberate
eager-immediate-writeback choice in Design above, which keeps `fence`'s pre-existing guarantee intact for
every line that ever passes through the PRIMARY eviction path — only a line that itself later gets evicted
FROM the victim buffer's own FIFO without an intervening promote could theoretically still be dirty-only-
in-the-buffer at flush time; a future phase wanting airtight `fence` coverage should teach it to scan the
victim buffer too); (2) the buffer's own internal replacement is FIFO-only, not LRU-among-entries, per
Alternatives considered above.
