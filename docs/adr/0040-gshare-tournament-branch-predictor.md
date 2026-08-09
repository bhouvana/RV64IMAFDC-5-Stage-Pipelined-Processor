# ADR 0040: GShare + Tournament Branch Predictor (Generation 4, Phase A)

## Problem

Generation 3 closed (`docs/adr/0036`-`0039`); Phase X (the real Sv39 `relocate` page-fault
investigation) is real, open, deliberately-paused backlog, not this phase's concern. The user asked to
start Generation 4 ("Advanced Memory System," `docs/ROADMAP_VISION.md`) — five sub-items: advanced
branch prediction, advanced cache hierarchy, hardware prefetchers, non-blocking cache, memory
controller. Confirmed via `AskUserQuestion`, following this project's own established phase-by-phase
sequencing discipline (every Generation 3 sub-item was its own phase, not all built at once): branch
prediction first (research found the existing predictor interface already generic enough for a
low-risk drop-in, and `sim/tools/bench_runner.py` already had a working `--compare-predictors` A/B
harness built for exactly this), and both GShare and tournament, not just one (the user's own
established pattern of picking the most ambitious option every time this question has come up).

## Design

Two new standalone modules, each mirroring `design/Bht.v`'s existing shape (direct-mapped, 2-bit
saturating counters, deliberately untagged, combinational query / synchronous resolved-only update —
see that module's own header for the full correctness reasoning, unchanged here):

- **`design/Gshare.v`**: indexes by a PC-bit slice XORed with a global history register (the outcome
  of the last `INDEX_WIDTH` resolved branches/jumps). History width equals `INDEX_WIDTH` (reuses
  `NUM_ENTRIES`' own sizing, no new parameter) and updates **resolved-only**, not speculatively — the
  same "no same-cycle bypass" simplification `Bht.v` already accepts, deliberately not attempting
  speculative-history update-with-rollback (a genuinely separate, larger feature; see Alternatives
  considered).
- **`design/Chooser.v`**: the tournament meta-predictor. Trains only on *disagreement* between two
  sub-predictors ("A" = `Bht.v`, "B" = `Gshare.v`), nudging toward whichever was actually correct —
  the classic tournament training rule (agreement, right or wrong, carries no signal about which is
  more reliable).

**The one real design decision worth documenting**: how does `Chooser.v` learn which sub-predictor was
right, without a new per-instruction pipeline signal? The obvious approach — thread each sub-predictor's
original at-fetch-time opinion through `reg1`/`reg1a`/`reg2` alongside the instruction, the same way
`predict_taken_if`/`predict_target_if` already travel to `predict_taken_regde`/`predict_target_regde` —
would have needed two new latched bits end-to-end through the pipeline, a materially bigger and riskier
change than this phase's own research suggested was necessary. Instead, `Bht.v` gained a second,
independent combinational read port (`train_pc` → `train_predict_taken`, mirroring `design/Tlb.v`'s own
"one array, two independent read ports" precedent, `docs/adr/0022`), and `Gshare.v` was given the
identical shape from the start. `Chooser.v`'s `a_correct`/`b_correct` inputs are computed by re-querying
both tables at `bp_update_pc` (the PC actually resolving this cycle) via this second port and comparing
each against the real resolved outcome — zero new latched pipeline signal, at the cost of one small,
documented approximation: if the same PC is re-trained (a tight loop revisiting the same branch) between
when it was originally fetched and when it resolves, this re-query sees the table's *current* state, not
necessarily the exact opinion that was live at fetch time. Same class of accepted approximation `Bht.v`'s
own aliasing note already establishes — costs at most a bubble, never a wrong architectural answer,
confirmed by the full random cross-check below.

`design/Btb.v` (target prediction) is completely unchanged and shared across every dynamic scheme —
GShare/tournament only change *direction* prediction. The `gen_predictor` generate block was
restructured to instantiate `Btb.v` once, then nest direction-scheme selection inside it (three
`generate if` arms: BHT+BTB, GShare, tournament), avoiding tripling the `Btb.v` instantiation.

## Real bugs/findings

1. **A real, pre-existing hardcoding bug, found by design/read-through before writing any RTL** (same
   `docs/adr/0009` discipline): `branch_or_jump_redirect`/`branch_or_jump_target` were gated on
   `BRANCH_PREDICTOR == PREDICTOR_DYNAMIC_BHT_BTB` specifically, not "any dynamic scheme" — silently
   correct through Generation 3 (nothing else ever existed), but would have silently fallen through to
   `PREDICTOR_STATIC`'s own always-squash behavior for GShare/Tournament, architecturally safe but
   completely defeating the point of adding a new predictor, while `mispredict_pulse`/
   `branch_retired_pulse` kept reporting misleading "always mispredicted" stats. Generalized to
   `BRANCH_PREDICTOR != PREDICTOR_STATIC` — bit-exact for the existing two values.
2. **A real, pre-existing, project-wide tooling bug, found by running, not anticipated**: the
   constrained-random cross-check reported "exceeded 5000 steps without reaching a self-loop" for
   *every* seed at *every* `BRANCH_PREDICTOR` value, including the untouched default (0) — confirmed
   pre-existing against the fully unmodified tree before concluding it was this phase's own fault. Root
   cause: `sim/tools/run_random_tests.py`'s (and identically, `bench_runner.py`'s and `debugger.py`'s)
   own `load_words()` helper reconstructed each 32-bit word MSB-first — the byte order
   `InstructionMemory.v`/`DataMemoryBRAM.v` used *before* Phase U (`docs/adr/0037`). Phase U flipped
   both memories to LSB-first and updated `asm.py`/`elf2mem.py` to match, but never touched these three
   Python tools' own independent copies of the same helper — silently decoding every ISS-side reference
   word backwards ever since. Same root-cause class as `docs/adr/0039`'s `CompressedExpander.v` include
   gap: a real, load-bearing change that should have propagated everywhere but silently didn't, only
   surfacing once this phase's own work needed the constrained-random harness to actually run. Fixed in
   all three files identically (reverse the byte concatenation order); re-confirmed 100/100 at the
   pre-existing `BRANCH_PREDICTOR` values 0 and 1 after the fix, not just the two new ones.
3. **A third, smaller instance of the same missing-include pattern**: `dump_regs_template.v`,
   `dump_regs_interrupt_template.v`, `bench_template.v`, and `profiler_template.v` (the RTL templates
   `run_random_tests.py`/`bench_runner.py`/`profiler.py` fill in and compile per-seed/per-run) were
   missing `` `include "Gshare.v"``/``"Chooser.v"`` — needed once `BRANCH_PREDICTOR` could actually take
   values 2/3 through those tools. `c_bench_template.v` correctly left untouched — it never
   parameterizes `BRANCH_PREDICTOR` at all.
4. No bugs found in `Gshare.v`/`Chooser.v`'s own new logic by running — both standalone unit tests
   passed on the first run after a deliberate hand-trace of the GHR shift math (`INDEX_WIDTH=2`
   arithmetic worked out by hand before trusting the RTL, `docs/adr/0009`'s own discipline), and the
   live-wired end-to-end tests and 100/100 random cross-checks both passed without needing a second
   RTL iteration.

Real measured cycle-count data (`bench_runner.py --compare-predictors`, this project's own 3 benchmark
kernels): BHT+BTB gives the largest win over static (-10% to -24% cycles). GShare alone is a smaller
win (-6% to -19%) on these specific kernels — an honest, expected result: `bubble_sort`/`fib`/
`sum_array` are small, simple synthetic kernels without much cross-branch history correlation for
GShare's own indexing to exploit; the new `branch_predict_history.s` directed test (Task 5) separately
demonstrates the *directional* correctness of history-aware indexing on a program deliberately built to
have one. Tournament matches BHT+BTB's own numbers exactly on all three kernels — the chooser correctly
learned BHT was the better sub-predictor here and converged to always prefer it, exactly the intended
tournament behavior, not a bug.

## Alternatives considered

**Speculative-history GShare** (folding in-flight, not-yet-resolved branch guesses into the global
history register, with rollback on misprediction). Real, genuinely higher-fidelity GShare behavior —
resolved-history-only under-predicts in tight, deeply-pipelined branch sequences where several branches
are in flight before the oldest resolves. Not attempted this phase: needs real recovery/rollback
machinery this core has no precedent for at this granularity, a materially larger and riskier scope than
this phase's own confirmed goal (branch prediction as a low-risk *first* Gen4 phase). Real, flagged
future work.

**Threading each sub-predictor's original at-fetch-time opinion through the pipeline** as new latched
signals, instead of the second-read-port re-query design. Rejected in favor of the smaller, lower-risk
change — see Design section above for the full tradeoff.

## Validation strategy

`iverilog -Wall -g2005 -I design -tnull design/*.v` (via `/c/iverilog/bin`, not OSS CAD Suite's bundled
Icarus — `docs/adr/0039`'s own toolchain note): zero-warning at every step. Full directed suite
(`bash sim/run_tests.sh /c/iverilog/bin`): **92/94** — the same two pre-existing, unrelated failures
`docs/adr/0039` documents (`tb_arith`'s own flagged `ctz` off-by-one, `tb_icache_unit`'s stale
post-byte-order-fix expected values), plus the two new end-to-end directed tests
(`tb_branch_predictor_gshare`, `tb_branch_predictor_tournament`) both passing. `BRANCH_PREDICTOR=1`
re-confirmed bit-exact after the `gen_predictor` restructuring, including exact per-iteration
misprediction timing (`tb_branch_predictor.v`'s own existing checks). **100/100 constrained-random
cross-check** at both new values (2, 3) and re-confirmed 100/100 at both pre-existing values (0, 1)
after the `load_words()` fix. Real cycle-count comparison via `bench_runner.py --compare-predictors`
(see Real bugs/findings above for the actual numbers).

## Future improvements

Speculative-history GShare (see Alternatives considered). HPC event-counter codes specific to which
sub-predictor the chooser picked (today's generic `mispredict_pulse`/`branch_retired_pulse` already
correctly reflect the combined scheme's real accuracy, but don't distinguish "chooser picked A and was
right" from "chooser picked B and was right") — `docs/adr/0025`/`0026`'s own 19-event-slot ceiling
would need widening first. A wider history with fold-XOR indexing, if a much larger `BHT_BTB_ENTRIES`
is ever benchmarked (today's small default reuses the index width directly, a real, deliberate
simplification for this project's own small default table sizes). Generation 4 itself stays open — four
more sub-items (advanced cache hierarchy, hardware prefetchers, non-blocking cache/MSHRs, memory
controller) remain fully unscoped, each its own future phase.
