# Generation 6, Gen6-D. OOOCore.v's own first directed test: straight-line
# R-type/I-type integer ALU coverage, XLEN=64. Deliberately a FRESH,
# smaller program rather than reusing sim/programs/arith.s -- that file's
# own inline comments assume XLEN=32 results (e.g. "addi x13,x0,-1 ->
# 0xFFFFFFFF"), which are wrong at XLEN=64 (sign-extends to
# 0xFFFFFFFFFFFFFFFF instead) -- easier and safer to hand-derive a new,
# smaller set of XLEN=64-correct expected values than to re-verify every
# one of arith.s's own 22 instructions against the wider width.
#
# No branches/jumps (OOOCore.v's own Gen6-D scope has none yet) -- the
# testbench runs a fixed cycle count and checks final committed
# architectural state directly, same "generous fixed wait, then dump"
# convention sim/tb/dump_regs_template.v already established for the
# constrained-random harness.
addi x1, x0, 5          # x1 = 5
addi x2, x0, 3          # x2 = 3
add  x3, x1, x2         # x3 = 8
sub  x4, x1, x2         # x4 = 2
and  x5, x1, x2         # x5 = 1  (0b101 & 0b011)
or   x6, x1, x2         # x6 = 7  (0b101 | 0b011)
xor  x7, x1, x2         # x7 = 6  (0b101 ^ 0b011)
sll  x8, x1, x2         # x8 = 5 << 3 = 40
srl  x9, x8, x2         # x9 = 40 >> 3 = 5
slt  x10, x2, x1        # x10 = (3 < 5) = 1
sltu x11, x1, x2        # x11 = (5 <3u) = 0
addi x12, x0, -1        # x12 = 0xFFFFFFFFFFFFFFFF (XLEN=64 sign-extend)
srli x13, x12, 4        # x13 = 0x0FFFFFFFFFFFFFFF (logical)
srai x14, x12, 4        # x14 = 0xFFFFFFFFFFFFFFFF (arithmetic, stays all-1s)
slli x15, x1, 2         # x15 = 5 << 2 = 20
ctz  x16, x0             # x16 = ctz(0) = 64 (docs/adr/0041's own fixed all-zero case)
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
