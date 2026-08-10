# Generation 6, Gen6-P3 (docs/adr/0054). OOOCore.v's own first real
# interrupt test: enables mie.MTIE + mstatus.MIE, sets mtvec, then spins
# in a tight self-branch loop (beq x0,x0,loop) -- the loop itself is what
# lets rob_empty genuinely go true between iterations (each beq fully
# retires before the next one dispatches), the exact condition
# interrupt_take waits for. The testbench (tb_ooocore_int_p3.v) asserts
# the DUT's own real timer_pending port partway through; once recognized,
# the core redirects to the handler with NO further help from this
# program -- the marker there is what proves it actually happened.
addi  x1, x0, 128        # 0:  x1 = 1<<7 (MIE_MTIE_BIT)
csrrs x0, mie, x1          # 4:  mie.MTIE <- 1
csrrsi x0, mstatus, 8        # 8:  mstatus.MIE <- 1 (bit 3)
addi  x2, x0, 24               # 12: x2 = 24 == handler's own PA
csrrw x0, mtvec, x2              # 16: mtvec <- 24
loop:
beq   x0, x0, loop                 # 20: spin -- rob_empty toggles true between each iteration
handler:
addi  x10, x0, 123                    # 24: marker -- proves the interrupt correctly redirected here
halt:
beq   x0, x0, halt                      # 28: real halt
