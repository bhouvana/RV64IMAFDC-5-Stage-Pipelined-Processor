# Generation 7, Pillar V backlog closure (docs/adr/0066). Mask-writing
# compares end-to-end through OOOCore.v's real dispatch/rename path.
# VALU.v's own compare semantics are already proven standalone
# (tb_valu_cmp_unit.v); this test proves the WIRING (real dispatch,
# RS_VALU issue, CDB, ROB retire into a REAL vector destination preg)
# survives for the .vv and .vx forms, LMUL=1.
#
# vsetvli x5, x10, e32, m1: SEW=32, LMUL=1 -> VLMAX=16.
addi x10, x0, 100           # AVL=100 (> VLMAX=16 -> vl clamps to 16)
word 0x010572D7             # vsetvli x5, x10, e32, m1 -> x5=16

# vadd.vi v1, v0, 5 (vs2=v0=0) -> v1 = 5 (each of 16 SEW32 elements). Reused
# from tb_ooocore_vector_arith_v2a.s, already independently re-derived there.
word 0x0202B0D7
# vadd.vi v2, v0, 3 -> v2 = 3 (each element).
word 0x0201B157

# vmsltu.vv v6, v2(vs2), v1(vs1), vm=1 -> compares vs2<vs1 unsigned:
# 3<5=true=1 for each of the 16 active elements -> v6's low 16 BITS
# (raw, not SEW-wide) = 0xFFFF, everything past elem15 stays reset-zero.
word 0x6A208357

addi x11, x0, 10            # scalar = 10
# vmslt.vx v8, v1(vs2), x11(rs1=scalar), vm=1 -> compares vs2<scalar signed:
# 5<10=true=1 for each of the 16 active elements -> v8's low 16 bits = 0xFFFF.
word 0x6E15C457

halt:
jal x0, halt   # spin here forever instead of running off the end of the program
