# Generation 6, Gen6-O (docs/adr/0051). LUI/AUIPC's own first directed
# test -- OOOCore.v's own operand-A "force" payload mechanism
# (use_forced_a0/forced_a_value0) proven for the first time. lui: rd =
# 0+imm (A forced to 0). auipc: rd = PC+imm (A forced to this
# instruction's own captured pc_r).
lui   x1, 0x1        # x1 = 0x1000 (small, positive -- no sign-extension
                       # complication; inst[31]==0 since 0x1's own top
                       # bit within the 20-bit field is 0)
auipc x2, 0x1         # x2 = (this instruction's own PC, byte offset 4) +
                       # 0x1000 = 0x1004
addi  x3, x1, 0       # x3 = x1 (proves the RS-based Tomasulo wakeup
                       # correctly saw lui's own completed write, not
                       # just that x1 itself looks right in isolation)
addi  x0, x0, 0
addi  x0, x0, 0
addi  x0, x0, 0
addi  x0, x0, 0
