# Generation 6, Gen6-O (docs/adr/0051). JAL's own first directed test --
# OOOCore.v's own decode-time-resolvable PC redirect proven for the
# first time: jal's target (pc + J-type immediate) is known
# unconditionally at decode, no speculation needed, so this is a real
# (not predicted) redirect the same cycle jal dispatches.
addi x1, x0, 11         # 0: x1 = 11 (must survive the jump over x1's own
                          # would-be corruption below)
jal  x5, target          # 4: x5 = link value (pc+4 = 8); jumps to target
addi x1, x0, 99          # 8: SKIPPED -- if jal's own redirect didn't
                          # work, this would corrupt x1 to 99
addi x1, x0, 99          # 12: also skipped
target:
addi x2, x1, 1            # x2 = 12 -- proves x1 (11) survived the jump
                            # AND that fetch/dispatch really landed here
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
