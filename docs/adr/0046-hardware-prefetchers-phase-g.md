# ADR 0046: Hardware Prefetchers (Generation 4, Phase G)

## Problem

`docs/ROADMAP_VISION.md`'s own Generation 4 section names three prefetch
techniques — next-line, stride, stream — as its own bullet, with no
ordering note attached; the real Gen4 implementation order (victim cache →
memory controller → non-blocking/MSHR → L2 → prefetchers) was decided
separately, via `AskUserQuestion`, in `docs/adr/0042`'s own Problem section.
Every other item in that order is now closed (`docs/adr/0042`-`0045`).
Prefetchers is the sole remaining unscoped item — closing this phase closes
Generation 4 (Advanced Memory Architecture v4.0) itself.

## Design

**Scope, confirmed via `AskUserQuestion` before any RTL** (most-ambitious
option chosen every time, per this project's own established pattern): both
I$ and D$ (not D$-only); all three techniques as one swappable
`PREFETCH_MODE` parameter (not next-line only); opportunistic reuse of each
cache's existing fill machinery (not a dedicated bus master +
`MemoryController.v` arbitration tier); fixed 1-line-ahead prediction for
every mode (no `PREFETCH_DEGREE` parameter).

**One module, `design/Prefetcher.v`, two instances** — mirrors
`VictimCache.v`'s own "one implementation shared by both caches" precedent
(`docs/adr/0042`). A genuine, deliberate simplification found by research
*before* writing any RTL, not discovered by running: neither `ICache.v` nor
`DCache.v` has a per-access PC available at the point a miss is recognized
(`DCache.v`'s own query address is the ALU-computed effective address, not
an instruction PC — confirmed by direct code read). A real PC-indexed
stride table would need new pipeline plumbing threading PC into both
caches, out of scope for this phase — `Prefetcher.v` is instead a
single-global-entry predictor, keyed on the raw miss-address stream itself
(`# ponytail`-tagged in the module's own header: table-of-1, upgrade to an
N-entry PC-indexed table only if a future phase threads PC in and
multi-stream interleaving turns out to matter). Stride confirmation needs
two consecutive matching strides before it trusts a prediction; stream
mode reuses the identical mechanism with a higher confirmation-run
threshold (`STREAM_CONFIRM_RUN=2`) — the only difference between the two
modes is how many confirmations it takes to trust the same underlying
stride estimate.

**Fires only on a genuine demand-miss**, reusing each cache's own existing
miss-detection condition as the update trigger (`DCache.v`'s `access_miss`,
`ICache.v`'s own `S_IDLE` genuine-miss branch) — zero new hooks into either
cache's hit path.

**No new bus-master port, no `MemoryController.v` change** — deliberately
sidesteps the exact gap `docs/adr/0043`/`0045` both flagged for a future
new bus master ("should re-derive the starvation-freedom proof from
scratch"). D$ opportunistically allocates an ordinary MSHR entry (flagged
`mshr_is_prefetch[]`) through the existing Phase E machinery, only when
otherwise idle and a spare slot exists (`MSHR_ENTRIES>1` required — a solo
prefetch at `MSHR_ENTRIES==1` would block a real access with no way to
overlap it, a documented no-op otherwise). I$ has no MSHR at all — a
single-entry "prefetch-in-flight" reuse of its existing two-state FSM,
firing only when the cache is otherwise idle (a real hit this cycle, no
fill in progress); only meaningful when `L2_ENABLE=1` (no real miss latency
to hide under the private, always-combinational `InstructionMemory` path).
Confirmed by direct trace, not assumed: `icache_busy`/`icache_done` are
dead wires in `riscvpipeline.v` (declared, wired to `ICache`, never read by
anything else) — `pc_stall`'s own `icache_miss` term is purely
`!icache_hit`-based, so an opportunistic I$ prefetch occupying the FSM in
the background is externally invisible to the pipeline as long as the
current fetch keeps hitting.

**Dedupe, both caches**: skip firing if the predicted line is already
resident (a second, independent tag/set decode + N-way compare against the
predicted address, mirroring the inclusion probe port's own "arbitrary
address, not the live request" pattern, `docs/adr/0045`) or, D$ only,
already the target of an outstanding MSHR entry. **Never evicts a dirty D$
line** for speculation — `prefetch_fire` is gated on the target victim way
being clean; I$ needs no equivalent guard (no dirty bit at all, any
resident line is safe to evict). Prefetch fills are always committed clean
(`a_is_write` is always `1'b0` for a prefetch entry) — `fence`'s existing
whole-cache-flush logic needs zero changes, unlike the victim buffer's own
documented fence-visibility gap.

**`mshr_complete`/`resp_ready`/`resp_rdata`'s S_FILL arms explicitly
exclude a completing prefetch entry** (`mshr_is_prefetch[mshr_head_r]`) —
nothing real is waiting on it, so it must never accidentally satisfy a real
caller. The array-commit logic itself needs no such exclusion; it is
correct and desired for a prefetch fill too.

## Real bugs/findings

Two real, distinct issues found by running — one genuinely new (introduced
by this phase's own design), one a previously-latent bug this phase's own
verification axis was the first to exercise. Neither found by the directed
suite alone; both found by the constrained-random cross-check, matching
this project's long-established "bugs reveal themselves by running"
pattern:

1. **A genuine, permanent deadlock**, found by a 30-seed smoke sweep at
   `--prefetch-mode 1` hanging on seed=3. The original design's own Global
   Constraint assumed an out-of-range predicted address was harmless
   ("same masking any address gets, worst case wastes a bus cycle") —
   never verified against this project's actual bus decode before being
   written down, and wrong: `WbDecoder.v`'s own "gap" behavior (already
   proven by `tb_wbdecoder_unit.v`'s own "no slave selected... `m_ack`
   stays low" case) means a predicted line running past the end of real
   backing memory gets **no bus acknowledgement at all**, not a masked/
   wrapped address. Confirmed by direct trace: a `NEXT_LINE` prediction one
   line past `MEM_SIZE_BYTES=128` (`m_addr=0x80`) left `m_ack` permanently
   0, hanging the whole pipeline forever waiting on a prefetch fill that
   could never complete — a full deadlock, not a bounded performance cost.
   Fixed with a new `MEM_SIZE_BYTES` parameter on `DCache.v` (a real
   backing-memory-size bound the module never previously needed to know)
   and reuse of `ICache.v`'s own existing `IMEM_SIZE_BYTES` parameter —
   `prefetch_fire` now requires the predicted line to end at or before that
   bound. Defaults to an enormous sentinel so every pre-existing standalone
   testbench that never wires the parameter is unaffected;
   `riscvpipeline.v` passes the real `MEM_SIZE_BYTES` whenever it wires
   `PREFETCH_MODE` live.
2. **A real, pre-existing, previously-unknown bug, confirmed unrelated to
   prefetching**: found by a 200-seed sweep at `--mshr-entries 2 --mmu`
   (this phase's own required verification combo), seed=155 mismatching on
   an architectural register never explicitly written by the generated
   program. Confirmed pre-existing (not a Phase G regression) by
   reproducing identically with `PREFETCH_MODE=0` and again by bisecting to
   Phase E's own closing commit (`bb6f3d2`, before L2/RV64/prefetch work
   ever touched `DCache.v`) — latent since Phase E's own non-blocking MSHR
   landed, not introduced by any later phase. Root cause: `Scoreboard.v`'s
   `pending[]` array update (`docs/adr/0044`) is a registered, non-blocking
   assignment — `dcache_mshr_accept` firing for a load sets its
   destination register pending only from the *next* cycle onward.
   `scoreboard_stall` in `riscvpipeline.v` checked only this registered
   mask, missing the exact cycle allocation itself fires: an instruction
   already in decode that same cycle (the one immediately behind the load
   that just went non-blocking) sees a stale, not-yet-updated mask, sails
   through unstalled, and reads garbage instead of stalling for the real
   value. Direct trace confirmed the exact mechanism: a queued `lbu`'s own
   destination register briefly held whatever value the page-table
   walker's own most recent bus read happened to leave behind (pure
   coincidence of timing, not itself the bug). Fixed by also checking THIS
   cycle's own fresh allocation combinationally
   (`dcache_mshr_accept`+`write_to_Reg_regem`, the same RAW/WAW shape the
   registered check already uses), not waiting one cycle for the
   registered mask to catch up. Confirmed via `AskUserQuestion` (fix now
   vs. flag-and-defer) — chosen to fix now, matching this project's
   established precedent (`docs/adr/0045`'s own RV64 `ld`/`sd` finding).

## Alternatives considered

- **A dedicated bus-master port + a new `MemoryController.v` priority
  tier** — the more "textbook" prefetcher architecture (a genuine separate
  requester, lowest priority); explicitly offered via `AskUserQuestion`,
  not chosen. Reopens the exact bus-preemption gap `docs/adr/0043`/`0045`
  both already flagged: once a lower-priority prefetch wins the bus,
  today's single-outstanding-per-master discipline has no way to abort it
  mid-transfer to let a real demand miss through.
- **A PC-indexed, N-entry stride/stream table** — the more accurate
  classical design; not built, since neither cache has a PC available at
  the point a miss is recognized without new pipeline plumbing (see
  Design). Single-global-entry chosen instead, `# ponytail`-flagged as the
  real ceiling.
- **A configurable `PREFETCH_DEGREE` parameter** — offered, not chosen
  (confirmed via `AskUserQuestion`): this project's own tiny benchmark
  kernels can't meaningfully validate a different value either way: a
  tuning knob with nothing real to tune against is speculative complexity.
- **Next-line only, stride/stream deferred** — offered as the simpler
  option; not chosen. All three techniques shipped as one swappable
  parameter, matching `REPLACEMENT_POLICY`'s exact precedent shape.

## Validation strategy

Zero-warning `iverilog -Wall -g2005 -I design -tnull design/*.v` compile at
`PREFETCH_MODE=0` (default, bit-identical to pre-Phase-G) throughout.

**109/109 directed tests** (up from 107/107 — `tb_prefetcher_unit.v` 25
checks standalone, unit-testing all 3 modes plus off/reset behavior against
the module in isolation; `tb_cache_prefetch_g1.v` end-to-end, proving both
correctness at both `PREFETCH_MODE` settings and the real intended
mechanism directly — dut1's second load is a genuine `access_miss`, dut2's
identical load is a genuine `access_hit` — rather than asserting a
whole-program cycle-count race, see that testbench's own header comment for
why: `MSHR_ENTRIES>1` (required for D$ prefetching) already lets a plain
dependency-free miss retire non-blockingly at near-zero cost on its own,
Phase E, so converting that same miss into a hit doesn't automatically win
a whole-program race the way it would against a genuinely blocking
baseline).

**Constrained-random cross-check**: this phase's own required bar (7 axis
combinations, 200 seeds each = 1400 total: default `PREFETCH_MODE=1/2/3`
alone, prefetch+victim-cache, prefetch+L2 — exercising I$ prefetch too,
prefetch+burst+real-latency, prefetch+MMU) all clean, plus a 200-seed
`--mshr-entries 2 --mmu` re-run with `PREFETCH_MODE=0` confirming finding 2
above is fully fixed independent of prefetching, plus a fresh 200-seed
re-run of the exact prefetch+MMU combo that originally found it. **1800
total seeds, all clean.**

`bench_runner.py --compare-prefetch`: an honest, real, small **mixed-sign**
delta on this project's own tiny benchmark kernels at `PREFETCH_MODE=1`
(+0.7% `bubble_sort`, +0.0% `fib`, -2.1% `sum_array`) — matching the
established "near-zero, not much to exploit on these tiny kernels" result
every prior Gen4 cache-family phase except L2 has found (L2's own real
*negative* delta remains the one outlier). Recorded honestly, not smoothed
over — the real mechanism proof is `tb_cache_prefetch_g1.v`'s own direct
`access_hit`/`access_miss` check, not the benchmark numbers.

## Future improvements

- **Single-global-entry predictor, not PC-indexed** — see Design/
  Alternatives. A future phase threading PC into `ICache.v`/`DCache.v`
  (needed for other reasons too, e.g. a real branch-target-adjacent
  prefetcher) could revisit this for genuinely better multi-stream
  accuracy; not motivated by anything broken today.
- **Fixed 1-line-ahead degree, no `PREFETCH_DEGREE` parameter** — see
  Alternatives. This project's own tiny benchmark kernels give no signal
  either way; add the knob only if a real, larger workload ever needs it.
- **D$ prefetch requires `MSHR_ENTRIES>1`; I$ prefetch requires
  `L2_ENABLE=1`** — both documented, deliberate no-ops otherwise, not
  silently-dropped gaps.
- **No cross-cache prefetch** — a D$ miss never triggers an I$ prefetch or
  vice versa; each `Prefetcher.v` instance only ever learns from its own
  cache's own miss stream.
- **I$'s own demand-miss-races-a-prefetch cost is worse than D$'s** — I$
  has no MSHR to overlap a demand miss with an in-flight prefetch fill (a
  real access must wait for the single FSM to free up, bounded to
  `LINE_WORDS` cycles worst case); D$ can overlap both via its existing
  non-blocking MSHR machinery. A real, honest, bounded, documented
  asymmetry, not an oversight.
- **The pre-existing scoreboard one-cycle race (finding 2)** was fixed at
  its one real call site (`scoreboard_stall`) — if a future phase adds
  another consumer of `scoreboard_pending_mask` that needs same-cycle
  visibility into a fresh `dcache_mshr_accept` allocation, it will need the
  identical combinational same-cycle check, not just the registered mask.

**Generation 4 (Advanced Memory Architecture v4.0) is now CLOSED** — every
item in `docs/ROADMAP_VISION.md`'s own Generation 4 section (advanced
branch prediction, advanced cache hierarchy, non-blocking cache, memory
controller, hardware prefetchers) is done.
