# Generation 6, Gen6-N (docs/adr/0050). PIPELINED's own half of the real
# HeteroSoC.v cross-core handoff: writes a 6-element array + length into
# the shared Mailbox.v (MAILBOX_BASE = 0x1020_0000, riscv_defs.vh),
# raises GO, polls DONE, reads the result OOOCore.v's own worker program
# (hetero_ooo_n1.s) computed back into x10 -- the same "the" result
# register debug_x10/EXPECTED_X10 convention every other benchmark/
# directed test in this project already uses.
#
# Mailbox word layout (all word-aligned, 4 bytes each):
#   +0  GO      (PIPELINED writes 1 last, after every input word is
#                already committed -- the real handoff signal)
#   +4  N       (element count)
#   +8  DONE    (OOOCore.v writes 1 once finished)
#   +12 RESULT  (OOOCore.v writes the sum here)
#   +16.. data[0..N-1]
lui   x31, 0x10200      # x31 = MAILBOX_BASE = 0x1020_0000

addi  x1, x0, 6
sw    x1, 4(x31)         # N = 6

addi  x1, x0, 1
sw    x1, 16(x31)        # data[0] = 1
addi  x1, x0, 2
sw    x1, 20(x31)        # data[1] = 2
addi  x1, x0, 3
sw    x1, 24(x31)        # data[2] = 3
addi  x1, x0, 4
sw    x1, 28(x31)        # data[3] = 4
addi  x1, x0, 5
sw    x1, 32(x31)        # data[4] = 5
addi  x1, x0, 6
sw    x1, 36(x31)        # data[5] = 6

addi  x1, x0, 1
sw    x1, 0(x31)         # GO = 1 -- real handoff, everything above must
                          # already be committed (it is: this core is
                          # in-order, no reordering across these stores)

poll_done:
lw    x2, 8(x31)
beq   x2, x0, poll_done   # spin until OOOCore.v sets DONE

lw    x10, 12(x31)        # x10 = RESULT (expected: 1+2+...+6 = 21)

fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
