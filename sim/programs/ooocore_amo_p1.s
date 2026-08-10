# Generation 6, Gen6-P1. OOOCore.v's own general AMO-RMW + SC end-to-end
# test: exercises the NEW disp_op_type0 dispatch path (OP_SC / OP_AMO_RMW)
# added this phase, on top of Gen6-J's own LR-only atomics. Same convention
# as ooocore_amo_j1.s (Gen6-J) -- sim/tools/asm.py has no AMO mnemonic
# support (docs/adr/0038/0039), so `word` hand-encodes the two new
# instructions.
#
# word 0x1820b2af == sc.d x5, x2, (x1): funct5=AMO_F5_SC(00011), aq=0,
# rl=0, rs2=x2, rs1=x1, funct3=011(D), rd=x5, opcode=0101111.
#
# word 0x0020b32f == amoadd.d x6, x2, (x1): funct5=AMO_F5_ADD(00000),
# aq=0, rl=0, rs2=x2, rs1=x1, funct3=011(D), rd=x6, opcode=0101111.
addi x1, x0, 100         # x1 = 100 (address)
addi x2, x0, 555          # x2 = 555
sd   x2, 0(x1)             # mem[100:108] = 555
word 0x1820b2af            # sc.d x5, x2, (x1) -- overwrite mem[100]=555 again, x5=0 (always succeeds, single-hart)
addi x2, x0, 1000          # x2 = 1000 (new rs2 for the AMOADD below)
word 0x0020b32f            # amoadd.d x6, x2, (x1) -- x6 = OLD mem value (555), mem[100] = 555+1000 = 1555
ld   x7, 0(x1)              # x7 = 1555 -- confirms the AMO's own write really landed
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
