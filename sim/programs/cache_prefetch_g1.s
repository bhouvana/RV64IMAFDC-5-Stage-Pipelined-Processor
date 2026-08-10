# docs/adr/0046-hardware-prefetchers-phase-g.md (Generation 4, Phase G).
# End-to-end directed regression: PREFETCH_MODE wired live through the real
# pipeline, not just Prefetcher.v's own standalone unit test (mirrors
# cache_mshr_e1.s's own role for MSHR_ENTRIES). A cold miss at line0 (addr
# 0-7, at the 2-way/32B/8B-line D$ override tb_cache_prefetch_g1.v
# instantiates) should trigger a next-line opportunistic prefetch of line1
# (addr 8-15) once the cache goes idle -- ten independent ALU instructions
# give line0's own fill AND the background prefetch's own fill time to both
# complete before the SECOND load reaches line1, which tb_cache_prefetch_g1.v
# confirms directly resolves as a real cache HIT (not a miss) via a
# hierarchical tap on DCache.v's own access_hit/access_miss, mirroring
# tb_cache_l2_f1.v's own "prove the mechanism directly" style. (Real total
# cycle count is reported informationally, not asserted as a hard win --
# see the testbench's own comment for why: D$ prefetching requires
# MSHR_ENTRIES>1, which ALSO makes a plain dependency-free miss retire
# non-blockingly on its own (Phase E), so converting it to a hit doesn't
# necessarily win the whole-program race -- the same honest "near-zero/even
# negative on tiny synthetic kernels" result every prior Gen4 cache-family
# phase found, most notably L2's own real negative delta.)
lw   x5, 0(x0)          # 0:  cold miss, line0 -- triggers next-line prefetch of line1 once idle
addi x10, x0, 1          # 4:  independent filler, no dependency on x5/x7
addi x10, x0, 2          # 8
addi x10, x0, 3          # 12
addi x10, x0, 4          # 16
addi x10, x0, 5          # 20
addi x10, x0, 6          # 24
addi x10, x0, 7          # 28
addi x10, x0, 8          # 32
addi x10, x0, 9          # 36
addi x10, x0, 10          # 40: by now line1 should already be resident via the opportunistic prefetch
lw   x7, 8(x0)             # 44: HIT if PREFETCH_MODE!=0, cold miss if PREFETCH_MODE=0
addi x9, x0, 777            # 48: marker: reached the end correctly
fence                        # 52
halt:
jal x0, halt                   # 56
