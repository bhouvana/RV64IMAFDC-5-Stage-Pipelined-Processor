# Generation 7, Pillar V backlog closure (docs/adr/0066). Scalar-vs-
# hardware-vector benchmark PAIR, vector half. Computes the IDENTICAL
# C[i] = A[i] + B[i] result as bench_vecadd_scalar.s's own scalar loop,
# but with real vle32.v/vadd.vv/vse32.v instructions (LMUL=1, docs/adr/
# 0062, docs/adr/0064) instead -- ONE macro instruction per array rather
# than an 8-iteration loop. asm.py has no vector mnemonic support yet,
# same "word hand-encoding, independently re-derived against the real
# encoding" precedent every other Gen7-V test program already
# established; every word below was cross-checked against the
# already-verified encodings in sim/programs/ooocore_vector_arith_v2a.s
# and sim/programs/ooocore_vector_ls_v3.s (identical register indices,
# identical resulting words -- a real, independent confirmation the
# hand-derivation is correct, not just asserted).
#
# Layout: A@0..31, B@32..63, C@64..95 (int32, 8 elements each) -- same as
# the scalar half. fill_a/fill_b/the reduction tail below are
# BYTE-IDENTICAL to bench_vecadd_scalar.s on purpose.
addi x9, x0, 0         # A base
addi x6, x0, 8         # element count
addi x7, x0, 1         # A fill value (1, 2, ..., 8)
addi x8, x0, 0         # fill index
fill_a:
sw   x7, 0(x9)
addi x9, x9, 4
addi x7, x7, 1
addi x8, x8, 1
bne  x8, x6, fill_a

addi x9, x0, 32        # B base
addi x7, x0, 10        # B fill value (10, 20, ..., 80)
addi x8, x0, 0
fill_b:
sw   x7, 0(x9)
addi x9, x9, 4
addi x7, x7, 10
addi x8, x8, 1
bne  x8, x6, fill_b

# --- measured region: C = A + B, one real vector sequence ---
addi x9, x0, 0         # A ptr
addi x11, x0, 32       # B ptr
addi x12, x0, 64       # C ptr
addi x10, x0, 8        # AVL = 8
word 0x010572D7        # vsetvli x5, x10, e32, m1 -> x5 = 8
word 0x0204E087        # vle32.v v1, (x9)   [A]
word 0x0205E107        # vle32.v v2, (x11)  [B]
word 0x021101D7        # vadd.vv v3, v1, v2 [C = A+B]
word 0x020661A7        # vse32.v v3, (x12)  [store C]
# --- end measured region ---

# reduction: sum C[] into x10 (correctness checksum, identical in both files)
addi x12, x0, 64
addi x8, x0, 0
addi x5, x0, 0
sum_loop:
lw   x10, 0(x12)
add  x5, x5, x10
addi x12, x12, 4
addi x8, x8, 1
bne  x8, x6, sum_loop
add  x10, x5, x0       # x10 = 11+22+33+44+55+66+77+88 = 396

fence
halt:
jal x0, halt
