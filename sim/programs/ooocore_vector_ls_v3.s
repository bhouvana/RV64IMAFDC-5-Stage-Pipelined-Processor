# Generation 7, Pillar V, Phase 3 (Gen7-V, docs/adr/0064). Real vle32.v/
# vse32.v round-trip proof on OOOCore.v, LMUL=1. asm.py has no vector-
# load/store mnemonic support yet -- hand-encoded and independently
# re-derived against the real unit-stride encoding (nf=000,mew=0,mop=00,
# vm,lumop/sumop=00000,rs1,funct3=EEW-width,vd/vs3,opcode) before
# trusting it here.
#
# vsetvli x5, x10, e32, m1: SEW=32, LMUL=1 -> VLMAX=512*1/32=16.
addi x10, x0, 100          # AVL=100 (>VLMAX=16 -> vl clamps to 16)
word 0x010572D7             # vsetvli x5, x10, e32, m1 -> x5=16

# vadd.vi v1, v0, 5 -> v1 = 5 (each of 16 SEW32 elements), the bootstrap
# source (matches Phase 2a's own precedent -- v0 is real, deterministic
# zero before anything writes it).
word 0x0202B0D7

addi x11, x0, 64            # x11 = base address (this core's own D-side memory, plenty of headroom)

# vse32.v v1, (x11): store v1's own 16 elements to memory starting at x11.
#   inst[31:20] = {nf=000,mew=0,mop=00,vm=1,sumop=00000} = 0x020
#   = (0x020<<20)|(x11=11<<15)|(funct3=110<<12)|(vs3=v1=1<<7)|0x27
word 0x0205E0A7

# vle32.v v2, (x11): load back into v2.
#   = (0x020<<20)|(11<<15)|(110<<12)|(vd=v2=2<<7)|0x07
word 0x0205E107

halt:
jal x0, halt   # spin here forever instead of running off the end of the program
