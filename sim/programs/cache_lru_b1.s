# docs/adr/0041-cache-replacement-policy-phase-b.md. Directed regression:
# proves REPLACEMENT_POLICY=2 (POLICY_LRU) threads live through the real
# pipeline, not just DCache.v's own standalone unit test. Same worked
# example as tb_dcache_unit.v's own dut2 (docs/adr/0041's findings
# section): store A(0)/B(16)/C(32)/D(48) -- one per way of a 4-way/2-set
# D$ override, all sharing set0 -- re-load A/B (real hits), store E(64)
# forces a real eviction (of C, the actual least-recently-used way; a
# round-robin policy would instead blindly evict A). Then confirm D/A
# still hit correctly and C, though evicted, still round-trips correctly
# (write-back never loses data regardless of which way gets evicted --
# that's why this test checks REAL miss-event COUNT via a sticky tap
# rather than trying to infer eviction choice from register content
# alone, the same content-ambiguity tb_dcache_unit.v's own dut2 hit while
# under construction).
addi x1, x0, 100      # 0:  A's value
addi x2, x0, 200       # 4:  B's value
addi x3, x0, 300         # 8:  C's value
addi x4, x0, 400           # 12: D's value
addi x5, x0, 500             # 16: E's value
sw   x1, 0(x0)                  # 20: A -> addr0  (miss 1, fills way)
sw   x2, 16(x0)                   # 24: B -> addr16 (miss 2, fills way)
sw   x3, 32(x0)                     # 28: C -> addr32 (miss 3, fills way)
sw   x4, 48(x0)                       # 32: D -> addr48 (miss 4, fills way -- all 4 ways of set0 now full)
lw   x6, 0(x0)                          # 36: re-touch A (real hit, moves A to MRU)
lw   x7, 16(x0)                           # 40: re-touch B (real hit, moves B to MRU)
sw   x5, 64(x0)                             # 44: E -> addr64 (miss 5): forces eviction --
                                              #     true LRU evicts C (way now LRU-tail after
                                              #     the two re-touches above), NOT A
lw   x8, 48(x0)                                # 48: D still hits -- untouched by E's own eviction
lw   x9, 0(x0)                                   # 52: A still hits -- round-robin's blind
                                                   #     choice (evict A) would have broken this
lw   x10, 32(x0)                                    # 56: C: genuinely evicted, forces miss 6 --
                                                       #     content still correct (write-back
                                                       #     never loses data regardless of policy)
addi x11, x0, 999                                       # 60: marker: reached the end correctly
fence
halt:
jal x0, halt                                              # 68
