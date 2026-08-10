# Generation 6, Gen6-K. Dual-issue widening directed test, XLEN=64.
#
# Instruction pairing is whatever two consecutive words land in the SAME
# fetch bundle (pc, pc+4) -- which shifts as soon as any bundle actually
# dual-issues (pc jumps by 8, not 4). Traced by hand against OOOCore.v's
# own dispatch logic:
#
#   bundle A (pc 0/4):   i0 addi x1,x0,5     i1 addi x2,x0,3
#     -- independent pair, both plain ALU -> dual-issues.
#   bundle B (pc 8/12):  i2 add x3,x1,x2     i3 sub x4,x3,x1
#     -- i3's rs1 (x3) IS i2's own rd -- the same-bundle RAW bypass
#        (slot1_src1_from_slot0) is the thing under test here: i2 hasn't
#        executed yet this cycle, so i3 must grab i2's freshly-allocated
#        preg directly, not RAT's stored (stale) mapping.
#   bundle C (pc 16/20): i4 xor x5,x1,x2     i5 or x6,x1,x2
#     -- independent pair again, both reading already-committed x1/x2.
#   bundle D (pc 24/28): i6 addi x7,x0,111   i7 addi x7,x0,222
#     -- same-bundle WAW (both target x7) -- RegisterAliasTable.v's own
#        existing wen0/wen1 same-target logic (built in Gen6-A, no new
#        Gen6-K code) must make i7 (slot1) win.
#   bundle E (pc 32/36): i8 addi x0,x0,0     i9 addi x0,x0,0
#     -- plain nops, dual-issues trivially (no dest either side).
#
# Expected committed architectural state:
#   x1=5  x2=3  x3=8  x4=3 (x3-x1 = 8-5)  x5=6 (5^3)  x6=7 (5|3)
#   x7=222 (WAW: slot1 wins)
addi x1, x0, 5           # i0
addi x2, x0, 3           # i1
add  x3, x1, x2          # i2
sub  x4, x3, x1           # i3 -- same-bundle RAW bypass on rs1
xor  x5, x1, x2          # i4
or   x6, x1, x2          # i5
addi x7, x0, 111          # i6
addi x7, x0, 222          # i7 -- same-bundle WAW, slot1 wins
addi x0, x0, 0            # i8 padding (trailing nops keep the tail's
addi x0, x0, 0            # i9 IMEM-out-of-range garbage-opcode read, see
addi x0, x0, 0            # i10 tb_ooocore_alu_d1.v's own identical
addi x0, x0, 0            # i11 convention, well clear of the real checks)
