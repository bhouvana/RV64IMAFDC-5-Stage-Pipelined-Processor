# Generation 6, Gen6-O (docs/adr/0051). JALR's own first directed test --
# OOOCore.v's own jr_inflight single-outstanding scope cut proven for
# the first time: jalr's target is register-dependent (rs1+imm), so
# dispatch of everything else stalls until it resolves (jr_resolve),
# same shape as trap_inflight's own single-outstanding scope cut.
addi x10, x0, 20         # 0: x10 = 20 (target address, word-aligned)
addi x1, x0, 11           # 4: x1 = 11 (must survive the jump)
jalr x5, 0(x10)            # 8: x5 = link value (pc+4 = 12); jumps to
                            # (x10+0) & ~1 = 20
addi x1, x0, 99            # 12: SKIPPED
addi x1, x0, 99            # 16: SKIPPED
# byte offset 20:
addi x2, x1, 1              # 20: x2 = 12 -- proves x1 (11) survived AND
                              # fetch/dispatch really landed here
addi x0, x0, 0
addi x0, x0, 0
