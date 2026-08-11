# ADR 0056: BTB-Predicted jalr in OOOCore.v (Gen6-P5)

## Problem

`docs/adr/0051` (Gen6-O4) deferred a genuine BTB-predicted jalr as "real future work, if profiling ever
shows this stall costing real cycles" — the fifth of six backlog sub-phases the user's own "finish the
backlog first, then close" directive names. jalr previously used a plain stall-and-wait (mirroring
`trap_inflight_valid_r`'s shape): dispatch of everything else blocks, `pc_r` freezes at a meaningless
value, and only resolves once the RS_ALU entry actually issues and computes the real `rs1+imm` target.

## Design

### Same predict/verify/recover shape conditional branches already use

Reuses the SAME shared `m_Btb` instance conditional branches already query every cycle (untagged by
instruction class, per `Btb.v`'s own header — any instruction can train or query it). `jr_resolve` joins
`br_resolve && br_actual_taken` as a second, independent BTB training source — jalr needs no BHT
(direction) involvement at all, since it's unconditional ("always taken"). The two training sources are
mutually exclusive by construction: both require their own `*_inflight_valid_r`, and this whole
generation's single-outstanding scope cut means at most one of branch/jalr can ever be in flight at once.

At dispatch, `jr_predicted_target = btb_hit ? btb_target : (pc_r + 4)` — a cold/missed BTB entry has no
real target at all, so the "prediction" is an honest near-certain-miss fallback (`pc+4`), matching
PIPELINED's own conditional-branch BTB-miss default, not a fabricated guess. `pc_r` speculatively
redirects to this predicted target THE SAME CYCLE jalr dispatches (mirrors `is_branch && predicted_taken`'s
own arm in the PC-advance block exactly). At resolve, `jr_mispredict = jr_resolve && (jr_target !=
jr_inflight_predicted_target_r)` — only a genuine mismatch redirects `pc_r`; a correct prediction needs
no action, since `pc_r` already sits at the right place.

### Honest finding: zero measurable cycle benefit in THIS core, as it stands today

Worked out by design, not assumed correct and left unexamined: because dispatch of everything else stays
blocked regardless of prediction quality (the SAME single-outstanding scope cut conditional branches
already live with — `docs/adr/0021`'s own header: "dispatch of EVERYTHING... stalls until it resolves"),
and this core's own frontend is purely combinational with zero fetch/dispatch decoupling (Gen6-D's own
documented scope), a CORRECT prediction saves nothing measurable over the old stall-and-wait design —
`pc_r` already sat at `jr_target` the cycle `jr_resolve` fired either way, in both the old and new
designs, for the correctly-resolving case. The real value delivered this phase is architectural
consistency with branches (one prediction/recovery mechanism for both kinds of indirect control flow,
not two different shapes) and a genuine foundation for whichever future phase relaxes the
single-outstanding scope cut into real deep speculation — where decoupled fetch would actually benefit.
Documented plainly here rather than oversold, matching this project's own "evidence over assumption"
discipline.

## Real bugs/findings

None found by running — the mechanism worked correctly on the first real attempt for both the
misprediction-recovery path (proven already by the pre-existing `tb_ooocore_jalr_o3.v`, unmodified,
still 4/4) and the new correct-prediction path (the new directed test below, 6/6 first run). The one
substantive design decision requiring care — using `jr_inflight_pc_r`/`jr_inflight_predicted_target_r`
captured at DISPATCH time, not resolve time, for BTB training/misprediction comparison, mirroring
`br_inflight_pc_r`/`br_inflight_predicted_target_r`'s own exact precedent — was gotten right by directly
copying the already-proven branch shape rather than re-deriving it from scratch.

## Testing

- `tb_ooocore_jalr_btb_p5.v`: the SAME jalr instruction (fixed PC) executes twice via a real loop —
  iteration 1 is a genuine cold-BTB miss (predicts `pc+4`, mispredicts against the real target, recovers);
  iteration 2 (after the BTB trains from iteration 1's own `jr_resolve`) is a genuine BTB hit, predicting
  the real target correctly with `jr_mispredict=0`. A live per-cycle monitor captures `jr_mispredict` at
  each of the two `jr_resolve` pulses to prove both paths directly, not just infer them from final
  architectural state. 6/6, first run.
- `tb_ooocore_jalr_o3.v` (pre-existing, unmodified): still 4/4 — confirms the single-jalr,
  cold-BTB-miss-then-recover path (this phase's own mechanism, exercised for the first time by an
  EXISTING test written before this phase existed) stays correct.
- Full directed regression: confirmed clean, zero-warning `iverilog -Wall -g2005` compile, no other file
  needed changes (the shared `m_Btb` widening and jalr's own section are both fully internal to
  `OOOCore.v`).

## Alternatives considered

- **Skip this phase entirely**, given the honest zero-measurable-benefit finding above. Rejected — the
  user's own explicit backlog directive names it, `docs/adr/0051` itself flagged it as real (if
  deferred) future work, and the mechanism has genuine value as a foundation for future deep speculation
  plus architectural consistency with branches, even without an immediate throughput win.
- **A genuinely deeper speculative window for jalr** (relaxing single-outstanding, letting fetch actually
  decouple from dispatch to realize the prediction's real value). Rejected for this phase — the same
  "no deep speculation yet" scope cut this whole generation already applies to branches/traps; a much
  larger, riskier undertaking real future work, not this phase's own scope.

## Future improvements

- `docs/adr/0049`'s remaining backlog, now minus this phase: Gen6-P6 (widen `random_gen.py`'s own
  `--ooo` fuzzer), then the real Gen6 closure ADR.
- **Real deep speculation** (relaxing the single-outstanding scope cut for branches AND jalr together,
  with decoupled fetch) — the natural place this phase's own "zero measurable benefit today" finding
  would finally pay off. Real future work, flagged repeatedly across this whole generation's own ADRs
  (`docs/adr/0021`, `docs/adr/0051`, here).
- **Widen `random_gen.py`'s own `--ooo` fuzzer** to exercise jalr's own BTB hit/miss paths specifically
  — deferred alongside every other fuzzer-widening item already queued for Gen6-P6.
