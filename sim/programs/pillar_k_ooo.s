# Generation 7, Pillar K (Gen7-K7, docs/adr/0059). Directed K-extension
# coverage through OOOCore.v's real dispatch/rename/RS_ALU/CDB/ROB-retire
# path -- same shape as sim/programs/bext_b10.s / tb_ooocore_bext_b10.v.
# One instruction per Zkn family, all reusing x1=5/x2=3 as operands (kept
# small deliberately so every expected value is hand-verifiable without a
# multi-instruction 64-bit constant load).
#
# asm.py doesn't parse K-extension mnemonics yet (sim/tools/iss.py's own
# tooling closure is Task 8) -- every K instruction below is a real,
# individually verified machine-code word (funct7/funct3/opcode fields
# checked against the same riscv-opcodes-verified encodings design/
# riscv_defs.vh uses), embedded via asm.py's new `.word` raw-encoding
# directive (added this task) rather than waiting on full mnemonic support.
addi x1, x0, 5           # x1 = 5
addi x2, x0, 3           # x2 = 3

.word 0x0a209533         # clmul x10,x1,x2 = (5<<0)^(5<<1) = 5^10 = 15 = 0xF
.word 0x0820c5b3         # pack  x11,x1,x2 = {low32(x2),low32(x1)} = 0x0000000300000005
.word 0x10209613         # sha256sig0 x12,x1 = ror32(5,7)^ror32(5,18)^(5>>3) = 0x0A014000
.word 0x2820a6b3         # xperm4 x13,x1,x2 : B nibble0=3->A nibble3=0, all other B nibbles=0->A nibble0=5
                          #                    -> 0x5555555555555550
.word 0x7e208733         # aes64ks2 x14,x1,x2 : rs1[63:32]=0,rs2[31:0]=3,rs2[63:32]=0 -> w0=3,w1=3 -> 0x0000000300000003
