# Generation 6, Gen6-J. OOOCore.v's first atomics test: LR.D (this
# core's own single-hart simplification, ADR 0038 -- LR reduces to a
# plain load, no reservation needed, since nothing else can ever
# contend). sim/tools/asm.py has no AMO mnemonic support at all (a real,
# pre-existing gap, docs/adr/0038/0039 both flag it) -- `word` hand-
# encodes the raw instruction, same convention this project's own
# aluctl_illegal.s test already uses for opcodes/forms asm.py can't emit.
#
# word 0x1000b1af == lr.d x3, (x1): funct5=AMO_F5_LR(00010), aq=0, rl=0,
# rs2=0(unused), rs1=x1, funct3=011(D/64-bit), rd=x3, opcode=0101111.
addi x1, x0, 100        # x1 = 100 (address)
addi x2, x0, 555         # x2 = 555
sd   x2, 0(x1)           # mem[100:108] = 555
word 0x1000b1af          # lr.d x3, (x1) -- x3 = 555, via the SAME LSQ path an ordinary load uses
add  x4, x3, x0           # x4 = 555 -- an ordinary ALU op consuming LR's own loaded value
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
