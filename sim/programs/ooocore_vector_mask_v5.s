# Generation 7, Pillar V, Phase 5 (Gen7-V, docs/adr/0065). Real v0.t
# masking end-to-end through OOOCore.v's real dispatch/rename path --
# VALU.v's own masking mechanics are already proven standalone
# (tb_valu_unit.v), this test proves the WIRING (v0's own live rename
# feeding VALU.v's issue-time mask read) survives real dispatch.
#
# vsetvli x5, x10, e32, m1: SEW=32, LMUL=1 -> VLMAX=16.
addi x10, x0, 8             # AVL=8 (<VLMAX=16 -> vl=8, unclamped)
word 0x010572D7              # vsetvli x5, x10, e32, m1 -> x5=8

# vadd.vi v1, v0, 7 -> v1 = 7 (each element), v0 still 0 (real, reset value) here.
word 0x0203B0D7

# vadd.vi v0, v0, 1 -> v0 = 1 (each 32-bit element). As a RAW BIT vector
# (real spec: mask reading is bit-indexed regardless of SEW), only bit0
# (element0's own low bit) is set -- mask bit0=1 (element0 active),
# mask bits 1-7=0 (elements 1-7 masked off), the exact real pattern this
# test needs.
word 0x0200B057

# vadd.vv v2, v1, v1, vm=0 (MASKED) -> only element0 computed (7+7=14);
# elements 1-7 tail-agnostic ZERO (masked off, real v0.t semantics).
word 0x00108157

halt:
jal x0, halt   # spin here forever instead of running off the end of the program
