# docs/adr/0042-victim-cache-phase-c.md (Generation 4, Phase C). End-to-end
# directed regression: VICTIM_ENTRIES wired live through the real pipeline,
# not just DCache.v's own standalone unit test (mirrors cache_lru_b1.s's own
# role for REPLACEMENT_POLICY). 2-way/32B/8B-line D$ override (2 sets) --
# store A(0)/C(16) fills both ways of set0, store E(32) (a 3rd distinct tag)
# forces a real eviction of A (dirty) into the victim buffer, then re-load A
# -- main array misses it, but the victim buffer promotes it back in one
# cycle. tb_cache_victim_c1.v's own sticky tap confirms the promote path
# genuinely fired, not just that the final register content happens to be
# correct.
addi x1, x0, 100      # 0:  A's value
addi x2, x0, 200       # 4:  C's value
addi x3, x0, 300         # 8:  E's value
sw   x1, 0(x0)              # 12: A -> addr0  (miss, fills way0)
sw   x2, 16(x0)                # 16: C -> addr16 (miss, fills way1 -- set0 now full)
sw   x3, 32(x0)                   # 20: E -> addr32 (miss): forces eviction of A
                                    #     (dirty) into the victim buffer
lw   x4, 0(x0)                        # 24: re-load A -- main array misses, victim
                                        #     buffer promotes it back in ONE cycle
addi x5, x0, 999                          # 28: marker: reached the end correctly
fence
halt:
jal x0, halt                                # 36
