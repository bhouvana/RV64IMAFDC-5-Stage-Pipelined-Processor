# Generation 7, Pillar V, Phase 2a (Gen7-V, docs/adr/0062). Real vector
# arithmetic end-to-end proof on OOOCore.v, LMUL=1. asm.py has no vector-
# arithmetic mnemonic support yet (same "word hand-encoding until a
# mnemonic exists" precedent Phase 1's own vsetvli test already
# established) -- every vector instruction below is hand-encoded and
# independently re-derived against the real OPIVV/OPIVX/OPIVI encodings
# (fetched from riscv/riscv-opcodes in Phase 1's own research) before
# trusting it here.
#
# Bootstrap note: v0-v31 all read as real, deterministic ZERO before
# anything writes them (PhysicalRegisterFile.v's own reset clears every
# preg to 0) -- v0 itself (also 0 at reset) is used below as a "vs2=0"
# source for the first two vadd.vi instructions, giving v1/v2 real, known
# values to chain into the rest of the test. This is the only way to get
# a first real vector value onto this core at all before vle/vse land
# (Phase 3).
#
# vsetvli x5, x10, e32, m1: SEW=32(010), LMUL=1(000) -> vtype8=0b01_010_000=0x50
#   zimm11 = {3'b000, vtype8} = 0x010
#   VLMAX = VLEN*LMUL/SEW = 512*1/32 = 16
addi x10, x0, 100          # AVL = 100 (> VLMAX=16 -> vl clamps to 16)
word 0x010572D7             # vsetvli x5, x10, e32, m1  -> x5 = 16

# vadd.vi v1, v0, 5 (vs2=v0=0, simm5=5, vm=1/unmasked) -> v1 = 5 (each of 16 SEW32 elements)
word 0x0202B0D7
# vadd.vi v2, v0, 3 -> v2 = 3
word 0x0201B157
# vadd.vv v3, v1(vs2), v2(vs1) -> v3 = 5+3 = 8 (real .vv, both real vector sources)
word 0x021101D7

addi x11, x0, 15            # x11 = 0xF
# vand.vx v4, v1(vs2), x11(scalar rs1) -> v4 = 5 & 15 = 5 (real .vx, cross-file integer read)
word 0x2615C257

# vadd.vi v6, v0, -1 (simm5=11111=-1, sign-extended) -> v6 = 0xFFFFFFFF each element
word 0x020FB357
# vmin.vv v7, v6(vs2,-1 signed), v2(vs1,3) -> v7 = min(-1,3) = -1 (real signed compare)
word 0x166103D7

halt:
jal x0, halt   # spin here forever instead of running off the end of the program
