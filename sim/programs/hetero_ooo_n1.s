# Generation 6, Gen6-N (docs/adr/0050). OOOCore.v's own half of the real
# HeteroSoC.v cross-core handoff -- the "little core" worker. No lui/
# jal anywhere (design/OOOCore.v cannot execute either, see its own
# header) -- MAILBOX_BASE is built via the same chunked addi/slli idiom
# sim/tools/random_gen.py's own `no_lui` mode established, and every
# loop (including the final halt) uses a conditional branch instead of
# an unconditional jump: `beq x0, x0, <label>` is ALWAYS taken (x0
# always equals x0), giving a REAL, working infinite self-loop using
# only an instruction class OOOCore.v actually executes correctly --
# unlike random_gen.py's own jal-based trailer, this one genuinely
# halts instead of falling through into the zero-filled tail.
#
# Mailbox word layout -- see hetero_pipelined_n1.s's own header for the
# full protocol; this program only ever WRITES words +8 (DONE) and +12
# (RESULT), only ever READS +0 (GO)/+4 (N)/+16.. (data) -- the same
# "each core only writes its own designated words" discipline
# design/Mailbox.v's own header requires.
addi x31, x0, 64          # x31 = MAILBOX_BASE = 0x1020_0000, built in
slli x31, x31, 11          # 3 chunks (no lui): 64<<22 | 1024<<11 =
addi x31, x31, 1024        # 0x10000000 | 0x00200000 = 0x10200000
slli x31, x31, 11

poll_go:
lw   x1, 0(x31)
beq  x1, x0, poll_go       # spin until PIPELINED sets GO

lw   x2, 4(x31)            # x2 = N
addi x3, x0, 0             # x3 = running sum
addi x4, x0, 0             # x4 = loop index i
addi x9, x31, 16           # x9 = &data[0]

sum_loop:
beq  x4, x2, sum_done
lw   x5, 0(x9)
add  x3, x3, x5
addi x9, x9, 4
addi x4, x4, 1
beq  x0, x0, sum_loop      # unconditional (x0 == x0 always) -- see this
                            # file's own header for why, not jal

sum_done:
sw   x3, 12(x31)           # RESULT = sum
addi x6, x0, 1
sw   x6, 8(x31)             # DONE = 1

halt_ooo:
beq  x0, x0, halt_ooo      # real infinite self-loop -- see header
