# Generation 6, Gen6-P5 (docs/adr/0056). OOOCore.v's own first BTB-
# predicted jalr test: the SAME jalr instruction (fixed PC=8) executes
# TWICE via a real loop -- the first execution is a genuine BTB miss
# (cold, predicts pc+4, mispredicts, recovers -- proving the recovery
# path, same mechanism the pre-existing ooocore_jalr_o3.s test already
# covers); the SECOND execution (after the BTB trains from the first
# jr_resolve) is a genuine BTB HIT, predicting the real target correctly
# -- proving the NEW prediction path this phase actually adds.
addi x1, x0, 24          # 0:  x1 = 24 (jalr's own target PA)
addi x3, x0, 0              # 4:  x3 = loop counter
loop:
jalr x5, 0(x1)                 # 8:  jump to x1 (24), link (PC+4=12) -> x5.
                                #     Iteration 1: BTB cold, predicts 12,
                                #     real target 24 -> mispredict -> recover.
                                #     Iteration 2: BTB trained (8 -> 24)
                                #     from iteration 1's own jr_resolve,
                                #     predicts 24 correctly -> no redirect.
dead1:
addi x11, x0, 777                # 12: dead code -- jalr's own link value
addi x11, x0, 888                # 16:    (not its target); architecturally
addi x11, x0, 999                # 20:    never retires, jalr always redirects
target:
addi x3, x3, 1                     # 24: counter++
addi x4, x0, 2                       # 28: x4 = 2
blt  x3, x4, loop                      # 32: counter<2 -> back to `loop` (re-executes the SAME jalr at PC=8)
addi x20, x0, 42                         # 36: reached once counter==2 (second iteration falls through)
halt:
beq  x0, x0, halt                          # 40: real halt
