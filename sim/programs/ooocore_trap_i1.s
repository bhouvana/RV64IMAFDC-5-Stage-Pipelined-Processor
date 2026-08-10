# Generation 6, Gen6-I. OOOCore.v's first precise-exception test: an
# illegal instruction (opcode 0000000, the same "definitely not a real
# RISC-V opcode" pattern InstructionMemory.v's own zero-fill-past-the-
# program convention already relies on) traps every time it's fetched.
# mtvec resets to 0 (no CSR-write support in this phase's own scope, see
# OOOCore.v's Gen6-I header comment), so the redirect lands back at the
# START of this exact program -- a real, deliberate, self-re-triggering
# loop: x1/x2 get re-renamed and re-committed identically every pass,
# and x3 (the instruction immediately after the illegal one) must NEVER
# retire, no matter how many times the loop repeats. That's the actual
# property under test: the instruction after a fault never reaches
# architectural state, forever, not just once.
addi x1, x0, 5           # pc=0
addi x2, x0, 7           # pc=4
word 0x00000000          # pc=8: illegal instruction -- traps, redirects to mtvec=0
addi x3, x0, 999         # pc=12 -- must NEVER retire
