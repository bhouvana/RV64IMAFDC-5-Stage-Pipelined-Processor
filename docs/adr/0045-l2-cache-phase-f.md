# ADR 0045: L2 Cache (Generation 4, Phase F)

## Problem

Generation 4's confirmed phase order (`docs/adr/0042`, `0043`, `0044`) named
this phase next after non-blocking D$/MSHRs: victim cache → memory
controller → non-blocking/MSHR → **L2** → prefetchers. `docs/ROADMAP_VISION.md`'s
own Generation 4 "Advanced cache hierarchy" line still lists L2 as fully
unscoped after Phase E closed. This phase closes it — a shared, inclusive
L2 sitting behind both I$ and D$, closing every item in that line except
hardware prefetchers (Gen4's own last remaining phase).

## Design

**Scope, confirmed via `AskUserQuestion` before any RTL** (most-ambitious
option chosen every time, per this project's own established pattern):
shared by I$+D$ (not D$-only), inclusive (not non-inclusive), an
independent `L2_REPLACEMENT_POLICY` (not shared with L1's own).

**One module, two instances** — `design/L2Cache.v`, mirroring
`VictimCache.v`'s own "one implementation shared by both caches" precedent
(`docs/adr/0042`). This project's I$/D$ backing stores are physically
separate arrays (Harvard-style, confirmed by research before design) — a
D-side instance splices between `DCache.v`'s existing Wishbone-master port
and `MemoryController.v`'s `dcache_*` arm; an I-side instance splices
between a **new** bus-master port on `ICache.v` (it had none — I$'s own
fetch path was a private, non-bus-mediated `InstructionMemory.v` instance)
and a **new** `InstructionMemoryWishboneAdapter.v` (mirrors
`RamWishboneAdapter.v`'s own "wrap, don't touch a verified module"
precedent), point-to-point, no shared bus involved.

**`L2Cache.v`'s own core FSM** closely mirrors `DCache.v`'s proven
S_IDLE/S_HIT_RD/S_WB/S_FILL shape — deliberately *without* DCache.v's own
MSHR array, victim-buffer instantiation, or burst-CTI generation (blocking,
single-outstanding, always presents a plain classic transaction downstream
— no `cti` port at all). Same incremental-phase discipline every prior
Gen4 axis (victim cache, memory controller, MSHR, burst) already followed:
each arrived as its own phase, not bundled for free into this one.

**Inclusion, the real design decision**: `L2Cache.v` unconditionally probes
the owning L1 before evicting *any* currently-valid line — there is no
`present_in_l1` tracking bit anywhere in the module. L1's own probe
response is the sole source of truth for whether a line is really present
and really dirty; an unnecessary probe (the line was already gone from L1)
costs one handshake round-trip and nothing else. This removes an entire
bookkeeping mechanism (a bit that would otherwise need updating correctly
at three separate event sites — fill-completion, writeback, invalidate) for
a bounded, honest, purely performance-only cost — the same `# ponytail`-
style tradeoff `VictimCache.v`'s own FIFO-only replacement comment already
establishes precedent for in this codebase.

**New probe-responder port** on both `DCache.v` and `ICache.v`
(`probe_req`/`probe_addr` in, `probe_ack` out, plus `probe_dirty`/
`probe_data` on `DCache.v` only — `ICache.v` is read-only, nothing to pull
back). Answers truthfully whether `probe_addr`'s line is resident, hands
over dirty state + full line data, and invalidates it, all in the cycle it
fires — from *any* FSM state (see Real bugs/findings — this was originally
gated `state==S_IDLE`, a real deadlock). Permanently dark (unreachable, no
behavior change) when a caller ties `probe_req=0`, the default at
`L2_SIZE_BYTES=0`.

**New `flush_all`/`flush_busy`/`flush_done` port** on `L2Cache.v` itself,
mirroring `DCache.v`'s own `S_FLUSH_SCAN` exactly — writes back in place,
never invalidates (lines stay valid/cached, just become clean). `fence`
now sequences a **second** flush stage in `riscvpipeline.v`: drain L1 into
L2 first (existing, unchanged), then drain L2 into backing memory
(`fence_complete`, not `dcache_flush_done` directly, is what actually
releases the pipeline stall now). Bit-identical single-stage behavior at
`L2_SIZE_BYTES=0` via `generate`.

**New parameters** on `riscvpipeline.v`: `L2_SIZE_BYTES` (0=disabled,
bit-identical to pre-Phase-F behavior for both I$ and D$ — no L2 module
even elaborates), `L2_WAYS`, `L2_REPLACEMENT_POLICY` (independent of L1's
own `REPLACEMENT_POLICY`, per the confirmed scope decision). No separate
`L2_LINE_BYTES` — each instance inherits its own L1's line size directly
(`ICACHE_LINE_BYTES`/`DCACHE_LINE_BYTES`), avoiding the real complexity of
a wider L2 line needing multiple L1-line-sized backing-store fetches per
L2 miss (a documented scope cut, see Future improvements).

## Real bugs/findings

Four real, distinct issues found by running — three genuinely new, one a
previously-latent bug this phase's own testing was the first to exercise.
None found by the directed suite alone; every one found by either the
end-to-end directed test (`tb_cache_l2_f1.v`) or the constrained-random
cross-check, matching this project's long-established "bugs reveal
themselves by running" pattern:

1. **A genuine deadlock**, found by `tb_cache_l2_f1.v`'s own "correctness"
   scenario hanging completely (never reaching its halt loop). `DCache.v`/
   `ICache.v`'s own probe-response logic was originally gated
   `state==S_IDLE`. While DCache is itself busy (`S_WB`/`S_FILL`) waiting on
   its own request to L2, L2 may need to evict and probe DCache for a
   *different* line — the exact eviction pressure DCache's own in-flight
   request itself creates. DCache can never leave its busy state to answer
   the probe; L2 can never finish servicing DCache's own request until the
   probe is answered. A real circular wait, not a missed corner case. Fixed
   by decoupling probe response from `state` entirely (services from any
   state) — mirroring this file's own `hu_pending_r`-style "decoupled from
   `case(state)`" precedent.
2. **Two previously-latent instances of `docs/adr/0041`'s own SET_BITS==0
   part-select bug**, found the moment this phase's own "correctness" test
   scenario genuinely needed a fully-associative-shaped L2 (2 ways/1 set) —
   the exact configuration `docs/adr/0041` itself documented as "flagged in
   this ADR's own Future improvements, real open item if a future phase
   wants a fully-associative config," and which `tb_icache_unit.v`'s own
   `dut3` comment documents deliberately routing around rather than fixing.
   `access_hit_set` (`DCache.v`, and this phase's own new `L2Cache.v`) and
   `flush_scan_r`'s own address reconstruction (`DCache.v`) all reverse to
   an invalid high<low slice (`[LINE_IDX_BITS-1:WAY_BITS]` when
   `SET_BITS==0`) — the same class of bug `set_idx`/`probe_set_idx` already
   had a `generate`-guard for, just two more sites the original 0041 fix
   never extended to. Fixed with the identical guard pattern; also fixed
   the original `{SET_BITS{1'b0}}` zero-repeat-concatenation form of the
   same root bug (invalid at `SET_BITS==0`) in `set_idx`/`probe_set_idx`
   across `DCache.v`, `ICache.v`, and `L2Cache.v`.
3. **L2 never participated in `fence` at all** — found by the constrained-
   random cross-check (a real memory-content mismatch, RTL showing 0 where
   ISS expected a real written value, at exactly the addresses two
   mid-program stores targeted). A dirty write merged into L2 (e.g. via an
   ordinary D$ flush-writeback) had no *further* trigger ever pushing it
   down to backing memory — L2 only wrote back on its own eviction
   pressure. `fence`'s own architectural guarantee (every prior write
   durably visible afterward) silently broke the instant L2 was enabled.
   Fixed with the new flush port described above. `tb_cache_l2_f1.v` was
   strengthened to check backing RAM directly (not just register values) —
   its own prior register-only checks never caught this, since the data it
   checked loads straight through the cache hierarchy, never touching
   backing RAM directly; that stronger check stays permanently as a
   regression guard.
4. **A real, pre-existing, previously-unknown gap, unrelated to L2**: found
   by an extra constrained-random sweep at `--xlen 64 --cache-mode 1`
   (beyond this phase's own required verification combos) — confirmed
   pre-existing by reproducing identically with L2 disabled before any
   L2-side investigation. `DCache.v`'s own write-back array has always been
   a fixed 4-byte (word) granularity regardless of XLEN (`word_off` from
   `req_addr[OFFSET_BITS-1:2]`), even though each storage slot happens to
   be declared `XLEN` bits wide — an 8-byte `ld`/`sd` only ever touched the
   low 32 bits of its own slot, silently losing the upper half on every
   fill, write-hit, and victim-buffer promote. Generation 2's own RV64
   migration (`docs/adr/0028`) only ever extended the `CACHE_NONE` path
   (`DataMemoryBRAM.v`'s flat byte array, which naturally handles any
   width); the write-back D$ Generation 4 built on top was never revisited
   — genuinely never exercised together by any prior phase's own sweep.
   Fixed by treating a naturally-aligned `ld`/`sd` as two adjacent 4-byte
   slots (`word_off` and `word_off+1`, always in-line, never crossing a
   line boundary) at every site touching `data_arr`: the S_IDLE write-hit
   arm, the victim-buffer write-promote, S_FILL's own write-allocate merge,
   and the S_HIT_RD/S_FILL/`mshr_complete` read-side combining logic.
   `dcache_extend_read`/`dcache_merge_write` themselves stay untouched
   (32-bit, one-slot) — all new handling lives at the call sites.
   `L2Cache.v` needed no equivalent fix: `DCache.v`'s own bus port was
   already word-granular regardless of what triggered it (`m_funct3` fixed
   at `3'b010` for every fill/writeback beat, confirmed directly — 30/30
   clean at `--l2-size` combined with `--xlen 64`).

## Alternatives considered

- **`present_in_l1` tracking bit** (probe only lines L2 believes are still
  L1-resident) — rejected in favor of the unconditional-probe design (see
  Design above): removes a real bookkeeping mechanism needing correct
  updates at three separate event sites, for a bounded, honest,
  performance-only cost. The `# ponytail`-style tradeoff this project
  already has precedent for.
- **Non-inclusive L2** (no probe/invalidate at all, L1 and L2 evict
  independently) — the simpler option, explicitly offered via
  `AskUserQuestion`; not chosen (inclusive picked, matching this project's
  consistent "most ambitious option" pattern).
- **D$-only L2** (skip giving `ICache.v` a bus port entirely) — the
  cheaper option, explicitly offered via `AskUserQuestion` with the real
  cost of the shared alternative stated up front; not chosen.
- **L2-side burst-CTI generation, victim buffer, or MSHR** — deferred, not
  implemented this phase. Matches this project's own incremental-phase
  discipline (`BURST_ENABLE`/`VICTIM_ENTRIES`/`MSHR_ENTRIES` each arrived
  as their own dedicated phase on top of the base cache design, not
  bundled in from day one) — a real, narrow, documented scope cut, not a
  silently-dropped one. See Future improvements.

## Validation strategy

Zero-warning `iverilog -Wall -g2005 -I design -tnull design/*.v` compile,
at both `L2_SIZE_BYTES=0` (default) and a real enabled configuration
(confirmed via a dedicated elaboration check instantiating `PIPELINED`
with `L2_SIZE_BYTES` nonzero, since the default-parameter null-elaboration
check alone never exercises the enabled `generate` branches).

**107/107 directed tests** (up from 103/103 — four new files:
`tb_l2cache_unit.v` 13 checks standalone, `tb_instr_mem_wb_adapter_unit.v`
7 checks standalone, `tb_icache_l2enable_unit.v` 3 checks standalone,
`tb_cache_l2_f1.v` 14 checks end-to-end across 4 DUT configs — proving the
inclusion probe's dirty-pullback correctness two genuinely different ways
(an L2-driven eviction forcing the probe, and an ordinary D$-driven
eviction the L2 simply absorbs), a real measured cycle-count win (148 vs
162 cycles, L2 hit vs a full round trip to backing RAM), and — after
finding 3 above — a direct backing-RAM check proving `fence` really
drains L2, not just registers).

**Constrained-random cross-check**: this phase's own required bar (5 axis
combinations, 100+50+50+50+50=300 seeds: default L2, L2+victim-cache,
L2+MSHR, L2+burst+real-latency, L2+MMU — the combined-axis runs are what
this project's own history says actually catches cross-feature bugs, not
a plain-L2-alone sweep) all clean, then re-confirmed clean again (150/150)
after finding 4's own fix. Plus 340/340 across three RV64-specific
combinations (`--xlen 64` alone, combined with `--l2-size`, combined with
`--victim-entries`) that surfaced and then confirmed the fix for finding 4.

`bench_runner.py --compare-l2`: an honest, real **negative** delta on this
project's own tiny benchmark kernels (+13.8%/+9.1%/+55.1% cycles at
`L2_SIZE_BYTES=4096`) — a genuinely different result than every prior
Gen4 cache-family phase's own "near-zero, not much to exploit" finding.
These benchmarks already fit almost entirely inside the default 4KB L1;
L2 has no capacity pressure to relieve on them at all, so every access
just pays an extra probe/hop's worth of latency with nothing to offset
it. Recorded honestly, not smoothed over — the real value proposition
(L2 absorbing what a capacity-limited L1 evicts) is what `tb_cache_l2_f1.v`'s
own `timing_on`/`timing_off` pair demonstrates directly instead.

## Future improvements

- **L2-side burst-CTI generation, victim buffer, MSHR** — deferred, see
  Alternatives above. L2's own downstream traffic never bursts this phase
  (always `CTI_CLASSIC`) — `DCache.v`'s own `BURST_ENABLE` hint is
  swallowed at L2's slave port and never propagates further.
- **Fixed L2-line-size-matches-L1 constraint** — no support for an L2 line
  wider than its own L1's line, a real, documented scope cut (see Design).
- **No HPM/CSR performance-counter event wiring for L2 hit/miss** —
  `access_hit`/`access_miss` exist on `L2Cache.v` (mirroring `DCache.v`'s
  own exactly-once discipline) but aren't wired into `CSR.v`'s
  `hpm_event_pulse[]` array this phase — testbench-tap-only, matching the
  `docs/adr/0025` precedent for every prior cache-family phase's own
  bench-runner-only evidence, not real hardware counters yet.
- **Victim-cache-related storage in `VictimCache.v` itself was NOT audited
  for the same RV64 ld/sd gap** finding 4 fixed in `DCache.v`'s own main
  array — `VictimCache.v`'s own `vc_data`/`lookup_data` arrays are
  similarly `XLEN`-wide-per-4-byte-slot. This phase's own fix covers the
  path a real random sweep exercised (100/100 clean at `--victim-entries 4
  --xlen 64`, since `sd` values do flow correctly through a victim-buffer
  promote via the fix in `DCache.v`'s own S_IDLE arm) — but `VictimCache.v`'s
  own internal FIFO-eviction/insert path was never independently re-derived
  for this width question and should be re-examined if a future phase
  needs to reason about it directly, not assumed safe purely by the
  random sweep's own absence of a failure.
- **`MemoryController.v`'s own starvation-freedom proof** (`docs/adr/0043`)
  and **the MSHR non-blocking design's own bus-serialization assumption**
  (`docs/adr/0044`) were both scoped to the pipeline's own pre-existing
  contention patterns, and both already explicitly flagged "a future phase
  adding a genuinely new bus master... should re-derive this from
  scratch." L2Cache.v *is* exactly that new bus master on the D-side path
  (between `DCache.v` and `MemoryController.v`) — not re-derived this
  phase; the physical bus stays single-master/single-outstanding
  throughout (L2 itself is blocking, no MSHR of its own), so the existing
  proof's real assumptions are unaffected in practice, but this is worth
  re-confirming explicitly if a future phase (hardware prefetchers, the
  next and final Gen4 item) adds a second genuinely independent requester.

**Generation 4 itself stays open** — hardware prefetchers remain the sole
unscoped item, its own future phase.
