# docs/adr/0044-non-blocking-dcache-mshr-phase-e.md (Generation 4, Phase E).
# End-to-end directed regression: MSHR_ENTRIES wired live through the real
# pipeline, not just DCache.v's own standalone unit test (mirrors
# cache_victim_c1.s's own role for VICTIM_ENTRIES). Two cold-miss loads to
# different lines (addr0/set0, addr8/set1 at the 2-way/32B/8B-line D$
# override tb_cache_mshr_e1.v instantiates) with an independent (no
# dependency on either load) ALU instruction between them, then a THIRD
# instruction with a real RAW dependency on the FIRST load's own result --
# proves both (a) correct data despite non-blocking completion and (b) the
# RAW consumer genuinely stalls until its own MSHR resolves, not just that
# the final architectural state happens to be right.
lw   x5, 0(x0)        # 0:  cold miss, addr0 (set0) -- non-blocking at MSHR_ENTRIES>1
addi x6, x0, 42        # 4:  independent -- no dependency on x5, should execute
                         #     WHILE addr0's own fill is still draining
lw   x7, 8(x0)            # 8:  cold miss, addr8 (set1) -- a SECOND concurrent MSHR
addi x8, x5, 1               # 12: RAW on x5 -- must stall in ID until x5's own
                               #     MSHR completes, then read the CORRECT value
addi x9, x0, 777                 # 16: marker: reached the end correctly
fence
halt:
jal x0, halt                        # 24
