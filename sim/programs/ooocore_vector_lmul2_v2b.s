# Generation 7, Pillar V, Phase 2b (Gen7-V, docs/adr/0063). Real LMUL=2
# crack-into-microops proof: ONE vadd.vi instruction with LMUL=2 must
# crack into TWO independent micro-ops (v2 and v3, the real register
# group), each with its own correctly-clamped local vl.
#
# vsetvli x5, x10, e32, m2: SEW=32(010), LMUL=2(001) -> vtype8=0b01_010_001=0x51
#   zimm11 = 0x011. VLMAX = VLEN*LMUL/SEW = 512*2/32 = 32.
addi x10, x0, 20            # AVL = 20 (< VLMAX=32 -> vl = 20 exactly, unclamped)
word 0x011572D7              # vsetvli x5, x10, e32, m2 -> x5 = 20

# vadd.vi v2, v0, 7 (vs2=v0, group={v0,v1}; vd=v2, group={v2,v3}) --
# cracks into 2 micro-ops: v2 = elems[0:16) of (v0+7), v3 = elems[16:20)
# of (v1+7) with the remaining elems[4:16) of v3 tail-agnostic ZERO
# (real per-crack-op local_vl clamping: crack0 gets local_vl=16, crack1
# gets local_vl=20-16=4).
word 0x0203B157

halt:
jal x0, halt   # spin here forever instead of running off the end of the program
