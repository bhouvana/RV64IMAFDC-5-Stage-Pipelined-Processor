# Generation 6, Gen6-P2d (docs/adr/0053). OOOCore.v's own D-side Sv39
# translation test: a real translated store+load through the same
# gigapage identity mapping ooocore_mmu_p2b.s already proved for fetch,
# then a genuine D-side page fault (a load from an address with NO valid
# Sv39 mapping at all -- VPN2=1, our own single gigapage PDE only ever
# lives at VPN2=0), proving three things at once: the fault's own cause
# (MCAUSE_LOAD_PAGE_FAULT) reaches CSR.v correctly, the redirect to
# mtvec actually happens (M-mode, translation bypassed there regardless
# of satp), and -- the real point of force_retire_ext -- the LSQ is NOT
# left permanently deadlocked by the one phantom head entry: a SECOND
# mret drops back into the SAME still-live translated region and proves
# an ORDINARY store+load still works fine afterward.
#
# Same gigapage identity mapping shape as ooocore_mmu_p2b.s, covering the
# whole low 1GB -- but W added this time (0x1F, not p2b's own I-side-only
# 0x1B): recovery's own sw genuinely needs write permission, unlike the
# faulting lw itself, which fails at the "is this PDE even valid" check
# (an unmapped VPN2=1 slot) long before any permission bit is consulted
# at all -- see Ptw39.v's own S_L2_DECODE. A REAL bug this exact PTE
# choice caught first, before this comment existed: an earlier version of
# this test reused p2b's own read+execute-only 0x1B verbatim, which made
# recovery's own sw ALSO genuinely page-fault (a legitimate
# MCAUSE_STORE_PAGE_FAULT, not an RTL bug) -- found by directly tracing
# dside_fault_cause_r/ls_hit/ls_perm_ok across the exact cycles, not
# guessed (see docs/adr/0053's own Real bugs/findings).
addi x1, x0, 0x1F        # 0:  x1 = 0x1F (gigapage leaf PTE: V|R|W|X|U, PPN=0 -- W included, unlike p2b's own I-side-only 0x1B, since recovery's own sw below genuinely needs write permission)
sw   x1, 0(x0)             # 4:  level-2[VPN2=0] <- leaf PTE (satp_ppn=0, table at addr 0)
addi x3, x0, 8               # 8:  x3 = 8
slli x3, x3, 30                # 12: (1/2) partial shift (5-bit shamt encoding limit)
slli x3, x3, 30                  # 16: (2/2) x3 = 8<<60 (satp: MODE=8/Sv39, PPN=0)
csrrw x0, satp, x3                 # 20: satp <- x3 -- M-mode still bypasses from here on
addi x2, x0, 76                      # 24: x2 = 76 == handler's own PA (M-mode, physical)
csrrw x0, mtvec, x2                    # 28: mtvec <- 76
addi x4, x0, 44                          # 32: x4 = 44 == u_code's own PA (VA==PA, gigapage identity)
csrrw x0, mepc, x4                         # 36: mepc <- 44
mret                                          # 40: -> U-mode, PC <- 44 (I-side translation live)
u_code:
addi x10, x0, 111                               # 44: marker A -- proves the translated fetch landed here (same as p2b)
addi x20, x0, 1                                   # 48: x20 = 1
slli x20, x20, 15                                   # 52: (1/2)
slli x20, x20, 15                                     # 56: (2/2) x20 = 1<<30 = 0x40000000 -- VPN2=1, NO valid PDE there
lw   x21, 0(x20)                                        # 60: D-SIDE FAULT: LOAD_PAGE_FAULT (invalid level-2 PDE)
recovery:                                                  # 64: only reached via the SECOND mret below, never fallthrough
sw   x1, 200(x0)                                              # 64: ordinary translated STORE -- proves the LSQ recovered
lw   x24, 200(x0)                                               # 68: ordinary translated LOAD, round-trip -- same proof
halt:
beq  x0, x0, halt                                                  # 72: real halt
handler:
addi x22, x0, 222                                                     # 76: marker B -- proves the fault correctly redirected here (M-mode, mtvec)
addi x4, x0, 64                                                          # 80: x4 = 64 == recovery's own PA
csrrw x0, mepc, x4                                                         # 84: mepc <- 64
mret                                                                         # 88: -> back to U-mode at recovery (still Sv39-live)
