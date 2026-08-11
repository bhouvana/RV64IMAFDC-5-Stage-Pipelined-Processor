# Generation 7, Pillar K (Gen7-K7, docs/adr/0059/0067). Scalar-vs-hardware
# benchmark, hardware half -- the IDENTICAL result (x2 = clmul(1000,0x55) =
# 0xc8c8) via one real `clmul` instruction instead of
# bench_clmul_scalar.s's own 7-instruction shift-XOR sequence.
addi x1, x0, 1000         # x1 = A = 1000
addi x2, x0, 0x55          # x2 = B = 0x55 (bits 0,2,4,6 set)
clmul x2, x1, x2           # x2 = clmul(1000, 0x55) = 0xc8c8
