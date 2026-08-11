// Single source of truth for opcode/ALUCtl encodings used across Control.v,
// ALUCtrl.v, and ImmGen.v. Before this file, each module hardcoded its own
// copy of these literals (docs/ARCHITECTURE.md sec 12) -- a duplicated
// magic-number table is exactly what tends to drift silently when a new
// opcode gets added (RV32M, CSR, ...), so centralizing it now pays for
// itself the moment Phase 5 extension work starts.
//
// sim/tools/asm.py's OP_*/R_TYPE/I_TYPE/BRANCH tables are a second,
// independent copy of this same information (Python can't `include` a
// Verilog header) -- keep them in sync by hand until they're generated from
// a shared source (docs/ROADMAP.md notes this as a known gap).

`ifndef RISCV_DEFS_VH
`define RISCV_DEFS_VH

// ---- opcodes (inst[6:0]) ----
`define OPCODE_R      7'b0110011  // R-type ALU
`define OPCODE_I      7'b0010011  // I-type ALU (addi/slti/.../srai)
`define OPCODE_LOAD   7'b0000011  // lb/lh/lw/lbu/lhu always; ld/lwu added at XLEN=64 (Gen2 Phase M)
`define OPCODE_STORE  7'b0100011  // sb/sh/sw always; sd added at XLEN=64 (Gen2 Phase M)
`define OPCODE_BRANCH 7'b1100011  // beq/bne/blt/bge/ble/bgt/bltu/bgeu
`define OPCODE_JAL    7'b1101111
`define OPCODE_JALR   7'b1100111
`define OPCODE_LUI    7'b0110111
`define OPCODE_AUIPC  7'b0010111
// docs/adr/0041-cache-replacement-policy-phase-b.md's own findings section:
// was 7'b0101010 (bits[1:0]=10) -- a real, previously-undiscovered bug,
// dormant since Phase U (docs/adr/0037) added RVC support:
// `is_compressed = (inst[1:0] != 2'b11)` in riscvpipeline.v means ANY
// opcode whose low 2 bits aren't 11 gets misdecoded as a 2-byte compressed
// instruction, corrupting the ctz instruction itself and misaligning every
// fetch after it -- ctz has silently never executed correctly since RVC
// landed, masked by a directed test whose own hardcoded expected value was
// already stale for an unrelated reason. Fixed to the real, spec-reserved
// custom-0 opcode (7'b0001011, RISC-V ISA manual's own opcode map), which
// has bits[1:0]=11 like every other real 32-bit opcode in this file.
`define OPCODE_CUSTOM 7'b0001011  // reserved (real RISC-V custom-0 space) -- unused since docs/adr/0060 moved ctz to its real Zbb encoding
`define OPCODE_SYSTEM 7'b1110011  // CSR instructions, ecall, ebreak, mret (docs/adr/0011-csr-and-exceptions.md)
`define OPCODE_MISC_MEM 7'b0001111  // fence (docs/adr/0023-caches.md, Phase G) -- funct3=000 only;
                                      // other MISC-MEM encodings (fence.i/Zifencei) unimplemented, illegal
`define OPCODE_AMO    7'b0101111  // docs/adr/0038-a-extension-phase-v.md -- lr/sc/amo*, funct3=010(.W)/011(.D)

// ---- RV32/64A (docs/adr/0038-a-extension-phase-v.md) ----
// funct5 = inst[31:27] (the top 5 bits of the standard funct7 field --
// inst[26:25] are the real spec's aq/rl ordering bits, ignored here: this
// core is genuinely single-hart, so every AMO is trivially atomic with
// respect to every OTHER hart -- there are none -- and this core's own
// pipeline never splits an instruction's own memory phases across a
// window another instruction could observe mid-sequence either, so aq/rl
// have no real effect to model.
`define AMO_F5_ADD  5'b00000
`define AMO_F5_SWAP 5'b00001
`define AMO_F5_LR   5'b00010
`define AMO_F5_SC   5'b00011
`define AMO_F5_XOR  5'b00100
`define AMO_F5_OR   5'b01000
`define AMO_F5_AND  5'b01100
`define AMO_F5_MIN  5'b10000
`define AMO_F5_MAX  5'b10100
`define AMO_F5_MINU 5'b11000
`define AMO_F5_MAXU 5'b11100

// ---- RV64I (Generation 2, docs/adr/0028-rv64-migration-phase-m.md) ----
// OP-32/OP-IMM-32 reuse OP/OP-IMM's existing funct7/funct3 encodings
// byte-for-byte (see ALUCtrl.v) -- these two new opcodes are the only new
// opcode space RV64I's word-width ("w"-suffixed) instruction family needs.
// Both are XLEN-gated in Control.v: illegalOpcode at XLEN=32 (previously-
// reserved encodings), decoded only at XLEN>=64.
`define OPCODE_OP_32     7'b0111011  // addw/subw/sllw/srlw/sraw/mulw/divw/divuw/remw/remuw
`define OPCODE_OP_IMM_32 7'b0011011  // addiw/slliw/srliw/sraiw (shamt always 5 bits, unlike below)

// New OPCODE_LOAD/OPCODE_STORE funct3 values, real only at XLEN>=64
// (DataMemoryBRAM.v gates their arms on a `generate if (XLEN>=64)` block).
`define F3_LOAD_LD   3'b011  // ld: 8-byte load
`define F3_LOAD_LWU  3'b110  // lwu: 4-byte load, zero-extended (vs. lw's sign-extended)
`define F3_STORE_SD  3'b011  // sd: 8-byte store

// ---- ALUOp (Control.v output -> ALUCtrl.v input) ----
`define ALUOP_LOAD_STORE 2'b00  // lw/sw/jal: ALU always adds
`define ALUOP_BRANCH     2'b01
`define ALUOP_RTYPE      2'b10  // also covers OPCODE_CUSTOM (ctz)
`define ALUOP_ITYPE      2'b11

// ---- ALUCtl (ALUCtrl.v output -> ALU.v input) ----
// Widened 5->6 bits for the B extension (docs/adr/0060) -- only 4 free
// 5-bit codes existed (15,28,29,30), ~26 new B-ext ops needed 6.
`define ALUCTL_ADD  6'b000000
`define ALUCTL_SUB  6'b000001
`define ALUCTL_SLL  6'b000010
`define ALUCTL_SLT  6'b000011
`define ALUCTL_SLTU 6'b000100
`define ALUCTL_XOR  6'b000101
`define ALUCTL_SRL  6'b000110
`define ALUCTL_SRA  6'b000111
`define ALUCTL_OR   6'b001000
`define ALUCTL_AND  6'b001001
`define ALUCTL_BEQ  6'b001010
`define ALUCTL_BNE  6'b001011
`define ALUCTL_BLT  6'b001100
`define ALUCTL_BGE  6'b001101
`define ALUCTL_BLE  6'b001110  // custom (see docs/ARCHITECTURE.md sec 5: not standard RV32I)
`define ALUCTL_BGT  6'b010000  // custom
`define ALUCTL_BLTU 6'b010001
`define ALUCTL_BGEU 6'b010010
`define ALUCTL_CTZ  6'b010101  // now reached via ctz's REAL Zbb encoding, not the retired custom opcode -- see docs/adr/0060
`define ALUCTL_ILLEGAL 6'b111111

// ---- RV32M (docs/adr/0006-rv32m.md) ----
`define ALUCTL_MUL    6'b010011
`define ALUCTL_MULH   6'b010100
`define ALUCTL_MULHSU 6'b010110
`define ALUCTL_MULHU  6'b010111
`define ALUCTL_DIV    6'b011000
`define ALUCTL_DIVU   6'b011001
`define ALUCTL_REM    6'b011010
`define ALUCTL_REMU   6'b011011

// ---- B extension: Zba+Zbb+Zbs (docs/adr/0060) ----
`define ALUCTL_ANDN     6'b100000
`define ALUCTL_ORN      6'b100001
`define ALUCTL_XNOR     6'b100010
`define ALUCTL_MIN      6'b100011
`define ALUCTL_MINU     6'b100100
`define ALUCTL_MAX      6'b100101
`define ALUCTL_MAXU     6'b100110
`define ALUCTL_ROL      6'b100111
`define ALUCTL_ROR      6'b101000
`define ALUCTL_CLZ      6'b101001
`define ALUCTL_CPOP     6'b101010
`define ALUCTL_SEXTB    6'b101011
`define ALUCTL_SEXTH    6'b101100
`define ALUCTL_ORCB     6'b101101
`define ALUCTL_REV8     6'b101110
`define ALUCTL_BCLR     6'b101111
`define ALUCTL_BEXT     6'b110000
`define ALUCTL_BINV     6'b110001
`define ALUCTL_BSET     6'b110010
`define ALUCTL_SH1ADD   6'b110011
`define ALUCTL_SH2ADD   6'b110100
`define ALUCTL_SH3ADD   6'b110101
`define ALUCTL_ADD_UW     6'b110110  // zero-extends A[31:0] before adding -- NOT the same as wordOp (which truncates/sign-extends the RESULT)
`define ALUCTL_SH1ADD_UW  6'b110111
`define ALUCTL_SH2ADD_UW  6'b111000
`define ALUCTL_SH3ADD_UW  6'b111001
`define ALUCTL_SLLI_UW    6'b111010  // shift left then zero-extend the low-32-bit result to XLEN

// funct7 for the B-ext R-type groups (funct3 alone distinguishes within each)
`define FUNCT7_ZBB_MINMAX 7'b0000101
`define FUNCT7_ZBB_ROTATE 7'b0110000
`define FUNCT7_ZBA_SHADD  7'b0010000
`define FUNCT7_ZBS_BCLR_BEXT 7'b0100100  // bclr(f3=001) / bext(f3=101)
`define FUNCT7_ZBS_BINV      7'b0110100
`define FUNCT7_ZBS_BSET      7'b0010100
`define FUNCT7_ZBA_ADD_UW    7'b0000100

// funct6 (funct7[6:1]) for the B-ext I-type groups -- same "top shamt bit
// folds into shift width at XLEN=64" idiom as the existing FUNCT6_ALT.
`define FUNCT6_ZBB_RORI_CLZFAM 6'b011000  // rori(f3=101) / clz,ctz,cpop,sext.b,sext.h(f3=001, rs2-field selects)
`define FUNCT6_ZBS_BCLRI_BEXTI 6'b010010  // bclri(f3=001) / bexti(f3=101)
`define FUNCT6_ZBS_BINVI       6'b011010
`define FUNCT6_ZBS_BSETI       6'b001010
`define FUNCT6_ZBB_ORCB        6'b001010  // same bit pattern as BSETI's funct6, disambiguated by funct3 (101 vs 001)
`define FUNCT6_ZBB_REV8        6'b011010  // same bit pattern as BINVI's funct6, disambiguated by funct3 (101 vs 001)
`define FUNCT6_ZBA_SLLIUW      6'b000010

// rs2-field (inst[24:20]) values that select within FUNCT6_ZBB_RORI_CLZFAM/f3=001
`define RS2_CLZ     5'b00000
`define RS2_CTZ     5'b00001
`define RS2_CPOP    5'b00010
`define RS2_SEXTB   5'b00100
`define RS2_SEXTH   5'b00101

// funct7 values used to distinguish R-type sub-ops now that ALUCtrl sees the
// full 7-bit field (previously only inst[30] was threaded through, enough
// for add/sub but not enough to add a whole new funct7=0000001 group).
`define FUNCT7_BASE   7'b0000000  // add/sll/slt/sltu/xor/srl/or/and
`define FUNCT7_ALT    7'b0100000  // sub/sra, and this core's custom ctz
`define FUNCT7_MULDIV 7'b0000001  // RV32M

// RV64I's full-width (non-"w") slli/srli/srai widen shamt from 5 bits
// (inst[24:20]) to 6 bits (inst[25:20]) to reach 63 -- bit 25, formerly
// the low bit of FUNCT7_ALT/FUNCT7_BASE, is now part of shamt, so the
// srl-vs-sra discriminator shrinks to this 6-bit funct6 (inst[31:26]).
// At XLEN=32 bit 25 is spec-0 for every legal shift encoding, so gating on
// funct7[6:1] instead of the full 7-bit funct7 is bit-exact there (see
// ALUCtrl.v). The OP-IMM-32 "w"-suffixed shifts (slliw/srliw/sraiw) keep
// the original 5-bit shamt/7-bit-funct7 shape unconditionally -- see
// OPCODE_OP_IMM_32 above.
`define FUNCT6_ALT 6'b010000

// ---- CSR / exceptions (docs/adr/0011-csr-and-exceptions.md) ----
// M-mode only: no S-mode/U-mode, no PMP, no real interrupts (this design
// has no interrupt lines) -- synchronous exceptions (illegal instruction,
// ecall, ebreak) and the 5 CSRs needed to handle and return from them.

// SYSTEM opcode funct3 (inst[14:12]): which CSR op, or "not a CSR read/
// write at all" (000 -- ecall/ebreak/mret, distinguished by inst[31:20]).
`define CSR_F3_NONE   3'b000
`define CSR_F3_RW     3'b001
`define CSR_F3_RS     3'b010
`define CSR_F3_RC     3'b011
`define CSR_F3_RWI    3'b101
`define CSR_F3_RSI    3'b110
`define CSR_F3_RCI    3'b111

// inst[31:20] (the "csr" field position) for funct3=000's three defined instructions.
`define CSR_IMM12_ECALL  12'h000
`define CSR_IMM12_EBREAK 12'h001
`define CSR_IMM12_MRET   12'h302

// CSR addresses (standard RISC-V machine-mode assignments)
`define CSR_ADDR_MSTATUS  12'h300
`define CSR_ADDR_MIE      12'h304
`define CSR_ADDR_MTVEC    12'h305
`define CSR_ADDR_MSCRATCH 12'h340
`define CSR_ADDR_MEPC     12'h341
`define CSR_ADDR_MCAUSE   12'h342
`define CSR_ADDR_MIP      12'h344

// mcause values this core can actually raise. Exceptions: mcause[31]=0,
// the values below in the low bits. docs/adr/0020-soc-integration.md
// (Phase D7) adds the two interrupt causes this core can now also raise
// (mcause[31]=1 -- see CSR.v's trap_is_interrupt input) using the same
// spec-assigned low-bit codes as the exception ones, since the interrupt
// bit itself is what disambiguates them, not a disjoint numbering.
`define MCAUSE_ILLEGAL_INSTRUCTION 32'd2
`define MCAUSE_BREAKPOINT          32'd3
`define MCAUSE_ECALL_FROM_M        32'd11

// mie/mip bit positions (standard RISC-V machine-mode assignments).
// docs/adr/0034-uart-clint-register-compat-phase-r.md (Phase R) adds the
// third real bit, MIE_MSIE_BIT (machine software interrupt, driven by the
// real CLINT `msip` register in Timer.v, not a CSR-writable bit) -- every
// other mie/mip bit stays hardwired 0 (no S-mode/U-mode delegation, this
// core is M-mode only throughout).
`define MIE_MSIE_BIT 3   // machine software interrupt enable/pending (Phase R)
`define MIE_MTIE_BIT 7   // machine timer interrupt enable/pending
`define MIE_MEIE_BIT 11  // machine external interrupt enable/pending
`define MCAUSE_INT_MACHINE_SOFTWARE 32'd3
`define MCAUSE_INT_MACHINE_TIMER    32'd7
`define MCAUSE_INT_MACHINE_EXTERNAL 32'd11

// docs/adr/0035-minimal-sbi-firmware-phase-s.md (Phase S). Real supervisor-
// level interrupt causes -- MIE_SSIE_BIT/MIE_STIE_BIT (riscv_defs.vh, Phase
// F) already named the mie/mip_sw bit positions; these are the mcause/
// scause low-bit values a software-synthesized supervisor software/timer
// interrupt actually reports once riscvpipeline.v's own interrupt_taken
// recognizes it (a real gap Phase S found and fixed -- mip_sw's SSIP/STIP
// had no path into interrupt_taken before this phase).
`define MCAUSE_INT_SUPERVISOR_SOFTWARE 32'd1
`define MCAUSE_INT_SUPERVISOR_TIMER    32'd5

// ---- RV32F (docs/adr/0019-f-extension.md, Phase C of the redesign) ----
// Encoding constants only in this commit -- no RTL consumes any of these
// yet (mirrors this project's own precedent of declaring a new mechanism
// before anything wires it up, e.g. docs/adr/0018's Phase A1). This core
// implements F only, never D (double-precision) -- fmt is always FMT_S,
// and FLEN==XLEN==32 exactly, so NaN-boxing (which exists only to keep
// narrower-than-FLEN values distinguishable from real FLEN-wide ones) does
// not apply here and is deliberately not implemented (see the ADR).

// New opcodes (inst[6:0])
`define OPCODE_FP       7'b1010011  // fadd.s/fsub.s/fmul.s/.../feq.s/fcvt.*/fmv.*/fclass.s -- sub-op in funct5 (inst[31:27])
`define OPCODE_LOAD_FP  7'b0000111  // flw
`define OPCODE_STORE_FP 7'b0100111  // fsw
`define OPCODE_MADD     7'b1000011  // fmadd.s
`define OPCODE_MSUB     7'b1000111  // fmsub.s
`define OPCODE_NMSUB    7'b1001011  // fnmsub.s
`define OPCODE_NMADD    7'b1001111  // fnmadd.s

// fmt field (inst[26:25], present on OPCODE_FP and the MADD-family
// opcodes) -- 2'b00 (S, single-precision) is the only value this core ever
// produces or accepts; 2'b01 (D)/2'b10 (H)/2'b11 (Q) are other precisions
// this core does not implement.
`define FMT_S 2'b00

// OP-FP funct5 (inst[31:27]): which float operation. A recognized funct5
// with an unrecognized funct3/rs2 sub-selector below still traps as
// illegal, the same way ALUCtrl.v's own `default: ALUCTL_ILLEGAL` does for
// integer ops.
`define FUNCT5_FADD           5'b00000
`define FUNCT5_FSUB           5'b00001
`define FUNCT5_FMUL           5'b00010
`define FUNCT5_FDIV           5'b00011
`define FUNCT5_FSQRT          5'b01011  // rs2 must be 0 (single real operand, rs1)
`define FUNCT5_FSGNJ          5'b00100  // funct3 selects fsgnj.s/fsgnjn.s/fsgnjx.s
`define FUNCT5_FMINMAX        5'b00101  // funct3 selects fmin.s/fmax.s
`define FUNCT5_FCMP           5'b10100  // funct3 selects fle.s/flt.s/feq.s -- writes an INTEGER dest register
`define FUNCT5_FCVT_W_S       5'b11000  // rs2 selects fcvt.w.s/fcvt.wu.s -- writes an INTEGER dest register
`define FUNCT5_FCVT_S_W       5'b11010  // rs2 selects fcvt.s.w/fcvt.s.wu -- writes the FLOAT dest register
`define FUNCT5_FMV_X_W_FCLASS 5'b11100  // funct3 selects fmv.x.w/fclass.s -- both write an INTEGER dest register; rs2 must be 0
`define FUNCT5_FMV_W_X        5'b11110  // rs2 must be 0; writes the FLOAT dest register

// funct3 sub-selectors within a shared funct5 group
`define F3_FSGNJ_J      3'b000
`define F3_FSGNJ_JN     3'b001
`define F3_FSGNJ_JX     3'b010
`define F3_FMIN         3'b000
`define F3_FMAX         3'b001
`define F3_FLE          3'b000
`define F3_FLT          3'b001
`define F3_FEQ          3'b010
`define F3_FMV_X_W      3'b000
`define F3_FCLASS       3'b001

// rs2 sub-selectors (inst[24:20]) within FUNCT5_FCVT_W_S/FUNCT5_FCVT_S_W --
// only meaningful for those two funct5 groups; every other OP-FP funct5
// either ignores rs2 entirely (2-operand ops) or requires it to be 0
// (fsqrt.s/fmv.x.w/fmv.w.x/fclass.s, per spec -- a nonzero rs2 there is a
// reserved/illegal encoding, not a real conversion variant).
`define RS2_FCVT_W  5'b00000
`define RS2_FCVT_WU 5'b00001

// Rounding mode (inst[14:12] on OP-FP/MADD-family instructions, "rm").
// RM_DYN means "use frm's current value instead of a static per-instruction
// mode" -- see docs/adr/0019 and CSR_ADDR_FRM below. 3'b101/3'b110 are
// reserved (unrecognized rm -- see docs/adr/0019 for how this core handles it).
`define RM_RNE 3'b000  // round to nearest, ties to even (IEEE 754 default)
`define RM_RTZ 3'b001  // round toward zero
`define RM_RDN 3'b010  // round down (toward -infinity)
`define RM_RUP 3'b011  // round up (toward +infinity)
`define RM_RMM 3'b100  // round to nearest, ties to max magnitude
`define RM_DYN 3'b111  // dynamic -- use frm

// New CSR addresses (standard RISC-V assignments). fflags/frm are the two
// sub-fields of fcsr, also independently addressable per spec (a csrrw to
// fflags or frm alone must not disturb the other field).
`define CSR_ADDR_FFLAGS 12'h001
`define CSR_ADDR_FRM    12'h002
`define CSR_ADDR_FCSR   12'h003

// docs/adr/0020-soc-integration.md (Phase D1). Memory-mapped I/O base
// address -- the boundary between RAM (address < MEM_SIZE_BYTES, riscv-
// pipeline.v's own parameter, not a `` `define`` here since it's already a
// per-instantiation-configurable RTL parameter) and peripherals. Chosen far
// above any address this core's small test programs ever generate (every
// existing directed/random test computes tiny offsets from a base near 0
// or 32 -- docs/adr/0010's `random_gen.py`), so RAM and MMIO can never
// collide even though nothing currently range-checks a load/store address
// against RAM's own size. No consumers yet -- WbDecoder.v (D1) takes
// per-slave base/size as elaboration parameters at its instantiation site,
// not by reading this file directly; this constant is the single place a
// future peripheral's own base address (`UART_BASE`, `TIMER_BASE`, added
// in D5/D8) is defined relative to.
`define MMIO_BASE 32'h1000_0000

// docs/adr/0034-uart-clint-register-compat-phase-r.md (Phase R, superseding
// the old D5-era 4-register map). Uart.v's own 8-register, ns16550a-
// compatible window (RBR/THR, IER, IIR/FCR, LCR, MCR, LSR, MSR, SCR at word
// offsets 0/4/8/C/10/14/18/1C, DLAB-gated per real ns16550a semantics,
// decoded on s_addr[4:2] inside Uart.v itself) -- 32 bytes is exactly that
// window. Base address unchanged from the original D5 choice -- a real,
// free coincidence: 0x1000_0000 already matches QEMU-virt's own literal
// UART address.
`define UART_BASE `MMIO_BASE  // the first, and today only until Phase R's Timer/CLINT, peripheral
`define UART_SIZE 32'd32

// docs/adr/0034-uart-clint-register-compat-phase-r.md (Phase R, superseding
// the old D8-era 2-register 32-bit map). Timer.v is now a real CLINT-
// compatible peripheral: msip/mtimecmp/mtime at the exact byte offsets
// Linux's own drivers/clocksource/timer-clint.c hardcodes (CLINT_OFF_*
// below), mtime/mtimecmp genuinely 64-bit regardless of XLEN. Given its own
// fresh base (not derived off UART_BASE+UART_SIZE any more, since the real
// offsets span up to 0xBFFC) -- 0x10000-aligned so Timer.v can decode the
// three real offsets directly off the low 16 bits of the absolute address,
// no BASE subtraction needed inside the module (mirrors Uart.v's own
// "decode raw address bits" idiom). Deliberately NOT QEMU-virt's own
// literal CLINT address (0x0200_0000) -- that address is below this
// project's own RAM region (RAM starts at 0, up to MEM_SIZE_BYTES, which
// can reach 64MB per Phase Q) and would collide, since this core's memory
// map shape (RAM-at-0, MMIO far above) differs from QEMU-virt's own
// (RAM-at-0x8000_0000).
`define TIMER_BASE (`MMIO_BASE + 32'h0010_0000)  // 0x1010_0000
`define TIMER_SIZE 32'h0001_0000                 // 64KB, matches the real SiFive/QEMU-virt CLINT region size
`define CLINT_OFF_MSIP      16'h0000
`define CLINT_OFF_MTIMECMP  16'h4000  // + 4 = mtimecmph, XLEN=32 only
`define CLINT_OFF_MTIME     16'hBFF8  // + 4 = mtimeh, XLEN=32 only

// docs/adr/0050-heterogeneous-dual-core-soc-gen6-n.md (Gen6-N). Mailbox.v's
// own address window -- the real inter-core handoff surface for
// design/HeteroSoC.v (PIPELINED + OOOCore.v). Fresh 0x10000-aligned base
// off TIMER_BASE, same precedent TIMER_BASE itself already used off
// UART_BASE. 256 bytes (64 words) -- generous for a real mailbox
// protocol (go/done flags, a handful of args, a small result area) well
// beyond what any current directed test needs.
`define MAILBOX_BASE (`MMIO_BASE + 32'h0020_0000)  // 0x1020_0000
`define MAILBOX_SIZE 32'd256

// ---- Sv32 MMU / M-S-U privilege modes (Phase F of the redesign) ----
// This core was M-mode only through Phase E (docs/adr/0011 explicitly drew
// that boundary; docs/adr/0020's Future Improvements explicitly deferred
// S/U-mode delegation to "whenever" this phase happens). Phase F is that
// phase: real S-mode/U-mode privilege levels, `mideleg`/`medeleg` trap
// delegation, and a full 2-level Sv32 page-table walk with a TLB, gated
// off unless `satp.MODE`==Sv32 and the current privilege is below M
// (M-mode always executes physical addresses this phase -- `mstatus.MPRV`,
// which would let M opt into translation too, is out of scope, see the
// phase plan's own Explicitly out of scope section).

// Current-privilege-level encoding (standard RISC-V `mstatus.MPP`/`sstatus.SPP`
// and satp.MODE-adjacent convention) -- 2'b10 (H, hypervisor) is a reserved
// encoding this core never produces or accepts, since there is no H-mode.
`define PRIV_U 2'b00
`define PRIV_S 2'b01
`define PRIV_M 2'b11

// `sret` (SYSTEM opcode, funct3=000, like ecall/ebreak/mret) -- distinguished
// by the same fixed inst[31:20] "csr" field position those three already use.
`define CSR_IMM12_SRET 12'h102

// `sfence.vma rs1, rs2` (SYSTEM opcode, funct3=000) -- unlike ecall/ebreak/
// mret/sret, this one has real rs1 (address, or x0 for "all addresses") and
// rs2 (ASID, or x0 for "all ASIDs") register fields, so it's distinguished
// by funct7 (inst[31:25]) alone, not the full 12-bit immediate position.
// This phase always flushes the whole TLB regardless of rs1/rs2 (see the
// phase plan's own "sfence.vma flushes unconditionally" scoping default),
// so rs1/rs2 are decoded (Control.v must still recognize this funct7 to
// avoid misdecoding it as something else) but not actually read for their
// address/ASID meaning.
`define FUNCT7_SFENCE_VMA 7'b0001001

// New CSR addresses (standard RISC-V S-mode assignments) -- `sstatus`/`sie`/
// `sip` are NOT separate storage, same "one more view onto the same bits"
// relationship `fcsr` already has onto `{frm,fflags}` (CSR.v's own header
// comment) -- here the view is onto `mstatus`/`mie`/`mip`'s S-mode-visible
// bit subset, which is how the real privileged spec itself defines them.
`define CSR_ADDR_SSTATUS  12'h100
`define CSR_ADDR_SIE      12'h104
`define CSR_ADDR_STVEC    12'h105
`define CSR_ADDR_SSCRATCH 12'h140
`define CSR_ADDR_SEPC     12'h141
`define CSR_ADDR_SCAUSE   12'h142
`define CSR_ADDR_STVAL    12'h143
`define CSR_ADDR_SIP      12'h144
`define CSR_ADDR_SATP     12'h180
// M-mode-only additions this phase needs alongside the S-mode set above:
// `mtval` (the faulting address companion to `mcause`, not previously
// implemented -- this phase is the first real consumer, a page fault's
// faulting virtual address) and `mideleg`/`medeleg` (which causes, if they
// occur at or below S-mode, get delegated to S's own trap vector instead
// of M's -- per spec, a trap whose *source* privilege is M itself is never
// delegated, regardless of these bits, see riscvpipeline.v's own delegation
// condition).
`define CSR_ADDR_MTVAL   12'h343
`define CSR_ADDR_MEDELEG 12'h302
`define CSR_ADDR_MIDELEG 12'h303

// docs/adr/0025-hpc-performance-csrs.md (Phase J). Standard mcycle/minstret
// (64-bit each via a `h` high-half register, spec-standard addresses) plus
// mcountinhibit (spec-standard: bit0=CY inhibits mcycle, bit2=IR inhibits
// minstret, bits[3+i] inhibit mhpmcounter[3+i] -- bit1 and every bit past
// what this core implements are hardwired 0) and 9 generic mhpmcounter3-11/
// mhpmevent3-11 pairs -- one per Generation-1 event this core actually
// wants to observe (see riscv_defs.vh's own event-index comment at
// CSR.v's `hpm_event_pulse` declaration for what index 1-9 each select).
// Read-write per the real privileged spec (an OS can save/restore these
// across a context switch); this core has no OS today, but the real spec
// behavior costs nothing extra to implement (docs/adr/0025).
`define CSR_ADDR_MCOUNTINHIBIT 12'h320
`define CSR_ADDR_MCYCLE        12'hB00
`define CSR_ADDR_MCYCLEH       12'hB80
`define CSR_ADDR_MINSTRET      12'hB02
`define CSR_ADDR_MINSTRETH     12'hB82
// mhpmcounter3/mhpmevent3 are the base of a 9-entry contiguous range
// (mhpmcounter3-11 / mhpmevent3-11); CSR.v derives every other address in
// each range arithmetically off these two bases (`csr_addr - BASE`) rather
// than needing 9 independent `\`define`s per range, the same derived-
// address precedent `TIMER_BASE` already uses off `UART_BASE` above.
`define CSR_ADDR_MHPMCOUNTER3_BASE  12'hB03
`define CSR_ADDR_MHPMCOUNTER3H_BASE 12'hB83
`define CSR_ADDR_MHPMEVENT3_BASE    12'h323
`define NUM_HPM_COUNTERS 9

// New mcause values this phase adds, same "already-assigned spec numbering,
// the interrupt bit is what disambiguates, not a disjoint range" convention
// docs/adr/0020 established for the timer/external interrupt causes.
// ECALL_FROM_M already existed (docs/adr/0011); ecall's cause is now
// privilege-dependent (whichever of these three was current at trap time),
// not the fixed M-only value it always was through Phase E.
`define MCAUSE_ECALL_FROM_U 32'd8
`define MCAUSE_ECALL_FROM_S 32'd9
`define MCAUSE_INSTRUCTION_PAGE_FAULT 32'd12
`define MCAUSE_LOAD_PAGE_FAULT        32'd13
`define MCAUSE_STORE_PAGE_FAULT       32'd15

// mstatus bit positions this phase makes real, alongside the existing
// MIE_MTIE_BIT/MIE_MEIE_BIT for mie/mip and mstatus's own pre-existing
// bit3(MIE)/bit7(MPIE) (CSR.v itself still hardcodes those two directly --
// only the genuinely new bits get named constants here, matching how
// MIE_MTIE_BIT/MIE_MEIE_BIT were the only mie/mip bits that needed names
// when D7 added them).
`define MSTATUS_SIE_BIT   1   // S-mode global interrupt enable
`define MSTATUS_SPIE_BIT  5   // S-mode: previous SIE, saved across a trap into S
`define MSTATUS_SPP_BIT   8   // S-mode: privilege mode (U or S only, 1 bit) before a trap into S
`define MSTATUS_MPP_LO    11  // M-mode: privilege mode (U/S/M, 2 bits, 12:11) before a trap into M
`define MIE_SSIE_BIT 1   // S-mode software interrupt enable (mip's software half is not implemented,
                           // no second hart -- mirrors this core's existing MSIP omission)
`define MIE_STIE_BIT 5   // S-mode timer interrupt enable
`define MIE_SEIE_BIT 9   // S-mode external interrupt enable

// satp fields (Sv32 -- the only mode this core implements besides Bare).
// MODE is a single bit for Sv32 (0=Bare/no translation, 1=Sv32) -- real
// RV32 satp has no other mode encoding to choose between.
`define SATP_MODE_BIT 31
`define SATP_ASID_HI  30
`define SATP_ASID_LO  22
`define SATP_PPN_HI   21
`define SATP_PPN_LO   0

// Sv32 PTE (page-table-entry) format -- identical at both walk levels.
// PPN occupies bits 31:10 (two sub-fields, PPN[1]=31:20/PPN[0]=19:10, only
// relevant for reconstructing a megapage's physical address; the walker
// otherwise treats PPN as one 22-bit field). A/D (accessed/dirty) are
// tracked here as ordinary bits the walker reads but this phase's own
// Ptw.v does not itself set on a successful access (matching this core's
// existing "simulate today's real timing, simplify what doesn't change
// correctness" convention -- a real OS sets these up front or via its own
// fault handler; auto-set-on-access is a real but separable future
// optimization, not attempted here).
`define PTE_V_BIT 0   // valid
`define PTE_R_BIT 1   // readable
`define PTE_W_BIT 2   // writable
`define PTE_X_BIT 3   // executable
`define PTE_U_BIT 4   // accessible from U-mode
`define PTE_G_BIT 5   // global (matches in every address space -- this phase's
                        // TLB does not special-case this bit; see Ptw.v)
`define PTE_A_BIT 6   // accessed
`define PTE_D_BIT 7   // dirty
`define PTE_PPN_LO 10  // PPN occupies bits 31:10 of the 32-bit PTE word

// Sv32 address decomposition -- VPN[1] is the level-1 (megapage) index,
// VPN[0] the level-0 (4KB page) index, both 10 bits; the low 12 bits are
// the page offset, untouched by translation.
`define VPN1_HI 31
`define VPN1_LO 22
`define VPN0_HI 21
`define VPN0_LO 12
`define PAGE_OFFSET_HI 11
`define PAGE_OFFSET_LO 0

// Generation 3, Phase O: RV64/Sv39 privilege-CSR groundwork
// (docs/adr/0031-sv39-privilege-csr-groundwork-phase-o.md). Declaration only
// -- translate_enable stays gated (XLEN==32) until Phase P builds a real
// Sv39 TLB/PTW; nothing here changes live translation behavior.

// mstatus.UXL/SXL (RV64 only) -- report the effective XLEN visible to
// U-mode/S-mode. This core has no real 32-bit U/S sub-mode, so these are
// fixed WARL-to-2 constants applied at the CSR read mux, not real storage
// bits (CSR.v never writes them).
`define MSTATUS_UXL_LO 32
`define MSTATUS_SXL_LO 34
`define MXL_XLEN64 2'd2

// satp fields for Sv39 (RV64) -- a completely different layout from Sv32's
// (MODE is 4 bits at 63:60, not 1 bit at 31; Bare=0, Sv39=8; Sv48/Sv57 are
// not implemented). CSR.v's satp_mode_val/satp_ppn_val decode picks between
// this layout and the existing Sv32 one based on XLEN.
`define SATP64_MODE_HI 63
`define SATP64_MODE_LO 60
`define SATP64_ASID_HI 59
`define SATP64_ASID_LO 44
`define SATP64_PPN_HI  43
`define SATP64_PPN_LO  0
`define SATP_MODE_SV39 4'h8

// Sv39 VA decomposition (VPN[2]/VPN[1]/VPN[0], 9 bits each) and Sv39 PTE PPN
// sub-fields (PPN[2]/PPN[1]/PPN[0], for megapage/gigapage reconstruction) --
// no RTL consumes any of these yet, pre-declared for Phase P's own new
// Tlb.v/Ptw.v (mirrors how Phase F1 pre-declared the Sv32 equivalents ahead
// of F3/F4 actually using them). Page offset and the V/R/W/X/U/G/A/D PTE
// flag bits are identical in both formats -- reuse PAGE_OFFSET_HI/LO and
// PTE_*_BIT above, no new defines needed.
`define SV39_VPN2_HI 38
`define SV39_VPN2_LO 30
`define SV39_VPN1_HI 29
`define SV39_VPN1_LO 21
`define SV39_VPN0_HI 20
`define SV39_VPN0_LO 12
`define SV39_PTE_PPN2_HI 53
`define SV39_PTE_PPN2_LO 28
`define SV39_PTE_PPN1_HI 27
`define SV39_PTE_PPN1_LO 19
`define SV39_PTE_PPN0_HI 18
`define SV39_PTE_PPN0_LO 10

`endif
