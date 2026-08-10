# Generation 6, Gen6-O (docs/adr/0051). csrrw/csrrs/csrrc(+i)'s own first
# directed test -- OOOCore.v's own csr_inflight single-outstanding scope
# cut proven for the first time: the OLD value (captured at dispatch,
# via the same "force A" mechanism lui/auipc/jal/jalr already use) and
# the real WRITE (fired at resolve, using rs1's/uimm's own value) are
# checked independently across write/set/clear/immediate forms.
addi   x1, x0, 5
csrrw  x2, mscratch, x1     # x2 = old mscratch (0, reset default); mscratch <- 5
csrrs  x3, mscratch, x0      # x3 = mscratch (5); rs1=x0 contributes nothing, mscratch stays 5
addi   x4, x0, 3
csrrs  x5, mscratch, x4       # x5 = mscratch BEFORE this op (5); mscratch <- 5|3 = 7
csrrc  x6, mscratch, x4        # x6 = mscratch BEFORE this op (7); mscratch <- 7 & ~3 = 4
csrrwi x7, mscratch, 9          # x7 = mscratch BEFORE this op (4); mscratch <- 9 (uimm, not a register)
csrrs  x8, mscratch, x0          # x8 = final mscratch (9) -- pure read

# Real halt, not just nop padding -- found necessary by running: this
# program's own x2 check (the value BEFORE any writes at all) is NOT
# idempotent across multiple passes the way most directed-test checks
# are, so falling off the end into the zero-filled tail (illegal
# opcode -> trap -> mtvec's own reset default of 0 -> restart) silently
# corrupts x2 with a LATER pass's own already-mutated mscratch instead
# of the true initial value, exactly the class of bug docs/adr/0048's
# own bench_sum_array.s investigation already found for random_gen.py's
# shared jal-based trailer -- `beq x0,x0,halt` is unconditionally taken
# (x0 always equals x0), a REAL working infinite loop using only a
# branch, same idiom sim/programs/hetero_ooo_n1.s (docs/adr/0050) uses.
halt:
beq x0, x0, halt
