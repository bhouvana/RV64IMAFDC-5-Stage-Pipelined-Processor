# Generation 6, Gen6-F. OOOCore.v's first MUL/DIV test. MUL/MULH/MULHSU/
# MULHU need no new wiring (ALU.v already computes them single-cycle,
# flow through the ordinary RS_ALU path) -- included here as
# confirmation, not because anything new was built for them. DIV/DIVU/
# REM/REMU exercise the real new RS_DIV + Divider.v multi-cycle path.
addi x1, x0, 6           # x1 = 6
addi x2, x0, 7           # x2 = 7
mul  x3, x1, x2          # x3 = 42
addi x4, x0, -1          # x4 = -1 (0xFFFF...FFFF)
mulhu x5, x4, x2         # x5 = high 64 bits of (2^64-1)*7 unsigned = 6
div  x6, x3, x2          # x6 = 42/7 = 6 (signed)
rem  x7, x3, x2          # x7 = 42%7 = 0
addi x8, x0, -20         # x8 = -20
div  x9, x8, x2          # x9 = -20/7 = -2 (signed, truncates toward 0)
rem  x10, x8, x2         # x10 = -20%7 = -6 (signed remainder)
divu x11, x8, x2         # x11 = unsigned(-20)/7 -- a real huge unsigned quotient
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
