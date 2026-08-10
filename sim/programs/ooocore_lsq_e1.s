# Generation 6, Gen6-E. OOOCore.v's first load/store test: a store
# followed by a dependent load at the same address (proves the real
# memory round trip through LoadStoreQueue.v + DataMemoryBRAM.v), plus a
# second store/load pair at a different offset to prove the in-order LSQ
# correctly processes more than one memory op back to back.
addi x1, x0, 100        # x1 = 100 (base address)
addi x2, x0, 42         # x2 = 42
sd   x2, 0(x1)          # mem[100:108] = 42
ld   x3, 0(x1)          # x3 = 42 (dependent load, same address)
addi x4, x0, 7
sd   x4, 8(x1)          # mem[108:116] = 7
lw   x5, 8(x1)          # x5 = 7 (word load)
add  x6, x3, x5         # x6 = 42+7 = 49 -- proves an ordinary ALU op can
                         # consume a loaded value through the CDB/RS wakeup
                         # path, same as any other producer
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
addi x0, x0, 0
