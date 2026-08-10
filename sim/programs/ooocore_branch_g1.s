# Generation 6, Gen6-G. OOOCore.v's first branch-speculation test.
# Bht.v/Btb.v both start cold (predict not-taken, BTB miss) -- branch1 is
# actually TAKEN, so it's a genuine misprediction the first (only) time
# it's seen, exercising real redirect/recovery. branch2 is actually NOT
# taken, matching the cold prediction, exercising the plain
# correctly-predicted path (no redirect needed).
addi x1, x0, 5
addi x2, x0, 5
addi x3, x0, 0
beq  x1, x2, taken_target   # 5==5 -> TAKEN -- mispredicts (cold BHT guesses not-taken)
addi x3, x0, 111            # must be SKIPPED (wrong-path fallthrough)
taken_target:
addi x4, x0, 222            # reached via the branch's real target

addi x5, x0, 9
addi x6, x0, 3
addi x7, x0, 0
beq  x5, x6, wrong_target   # 9!=3 -> NOT taken -- correctly predicted (cold BHT also guesses not-taken)
addi x7, x0, 333            # must execute (correct fallthrough path)
wrong_target:
addi x8, x0, 444            # reached either way

addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
