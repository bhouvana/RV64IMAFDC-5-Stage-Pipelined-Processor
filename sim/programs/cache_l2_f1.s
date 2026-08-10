# docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). End-to-end
# directed regression: L2 wired live through the real pipeline, not just
# L2Cache.v's own standalone unit test (mirrors cache_mshr_e1.s's own role
# for MSHR_ENTRIES). One straight-line program, run against FOUR different
# D$/L2 sizing pairs in tb_cache_l2_f1.v -- the SAME instruction sequence
# produces two genuinely different real scenarios depending purely on
# cache geometry:
#
#  - "correctness" sizing (D$ 2 sets, L2 2-way/1-set): loading addr64 (C)
#    never evicts addr0 (A) from D$ (D$ has room), but DOES force L2 to
#    evict A's line (L2's own capacity is exhausted by A+B already) WHILE
#    A is still dirty-resident in D$ -- L2 must probe D$, pull the dirty
#    data, and the probe's own invalidate side effect is what forces the
#    final re-read of A to miss all the way down. Proves the inclusion
#    probe's dirty-pullback end to end, through the real pipeline.
#  - "timing" sizing (D$ 1 set/2-way, L2 4-way/1-set): loading addr64 (C)
#    forces D$ to evict A on its OWN capacity (an ordinary, pre-existing
#    DCache.v writeback, nothing L2-specific) -- L2 has plenty of spare
#    capacity and simply absorbs it. The final re-read of A is a genuine
#    D$ miss but a real L2 HIT -- the real, measurable win this phase
#    exists for, vs. a full round trip to backing RAM when L2 is disabled.
#
# Either way, x9's own final value (999, the dirty value written in the
# middle of the program) is the same real correctness invariant -- L2
# on or off, small or big, the SAME dirty write must survive.
lw   x5, 0(x0)         # 0:  load A (addr0) -- cold miss
lw   x6, 16(x0)        # 4:  load B (addr16) -- cold miss
addi x7, x0, 999        # 8:  known dirty value
sw   x7, 0(x0)             # 12: store A -- D$ write-hit (write-back, dirties D$ ONLY)
lw   x8, 64(x0)               # 16: load C (addr64) -- forces an eviction (D$'s own
                                #     capacity under "timing" sizing, L2's own capacity
                                #     under "correctness" sizing) while A is still dirty
lw   x9, 0(x0)                    # 20: re-load A -- must return 999, the dirty value,
                                    #     regardless of which eviction path forced it
addi x10, x0, 111                     # 24: marker -- reached the end correctly
fence                                    # 28
halt:
jal x0, halt                                # 32
