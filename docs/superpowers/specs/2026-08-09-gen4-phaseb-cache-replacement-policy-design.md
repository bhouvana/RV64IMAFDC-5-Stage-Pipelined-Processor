# Gen4 Phase B: configurable cache replacement policy — design

**Date**: 2026-08-09
**Status**: approved, pre-implementation
**Precedent**: mirrors the swappable-parameter convention `HAZARD_STRATEGY`/`PIPELINE_PROFILE`/`BRANCH_PREDICTOR`/`CACHE_MODE`/`MEM_LATENCY_I`/`MEM_LATENCY_D` already established (`docs/adr/0016`, `0018`, `0021`, `0023`, `0024`, `0040`).

## Problem

`docs/ROADMAP_VISION.md`'s Generation 4 bullet "Advanced cache hierarchy" bundles four distinct items: associativity variants (2-way/4-way), victim cache, L2, replacement policies (LRU/FIFO). Treating all four as one phase risks the same coupling problems every prior multi-item Gen3/Gen4 phase avoided by staying to one coherent RTL change. This spec scopes the smallest first slice.

## Background

`design/ICache.v`/`design/DCache.v` (Phase G, `docs/adr/0023`) are already `WAYS`-parameterized (default 4, works at any power-of-2 associativity) — so "2-way vs 4-way" needs zero new RTL, only a future `bench_runner.py` sweep at different `WAYS` values. Both caches currently evict via a bare per-set round-robin pointer (`reg [WAY_BITS-1:0] victim[0:NUM_SETS-1]`, advances unconditionally on every fill, `docs/adr/0023`'s own G-phase design) — no access-recency tracking exists anywhere. This is functionally in the same family as FIFO (oldest-filled-wins), but there is no true LRU (most-recently-*used*, including hits, not just fills) anywhere in the project.

## Goals

- New `REPLACEMENT_POLICY` parameter on `ICache.v`/`DCache.v`, threaded through `riscvpipeline.v` only where `CACHE_MODE==CACHE_WRITEBACK_SETASSOC` instantiates them.
- Three closed enum values in `riscv_defs.vh`: `POLICY_ROUND_ROBIN`=0 (default, bit-exact with every existing test/ADR/benchmark), `POLICY_FIFO`=1, `POLICY_LRU`=2.
- True per-way LRU (not pseudo-LRU tree bits) — at this project's default scale (`NUM_SETS=64` at the 4KB/4-way/16B-line default) the extra state is trivial, so true LRU is strictly more correct than pseudo-LRU for no real hardware cost, matching this project's established "pick the more ambitious/more correct option" pattern.
- `sim/tools/bench_runner.py --compare-replacement` (mirrors `--compare-predictors`/`--compare-cache`/`--compare-latency`/`--compare-profiles`/`--compare-strategies`) quantifying hit-rate/cycle deltas across the three benchmark kernels.

## Non-goals (deferred to later Gen4 sub-phases, not silently dropped)

- Victim cache — separate future phase.
- L2 cache — separate future phase.
- Associativity sweep beyond the default (mechanically already possible via `WAYS`, just not exercised/benchmarked yet) — folded into whichever future phase's benchmarking pass wants it, not blocking this one.

## Design

### Enum values, `riscv_defs.vh`

`POLICY_ROUND_ROBIN`=0, `POLICY_FIFO`=1, `POLICY_LRU`=2. `POLICY_ROUND_ROBIN` and `POLICY_FIFO` are **genuinely the same underlying mechanism** (a per-set fill-order pointer advancing unconditionally on every miss, oldest-filled-wins) — both select the identical non-LRU `generate` branch in both caches. This is not a shortcut: round-robin *is* FIFO-by-fill-order at this associativity; a separately-implemented "FIFO" would be redundant RTL with zero behavioral difference from round-robin. Exposing both names lets a future benchmark/comparison explicitly label which policy a run used, without pretending they differ.

### LRU mechanism (`ICache.v`/`DCache.v`, both get the identical addition)

New `reg [WAY_BITS-1:0] age [0:NUM_SETS-1][0:WAYS-1]` per-set age-rank array: 0 = most-recently-used, `WAYS-1` = least-recently-used. Reset: `age[set][way] = way` for every set (an arbitrary-but-valid total order, matches `victim[]`'s own reset-to-0 convention of "any deterministic initial state is fine, only relative order after real accesses matters").

On every real access that touches a way — a cache **hit** (existing `way_hit`/way-index-reduction logic, extended to also produce the winning way's index, not just its data, via the same accumulator-tree pattern `hit_data_acc`/`hit_lineidx_acc` already use) or a fill completing (a miss's replacement way, the moment `valid[]`/`tag_arr[]` commit) — apply the standard LRU-stack update: every way whose current age is less than the accessed way's old age increments by one; the accessed way's age resets to 0. This is a single combinational-into-registered update, structurally the same shape as the existing `victim[fill_set_r] <= ...` fill-time update, just replacing "advance one pointer" with "reorder the whole per-set age array."

Victim selection on a miss, when `REPLACEMENT_POLICY==POLICY_LRU`: the way with `age[set_idx] == WAYS-1` (true least-recently-used), computed the same cycle the existing round-robin case reads `victim[set_idx]` — a `generate if (POLICY==POLICY_LRU) ... else ...` selects between the two victim-selection sources, mirroring `CACHE_MODE`'s own "unselected branch costs nothing" convention.

### `riscvpipeline.v`

New top-level `REPLACEMENT_POLICY` parameter, passed straight through to both cache instantiations inside the existing `CACHE_WRITEBACK_SETASSOC` generate branch. No effect at `CACHE_MODE==CACHE_NONE` (parameter simply unused, same as `MEM_LATENCY_I`/`_D` at the direct-memory path).

### Toolchain

`sim/tools/iss.py` — **zero changes**, confirmed by design: it has no cache model of any kind, the same "purely timing, zero architectural effect" category branch prediction/caches/memory-latency already established (Phase A/G/I precedent, each explicitly verified this holds before trusting it). `sim/tools/random_gen.py`/`run_random_tests.py` gain a `--replacement-policy {0,1,2}` CLI passthrough (mirrors `--branch-predictor`'s own existing shape) so the constrained-random harness can sweep it.

## Verification strategy

- **New unit-level directed test** proving true LRU differs from round-robin, not just coincidentally matching it: force a known access sequence at a small associativity (`WAYS=4`, one set) — fill A, B, C, D in order (fills way0..way3, one per way, round-robin's fill pointer wraps back to way0 after). Then hit A (a real access, not a fill — moves A to MRU), then hit B (moves B to MRU). Now miss a 5th line mapping to the same set, forcing an eviction. **Round-robin** picks whatever the blind fill-order pointer already wrapped to — way0, i.e. **evicts A** — entirely oblivious to the two intervening hits that just re-used it. **True LRU**, correctly tracking recency including hits, has the real order (MRU→LRU) B,A,D,C at that point — so it **evicts C**, the actual least-recently-touched way. This A-vs-C divergence is the concrete, worked proof the two policies are genuinely different, not just differently-named. Verify this exact hand-derived expectation against the RTL, don't assume it holds without checking (same discipline `docs/adr/0009` established).
- Full directed suite (`bash sim/run_tests.sh`), zero-warning `iverilog -Wall -g2005 -I design -tnull design/*.v`.
- Constrained-random cross-check at all 3 `REPLACEMENT_POLICY` values, `CACHE_MODE=1` only (the parameter is inert otherwise) — at least 60-100 seeds each, per this project's established sample-size bar.
- `bench_runner.py --compare-replacement` real measured hit-rate/cycle data across `bench_fib`/`bench_bubble_sort`/`bench_sum_array`.

## Risks / open questions

- The hit-way-index reduction tree is new plumbing inside both caches' existing accumulator pattern — real risk of an off-by-one in the priority-encode-style reduction (same bug class Phase G's own G-phase bugs hit). Hand-trace before trusting, mirroring `docs/adr/0009`'s precedent.
- `NUM_SETS*WAYS*WAY_BITS` age-array size at large `CACHE_SIZE_BYTES` (e.g. a hypothetical future large-cache config) grows linearly with set count — fine at this project's real default scale, worth a comment flagging it as a real (not urgent) cost if `CACHE_SIZE_BYTES` is ever pushed much larger, mirroring `docs/adr/0032`'s own "flagged, not urgent" framing for the Sv32/Sv39 PPN truncation question.
