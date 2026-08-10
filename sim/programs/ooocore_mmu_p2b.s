# Generation 6, Gen6-P2b (docs/adr/0053). OOOCore.v's own first live Sv39
# translation test: I-side (fetch) only -- D-side translation isn't wired
# live until Gen6-P2d (the LSQ's own address path still passes its VA
# through untranslated this sub-phase; see LoadStoreQueue.v's new
# mem_stall_ext port, currently only ever driven by ptw_busy, the shared-
# port arbiter, not by a real DTLB miss yet).
#
# M-mode (still physical, satp not yet live) builds a single Sv39 LEVEL-2
# LEAF -- a real 1GB gigapage, identity-mapped (PPN=0) -- covering the
# entire low 1GB, then mret drops to U-mode (mstatus.MPP reads PRIV_U/
# 2'b00 straight off CSR.v's own all-zero reset default, confirmed by
# direct reading, not assumed -- relying on that same reset-default idiom
# sim/programs/mmu_translate_sv39_p3.s already established, no explicit
# MPP write needed) at a VIRTUAL address
# that (since the mapping is a gigapage identity, VA==PA trivially
# everywhere in the low 1GB) equals the marker instruction's own real
# physical address directly -- no VPN-offset arithmetic needed, unlike
# mmu_translate_sv39_p3.s's own 3-level/4KB-leaf test. This deliberately
# exercises the GIGAPAGE leaf-reconstruction path in Ptw39.v (untested by
# that earlier 3-level test, which only ever reaches a level-0 leaf).
#
# PTE value 0x1B = V|R|X|U (0x1|0x2|0x8|0x10), PPN=0 -- same value
# mmu_translate_sv39_p3.s's own fetch PTE already used, reused here as a
# LEVEL-2 leaf instead of a level-0 one (leaf-ness is determined purely by
# R/W/X being nonzero at whichever level a PDE is read, per Ptw39.v's own
# header -- the exact same PTE bit pattern is valid at any level).
addi x1, x0, 0x1B        # 0:  x1 = 0x1B (gigapage leaf PTE: V|R|X|U, PPN=0)
sw   x1, 0(x0)             # 4:  level-2[VPN2=0] <- leaf PTE (satp_ppn=0, table at addr 0)
addi x3, x0, 8               # 8:  x3 = 8
slli x3, x3, 30                # 12: (1/2) partial shift (5-bit shamt encoding limit)
slli x3, x3, 30                  # 16: (2/2) x3 = 8<<60 (satp: MODE=8/Sv39, PPN=0)
csrrw x0, satp, x3                 # 20: satp <- x3 -- M-mode still bypasses from here on
addi x4, x0, 36                      # 24: x4 = 36 == marker's own real PA (VA==PA, gigapage identity)
csrrw x0, mepc, x4                     # 28: mepc <- 36
mret                                      # 32: -> S-mode, PC <- 36 (I-side translation live)
marker:
addi x10, x0, 111                           # 36: proves the translated fetch landed exactly here
halt:
beq x0, x0, halt                              # 40
