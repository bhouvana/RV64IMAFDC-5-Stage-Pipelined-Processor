# Generation 6, Gen6-P4 (docs/adr/0055). OOOCore.v's own first fdiv.s/
# fsqrt.s test -- RS_FDIV + the real, multi-cycle FDivider.v/FSqrt.v
# (reused completely unmodified from PIPELINED), proving the busy/done
# in-flight tracking actually works end to end through dispatch/issue/
# CDB/retire, not just that it elaborates.
addi x1, x0, 1036        # 0x40C (top 12 bits of 6.0f's IEEE-754 bit pattern)
slli x1, x1, 20            # x1 = 0x40C00000 = 6.0f
addi x2, x0, 1024            # 0x400 (top 12 bits of 2.0f's bit pattern)
slli x2, x2, 20                # x2 = 0x40000000 = 2.0f
fmv.w.x f1, x1                   # f1 = 6.0f
fmv.w.x f2, x2                     # f2 = 2.0f
fdiv.s f3, f1, f2                    # f3 = 6.0f/2.0f = 3.0f = 0x40400000
fsqrt.s f4, f2                         # f4 = sqrt(2.0f) = 0x3FB504F3
# Deliberately NOT chaining a FALU op onto f3/f4 here -- RS_FALU's own CDB
# snoop doesn't cover fdiv_complete_valid (a real, documented, bounded
# scope cut, same class Gen6-H's own header already flagged for
# LoadStoreQueue.v's completions -- see design/OOOCore.v's own RS_FDIV
# section comment). A FALU op depending on a still-in-flight FDIV/FSQRT
# result would never wake up and this program would hang; checking f3/f4
# directly (this test's own testbench reads the float PRF array
# directly) is the correct, honest way to prove THIS phase's own scope.
#
# Real halt, not nop padding -- found necessary by running: falling off
# the end into the zero-filled tail (illegal opcode -> trap -> mtvec's
# own reset default of 0 -> restart) repeatedly re-executes this whole
# program forever within the test's own fixed cycle window, the exact
# "persistent-state check corrupted by an unplanned restart" bug class
# docs/adr/0048/0051 already found and fixed this same way more than
# once. `beq x0,x0,halt` is a genuine working infinite loop (x0 always
# equals x0), same idiom every other Gen6-* directed test now uses.
halt:
beq x0, x0, halt
