# Generation 7, Pillar V, Phase 1 (Gen7-V4, docs/adr/0061). Real vsetvli
# end-to-end proof on OOOCore.v: vl = min(AVL, VLMAX), VLMAX = VLEN*LMUL/SEW.
# asm.py has no vsetvli/vsetivli mnemonic support yet (a future phase's own
# tooling work, same "word hand-encoding until a mnemonic exists" precedent
# ooocore_amo_j1.s already established for lr.d) -- both instructions below
# are hand-encoded and independently re-derived (not copy-pasted) against
# riscv_defs.vh's own VTYPE_* field layout before trusting them here.
#
# vsetvli x5, x10, e32, m4: SEW=32(vsew=010), LMUL=4(vlmul=010).
#   zimm11 = {3'b000 reserved, vma=0, vta=0, vsew=010, vlmul=010}
#          = 11'b000_00_010_010 = 0x012
#   inst[31]=0, inst[30:20]=zimm11, inst[19:15]=rs1(x10=5'd10),
#   inst[14:12]=111, inst[11:7]=rd(x5=5'd5), inst[6:0]=0x57
#   = (0x012<<20)|(10<<15)|(7<<12)|(5<<7)|0x57 = 0x012572D7
addi x10, x0, 100        # AVL = 100 (> VLMAX=512*4/32=64 -> vl clamps to 64)
word 0x012572D7           # vsetvli x5, x10, e32, m4  ->  x5 = 64

# vsetvli x7, x11, e32, m4: same vtype immediate (zimm11=0x012), different
# rs1/rd.
#   = (0x012<<20)|(11<<15)|(7<<12)|(7<<7)|0x57 = 0x0125F3D7
addi x11, x0, 10         # AVL = 10 (< VLMAX=64 -> vl stays exactly 10, unclamped)
word 0x0125F3D7           # vsetvli x7, x11, e32, m4  ->  x7 = 10

halt:
jal x0, halt   # spin here forever instead of running off the end of the program
