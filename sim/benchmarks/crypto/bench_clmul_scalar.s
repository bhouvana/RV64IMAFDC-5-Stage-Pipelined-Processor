# Generation 7, Pillar K (Gen7-K7, docs/adr/0059/0067). Scalar-vs-hardware
# benchmark, scalar half. Real carry-less multiply (the same shift-XOR
# algorithm design/ALU.v's own ALUCTL_CLMUL case implements combinationally
# in hardware), done as a plain scalar instruction sequence: x2 accumulates
# (A << i) for each set bit i of B=0x55 (bits 0,2,4,6), matching clmul's own
# real definition. No loop (OOOCore.v's own jal-doesn't-redirect-PC gap
# means every OoO benchmark in this project is straight-line/unrolled --
# same convention sim/benchmarks/vector/bench_vecadd_scalar.s already
# established). B deliberately has 4 set bits (not 1) so this is a real,
# representative multi-term scalar sequence, not a trivial single shift.
#
# Expected: x2 = clmul(1000, 0x55) = 0xc8c8 (hand-verified: 1000 = 0x3E8;
# 0x3E8^(0x3E8<<2)^(0x3E8<<4)^(0x3E8<<6) = 0x3E8^0xFA0^0x3E80^0xFA00 = 0xC8C8).
addi x1, x0, 1000         # x1 = A = 1000
addi x2, x1, 0             # x2 = running XOR-accumulator, term for bit0 = A<<0
slli x3, x1, 2
xor  x2, x2, x3            # + A<<2 (bit2 of B set)
slli x3, x1, 4
xor  x2, x2, x3            # + A<<4 (bit4 of B set)
slli x3, x1, 6
xor  x2, x2, x3            # + A<<6 (bit6 of B set) -> x2 = 0xc8c8
