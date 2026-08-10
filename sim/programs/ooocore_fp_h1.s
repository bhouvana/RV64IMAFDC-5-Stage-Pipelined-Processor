# Generation 6, Gen6-H. OOOCore.v's first F-extension test: FMV.W.X
# bootstraps two real IEEE-754 single-precision values (1.0f/2.0f, built
# via addi+slli since this core has no lui/fld yet) into f1/f2, then
# exercises FADD.S/FSUB.S/FMUL.S/FMIN.S/FMAX.S/FSGNJX.S -- the real new
# RS_FALU + FALU.v path + the separate float rename/PRF stack, entirely
# distinct from the integer one.
addi x1, x0, 1016        # 0x3F8 (top 12 bits of 1.0f's IEEE-754 bit pattern)
slli x1, x1, 20          # x1 = 0x3F800000 = 1.0f
addi x2, x0, 1024        # 0x400 (top 12 bits of 2.0f's bit pattern)
slli x2, x2, 20          # x2 = 0x40000000 = 2.0f
fmv.w.x f1, x1           # f1 = 1.0f
fmv.w.x f2, x2           # f2 = 2.0f
fadd.s f3, f1, f2        # f3 = 3.0f = 0x40400000
fsub.s f4, f2, f1        # f4 = 1.0f = 0x3F800000
fmul.s f5, f1, f2        # f5 = 2.0f = 0x40000000
fmin.s f6, f1, f2        # f6 = 1.0f
fmax.s f7, f1, f2        # f7 = 2.0f
fsgnjx.s f8, f1, f1      # f8 = 1.0f (sign(f1)^sign(f1) = positive, magnitude unchanged)
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
