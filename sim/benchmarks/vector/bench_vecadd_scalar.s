# Generation 7, Pillar V backlog closure (docs/adr/0066). Scalar-vs-
# hardware-vector benchmark PAIR, scalar half. C[i] = A[i] + B[i] for an
# 8-element int32 array, computed with an ordinary scalar loop (load,
# load, add, store, per element) -- the OTHER half
# (bench_vecadd_vector.s) computes the IDENTICAL result with one
# vle32.v/vle32.v/vadd.vv/vse32.v sequence instead. Everything except
# the compute region (fill loops, final reduction) is BYTE-IDENTICAL
# between the two files on purpose, so bench_runner.py's own
# --compare-vector delta isolates exactly the compute region.
#
# Layout: A@0..31, B@32..63, C@64..95 (int32, 8 elements each).
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

# --- measured region: C[i] = A[i] + B[i], scalar loop ---
addi x9, x0, 0         # A ptr
addi x11, x0, 32       # B ptr
addi x12, x0, 64       # C ptr
addi x8, x0, 0         # index
compute:
lw   x13, 0(x9)
lw   x14, 0(x11)
add  x15, x13, x14
sw   x15, 0(x12)
addi x9, x9, 4
addi x11, x11, 4
addi x12, x12, 4
addi x8, x8, 1
bne  x8, x6, compute
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
