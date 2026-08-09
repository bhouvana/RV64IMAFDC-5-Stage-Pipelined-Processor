# docs/adr/0040-gshare-tournament-branch-predictor.md (Generation 4, Phase
# A). A branch whose own correct direction genuinely depends on recent
# history, not just raw taken/not-taken frequency: `beq x2,x0,skip` is taken
# on every EVEN iteration and not-taken on every ODD iteration (x2 is the
# parity of the remaining loop count) -- a strictly alternating pattern at
# ONE static PC, the textbook case a plain 2-bit bimodal counter (Bht.v
# alone) can never settle into a stable prediction for (it oscillates
# between weakly-taken/weakly-not-taken and mostly mispredicts), unlike a
# history-correlated scheme (Gshare.v/Chooser.v, BRANCH_PREDICTOR=2/3) that
# can in principle exploit the pattern once the same history recurs.
#
# This test checks ARCHITECTURAL correctness only (x10/x11/x12's final
# values) -- misprediction TIMING differs by design across BRANCH_PREDICTOR
# values and is never itself a correctness requirement (docs/adr/0021's own
# established invariant: misprediction changes cycle count, never the
# answer). Real cycle-count comparison across schemes is
# sim/tools/bench_runner.py's own job (docs/adr/0040's Validation strategy).
addi  x1, x0, 12     # 0: outer trip count (12 -> 6 full even/odd pairs)
addi  x10, x0, 0     # 4: accumulator -- total iterations
addi  x12, x0, 0     # 8: counts odd-parity iterations only
loop:
andi  x2, x1, 1      # 12: parity of remaining count -- alternates every iteration
beq   x2, x0, skip   # 16: taken on EVEN x1, not-taken on ODD x1
addi  x12, x12, 1    # 20: only reached on odd iterations
skip:
addi  x10, x10, 1    # 24
addi  x1, x1, -1     # 28
bne   x1, x0, loop   # 32
addi  x11, x0, 777   # 36: proves the loop exited via correct fall-through

fence
halt:
jal   x0, halt       # 40: spin here forever
