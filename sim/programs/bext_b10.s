# Generation 7, Pillar B (Gen7-B10, docs/adr/0060). Directed B-extension
# coverage for the scalar in-order core (riscvpipeline.v, PIPELINED=1),
# XLEN=64 -- straight-line, no branches, same "generous fixed wait then
# check committed state" convention as sim/programs/ooocore_alu_d1.s.
# Expected values below are cross-checked against sim/tools/iss.py, not
# hand-multiplied alone (this project's own "verify by running" precedent).
# Trimmed to fit the 128-byte default instruction memory (sim/run_tests.sh
# always assembles with asm.py's own --size default, no per-program
# override) -- binvi/trailing nops dropped since binv (register form)
# already proves ALUCTL_BINV's own execution semantics, and the 80-cycle
# fixed wait below is generous margin without trailing-nop padding.
addi x1, x0, 5           # x1 = 5
addi x2, x0, 3           # x2 = 3
addi x16, x0, 15         # x16 = 15 (0b1111), a real operand with low bits set for bclr/bext/binv/bset
lui  x17, 0xF0F0F         # x17 = sext(0xF0F0F000)
addi x17, x17, -256      # x17 = 0xFFFFFFFFF0F0EF00
andn x10, x1, x2         # x10 = x1 & ~x2
orn  x11, x1, x2         # x11 = x1 | ~x2
xnor x12, x1, x2         # x12 = ~(x1 ^ x2)
min  x13, x1, x2         # x13 = min(5,3) = 3
max  x14, x1, x2         # x14 = max(5,3) = 5
minu x15, x1, x2         # x15 = minu(5,3) = 3
maxu x18, x1, x2         # x18 = maxu(5,3) = 5
rol  x19, x1, x2         # x19 = rotl(5,3)
ror  x20, x1, x2         # x20 = rotr(5,3)
sh1add x21, x1, x2       # x21 = (5<<1)+3 = 13
sh2add x22, x1, x2       # x22 = (5<<2)+3 = 23
sh3add x23, x1, x2       # x23 = (5<<3)+3 = 43
bclr x24, x16, x2        # x24 = 15 & ~(1<<3) = 7
bext x25, x16, x2        # x25 = (15>>3)&1 = 1
binv x26, x16, x2        # x26 = 15 ^ (1<<3) = 7
bset x27, x2, x1         # x27 = 3 | (1<<5) = 35
bclri x28, x16, 3        # x28 = 15 & ~(1<<3) = 7 (overwritten by rev8 below)
bexti x29, x16, 3        # x29 = (15>>3)&1 = 1
rori x3, x1, 2           # x3 = rotr(5,2)
clz  x4, x1              # x4 = clz(5) = 61
ctz  x5, x1              # x5 = ctz(5) = 0
cpop x6, x1              # x6 = popcount(5) = 2
sext.b x7, x16           # x7 = sign-extend byte(15) = 15
sext.h x8, x16           # x8 = sign-extend halfword(15) = 15
orc.b  x9, x1            # x9 = orc.b(5): lowest byte nonzero -> 0xFF
rev8   x28, x17          # x28 = byte-reverse(0xFFFFFFFFF0F0EF00)
