`default_nettype none

`include "riscv_defs.vh"
`include "wb_defs.vh"   // Gen6-P2 (docs/adr/0053): WB_SEL_WIDTH, for Ptw39's own m_sel port

// No `include for the design/*.v modules instantiated below (Control.v,
// ALUCtrl.v, ImmGen.v, ALU.v, InstructionMemory.v, RegisterAliasTable.v,
// FreeList.v, PhysicalRegisterFile.v, ReorderBuffer.v,
// ReservationStation.v) -- matching this project's own established
// convention (riscvpipeline.v/DCache.v only `include their .vh headers,
// never sibling design/*.v modules): every design/*.v file is compiled
// together as siblings in one iverilog invocation (`design/*.v`), so a
// module `include here would double-declare when that same file is ALSO
// picked up directly by the glob. Testbenches (which aren't part of that
// glob) list the full flat dependency chain themselves instead -- see
// sim/tb/tb_ooocore_alu_d1.v, matching tb_cache_mshr_e1.v's own
// established flat-include-list precedent.

// Generation 6 (out-of-order core), Gen6-D
// (C:\Users\poorn\.claude\plans\gen6-ooo-core.md). A genuinely new
// top-level core -- coexists with, never modifies, `riscvpipeline.v`'s
// `PIPELINED` (docs/ROADMAP_VISION.md's own explicit Gen6 framing: "a new
// core, not a modification of the existing pipeline").
//
// Gen6-D's OWN scope, deliberately narrow (per the plan file): INT-ALU
// only (R-type/I-type integer ops -- no branches, no loads/stores, no
// mul/div, no FP, no MMU, no interrupts, no atomics yet -- each is its
// own later sub-phase). SINGLE-ISSUE internally for this first bring-up
// (Gen6-A/B/C's own modules are all already dual-issue-CAPABLE -- 2
// dispatch/complete/retire ports each -- but this phase only drives
// slot0 on every one of them, leaving slot1 permanently tied off; Gen6-K
// widens to real 2-wide once this single-issue skeleton is proven
// correct end-to-end, matching the plan's own explicitly-flagged "decide
// at Gen6-D time" contingency).
//
// Frontend (fetch/decode/rename/dispatch) is entirely COMBINATIONAL,
// single cycle, no pipeline latches at all -- a deliberate, flagged
// simplification for this bring-up: real frontend pipelining (separate
// F/D/R/D stage registers, almost certainly needed for realistic timing
// and for Gen6-K's own 2-wide widening) is future work, not attempted
// here. What Gen6-D actually proves is the OoO BACKEND (rename -> RS ->
// execute -> CDB -> ROB retire) is correct, decoupled from frontend
// timing entirely.
//
// No resource-exhaustion stall beyond a simple whole-cycle bubble
// (dispatch_stall, below) -- no real backpressure queueing. Sized
// generously (ROB_ENTRIES/RS_ALU_ENTRIES/free-preg count all comfortably
// exceed any realistic straight-line bring-up test program, and
// single-issue-in/roughly-single-issue-out keeps steady-state occupancy
// low) -- a real, deliberate simplification, not a hidden risk for
// THIS phase's own test scope, but genuinely insufficient for sustained
// high-occupancy execution; flagged, not silently dropped.
module OOOCore #(
    parameter XLEN            = 64,
    parameter NUM_AREGS       = 32,
    parameter NUM_PREGS       = 64,
    parameter ROB_ENTRIES     = 16,
    parameter RS_ALU_ENTRIES  = 8,
    parameter IMEM_SIZE_BYTES = 4096,
    parameter IMEM_INIT_FILE  = "sim/programs/arith.mem",
    parameter DMEM_SIZE_BYTES = 4096,
    parameter SP_INIT         = 64'd128,
    parameter BHT_BTB_ENTRIES = 32,   // Gen6-G, matches docs/adr/0021's own default
    parameter NUM_FREGS       = 32,   // Gen6-H -- f0-f31, RV32F register count
    parameter NUM_FPREGS      = 64,   // Gen6-H -- float physical register count
    parameter FLEN            = 32,   // Gen6-H -- this project's F-extension is
                                        // F-only (never D): FALU.v's own header
                                        // comment documents FLEN==32 always,
                                        // independent of XLEN
    parameter RS_FALU_ENTRIES = 8,    // Gen6-H

    parameter NUM_VREGS       = 32,   // Gen7 Pillar V Phase 1 (docs/adr/0061) -- v0-v31
    parameter NUM_VPREGS      = 64,   // vector physical register count
    parameter VLEN            = 64'd512,  // bits per vector register (user-confirmed
                                        // most-ambitious VLEN option via AskUserQuestion).
                                        // Explicitly 64-bit-sized -- an unsized literal
                                        // self-determines 32-bit width regardless of XLEN
                                        // (the same SP_INIT-class Icarus quirk fixed above),
                                        // which would corrupt VLEN[XLEN-1:0]'s own bit-select
                                        // in vec_cfg_vlmax below at XLEN=64.

    parameter AREG_BITS  = $clog2(NUM_AREGS),
    parameter PREG_BITS  = $clog2(NUM_PREGS),
    parameter FAREG_BITS = $clog2(NUM_FREGS),
    parameter FPREG_BITS = $clog2(NUM_FPREGS),
    parameter VAREG_BITS = $clog2(NUM_VREGS),
    parameter VPREG_BITS = $clog2(NUM_VPREGS),
    parameter ROB_IDX_BITS = $clog2(ROB_ENTRIES),
    // Reservation-station payload: {use_forced_a, use_link_b,
    // forced_a_value[XLEN-1:0], ALUSrc, ALUCtl[5:0], imm[XLEN-1:0]}.
    // ALUCtl widened 5->6 bits for the B extension (docs/adr/0060).
    // ALUSrc tells the execute step whether operand B is the decoded
    // immediate (I-type) or PhysicalRegisterFile's own src2 read
    // (R-type) -- see the execute section below. Gen6-O (docs/adr/0051):
    // use_forced_a/forced_a_value/use_link_b added for lui/auipc/jal/
    // jalr/csrrX -- none of these compute their own destination value
    // from a normal two-PRF-operand ALU op the way R/I-type instructions
    // do (lui: 0+imm; auipc/jal/jalr-link: PC+something; csrrX: the
    // CSR's own old value), so the execute stage's own operand-A/B
    // selection needs an escape hatch from the ordinary PRF-read path,
    // captured once at DISPATCH time (when the real value -- 0, this
    // instruction's own PC, or the CSR's own current value -- is known)
    // and carried through RS_ALU exactly like ALUSrc/imm already are.
    // Gen7 Pillar V Phase 1 (docs/adr/0061): +1 leading bit for
    // is_vsetvl, selecting a min(a,b) override of alu_out at issue time
    // (vsetvli/vsetivli's own vl=min(AVL,VLMAX) computation) instead of
    // ALU.v's own result -- reuses this exact escape-hatch mechanism,
    // same reasoning as lui/auipc/jal/jalr/csrrX above.
    parameter PAYLOAD_BITS = 1 + 1 + 1 + XLEN + 1 + 6 + XLEN
)(
    input wire clk,
    input wire rst,   // active-low, same convention as every other
                        // module in this project (Register.v, DCache.v, ...)

    // Gen6-N (docs/adr/0050): the mailbox side of a heterogeneous
    // PIPELINED+OOOCore.v SoC (design/HeteroSoC.v) -- design/Mailbox.v's
    // own "port B" simple direct interface (matching DataMemoryBRAM.v's
    // own memRead/memWrite/address/writeData/readData shape, word-only).
    // Unconnected in any standalone OOOCore.v instantiation (every
    // existing directed/random/formal test) -- changes nothing there.
    output wire              mailbox_memWrite,
    output wire              mailbox_memRead,
    output wire [XLEN-1:0]   mailbox_address,
    output wire [XLEN-1:0]   mailbox_writeData,
    input  wire [XLEN-1:0]   mailbox_readData,

    // Gen6-P3 (docs/adr/0054): raw, level-pending machine-mode interrupt
    // sources -- same names/shape as CSR.v's own ports (which these route
    // straight through to), same meaning as PIPELINED's own
    // msip_pending_w/timer_pending_w/uart_irq (docs/adr/0020 Phase D8/D9,
    // docs/adr/0034 Phase R). This core has no Timer.v/Uart.v (CLINT/PLIC-
    // lite) instantiated yet -- a caller (a future SoC integration, or a
    // testbench directly) drives these; tied 0 in every existing
    // standalone instantiation, changing nothing there.
    input  wire               msip_pending,
    input  wire               timer_pending,
    input  wire               ext_pending
);

// ==========================================================================
// Fetch (combinational read at pc_r; no cache yet -- Gen6-D scope. Gen6-P2
// (docs/adr/0053) added Sv39 translation -- itlb_hit/itlb_ppn/translate_enable
// are forward-referenced here, defined in the MMU section further down
// (same "declared where naturally consumed, wired up where naturally
// produced" convention every other Gen6-* forward reference in this file
// already uses).
// ==========================================================================
reg [XLEN-1:0] pc_r;

// Gen6-P2: translated physical fetch address when translation is live and
// the ITLB actually hit; the raw VA otherwise (both the "MMU off" case and
// the "still resolving" case -- itlb_hit reads a stale/never-filled entry
// as a structural miss, same X-avoidance reasoning docs/adr/0032's own P3
// imem_phys_addr comment already established for PIPELINED).
wire [XLEN-1:0] imem_phys_addr = (translate_enable && itlb_hit) ?
    {itlb_ppn[19:0], pc_r[11:0]} : pc_r;

wire [XLEN-1:0] inst_full;
InstructionMemory #(.INIT_FILE(IMEM_INIT_FILE), .SIZE_BYTES(IMEM_SIZE_BYTES), .XLEN(XLEN)) m_IMem(
    .readAddr(imem_phys_addr),
    .inst(inst_full)
);
// Gen6-P2: forced to a real, safe, already-established "illegal
// instruction" encoding (all-zero, InstructionMemory.v's own documented
// out-of-bounds convention) for as long as translation hasn't actually
// resolved to a hit -- covers both an in-progress walk (itlb_miss, still
// stalling dispatch below) and a walk that just concluded with a fault
// (itlb_hit stays 0; Tlb39.v only ever fills on a successful walk). This
// is what lets itlb_fault_this_cycle (below) reuse Gen6-I's existing
// illegal-instruction trap machinery completely unmodified -- every other
// decode wire (needs_dest, is_mem_op, ...) falls out safely 0 for free,
// the same way a real out-of-bounds fetch already does.
wire [31:0] inst_word = (translate_enable && !itlb_hit) ? 32'b0 : inst_full[31:0];
                                            // instructions are always a
                                            // 32-bit word here -- Gen6-D
                                            // doesn't support RVC yet.

// ==========================================================================
// Decode (reuses the SAME Control.v/ALUCtrl.v/ImmGen.v this project's
// existing PIPELINED core already uses and has already verified --
// decode logic doesn't care whether the backend is in-order or OoO).
// ==========================================================================
wire [4:0] rs1_areg = inst_word[19:15];
wire [4:0] rs2_areg = inst_word[24:20];
wire [4:0] rd_areg  = inst_word[11:7];

wire branch_c, memRead_c, memtoReg_c, memWrite_c, ALUSrc_c, regWrite_c;
wire [1:0] ALUOp_c;
wire [2:0] funct3_c;
wire [6:0] funct7_c;
wire jump_c, jalr_c, lui_c, auipc_c, isCsr_c, isEcall_c, isEbreak_c, isMret_c, isSret_c, isSfenceVma_c, isFence_c, isAmo_c, illegalOpcode_c, fRegWrite_c;
wire isVecCfg_c;   // Gen7 Pillar V Phase 1 (docs/adr/0061)

Control #(.XLEN(XLEN)) m_Control(
    .opcode(inst_word[6:0]),
    .funt7(inst_word[31:25]),
    .funt3(inst_word[14:12]),
    .csr_imm12(inst_word[31:20]),
    .branch(branch_c), .memRead(memRead_c), .memtoReg(memtoReg_c),
    .ALUOp(ALUOp_c), .memWrite(memWrite_c), .ALUSrc(ALUSrc_c), .regWrite(regWrite_c),
    .funct3(funct3_c), .funct7(funct7_c),
    .jump(jump_c), .jalr(jalr_c), .lui(lui_c), .auipc(auipc_c),
    .isCsr(isCsr_c), .isEcall(isEcall_c), .isEbreak(isEbreak_c), .isMret(isMret_c),
    .isSret(isSret_c), .isSfenceVma(isSfenceVma_c), .isFence(isFence_c), .isAmo(isAmo_c),
    .isVecCfg(isVecCfg_c),
    .illegalOpcode(illegalOpcode_c), .fRegWrite(fRegWrite_c)
);

wire [5:0] ALUCtl_d;
ALUCtrl m_ALUCtrl(.ALUOp(ALUOp_c), .funct7_c(funct7_c), .funct3_c(funct3_c), .rs2_c(rs2_areg), .ALUCtl(ALUCtl_d));

wire [XLEN-1:0] imm_d;
ImmGen #(.Width(XLEN)) m_ImmGen(.inst(inst_full), .imm(imm_d));

// Gen6-D+E's own scope cut: plain integer regWrite ALU ops (OP/OP-IMM)
// and plain integer loads/stores (LOAD/STORE) are supported --
// fRegWrite/isCsr/isEcall/branch/jump/isAmo instructions all decode
// harmlessly (their Control.v outputs are simply never consumed below)
// but produce no real effect yet; each is its own later Gen6-* sub-phase.
wire needs_dest = regWrite_c && (rd_areg != 5'd0);
// Gen6-J: LR.W/LR.D route through the EXACT SAME LoadStoreQueue.v
// dispatch path as an ordinary load -- Control.v deliberately leaves
// memRead/memWrite at 0 for the whole OPCODE_AMO family (docs/adr/0038's
// own design, so the caller can tell "is this an AMO" apart from "is
// this an ordinary load/store" before routing), so is_mem_op needs
// is_amo_lr OR'd in explicitly for LR to ever reach the LSQ at all.
// ImmGen.v has no OPCODE_AMO case arm, so imm_d is already its own
// documented default-0 for these (AMO's own encoding has no real
// immediate field -- those bits are aq/rl instead), needing no extra
// forcing at the dispatch site.
//
// Gen6-P1 (docs/adr/0052): SC.W/SC.D and the general AMOADD/AMOSWAP/
// AMOXOR/AMOOR/AMOAND/AMOMIN/AMOMAX/AMOMINU/AMOMAXU read-modify-write
// family are now real too -- LoadStoreQueue.v gained the real interface
// change (disp_op_type0, OP_SC/OP_AMO_RMW) and 2-phase sequencing
// (read old value -> compute new -> write new) this comment's own
// prior-phase self documented as needed. This core's own single-hart
// simplification (every AMO is trivially atomic, no other hart can
// ever contend, docs/adr/0038's own finding) still applies -- LR/SC/
// AMO-RMW all route through the SAME LoadStoreQueue.v dispatch path,
// none needing anything RS_ALU-side beyond the existing Gen6-O "force
// A" mechanism's own unrelated use for other instruction classes.
wire is_amo_lr  = isAmo_c && (funct7_c[6:2] == `AMO_F5_LR);
wire is_amo_sc  = isAmo_c && (funct7_c[6:2] == `AMO_F5_SC);
wire is_amo_rmw = isAmo_c && !is_amo_lr && !is_amo_sc;
wire is_mem_op  = memRead_c || memWrite_c || isAmo_c;
// LoadStoreQueue.v's own OP_LOAD/OP_STORE/OP_SC/OP_AMO_RMW localparams
// (2'd0/1/2/3) reused as plain literals here -- a cross-module
// parameter reference isn't appropriate for a port-driving value; must
// stay in sync with LoadStoreQueue.v's own definitions if those ever
// change.
wire [1:0] lsq_op_type0 = is_amo_lr  ? 2'd0 :
                          is_amo_sc  ? 2'd2 :
                          is_amo_rmw ? 2'd3 :
                          memWrite_c ? 2'd1 : 2'd0;
// Gen6-F: DIV/DIVU/REM/REMU route to their own reservation station +
// Divider.v, NOT the single-cycle RS_ALU/ALU.v path -- mirrors
// riscvpipeline.v's own isDivRem detection exactly (same ALUCtl
// literals). MUL/MULH/MULHSU/MULHU need no new routing at all: ALU.v
// already computes them single-cycle (docs/adr/0006), so they already
// flow correctly through the existing Gen6-D RS_ALU path -- confirmed
// by this phase's own directed test, not assumed.
wire is_div_op = (ALUCtl_d == `ALUCTL_DIV) || (ALUCtl_d == `ALUCTL_DIVU) ||
                 (ALUCtl_d == `ALUCTL_REM) || (ALUCtl_d == `ALUCTL_REMU);
// Gen6-G: conditional branches also need no new execution unit --
// ALU.v's own ALUCTL_BEQ/BNE/BLT/BGE/BLE/BGT/BLTU/BGEU family (branch_c
// selects OPCODE_BRANCH -> ALUOP_BRANCH -> ALUCtrl.v's existing branch
// case) already computes `branch_zero`, so a branch dispatches through
// the ordinary RS_ALU/ALU.v path exactly like an ALU op with no
// destination (regWrite_c is already 0 for OPCODE_BRANCH, matching a
// store's own has_dest=0 shape). JAL/JALR are explicitly OUT of this
// phase's own scope -- deferred, not silently dropped; see the header
// comment on the branch-speculation section below for why.
wire is_branch = branch_c;

// Gen6-I: precise exceptions, ROB-retire-gated (the research finding this
// whole generation's own planning session made: CSR.v's existing single-
// trap-scalar, exactly-once-per-instruction contract is satisfied
// UNMODIFIED as long as only the ROB-retiring instruction ever asserts
// trap_taken/mret_taken -- no CSR.v change needed at all, unlike every
// other Gen6-* integration so far). Scope this phase, deliberately
// narrow: illegal-instruction and ecall (the two causes this core's own
// decode can already recognize combinationally) plus mret (needed for a
// complete, testable trap round trip) -- real interrupts (timer/
// software/external) and the Sv39 MMU (page faults, address translation)
// are explicitly OUT of scope, real future work, not attempted this
// pass: both need their own careful design (interrupts need a real
// retire-boundary injection point; the MMU touches fetch AND
// LoadStoreQueue.v's own address path).
wire has_exception = illegalOpcode_c || isEcall_c;
// Gen6-P2 (docs/adr/0053): an ITLB fault fits this SAME dispatch-time-only
// trap shape unmodified -- unlike a D-side page fault (discovered only
// once the LSQ's already-dispatched head entry gets to it, needing new
// late-injection plumbing, see the MMU section below), a fetch-side fault
// is fully resolved BEFORE dispatch even happens (itlb_miss below blocks
// dispatch_stall for the walk's whole duration; is_trap_related only ever
// sees the SAME cycle the walk concludes, exactly mirroring has_exception's
// own "known combinationally, before dispatch" shape). itlb_fault_this_cycle/
// sfence_priv_violation forward-referenced from the MMU section further
// down -- an unauthorized (U-mode) sfence.vma needs no dedicated cause
// selection below: it naturally falls to trap_inflight_cause_r's own
// ternary default (MCAUSE_ILLEGAL_INSTRUCTION), exactly matching real
// RISC-V behavior (same treatment docs/adr/0032's own sfence_priv_violation
// already established for PIPELINED).
wire is_trap_related = has_exception || isMret_c || itlb_fault_this_cycle || sfence_priv_violation;

// ==========================================================================
// Gen6-O (docs/adr/0051): lui/auipc/jal/jalr/csrrX. jump_c/jalr_c/lui_c/
// auipc_c/isCsr_c were decoded (Control.v) since Gen6-D but never
// consumed anywhere in this file until now (confirmed by direct code
// read before Gen6-L's own verification tooling ever ran, and again
// before this phase touched anything) -- OOOCore.v silently mis-executed
// or no-op'd every one of these; see docs/adr/0048's own "real bugs/
// findings" for the exact failure mode each one had.
wire is_lui   = lui_c;
wire is_auipc = auipc_c;
wire is_jal   = jump_c && !jalr_c;   // Control.v sets jump=1 for BOTH
                                       // jal and jalr; jalr additionally
                                       // sets jalr=1 -- jump&&!jalr
                                       // isolates the decode-time-
                                       // resolvable case (see the PC-
                                       // advance block further down).
wire is_jalr  = jalr_c;
wire is_csr   = isCsr_c;
// Gen6-K's own dual-issue scope deliberately excludes all five of these
// (single-issue only) -- see try_dual_issue's own definition further
// down for why (real, flagged scope cut, not an oversight): each one
// needs the NEW force-a/link-b payload machinery below, and jalr/csrrX
// specifically need their own single-outstanding speculative-resolution
// state (jr_inflight_valid_r/csr_inflight_valid_r further down), neither
// of which this phase extends to a hypothetical slot1 -- doubling every
// one of Gen6-K's own already-real same-bundle hazard concerns for a
// class of instructions real code uses far less densely than plain ALU
// ops, for no proven benefit yet.
wire is_lui_auipc_jal_jalr_csr = is_lui || is_auipc || is_jal || is_jalr || is_csr;

// ==========================================================================
// Gen7 Pillar V Phase 1 (docs/adr/0061). vsetvli/vsetivli decode --
// isVecCfg_c is Control.v's own new output. vtype fields are re-extracted
// directly from inst_word (same "cheap, direct field extraction, don't
// route everything through Control.v" idiom rs1_areg/rs2_areg/rd_areg
// already use) rather than adding an ImmGen.v output -- both vsetvli and
// vsetivli place {vma,vta,vsew,vlmul} at the identical bit positions
// (riscv_defs.vh's own VTYPE_* constants, hand-derived and documented
// there).
// ==========================================================================
wire is_vec_cfg = isVecCfg_c;
wire [2:0] vec_cfg_vsew_dec  = inst_word[`VTYPE_VSEW_HI:`VTYPE_VSEW_LO];
wire [2:0] vec_cfg_vlmul_dec = inst_word[`VTYPE_VLMUL_HI:`VTYPE_VLMUL_LO];
wire       vec_cfg_vma_dec   = inst_word[`VTYPE_VMA_BIT];
wire       vec_cfg_vta_dec   = inst_word[`VTYPE_VTA_BIT];

// Reserved-vtype check (real spec: an out-of-range SEW or LMUL sets
// vill=1, vl=0, vtype=all-1s-with-vill-set, discarding the rest of the
// requested fields entirely -- not a trap, a defined "illegal vtype"
// state).
wire vec_cfg_reserved = (vec_cfg_vsew_dec > `VSEW_64) || (vec_cfg_vlmul_dec == 3'b100);

// VLMAX = VLEN >> ((3+vsew) - $signed(vlmul)) -- hand-derived and
// verified against 5 worked examples in the plan
// (C:\Users\poorn\.claude\plans\gen7-v-vector-phase1.md) before trusting
// it here; shift is always 0..9 at VLEN=512 for every legal (non-
// reserved) input, confirmed by checking both extremes there.
wire signed [4:0] vec_cfg_shift = ($signed({2'b00, vec_cfg_vsew_dec}) + 4'sd3) - $signed(vec_cfg_vlmul_dec);
wire [XLEN-1:0] vec_cfg_vlmax = vec_cfg_reserved ? {XLEN{1'b0}} : (VLEN[XLEN-1:0] >> vec_cfg_shift);

// ==========================================================================
// Gen6-H: F-extension, scoped to a real, tested, but deliberately narrow
// subset -- see design/OOOCore.v's own Gen6-H section further down (right
// before the float rename stack) for the full rationale on which funct5
// groups are in scope this phase and why (fRegWrite_c is NOT a clean
// "pure float-float op" signal: it's ALSO set for fcvt.s.w*/fmv.w.x,
// which read an INTEGER source, and Control.v routes fcmp/fcvt.w.s/
// fmv.x.w/fclass.s through plain regWrite_c instead since they write an
// INTEGER dest despite reading float operands -- see Control.v's own
// OPCODE_FP case comment). fp_funct5 mirrors ALUCtrl.v's own funct7[6:2]
// convention (this project's OP-FP funct5 sits at the same bit position
// funct7 does for R-type).
wire [4:0] fp_funct5 = funct7_c[6:2];
wire is_fp_pure = fRegWrite_c && (
    fp_funct5 == `FUNCT5_FADD || fp_funct5 == `FUNCT5_FSUB || fp_funct5 == `FUNCT5_FMUL ||
    fp_funct5 == `FUNCT5_FSGNJ || fp_funct5 == `FUNCT5_FMINMAX
);
wire is_fp_intmove = fRegWrite_c && (fp_funct5 == `FUNCT5_FMV_W_X);
// Gen6-P4 (docs/adr/0055): fdiv.s/fsqrt.s -- multi-cycle, so they need
// their OWN reservation station + in-flight tracking (RS_FDIV, mirroring
// Gen6-F's own RS_DIV/Divider.v shape exactly), not RS_FALU's single-
// cycle path. is_fp_op itself widens to include them (needs_dest-style
// rename allocation/ROB fp-dest tracking is identical regardless of
// WHICH unit ends up computing the result) -- only the EXECUTION routing
// (which RS gets disp_en0) distinguishes is_fp_multicycle below.
wire is_fp_div  = fRegWrite_c && (fp_funct5 == `FUNCT5_FDIV);
wire is_fp_sqrt = fRegWrite_c && (fp_funct5 == `FUNCT5_FSQRT);
wire is_fp_multicycle = is_fp_div || is_fp_sqrt;
wire is_fp_op = is_fp_pure || is_fp_intmove || is_fp_multicycle;

// ==========================================================================
// Gen6-G: branch speculation. Reuses Gen1's own Bht.v/Btb.v exactly
// (docs/adr/0021) -- queried combinationally every cycle at pc_r (before
// even knowing if the fetched instruction IS a branch; is_branch gates
// whether the prediction is ever acted on, same "untagged, aliasing is
// harmless" table design those modules already document).
//
// `# ponytail`-tagged scope cut, real and load-bearing, not incidental:
// AT MOST ONE branch may be in flight (dispatched but not yet resolved)
// at a time -- dispatch of EVERYTHING (not just other branches) stalls
// until it resolves (br_inflight_valid_r, folded into dispatch_stall
// below). This means a misprediction NEVER has anything dispatched past
// the branch to unwind -- no ROB truncation, no RS_ALU/RS_DIV/LSQ flush,
// no physical-register reclaim, and RegisterAliasTable.v's own
// restore_en (built in Gen6-A for exactly this) isn't even needed, since
// no speculative rename divergence can ever happen. Recovery is just "PC
// was wrong, redirect it." This is a REAL, substantial narrowing from
// this generation's own originally-confirmed "full speculation, ROB-based
// squash of an arbitrary wrong-path window" scope -- deep speculation
// needs RS_ALU/RS_DIV/LSQ entries (and an in-progress division/memory
// access!) to be abortable mid-flight, a genuinely larger, riskier
// undertaking flagged here as real future work, not attempted in this
// pass. What IS real and working here: BHT/BTB-trained prediction, a
// genuine speculative PC redirect, and correct misprediction recovery --
// just with a narrow (single-branch) speculative window instead of a
// deep one.
//
// JAL/JALR are explicitly OUT of scope this phase (deferred): JAL's
// target is unconditionally known at decode (pc+imm, no speculation
// needed at all), and JALR needs its own BTB-based target prediction --
// neither shares this section's own "predict direction, verify at
// resolve" shape closely enough to fold in for free, and this phase's
// own directed test only needs conditional branches to prove the
// mechanism.
// Forward declarations, same reason as every other Gen6-* one in this
// file: these are driven by regs/wires declared below (or, for
// alu_branch_zero/issue_valid/issue_rob_tag, by the execute-section ALU
// instantiation further down) but referenced here inside the Bht.v/
// Btb.v instantiations' own port connections.
reg                     br_inflight_valid_r;
reg [ROB_IDX_BITS-1:0]  br_inflight_rob_tag_r;
reg [XLEN-1:0]          br_inflight_pc_r;
reg [XLEN-1:0]          br_inflight_imm_r;
reg                     br_inflight_predicted_taken_r;
reg [XLEN-1:0]          br_inflight_predicted_target_r;

// Resolution: the cycle RS_ALU issues the exact entry carrying the
// in-flight branch's own rob_tag, alu_branch_zero (computed the SAME
// cycle from that entry's own rs1/rs2, see the execute section below)
// is its real, ground-truth outcome.
wire br_resolve = issue_valid && br_inflight_valid_r && (issue_rob_tag == br_inflight_rob_tag_r);
wire br_actual_taken  = alu_branch_zero;
wire [XLEN-1:0] br_actual_target = br_inflight_pc_r + br_inflight_imm_r;
wire [XLEN-1:0] br_correct_target = br_actual_taken ? br_actual_target : (br_inflight_pc_r + {{(XLEN-3){1'b0}}, 3'd4});
wire br_mispredict = br_resolve && (
    (br_actual_taken != br_inflight_predicted_taken_r) ||
    (br_actual_taken && (br_actual_target != br_inflight_predicted_target_r))
);

wire predict_taken_bht, btb_hit;
wire [XLEN-1:0] btb_target;
Bht #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Bht(
    .clk(clk), .rst(rst),
    .query_pc(pc_r), .predict_taken(predict_taken_bht),
    .train_pc({XLEN{1'b0}}), .train_predict_taken(),
    .update_valid(br_resolve), .update_pc(br_inflight_pc_r), .update_taken(br_actual_taken)
);
// Gen6-P5 (docs/adr/0056): jalr now ALSO trains/queries this SAME shared
// BTB instance (untagged by instruction class, per Btb.v's own header --
// any instruction can train or query it) -- jr_resolve joins br_resolve&&
// br_actual_taken as a second, independent training source. jalr "always
// taken" (it's an unconditional jump, no BHT direction-predictor
// involvement needed, unlike a conditional branch), so jr_resolve alone
// (no additional taken-gate) is the right training condition. Both
// sources are mutually exclusive by construction (br_resolve/jr_resolve
// each require their OWN *_inflight_valid_r, and this whole generation's
// own single-outstanding scope cut means at most one of branch/jalr can
// ever be in flight at a time -- see both sections' own header comments).
wire jr_train_now = jr_resolve;
Btb #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Btb(
    .clk(clk), .rst(rst),
    .query_pc(pc_r), .hit(btb_hit), .target(btb_target),
    .update_valid((br_resolve && br_actual_taken) || jr_train_now),
    .update_pc(jr_train_now ? jr_inflight_pc_r : br_inflight_pc_r),
    .update_target(jr_train_now ? jr_target : br_actual_target)
);

// Both BHT (direction) and BTB (target) must agree before trusting a
// taken prediction -- matches docs/adr/0021's own established
// requirement (a cold BTB entry with no real target can't be redirected
// to, even if the direction predictor alone guesses taken).
wire predicted_taken  = is_branch && predict_taken_bht && btb_hit;
wire [XLEN-1:0] predicted_target = btb_target;

always @(posedge clk) begin
    if (~rst) begin
        br_inflight_valid_r <= 1'b0;
    end
    else begin
        if (do_dispatch && is_branch) begin
            br_inflight_valid_r            <= 1'b1;
            br_inflight_rob_tag_r          <= rob_alloc_tag0;
            br_inflight_pc_r               <= pc_r;
            // ImmGen.v's own B-type case (see its header comment) deliberately
            // outputs the RAW immediate, pre-`<<1` -- riscvpipeline.v applies
            // a separate ShiftLeftOne.v downstream before ever treating it as
            // a real byte offset (branch/jal immediates are encoded in
            // multiples of 2, bit 0 implicit-0). Found by running: this
            // phase's own first branch test redirected to pc+4 instead of
            // the real target, exactly the symptom of using the pre-shift
            // value directly. imm_d itself must NOT be shifted at its own
            // declaration (I-type/S-type consumers elsewhere need the
            // unshifted value) -- only this branch-specific latch applies it.
            br_inflight_imm_r              <= (imm_d << 1);
            br_inflight_predicted_taken_r  <= predicted_taken;
            br_inflight_predicted_target_r <= predicted_target;
        end
        else if (br_resolve) begin
            br_inflight_valid_r <= 1'b0;
        end
    end
end

// ==========================================================================
// Gen6-P5 (docs/adr/0056): jalr, now BTB-predicted -- same predict/verify/
// recover shape br_inflight's own branch speculation already established
// (docs/adr/0021), reusing the SAME shared m_Btb instance (widened just
// above to also train on jr_resolve). Still single-outstanding (at most
// one branch OR jalr in flight at a time, dispatch of everything else
// stalls until it resolves) -- docs/adr/0051's own original deferral
// reasoning still applies to why this core doesn't attempt DEEP
// speculation here, just real target prediction instead of a blind
// stall. Honest finding, not assumed: because dispatch stays blocked
// regardless of prediction (the same single-outstanding scope cut
// conditional branches already live with), and this core's own frontend
// is purely combinational with no fetch/dispatch decoupling (Gen6-D's
// own documented scope), a correct prediction saves ZERO cycles over the
// old stall-and-wait design in THIS core as it stands today -- pc_r
// already sat at jr_target the cycle jr_resolve fired either way. The
// real value here is architectural consistency with branches (one
// prediction/recovery mechanism, not two different shapes for two kinds
// of indirect control flow) and a genuine foundation for whichever
// future phase relaxes the single-outstanding scope cut into real deep
// speculation, where decoupled fetch WOULD actually benefit from this.
// ==========================================================================
reg                     jr_inflight_valid_r;
reg [ROB_IDX_BITS-1:0]  jr_inflight_rob_tag_r;
reg [XLEN-1:0]          jr_inflight_imm_r;
reg [XLEN-1:0]          jr_inflight_pc_r;
reg [XLEN-1:0]          jr_inflight_predicted_target_r;

wire jr_resolve = issue_valid && jr_inflight_valid_r && (issue_rob_tag == jr_inflight_rob_tag_r);
// JALR spec: target = (rs1 + imm) & ~1. prf_rdata2 is rs1's own raw PRF
// read -- untouched by this same RS_ALU entry's own use_forced_a0
// override (which only ever affects alu_a/alu_out for the LINK value,
// never prf_rdata2 itself).
wire [XLEN-1:0] jr_target_raw = prf_rdata2 + jr_inflight_imm_r;
wire [XLEN-1:0] jr_target = {jr_target_raw[XLEN-1:1], 1'b0};
// A cold/missed BTB entry has no real target at all -- "predict" pc+4 (a
// near-certain misprediction, same honest non-guess PIPELINED's own
// conditional-branch BTB miss defaults to) rather than fabricate one;
// correctness is guaranteed by jr_mispredict's own verify+recover
// regardless of prediction quality, only the RECOVERY COST differs.
wire [XLEN-1:0] jr_predicted_target = btb_hit ? btb_target : (pc_r + {{(XLEN-3){1'b0}}, 3'd4});
wire jr_mispredict = jr_resolve && (jr_target != jr_inflight_predicted_target_r);

always @(posedge clk) begin
    if (~rst) begin
        jr_inflight_valid_r <= 1'b0;
    end
    else begin
        if (do_dispatch && is_jalr) begin
            jr_inflight_valid_r            <= 1'b1;
            jr_inflight_rob_tag_r          <= rob_alloc_tag0;
            jr_inflight_imm_r              <= imm_d;   // plain I-type, NOT <<1 --
                                                          // see ImmGen.v's own jalr
                                                          // case comment
            jr_inflight_pc_r               <= pc_r;
            jr_inflight_predicted_target_r <= jr_predicted_target;
        end
        else if (jr_resolve) begin
            jr_inflight_valid_r <= 1'b0;
        end
    end
end

// ==========================================================================
// Gen6-K: dual-issue widening. `# ponytail`-tagged scope cut, real and
// bounded, found by SCOPING this (not discovered mid-RTL): dual-dispatch
// only when BOTH slot0 AND slot1 are plain integer ALU ops (neither is
// mem/div/fp/branch/trap-related/AMO) -- every other combination falls
// back to single-issue (slot1's own instruction just gets re-fetched as
// slot0 next cycle, identical to any other dispatch_stall). This keeps
// branch/trap/mem/div/fp dispatch logic COMPLETELY untouched from every
// earlier sub-phase (a branch, say, is by definition never
// slot0_is_plain_alu, so try_dual_issue is false and it dispatches alone
// exactly as Gen6-G already verified) -- the only genuinely new
// correctness-critical piece is the same-fetch-bundle RAW bypass below.
//
// Slot1 gets its own full decode (mirrors slot0's Control.v/ALUCtrl.v/
// ImmGen.v instantiation exactly) -- needed both to know whether it
// QUALIFIES as plain-ALU and to actually dispatch it once it does.
wire [XLEN-1:0] inst_full1;
InstructionMemory #(.INIT_FILE(IMEM_INIT_FILE), .SIZE_BYTES(IMEM_SIZE_BYTES), .XLEN(XLEN)) m_IMem1(
    .readAddr(pc_r + 4),
    .inst(inst_full1)
);
wire [31:0] inst_word1 = inst_full1[31:0];

wire [4:0] rs1_areg_1 = inst_word1[19:15];
wire [4:0] rs2_areg_1 = inst_word1[24:20];
wire [4:0] rd_areg_1  = inst_word1[11:7];

wire branch_c_1, memRead_c_1, memtoReg_c_1, memWrite_c_1, ALUSrc_c_1, regWrite_c_1;
wire [1:0] ALUOp_c_1;
wire [2:0] funct3_c_1;
wire [6:0] funct7_c_1;
wire jump_c_1, jalr_c_1, lui_c_1, auipc_c_1, isCsr_c_1, isEcall_c_1, isEbreak_c_1, isMret_c_1, isSret_c_1, isSfenceVma_c_1, isFence_c_1, isAmo_c_1, illegalOpcode_c_1, fRegWrite_c_1;
wire isVecCfg_c_1;   // Gen7 Pillar V Phase 1 (docs/adr/0061)

Control #(.XLEN(XLEN)) m_Control_1(
    .opcode(inst_word1[6:0]),
    .funt7(inst_word1[31:25]),
    .funt3(inst_word1[14:12]),
    .csr_imm12(inst_word1[31:20]),
    .branch(branch_c_1), .memRead(memRead_c_1), .memtoReg(memtoReg_c_1),
    .ALUOp(ALUOp_c_1), .memWrite(memWrite_c_1), .ALUSrc(ALUSrc_c_1), .regWrite(regWrite_c_1),
    .funct3(funct3_c_1), .funct7(funct7_c_1),
    .jump(jump_c_1), .jalr(jalr_c_1), .lui(lui_c_1), .auipc(auipc_c_1),
    .isCsr(isCsr_c_1), .isEcall(isEcall_c_1), .isEbreak(isEbreak_c_1), .isMret(isMret_c_1),
    .isSret(isSret_c_1), .isSfenceVma(isSfenceVma_c_1), .isFence(isFence_c_1), .isAmo(isAmo_c_1),
    .isVecCfg(isVecCfg_c_1),
    .illegalOpcode(illegalOpcode_c_1), .fRegWrite(fRegWrite_c_1)
);

wire [5:0] ALUCtl_d_1;
ALUCtrl m_ALUCtrl_1(.ALUOp(ALUOp_c_1), .funct7_c(funct7_c_1), .funct3_c(funct3_c_1), .rs2_c(rs2_areg_1), .ALUCtl(ALUCtl_d_1));

wire [XLEN-1:0] imm_d_1;
ImmGen #(.Width(XLEN)) m_ImmGen_1(.inst(inst_full1), .imm(imm_d_1));

wire needs_dest_1  = regWrite_c_1 && (rd_areg_1 != 5'd0);
// Gen6-P1: widened to isAmo_c_1 (was is_amo_lr_1 alone) -- SC/AMO-RMW
// need the same dual-issue exclusion LR already had, or slot1_is_plain_alu
// would incorrectly stay true for an SC/AMO-RMW in slot1 (this generic
// flag only needs to gate dual-issue eligibility; slot1 never actually
// dispatches into the LSQ regardless, see try_dual_issue's own scope).
wire is_amo_lr_1   = isAmo_c_1 && (funct7_c_1[6:2] == `AMO_F5_LR);
wire is_mem_op_1   = memRead_c_1 || memWrite_c_1 || isAmo_c_1;
wire is_div_op_1   = (ALUCtl_d_1 == `ALUCTL_DIV) || (ALUCtl_d_1 == `ALUCTL_DIVU) ||
                     (ALUCtl_d_1 == `ALUCTL_REM) || (ALUCtl_d_1 == `ALUCTL_REMU);
wire is_branch_1   = branch_c_1;
wire has_exception_1 = illegalOpcode_c_1 || isEcall_c_1;
wire is_trap_related_1 = has_exception_1 || isMret_c_1;
wire [4:0] fp_funct5_1 = funct7_c_1[6:2];
// Gen6-P4/P6 (docs/adr/0055, 0057): FUNCT5_FDIV/FUNCT5_FSQRT widened in --
// a REAL bug found by running (the ooo fuzzer's own widened pool, Gen6-P6,
// is what first exercised an fdiv.s/fsqrt.s landing in slot1): without
// these, is_fp_op_1 wrongly reports FALSE for an actual fdiv.s/fsqrt.s in
// slot1, so slot1_is_plain_alu's own exclusion list (below) never catches
// it either -- the SAME "plain ALU" bucket every other unclassified
// instruction silently falls into, exactly the bug class docs/adr/0051/
// 0052 already found and fixed for csrrX/AMO in this exact spot. A
// dual-issued fdiv.s/fsqrt.s in slot1 would dispatch through RS_ALU
// instead of RS_FDIV, never computing its real result -- the destination
// register silently keeps whatever it held before, observed directly as
// f5 reading back a stale seeded value instead of its own fsqrt.s result
// (root-caused via cycle-by-cycle dispatch tracing: PC visibly skipped
// straight from one instruction's own address to the one two slots later,
// the unmistakable signature of an unwanted dual-issue).
wire is_fp_op_1 = fRegWrite_c_1 && (
    fp_funct5_1 == `FUNCT5_FADD || fp_funct5_1 == `FUNCT5_FSUB || fp_funct5_1 == `FUNCT5_FMUL ||
    fp_funct5_1 == `FUNCT5_FSGNJ || fp_funct5_1 == `FUNCT5_FMINMAX || fp_funct5_1 == `FUNCT5_FMV_W_X ||
    fp_funct5_1 == `FUNCT5_FDIV || fp_funct5_1 == `FUNCT5_FSQRT
);

// Both slots must be plain ALU (regWrite integer OP/OP-IMM, no other
// side effects) for dual-issue to even be considered this cycle.
wire slot0_is_plain_alu = !is_mem_op && !is_div_op && !is_fp_op && !is_branch && !is_trap_related && !is_lui_auipc_jal_jalr_csr && !is_vec_cfg;   // Gen7-V: vsetvli/vsetivli use the same forced-a-value machinery as lui/auipc/jal/jalr/csrrX, same single-issue-only exclusion
// Gen6-O: slot1's own equivalent exclusion -- lui_c_1/auipc_c_1/jump_c_1/
// jalr_c_1/isCsr_c_1 are slot1's own decode outputs (Gen6-K's own second
// Control.v instance), already computed, never consumed until now for
// the identical reason slot0's own versions weren't before this phase.
wire is_lui_auipc_jal_jalr_csr_1 = lui_c_1 || auipc_c_1 || jump_c_1 || jalr_c_1 || isCsr_c_1;
wire slot1_is_plain_alu = !is_mem_op_1 && !is_div_op_1 && !is_fp_op_1 && !is_branch_1 && !is_trap_related_1 && !is_lui_auipc_jal_jalr_csr_1 && !isVecCfg_c_1;   // Gen7-V: a vsetvli/vsetivli in the pc+4 slot must never be silently swept into slot1's own vsetvli-unaware payload pack (rs_disp_payload1 has no is_vec_cfg override at all) -- same exclusion reasoning as is_lui_auipc_jal_jalr_csr_1
// Gen6-P2 (docs/adr/0053): real, deliberate scope cut, same category as
// every other Gen6-K exclusion above -- dual-issue and live Sv39
// translation don't coexist this phase. m_IMem1's own speculative fetch
// at pc_r+4 stays untranslated regardless (harmless: slot1 never actually
// dispatches while translate_enable is 1, so nothing downstream ever
// consumes inst_word1 that cycle -- an unused speculative fetch producing
// an arbitrary byte value is not a correctness or security issue). Real
// future work if profiling ever shows this mattering on an MMU-heavy
// dual-issue-capable workload.
wire try_dual_issue = slot0_is_plain_alu && slot1_is_plain_alu && !translate_enable;

// Same-fetch-bundle RAW bypass -- the one genuinely new correctness-
// critical piece (found while SCOPING this phase, not mid-RTL): if
// slot1 reads a register slot0 is ITSELF renaming this exact cycle,
// RegisterAliasTable.v's own stored spec_map is still the OLD mapping
// (the write hasn't happened yet) -- slot1 must instead use slot0's own
// freshly-granted physical register directly, and treat it as
// unconditionally NOT READY (slot0 hasn't executed yet, so there's no
// value to read regardless of what PhysicalRegisterFile.v's own rvalid
// for that fresh, not-yet-written preg would report).
wire slot1_src1_from_slot0 = try_dual_issue && needs_dest && (rs1_areg_1 == rd_areg) && (rd_areg != 5'd0);
wire slot1_src2_from_slot0 = try_dual_issue && needs_dest && (rs2_areg_1 == rd_areg) && (rd_areg != 5'd0);
// Same-fetch-bundle WAW between two INTEGER destinations needs NO new
// logic at all: RegisterAliasTable.v's own wen0/wen1 same-target
// handling (old_preg1 bypasses slot0's own fresh write, slot1 -- the
// program-order-later instruction -- wins the final mapping) already
// covers it exactly, built in Gen6-A for precisely this shape.

// ==========================================================================
// Rename: RegisterAliasTable.v (operand tags) + FreeList.v (fresh
// physical register for the destination, if any) + PhysicalRegisterFile.v
// (operand READINESS at dispatch time, via its own rvalid* ports -- the
// same 4-read-port PRF Gen6-A built specifically so dispatch-time
// readiness and issue-time value-fetch could share one module, see
// PhysicalRegisterFile.v's own header comment).
// ==========================================================================
wire [PREG_BITS-1:0] rat_rpreg0, rat_rpreg1;   // rs1/rs2 -> current preg tag
wire [PREG_BITS-1:0] rat_old_preg0;            // rd's PRE-rename mapping (for FreeList reclaim at retire)

// Forward declarations -- these are driven by ReorderBuffer.v (m_ROB,
// instantiated further down) but consumed here by FreeList.v/
// RegisterAliasTable.v's own retire-commit ports. Declared here, ahead
// of first use, so every net has a real explicit declaration before its
// earliest reference (Icarus -g2005 flags a forward-referenced net used
// only inside an instantiation's port connections as an "implicit
// definition" warning otherwise, even though the eventual `wire`
// declaration is real).
wire rob_retire_valid0, rob_retire_has_dest0, rob_retire_is_fp_dest0;
wire [AREG_BITS-1:0] rob_retire_areg0;
wire [PREG_BITS-1:0] rob_retire_preg0, rob_retire_old_preg0;
wire [ROB_IDX_BITS-1:0] rob_retire_tag0;
// ReorderBuffer.v retires up to 2/cycle INTERNALLY (slot0 AND slot1)
// whenever both happen to be done the same cycle head_r reaches them --
// entirely independent of how many dispatch ports the caller actually
// drives. A single-issue caller that dispatches through slot0 only but
// leaves slot1's RETIRE outputs unwired would silently lose whichever
// instruction retires as slot1 (its RAT commit/FreeList reclaim would
// simply never happen) -- a real bug this phase's own end-to-end test
// found by running (a queued load completing one cycle behind an
// adjacent already-done entry let both retire together). Both slot1
// retire ports are wired through to RegisterAliasTable.v/FreeList.v's
// own already-present slot1 commit/free ports below, even though
// dispatch itself stays single-issue until Gen6-K -- retire draining
// faster than 1/cycle when the ROB has a backlog of already-completed
// entries is always correct, never something dispatch's own width needs
// to match.
wire rob_retire_valid1, rob_retire_has_dest1, rob_retire_is_fp_dest1;
wire [AREG_BITS-1:0] rob_retire_areg1;
wire [PREG_BITS-1:0] rob_retire_preg1, rob_retire_old_preg1;
wire [ROB_IDX_BITS-1:0] rob_retire_tag1;
wire issue_valid;
wire [ROB_IDX_BITS-1:0] issue_rob_tag;
wire [PREG_BITS-1:0] issue_dest_preg;

// Gen6-E: LoadStoreQueue.v's own completion, forward-declared for the
// identical reason (consumed by ROB/RS_ALU/PRF, all instantiated before
// m_LSQ itself further down).
wire                    lsq_complete_valid, lsq_complete_is_load;
wire [PREG_BITS-1:0]    lsq_complete_dest_preg;
wire [XLEN-1:0]         lsq_complete_data;
wire [ROB_IDX_BITS-1:0] lsq_complete_rob_tag;
wire                    lsq_full;

// Gen6-F: Divider.v's own completion, forward-declared for the identical
// reason (consumed by ROB/RS_ALU/LSQ/PRF, all instantiated before
// m_Divider itself further down). div_complete_valid is Divider.v's own
// one-cycle `done` pulse passed straight through (no extra registering
// needed -- see the in-flight-tracking comment further down for why the
// dest_preg/rob_tag/data fields ARE separately latched).
wire                    div_complete_valid;
wire [PREG_BITS-1:0]    div_complete_dest_preg;
wire [XLEN-1:0]         div_complete_data;
wire [ROB_IDX_BITS-1:0] div_complete_rob_tag;
wire                    rs_div_full;

// Gen6-H: RS_FALU's own completion + the float FreeList's own allocation
// readiness, forward-declared for the identical reason (consumed by
// dispatch_stall/ROB above where they're instantiated below).
wire                     falu_complete_valid;
wire [FPREG_BITS-1:0]    falu_complete_dest_preg;
wire [FLEN-1:0]          falu_complete_data;
wire [ROB_IDX_BITS-1:0]  falu_complete_rob_tag;
wire                     rs_falu_full;
wire                     fl_f_alloc_ok0;
wire [FPREG_BITS-1:0]    fl_f_alloc_preg0;
wire [FPREG_BITS-1:0]    rat_f_rpreg0, rat_f_rpreg1;
wire [FPREG_BITS-1:0]    rat_f_old_preg0;

wire [PREG_BITS-1:0] fl_alloc_preg0, fl_alloc_preg1;
wire                 fl_alloc_ok0, fl_alloc_ok1;
wire [PREG_BITS-1:0] rat_rpreg2, rat_rpreg3, rat_old_preg1;   // Gen6-K: slot1's own RAT read/write ports
wire [$clog2(NUM_PREGS - NUM_AREGS):0] fl_free_count;   // unused beyond
    // debug visibility -- dispatch_stall below gates on fl_alloc_ok0
    // directly, not this raw count. Width matches FreeList.v's own
    // free_count port exactly ([CAP_BITS:0], CAP_BITS = $clog2(CAPACITY)).

wire dispatch_stall = rob_full
                      || (is_mem_op ? lsq_full : (is_div_op ? rs_div_full :
                          (is_fp_op ? (is_fp_multicycle ? rs_fdiv_full : rs_falu_full) : rs_alu_full)))
                      || (needs_dest && !fl_alloc_ok0)
                      || (is_fp_op && !fl_f_alloc_ok0)   // Gen6-H
                      || br_inflight_valid_r    // Gen6-G: single-outstanding-
                                                  // branch scope cut, see the
                                                  // branch-speculation
                                                  // section's own header
                                                  // comment
                      || trap_inflight_valid_r   // Gen6-I: same scope cut,
                                                  // for exceptions/mret
                      || jr_inflight_valid_r     // Gen6-O4: same scope cut,
                                                  // for jalr (its own
                                                  // target is register-
                                                  // dependent, unlike
                                                  // jal's decode-time-known
                                                  // one -- see jr_inflight's
                                                  // own section below)
                      || csr_inflight_valid_r    // Gen6-O5: same scope cut,
                                                  // for csrrw/csrrs/csrrc(+i)
                      || itlb_miss               // Gen6-P2 (docs/adr/0053):
                                                  // same shape again -- a
                                                  // walk in progress (or one
                                                  // cycle from IT resolving
                                                  // successfully) holds pc_r
                                                  // still (see the PC-advance
                                                  // block's own do_dispatch
                                                  // gate); a walk resolving
                                                  // with a FAULT is
                                                  // deliberately excluded
                                                  // (itlb_miss's own
                                                  // definition below), so
                                                  // dispatch proceeds that
                                                  // one cycle and
                                                  // is_trap_related picks it
                                                  // up instead.
                      || dtlb_stall              // Gen6-P2: a REAL, load-
                                                  // bearing addition, not
                                                  // just symmetry with
                                                  // itlb_miss -- unlike
                                                  // RS_ALU results (never
                                                  // architecturally visible
                                                  // until RETIRE), this
                                                  // LSQ's own stores commit
                                                  // to real memory the
                                                  // moment they ISSUE, not
                                                  // gated on retirement at
                                                  // all (Gen6-E's own
                                                  // design). Without this,
                                                  // a YOUNGER store dispatched
                                                  // while an OLDER load's own
                                                  // DTLB translation is still
                                                  // unresolved could actually
                                                  // WRITE memory before the
                                                  // older instruction's own
                                                  // fault is even discovered
                                                  // -- a genuine precise-
                                                  // exception violation this
                                                  // phase's own design pass
                                                  // caught before writing any
                                                  // test for it (the same
                                                  // "trace the real
                                                  // consequence, don't just
                                                  // pattern-match the
                                                  // existing itlb_miss shape"
                                                  // discipline this project
                                                  // already used for Gen6-P1's
                                                  // own complete_is_load fix).
                      || dside_fault_valid_r     // Gen6-P2: same reasoning,
                                                  // held through to the
                                                  // fault's own eventual
                                                  // retire/redirect -- once
                                                  // dtlb_page_fault first
                                                  // fires, dtlb_stall alone
                                                  // would otherwise drop
                                                  // (dtlb_needed goes false
                                                  // once force_retire_ext
                                                  // has cleared the LSQ's own
                                                  // head), letting dispatch
                                                  // resume prematurely,
                                                  // BEFORE the trap has
                                                  // actually redirected.
                      || interrupt_pending       // Gen6-P3 (docs/adr/0054):
                                                  // stop admitting anything
                                                  // NEW the moment an
                                                  // enabled interrupt is
                                                  // recognized -- everything
                                                  // already in flight still
                                                  // drains out normally
                                                  // (rob_empty, which
                                                  // interrupt_take itself
                                                  // waits for, is what
                                                  // actually fires the
                                                  // redirect).
                      || vec_cfg_inflight_valid_r;   // Gen7-V Phase 1
                                                  // (docs/adr/0061): same
                                                  // single-outstanding
                                                  // shape as every source
                                                  // above -- vtype/vl can
                                                  // never change mid-flight
                                                  // under a future vector
                                                  // instruction's own
                                                  // dispatch-time decode.
wire do_dispatch     = !dispatch_stall;

// Gen6-K: room for a SECOND dispatch this cycle, checked independently
// of slot0's own room check above (dispatch_stall already guarantees
// room for slot0 alone; this asks "is there room for one MORE").
wire dual_dispatch_room = (rob_count <= (ROB_ENTRIES - 2))
                          && (rs_alu_count <= (RS_ALU_ENTRIES - 2))
                          && (!needs_dest_1 || fl_alloc_ok1);
wire do_dispatch_slot1 = do_dispatch && try_dual_issue && dual_dispatch_room;

// FreeList's own alloc_en0/1 stay a pure QUERY (fl_alloc_ok0/1 combinational
// regardless of do_dispatch* -- dispatch_stall itself needs to know room
// BEFORE do_dispatch is decided, see FreeList.v's own header for the
// combinational-cycle reason this can't be gated). Gen6-L fix (docs/
// adr/0048): the ACTUAL pop is commit_en0/1, gated on each slot's own
// CONFIRMED do_dispatch/do_dispatch_slot1 -- without this, every cycle
// dispatch stalls for an unrelated reason (ROB/RS/LSQ full, a same-
// bundle class mismatch) while needs_dest/needs_dest_1 is also true
// permanently orphaned one physical register (a real, confirmed deadlock,
// found by this project's own OoO verification tooling -- see the ADR).
FreeList #(.NUM_PREGS(NUM_PREGS), .NUM_AREGS(NUM_AREGS)) m_FreeList(
    .clk(clk), .rst(rst),
    .alloc_en0(needs_dest), .alloc_en1(needs_dest_1),
    .alloc_preg0(fl_alloc_preg0), .alloc_preg1(fl_alloc_preg1),
    .alloc_ok0(fl_alloc_ok0), .alloc_ok1(fl_alloc_ok1),
    .commit_en0(do_dispatch && needs_dest), .commit_en1(do_dispatch_slot1 && needs_dest_1),
    // Gen6-H: gated !is_fp_dest -- a float-destination entry's own
    // old_preg lives in the FLOAT preg space, and must be reclaimed by
    // FreeList_Float below instead, never this (integer) FreeList.
    // Gen6-P2 (docs/adr/0053): !dside_trap_resolve -- a D-side-page-faulting
    // load/store still gets an ordinary needs_dest=1 ROB entry (see the
    // MMU section's own synthetic-completion comment), but architecturally
    // a faulting instruction has NO effect: its destination must never
    // actually commit (which would both corrupt the arch register with a
    // never-really-loaded value AND free the OLD preg while the RAT
    // mapping stubbornly still points to it, corrupting a live value --
    // a real bug caught by design, before writing any test for it, by
    // re-deriving what "commit" is actually supposed to mean for a
    // trapping retire, the same discipline Gen6-P1's own complete_is_load
    // fix used). dside_trap_resolve is FP-irrelevant (a D-side fault is
    // always an integer-dest load/store/AMO in this core's current
    // scope, never an flw) -- only these two (integer) instances need
    // the gate, not m_FreeList_Float/m_RAT_Float below.
    .free_en0(rob_retire_valid0 && rob_retire_has_dest0 && !rob_retire_is_fp_dest0 && !dside_trap_resolve), .free_preg0(rob_retire_old_preg0),
    .free_en1(rob_retire_valid1 && rob_retire_has_dest1 && !rob_retire_is_fp_dest1), .free_preg1(rob_retire_old_preg1),
    .free_count(fl_free_count)
);

RegisterAliasTable #(.NUM_AREGS(NUM_AREGS), .NUM_PREGS(NUM_PREGS)) m_RAT(
    .clk(clk), .rst(rst),
    .raddr0(rs1_areg), .raddr1(rs2_areg), .raddr2(rs1_areg_1), .raddr3(rs2_areg_1),
    .rpreg0(rat_rpreg0), .rpreg1(rat_rpreg1), .rpreg2(rat_rpreg2), .rpreg3(rat_rpreg3),
    .wen0(do_dispatch && needs_dest), .waddr0(rd_areg), .wpreg0(fl_alloc_preg0), .old_preg0(rat_old_preg0),
    .wen1(do_dispatch_slot1 && needs_dest_1), .waddr1(rd_areg_1), .wpreg1(fl_alloc_preg1), .old_preg1(rat_old_preg1),
    .cwen0(rob_retire_valid0 && rob_retire_has_dest0 && !rob_retire_is_fp_dest0 && !dside_trap_resolve), .cwaddr0(rob_retire_areg0), .cwpreg0(rob_retire_preg0),
    .cwen1(rob_retire_valid1 && rob_retire_has_dest1 && !rob_retire_is_fp_dest1), .cwaddr1(rob_retire_areg1), .cwpreg1(rob_retire_preg1),
    .restore_en(1'b0)   // Gen6-G adds real speculation/squash; nothing to
                          // restore yet since nothing speculative can be
                          // in flight (no branches in Gen6-D's own scope).
);

// ==========================================================================
// Gen6-H: F-extension rename stack -- a SEPARATE FreeList/RAT/PRF instance
// for f0-f31, not a shared space with the integer one. RV32F's f0-f31 has
// no hardwired-zero register at all (FRegister.v's own header comment) --
// RegisterAliasTable.v/PhysicalRegisterFile.v's HARDWIRE_REG0/
// HARDWIRE_PREG0=0 here disables every x0-style special case those
// modules otherwise apply, so freg 0 renames/frees/reads/writes exactly
// like any other float register.
//
// Scope, deliberately narrow and real (not a placeholder): FADD.S/
// FSUB.S/FMUL.S/FSGNJ.S family/FMIN.S/FMAX.S (pure float-float, via
// FALU.v's existing single-cycle datapath) and FMV.W.X (integer-bit-
// pattern move, needed to get any value into a float register at all
// without also building flw's own LSQ-float-awareness this same pass).
// Explicitly OUT of scope, real future work: FDIV.S/FSQRT.S (multi-cycle,
// would need their own Divider.v-style in-flight tracking), the fused
// multiply-add family (3-operand, needs FRegister.v's own 3rd read port
// equivalent), FCVT.S.W (integer source, real rounding-mode conversion,
// unlike FMV.W.X's plain bit copy), FCMP/FCVT.W.S/FMV.X.W/FCLASS.S
// (float source, INTEGER dest -- the reverse cross-file direction from
// FMV.W.X), and FLW/FSW (float loads/stores through LoadStoreQueue.v,
// which currently only knows how to complete into the integer PRF).
// ==========================================================================
FreeList #(.NUM_PREGS(NUM_FPREGS), .NUM_AREGS(NUM_FREGS)) m_FreeList_Float(
    .clk(clk), .rst(rst),
    .alloc_en0(is_fp_op), .alloc_en1(1'b0),
    .alloc_preg0(fl_f_alloc_preg0), .alloc_preg1(),
    .alloc_ok0(fl_f_alloc_ok0), .alloc_ok1(),
    // Gen6-L fix (docs/adr/0048): same commit_en0 gating as m_FreeList
    // above -- no FP dual-issue in Gen6-K's own scope, so commit_en1
    // stays tied 0, matching alloc_en1 already being tied 0 here.
    .commit_en0(do_dispatch && is_fp_op), .commit_en1(1'b0),
    .free_en0(rob_retire_valid0 && rob_retire_has_dest0 && rob_retire_is_fp_dest0), .free_preg0(rob_retire_old_preg0),
    .free_en1(rob_retire_valid1 && rob_retire_has_dest1 && rob_retire_is_fp_dest1), .free_preg1(rob_retire_old_preg1),
    .free_count()
);

RegisterAliasTable #(.NUM_AREGS(NUM_FREGS), .NUM_PREGS(NUM_FPREGS), .HARDWIRE_REG0(0)) m_RAT_Float(
    .clk(clk), .rst(rst),
    .raddr0(rs1_areg), .raddr1(rs2_areg), .raddr2({FAREG_BITS{1'b0}}), .raddr3({FAREG_BITS{1'b0}}),
    .rpreg0(rat_f_rpreg0), .rpreg1(rat_f_rpreg1), .rpreg2(), .rpreg3(),
    .wen0(do_dispatch && is_fp_op), .waddr0(rd_areg), .wpreg0(fl_f_alloc_preg0), .old_preg0(rat_f_old_preg0),
    .wen1(1'b0), .waddr1({FAREG_BITS{1'b0}}), .wpreg1({FPREG_BITS{1'b0}}), .old_preg1(),
    .cwen0(rob_retire_valid0 && rob_retire_has_dest0 && rob_retire_is_fp_dest0), .cwaddr0(rob_retire_areg0), .cwpreg0(rob_retire_preg0),
    .cwen1(rob_retire_valid1 && rob_retire_has_dest1 && rob_retire_is_fp_dest1), .cwaddr1(rob_retire_areg1), .cwpreg1(rob_retire_preg1),
    .restore_en(1'b0)
);

// ==========================================================================
// Generation 7, Pillar V, Phase 1 (docs/adr/0061). Vector rename stack --
// a THIRD, genuinely independent register-file-class instance, exactly
// mirroring the float triad above (m_FreeList_Float/m_RAT_Float/
// m_PRF_Float, docs/adr/0047's own "a real, clean design pattern worth
// reusing if a future phase needs a third register-file space" note).
// HARDWIRE_REG0/HARDWIRE_PREG0=0: v0 is the real, addressable RVV mask
// register, not a hardwired-zero register (unlike x0) -- same reasoning
// f0-f31's own HARDWIRE_REG0=0 already established.
//
// No dispatch wiring to this triad yet -- alloc_en0/wen0/etc are all
// tied 0 this phase. A future phase (the vector-crack dispatch sequencer
// + RS_VALU + VALU.v) is what actually drives these; this task only
// proves the triad itself elaborates and resets correctly, matching this
// project's own "declare before any RTL consumes it" precedent
// (docs/adr/0019's own Phase C1 for RV32F's encoding constants).
// ==========================================================================
wire [VPREG_BITS-1:0] fl_v_alloc_preg0;
wire                  fl_v_alloc_ok0;
wire [VPREG_BITS-1:0] rat_v_rpreg0, rat_v_rpreg1;
wire [VPREG_BITS-1:0] rat_v_old_preg0;

FreeList #(.NUM_PREGS(NUM_VPREGS), .NUM_AREGS(NUM_VREGS)) m_FreeList_Vec(
    .clk(clk), .rst(rst),
    .alloc_en0(1'b0), .alloc_en1(1'b0),
    .alloc_preg0(fl_v_alloc_preg0), .alloc_preg1(),
    .alloc_ok0(fl_v_alloc_ok0), .alloc_ok1(),
    .commit_en0(1'b0), .commit_en1(1'b0),
    .free_en0(1'b0), .free_preg0({VPREG_BITS{1'b0}}),
    .free_en1(1'b0), .free_preg1({VPREG_BITS{1'b0}}),
    .free_count()
);

RegisterAliasTable #(.NUM_AREGS(NUM_VREGS), .NUM_PREGS(NUM_VPREGS), .HARDWIRE_REG0(0)) m_RAT_Vec(
    .clk(clk), .rst(rst),
    .raddr0({VAREG_BITS{1'b0}}), .raddr1({VAREG_BITS{1'b0}}),
    .raddr2({VAREG_BITS{1'b0}}), .raddr3({VAREG_BITS{1'b0}}),
    .rpreg0(rat_v_rpreg0), .rpreg1(rat_v_rpreg1), .rpreg2(), .rpreg3(),
    .wen0(1'b0), .waddr0({VAREG_BITS{1'b0}}), .wpreg0({VPREG_BITS{1'b0}}), .old_preg0(rat_v_old_preg0),
    .wen1(1'b0), .waddr1({VAREG_BITS{1'b0}}), .wpreg1({VPREG_BITS{1'b0}}), .old_preg1(),
    .cwen0(1'b0), .cwaddr0({VAREG_BITS{1'b0}}), .cwpreg0({VPREG_BITS{1'b0}}),
    .cwen1(1'b0), .cwaddr1({VAREG_BITS{1'b0}}), .cwpreg1({VPREG_BITS{1'b0}}),
    .restore_en(1'b0)
);

wire [VLEN-1:0] prf_v_rdata0, prf_v_rdata1;
wire            prf_v_rvalid0, prf_v_rvalid1;

// SP_INIT explicitly sized to VLEN bits -- an unsized `0` override would
// hit the same Icarus-self-determines-32-bit-width quirk Gen6-L's own
// SP_INIT bug already found (docs/adr/0048), here just a compile warning
// (this preg's reset value is never architecturally meaningful for a
// vector register file) rather than real corruption, but fixed at the
// root the same way regardless.
PhysicalRegisterFile #(.XLEN(VLEN), .NUM_PREGS(NUM_VPREGS), .NUM_AREGS(NUM_VREGS), .HARDWIRE_PREG0(0), .SP_INIT({VLEN{1'b0}})) m_PRF_Vec(
    .clk(clk), .rst(rst),
    .raddr0(rat_v_rpreg0), .raddr1(rat_v_rpreg1),
    .raddr2({VPREG_BITS{1'b0}}), .raddr3({VPREG_BITS{1'b0}}), .raddr4({VPREG_BITS{1'b0}}),
    .raddr5({VPREG_BITS{1'b0}}), .raddr6({VPREG_BITS{1'b0}}), .raddr7({VPREG_BITS{1'b0}}),
    .raddr8({VPREG_BITS{1'b0}}), .raddr9({VPREG_BITS{1'b0}}), .raddr10({VPREG_BITS{1'b0}}),
    .rdata0(prf_v_rdata0), .rdata1(prf_v_rdata1), .rdata2(), .rdata3(), .rdata4(), .rdata5(),
    .rdata6(), .rdata7(), .rdata8(), .rdata9(), .rdata10(),
    .rvalid0(prf_v_rvalid0), .rvalid1(prf_v_rvalid1), .rvalid2(), .rvalid3(), .rvalid4(), .rvalid5(),
    .rvalid6(), .rvalid7(), .rvalid8(), .rvalid9(), .rvalid10(),
    .wen0(1'b0), .waddr0({VPREG_BITS{1'b0}}), .wdata0({VLEN{1'b0}}),
    .wen1(1'b0), .waddr1({VPREG_BITS{1'b0}}), .wdata1({VLEN{1'b0}}),
    .wen2(1'b0), .waddr2({VPREG_BITS{1'b0}}), .wdata2({VLEN{1'b0}}),
    .alloc_en0(1'b0), .alloc_preg0({VPREG_BITS{1'b0}}),
    .alloc_en1(1'b0), .alloc_preg1({VPREG_BITS{1'b0}})
);

wire [XLEN-1:0] prf_rdata0, prf_rdata1, prf_rdata2, prf_rdata3;
wire            prf_rvalid0, prf_rvalid1, prf_rvalid2, prf_rvalid3;

// ==========================================================================
// Dispatch: ReorderBuffer.v (program-order retire tracking) +
// ReservationStation.v (one instance, the INT-ALU class -- Gen6-D's only
// functional-unit class).
// ==========================================================================
wire [ROB_IDX_BITS-1:0] rob_alloc_tag0, rob_alloc_tag1;
wire rob_full, rob_empty;
wire [$clog2(ROB_ENTRIES+1)-1:0] rob_count;

ReorderBuffer #(.ROB_ENTRIES(ROB_ENTRIES), .AREG_BITS(AREG_BITS), .PREG_BITS(PREG_BITS)) m_ROB(
    .clk(clk), .rst(rst),
    .alloc_en0(do_dispatch), .alloc_has_dest0(needs_dest || is_fp_op), .alloc_is_fp_dest0(is_fp_op),
    .alloc_areg0(rd_areg), .alloc_preg0(is_fp_op ? fl_f_alloc_preg0 : (needs_dest ? fl_alloc_preg0 : {PREG_BITS{1'b0}})),
    .alloc_old_preg0(is_fp_op ? rat_f_old_preg0 : rat_old_preg0), .alloc_tag0(rob_alloc_tag0),
    // Gen6-K: slot1 is always a plain ALU op (try_dual_issue's own
    // definition) -- never FP, never a real dest-less op class, so
    // alloc_is_fp_dest1 stays hardwired 0 (Gen6-K's scope never dual-
    // issues FP; see slot1_is_plain_alu above).
    .alloc_en1(do_dispatch_slot1), .alloc_has_dest1(needs_dest_1), .alloc_is_fp_dest1(1'b0),
    .alloc_areg1(rd_areg_1), .alloc_preg1(needs_dest_1 ? fl_alloc_preg1 : {PREG_BITS{1'b0}}),
    .alloc_old_preg1(rat_old_preg1), .alloc_tag1(rob_alloc_tag1),
    .complete_en0(issue_valid), .complete_tag0(issue_rob_tag),
    // Gen6-P2 (docs/adr/0053): dside_fault_pulse (MMU section, forward-
    // referenced) injects a SYNTHETIC one-cycle completion carrying
    // head_rob_tag -- a permanently-DTLB-faulted head never asserts
    // lsq_complete_valid on its own (mem_stall_ext holds it frozen
    // forever), so without this the ROB's own "done" bit for that entry
    // would never set and dside_trap_resolve could never fire, a real
    // deadlock caught by design before writing any RTL for it, not found
    // by running. Does NOT touch lsq_complete_valid itself -- see that
    // wire's own comment for why the PRF CDB write correctly stays gated
    // on the real signal alone.
    .complete_en1(lsq_complete_valid || dside_fault_pulse),
    .complete_tag1(dside_fault_pulse ? lsq_head_rob_tag : lsq_complete_rob_tag),
    .complete_en2(div_complete_valid), .complete_tag2(div_complete_rob_tag),
    .complete_en3(falu_complete_valid), .complete_tag3(falu_complete_rob_tag),
    .complete_en4(fdiv_complete_valid), .complete_tag4(fdiv_complete_rob_tag),
    .retire_valid0(rob_retire_valid0), .retire_has_dest0(rob_retire_has_dest0), .retire_is_fp_dest0(rob_retire_is_fp_dest0),
    .retire_areg0(rob_retire_areg0), .retire_preg0(rob_retire_preg0), .retire_old_preg0(rob_retire_old_preg0),
    .retire_tag0(rob_retire_tag0),
    .retire_valid1(rob_retire_valid1), .retire_has_dest1(rob_retire_has_dest1), .retire_is_fp_dest1(rob_retire_is_fp_dest1),
    .retire_areg1(rob_retire_areg1), .retire_preg1(rob_retire_preg1), .retire_old_preg1(rob_retire_old_preg1),
    .retire_tag1(rob_retire_tag1),
    .rob_count(rob_count), .rob_full(rob_full), .rob_empty(rob_empty)
);

// ==========================================================================
// Gen6-I: precise exceptions via ROB-retire-gated CSR.v. Same "single
// outstanding speculative thing" scope cut as Gen6-G's own branches
// (br_inflight_valid_r) -- dispatch of EVERYTHING stalls once a trap-
// related instruction (illegal opcode, ecall, or mret) is in flight,
// until it retires. This means the retiring instruction really is the
// ONLY thing that can ever assert trap_taken/mret_taken, satisfying
// CSR.v's own existing single-scalar/exactly-once contract with ZERO
// changes to that module -- the exact research finding this generation's
// own planning session made before writing any RTL. An excepting
// instruction still gets an ordinary (no-dest) ROB entry and flows
// through RS_ALU exactly like a store/branch (harmless garbage ALU
// computation, discarded) so it retires normally -- only the ACT of
// retiring it is special.
reg                     trap_inflight_valid_r;
reg                     trap_inflight_is_mret_r;
reg [XLEN-1:0]          trap_inflight_pc_r;
reg [31:0]              trap_inflight_cause_r;
reg [ROB_IDX_BITS-1:0]  trap_inflight_rob_tag_r;

// Gen6-P2 (docs/adr/0053): a D-side (LSQ) page fault does NOT fit the
// dispatch-time-only shape above -- the faulting entry was already
// dispatched, its own rob_tag already allocated, well before its own
// translation resolves (this can be many cycles later, once the LSQ's
// strictly-in-order head finally reaches it). Latched separately, the
// cycle dtlb_page_fault (MMU section) first fires, using the LSQ's own
// head_rob_tag/head_pc (LoadStoreQueue.v's own new Gen6-P2 outputs) --
// resolved against retire exactly like trap_inflight_rob_tag_r is, just
// via a second, independent comparison (dside_trap_resolve below;
// mutually exclusive with trap_resolve by construction, since a single
// ROB entry can never be tracked by both mechanisms at once -- one is
// set at dispatch for illegal/ecall/mret/itlb-fault, the other only ever
// for a LSQ entry that was a legitimate memory op at dispatch time).
reg                     dside_fault_valid_r;
reg [XLEN-1:0]          dside_fault_pc_r;
reg [31:0]              dside_fault_cause_r;
reg [ROB_IDX_BITS-1:0]  dside_fault_rob_tag_r;

always @(posedge clk) begin
    if (~rst) dside_fault_valid_r <= 1'b0;
    else if (dtlb_page_fault && !dside_fault_valid_r) begin
        dside_fault_valid_r   <= 1'b1;
        dside_fault_pc_r      <= lsq_head_pc;
        dside_fault_cause_r   <= lsq_head_want_write ? `MCAUSE_STORE_PAGE_FAULT : `MCAUSE_LOAD_PAGE_FAULT;
        dside_fault_rob_tag_r <= lsq_head_rob_tag;
    end
    else if (dside_trap_resolve) dside_fault_valid_r <= 1'b0;
end
// A permanently-DTLB-faulted head never asserts lsq_complete_valid on its
// own (mem_stall_ext, driven by dtlb_stall, holds it frozen forever once
// ls_hit can never become true) -- ReorderBuffer.v's own "done" bit for
// this entry needs a SYNTHETIC completion instead, injected via the
// SAME complete_en1/complete_tag1 port lsq_complete_valid already uses
// (see that instantiation further down), one cycle only (the same edge
// dside_fault_valid_r itself latches), carrying head_rob_tag instead of
// whatever lsq_complete_rob_tag happens to hold that unrelated cycle.
// Crucially this does NOT touch lsq_complete_valid itself, so
// PhysicalRegisterFile.v's own CDB writeback (wen1, gated on the REAL
// lsq_complete_valid) correctly never fires -- a faulting load must
// never actually write any value into its destination preg.
wire dside_fault_pulse = dtlb_page_fault && !dside_fault_valid_r;
wire dside_trap_resolve = rob_retire_valid0 && dside_fault_valid_r && (rob_retire_tag0 == dside_fault_rob_tag_r);

wire trap_resolve_dispatch = rob_retire_valid0 && trap_inflight_valid_r && (rob_retire_tag0 == trap_inflight_rob_tag_r);
wire trap_resolve = trap_resolve_dispatch || dside_trap_resolve;
// Gen6-P3 (docs/adr/0054): interrupt_take (forward-referenced, defined in
// the interrupt section further down) ORs in unconditionally -- it can
// never genuinely coincide with trap_resolve the same cycle (interrupt_take
// only ever fires with rob_empty, meaning nothing could simultaneously be
// retiring/resolving a trap), so there's no real priority question here
// either, same reasoning that section's own header comment already gives.
wire csr_trap_taken = (trap_resolve && !(trap_resolve_dispatch && trap_inflight_is_mret_r)) || interrupt_take;
wire csr_mret_taken = trap_resolve_dispatch && trap_inflight_is_mret_r;
// A D-side fault is never an mret, so widening csr_trap_taken/csr_mret_taken
// this way is unambiguous: dside_trap_resolve alone always means
// csr_trap_taken (never csr_mret_taken), exactly like every other real
// exception cause already handled through trap_resolve_dispatch.

always @(posedge clk) begin
    if (~rst) begin
        trap_inflight_valid_r <= 1'b0;
    end
    else begin
        if (do_dispatch && is_trap_related) begin
            trap_inflight_valid_r   <= 1'b1;
            trap_inflight_is_mret_r <= isMret_c;
            trap_inflight_pc_r      <= pc_r;
            // Gen6-P2: itlb_fault_this_cycle checked FIRST -- inst_word was
            // already forced to the all-zero "illegal" encoding for this
            // exact cycle (see the fetch section), so has_exception/
            // isEcall_c may ALSO spuriously read true off that forced
            // value; the real cause must win regardless of what garbage
            // bits would otherwise have decoded as.
            trap_inflight_cause_r   <= itlb_fault_this_cycle ? `MCAUSE_INSTRUCTION_PAGE_FAULT :
                                        isEcall_c ? `MCAUSE_ECALL_FROM_M : `MCAUSE_ILLEGAL_INSTRUCTION;
            trap_inflight_rob_tag_r <= rob_alloc_tag0;
        end
        else if (trap_resolve_dispatch) begin
            trap_inflight_valid_r <= 1'b0;
        end
    end
end

wire [XLEN-1:0] csr_mtvec_val, csr_mepc_val;

// ==========================================================================
// Gen6-O5 (docs/adr/0051): csrrw/csrrs/csrrc(+i), single-outstanding
// scope cut -- same shape as jr_inflight/trap_inflight (dispatch of
// everything else stalls until this resolves). Real research finding
// (confirmed before writing any of this, matching this whole
// generation's own established discipline): the READ (rd's own old-
// value writeback) and the WRITE (the actual mutation) do NOT need to
// happen at the same pipeline moment. Given the single-outstanding
// scope cut already guarantees NOTHING else (no other csrrX, no trap/
// mret, since dispatch_stall blocks ALL of them mutually exclusively)
// can touch any CSR state between this instruction's own dispatch and
// its own resolve, reading csr_rdata combinationally AT DISPATCH TIME
// (captured into forced_a_value0 above, same "force A" mechanism lui/
// auipc/jal/jalr already use, giving rd its old-value writeback via the
// ORDINARY RS_ALU->issue->CDB pipeline, no new completion path needed)
// is PROVABLY identical to reading it again at resolve time -- nothing
// could have changed it in between. The WRITE still needs the real
// operand value (rs1's PRF read for csrrw/csrrs/csrrc, or the captured
// 5-bit uimm for the *i forms), which may not be ready at dispatch time
// (rs1 could be an in-flight instruction's own result) -- so the write
// itself fires at RESOLVE (RS_ALU actually issuing this entry, rs1
// confirmed ready), exactly mirroring jr_resolve's own timing.
// ==========================================================================
reg                  csr_inflight_valid_r;
reg [ROB_IDX_BITS-1:0] csr_inflight_rob_tag_r;
reg [11:0]           csr_inflight_addr_r;
reg [1:0]            csr_inflight_op_r;
reg                  csr_inflight_is_imm_r;
reg [XLEN-1:0]       csr_inflight_uimm_r;

wire csr_write_fire = issue_valid && csr_inflight_valid_r && (issue_rob_tag == csr_inflight_rob_tag_r);
wire [XLEN-1:0] csr_wdata_final = csr_inflight_is_imm_r ? csr_inflight_uimm_r : prf_rdata2;

always @(posedge clk) begin
    if (~rst) begin
        csr_inflight_valid_r <= 1'b0;
    end
    else begin
        if (do_dispatch && is_csr) begin
            csr_inflight_valid_r   <= 1'b1;
            csr_inflight_rob_tag_r <= rob_alloc_tag0;
            csr_inflight_addr_r    <= imm_d[11:0];   // ImmGen.v's own
                                                        // SYSTEM case
                                                        // (zero-extended
                                                        // inst[31:20])
            csr_inflight_op_r      <= funct3_c[1:0];   // 01=write,
                                                          // 10=set,
                                                          // 11=clear --
                                                          // same funct3
                                                          // slice
                                                          // riscvpipeline.v
                                                          // already uses
            csr_inflight_is_imm_r  <= funct3_c[2];     // 1 = csrrwi/
                                                          // csrrsi/csrrci
                                                          // (uimm, not
                                                          // rs1)
            csr_inflight_uimm_r    <= {{(XLEN-5){1'b0}}, rs1_areg};   // inst[19:15]
                                                                        // IS the
                                                                        // 5-bit uimm
                                                                        // field for
                                                                        // the *i forms
                                                                        // -- same bit
                                                                        // position
                                                                        // rs1_areg
                                                                        // already reads
        end
        else if (csr_write_fire) begin
            csr_inflight_valid_r <= 1'b0;
        end
    end
end

// Every HPC/performance-counter pulse input and every S-mode/MMU-only
// output is tied off/left open this phase -- real future work alongside
// the MMU/interrupts noted above.
// Gen6-P3 (docs/adr/0054): CSR.v's own live enable outputs, needed by the
// interrupt-pending computation further down (after this instantiation,
// same forward-reference convention every other Gen6-* section in this
// file already uses for wires produced/consumed across sections).
wire mstatus_mie, mie_msie, mie_mtie, mie_meie;
wire [2:0] frm_live;   // Gen6-P4 (docs/adr/0055): CSR.v's own live frm, for RM_DYN resolution

CSR #(.XLEN(XLEN)) m_CSR(
    .clk(clk), .rst(rst),
    .csr_write_en(csr_write_fire),
    .csr_addr(csr_write_fire ? csr_inflight_addr_r : imm_d[11:0]),
    .csr_op(csr_inflight_op_r), .csr_wdata(csr_wdata_final), .csr_rdata(csr_old_value_captured),
    // Gen6-P2/P3: muxed on interrupt_take first (highest priority -- only
    // ever true with the ROB fully drained, see the interrupt section
    // below, so it can never genuinely coincide with a real dside_trap_
    // resolve/trap_resolve_dispatch the same cycle, but ordered first for
    // clarity), then dside_trap_resolve -- a D-side page fault's own
    // pc/cause live in a separate latch (dside_fault_*_r) from every
    // other, dispatch-time-known trap cause (trap_inflight_*_r).
    .trap_taken(csr_trap_taken),
    .trap_pc(interrupt_take ? pc_r : (dside_trap_resolve ? dside_fault_pc_r : trap_inflight_pc_r)),
    .trap_cause(interrupt_take ? {{(XLEN-32){1'b0}}, interrupt_cause} :
                (dside_trap_resolve ? {{(XLEN-32){1'b0}}, dside_fault_cause_r} : {{(XLEN-32){1'b0}}, trap_inflight_cause_r})),
    .trap_is_interrupt(interrupt_take),
    .trap_value({XLEN{1'b0}}),
    .mret_taken(csr_mret_taken), .sret_taken(1'b0),
    // Gen6-P4 (docs/adr/0055): frm_val wired for real -- FDivider.v/FSqrt.v
    // both need the resolved rounding mode (RM_DYN, funct3==111, means
    // "use frm's own live value" -- resolved once, at issue time, below,
    // the same single resolution point PIPELINED's own fpu_rm already
    // established). fp_flags_we/fp_flags_in stay tied off (Gen6-H's own
    // pre-existing scope -- fflags accumulation was never wired for FALU
    // either; not revisited here).
    .fp_flags_we(1'b0), .fp_flags_in(5'd0), .frm_val(frm_live),
    // Gen6-P3 (docs/adr/0054): routed straight through from this module's
    // own top-level ports.
    .msip_pending(msip_pending), .timer_pending(timer_pending), .ext_pending(ext_pending),
    .mstatus_mie(mstatus_mie), .mie_msie(mie_msie), .mie_mtie(mie_mtie), .mie_meie(mie_meie),
    .mie_ssie(), .mie_stie(), .mip_ssip(), .mip_stip(),
    .mstatus_mpie(), .mstatus_sie(), .mstatus_spie(), .mstatus_spp(), .mstatus_mpp(),
    .mtvec_val(csr_mtvec_val), .mepc_val(csr_mepc_val),
    .priv_mode_val(csr_priv_mode_val), .stvec_val(), .sepc_val(), .trap_target_is_s(),
    .satp_mode_val(csr_satp_mode_val), .satp_ppn_val(csr_satp_ppn_val),
    .instret_pulse(1'b0), .branch_retired_pulse(1'b0), .mispredict_pulse(1'b0),
    .icache_hit_pulse(1'b0), .icache_miss_pulse(1'b0), .dcache_hit_pulse(1'b0), .dcache_miss_pulse(1'b0),
    .stall_cycle_pulse(1'b0), .interrupt_pulse(1'b0), .exception_pulse(1'b0),
    .stall_hazard_pulse(1'b0), .stall_div_pulse(1'b0), .stall_mem_pulse(1'b0), .stall_fp_pulse(1'b0),
    .stall_float_lu_pulse(1'b0), .stall_itlb_pulse(1'b0), .stall_dtlb_pulse(1'b0),
    .stall_icache_pulse(1'b0), .stall_imem_wait_pulse(1'b0),
    // Gen7 Pillar V Phase 1 (docs/adr/0061).
    .vl_o(vl_o), .vsew_o(), .vlmul_o(), .vill_o(),
    .vec_cfg_write_en(vec_cfg_write_en_w), .vec_cfg_new_vtype(vec_cfg_new_vtype_w),
    .vec_cfg_new_vill(vec_cfg_new_vill_w), .vec_cfg_new_vl(vec_cfg_new_vl_w)
);

// ==========================================================================
// Gen6-P3 (docs/adr/0054): real interrupts -- machine-external/-software/
// -timer (mei/msi/mti), the same three sources PIPELINED's own Phase D8/
// D9/R baseline established, BEFORE Phase S's later S-mode delegation
// work (ssi/sti, sstatus.SIE, mip_ssip software-settable) -- a real,
// deliberate, narrower scope cut: this core has no medeleg/mideleg
// infrastructure at all yet (Gen6-I's own header already flagged this as
// real future work), so S-mode-targeted interrupt delegation stays out
// of scope here too, matching docs/adr/0053's own "not re-litigated"
// treatment of similar Sv39 scoping defaults.
//
// Real design decision, not the more elaborate option: rather than
// trying to inject an interrupt at an arbitrary mid-flight instruction
// boundary (what a genuinely precise, minimum-latency interrupt
// implementation would do), this core takes an interrupt only once the
// ROB is fully DRAINED (rob_empty) -- everything already in flight
// retires normally through its own existing path first, dispatch of
// anything NEW stops the moment an enabled interrupt is recognized
// (interrupt_pending folds into dispatch_stall, same single-outstanding
// shape every other Gen6-* control-flow source already uses), and the
// interrupt itself fires the first cycle nothing is left in flight. This
// This is a real, legitimate, spec-compliant point to recognize an interrupt
// (RISC-V does not mandate minimum latency), and it needs zero new
// per-instruction tracking (no *_inflight_valid_r register at all) --
// rob_empty already means nothing else could possibly want the SAME
// cycle's redirect mux, so there is no priority/coincidence question to
// resolve the way trap_resolve/br_resolve/jr_resolve's own mutual
// exclusion already had to be reasoned through.
wire mei_pending = mie_meie && ext_pending;
wire msi_pending = mie_msie && msip_pending;
wire mti_pending = mie_mtie && timer_pending;
// Spec-mandated priority when more than one is pending and enabled:
// machine-external > machine-software > machine-timer (identical order
// docs/adr/0020's own PIPELINED wiring already established).
wire [31:0] interrupt_cause = mei_pending ? `MCAUSE_INT_MACHINE_EXTERNAL :
                               msi_pending ? `MCAUSE_INT_MACHINE_SOFTWARE :
                                             `MCAUSE_INT_MACHINE_TIMER;
wire interrupt_pending = mstatus_mie && (mei_pending || msi_pending || mti_pending);
wire interrupt_take = interrupt_pending && rob_empty;

// ==========================================================================
// Gen6-P2 (docs/adr/0053): Sv39 MMU. Reuses Tlb39.v/Ptw39.v completely
// unmodified (docs/adr/0032, Phase P) -- both already expose exactly the
// shape this core needs (a unified TLB with independent fetch/ls query
// ports, a Wishbone-master-shaped walker) and neither is XLEN=32-aware
// (Sv39 doesn't exist there), matching this whole generation's own RV64-
// only scope (no OOOCore.v test has ever used XLEN=32). satp_ppn_val is
// already the real 44-bit Sv39 width (docs/adr/0032's own CSR.v widening),
// needing no adaptation here.
//
// Real structural difference from riscvpipeline.v's own P3 wiring, worth
// flagging: PIPELINED's Ptw.v/Ptw39.v share ONE Wishbone bus with the
// D-side LSU (a real master/master arbiter already exists there). This
// core's own D-side memory (DataMemoryBRAM.v, via LoadStoreQueue.v) is a
// plain synchronous-read array, not Wishbone -- Ptw39's own Wishbone-
// master-shaped port is adapted to that simpler shape below (m_cyc/m_stb
// -> memRead/memWrite, m_ack/m_data_i driven back at DataMemoryBRAM.v's
// own known fixed 1-cycle registered-read latency), and arbitrated
// against the LSQ's own ordinary traffic for the SAME single port. Page
// tables live in ordinary D-side memory, built by the test program's own
// runtime stores (addi+sd), exactly the same convention PIPELINED's own
// Sv39-aware random generator already established (docs/adr/0032 P5) --
// this core's own m_DMem never gets a DATA_INIT_FILE, so nothing needs
// preloading differently.
wire [1:0]  csr_priv_mode_val;
wire        csr_satp_mode_val;
wire [43:0] csr_satp_ppn_val;

wire translate_enable = (XLEN == 64) && csr_satp_mode_val && (csr_priv_mode_val != `PRIV_M);
wire priv_is_u         = (csr_priv_mode_val == `PRIV_U);

wire itlb_hit, ls_hit;
wire [XLEN-1:0] itlb_ppn, ls_ppn;
wire itlb_perm_r, itlb_perm_w, itlb_perm_x, itlb_perm_u;
wire ls_perm_r, ls_perm_w, ls_perm_x, ls_perm_u;
wire ptw_fill_valid;
wire [XLEN-1:0] ptw_fill_vaddr, ptw_fill_ppn;
wire ptw_fill_perm_r, ptw_fill_perm_w, ptw_fill_perm_x, ptw_fill_perm_u;

Tlb39 #(.XLEN(XLEN)) m_Tlb(
    .clk(clk), .rst(rst),
    .fetch_vaddr(pc_r),
    .fetch_hit(itlb_hit), .fetch_ppn(itlb_ppn),
    .fetch_perm_r(itlb_perm_r), .fetch_perm_w(itlb_perm_w),
    .fetch_perm_x(itlb_perm_x), .fetch_perm_u(itlb_perm_u),
    // Queried at the LSQ's own real head virtual address (valid whenever
    // lsq_head_want_access, combinationally -- see LoadStoreQueue.v's own
    // head_addr, which doesn't depend on mem_stall_ext, so no circular
    // dependency with the stall this same query feeds into below).
    .ls_vaddr(lsq_mem_address),
    .ls_hit(ls_hit), .ls_ppn(ls_ppn),
    .ls_perm_r(ls_perm_r), .ls_perm_w(ls_perm_w),
    .ls_perm_x(ls_perm_x), .ls_perm_u(ls_perm_u),
    .fill_valid(ptw_fill_valid), .fill_vaddr(ptw_fill_vaddr), .fill_ppn(ptw_fill_ppn),
    .fill_perm_r(ptw_fill_perm_r), .fill_perm_w(ptw_fill_perm_w),
    .fill_perm_x(ptw_fill_perm_x), .fill_perm_u(ptw_fill_perm_u),
    .flush_all(sfence_real)
);

// itlb_hit_fault: a genuine TLB hit whose own permission bits deny THIS
// access (X, plus the U-bit match) -- resolved the same cycle as any
// other combinational decode, no walk needed. itlb_miss: translation is
// on but nothing hit yet, AND this isn't the exact cycle a walk just
// concluded with a fault (that cycle needs to fall through to dispatch
// instead, so is_trap_related can pick it up -- see itlb_fault_this_cycle
// below). Mirrors docs/adr/0032 P3's itlb_hit_fault/itlb_miss exactly;
// this core has no branch_taken/redirect_squash_extend_r-style same-cycle
// redirect race to gate against the way PIPELINED's own front end does --
// br_mispredict/jr_resolve/trap_resolve all fold into dispatch_stall via
// their own *_inflight_valid_r, and none of them can coincide with a
// FETCH still in progress this cycle (do_dispatch is what advances pc_r
// at all -- see the PC-advance block).
wire itlb_hit_fault = translate_enable && itlb_hit &&
    !(itlb_perm_x && (priv_is_u ? itlb_perm_u : !itlb_perm_u));
wire itlb_miss = translate_enable && !itlb_hit && !(ptw_done_i && ptw_fault);
wire itlb_fault_this_cycle = itlb_hit_fault || (translate_enable && ptw_done_i && ptw_fault);

// D-side (LSQ) equivalent. dtlb_needed: the LSQ's head genuinely wants a
// real access this cycle (lsq_head_want_access, LoadStoreQueue.v's own
// pre-stall condition), gated on translation being live at all.
// ls_perm_ok checks W for a write-phase access (store/SC/AMO_RMW's own
// write), R otherwise (load/LR/AMO_RMW's own read phase) -- lsq_head_want_write
// already distinguishes these exactly the way LoadStoreQueue.v's own
// internal head_wants_write does. Unlike I-side, a D-side fault does NOT
// fit the dispatch-time-only trap shape (this entry was already
// dispatched, its own rob_tag already allocated, well before its
// translation resolves) -- see the late-injection latch further down.
wire dtlb_needed = translate_enable && lsq_head_want_access;
wire ls_perm_ok = (lsq_head_want_write ? ls_perm_w : ls_perm_r) &&
    (priv_is_u ? ls_perm_u : !ls_perm_u);
wire dtlb_hit_fault = dtlb_needed && ls_hit && !ls_perm_ok;
wire dtlb_miss = dtlb_needed && !ls_hit && !(ptw_done_d && ptw_fault);
wire dtlb_page_fault = dtlb_hit_fault || (dtlb_needed && ptw_done_d && ptw_fault);
// Freezes the LSQ's own head (mem_stall_ext, wired at m_LSQ above) from
// the FIRST cycle a miss is detected -- before ptw_busy even goes high --
// through to either a genuine hit (translation resolved, real access can
// finally issue) or a fault (at which point continuing to hold doesn't
// matter: dtlb_page_fault has already latched the late trap injection
// below, and the entry will never issue a real access again).
wire dtlb_stall = dtlb_needed && !ls_hit;

// -- Shared Ptw39, D-side vs. I-side arbitration: D-side (an older
// access, by construction -- the LSQ is strictly in-order and its own
// head is always the oldest outstanding memory op) wins whenever both
// are pending, same program-order priority docs/adr/0032 P3 already
// established for PIPELINED's own identical dtlb_miss/itlb_miss race.
// lsq_bus_busy_r is the real bug that same phase already found and fixed
// once (an older, unrelated access can genuinely still be using the
// shared port the exact cycle a walk wants to start) -- DataMemoryBRAM.v's
// own fixed 1-cycle registered-read latency means "was the LSQ using the
// real port (not the mailbox) THIS cycle OR last cycle" is the complete,
// sufficient condition here (no multi-cycle internal memory state to
// track beyond that, unlike a real cache/Wishbone adapter).
reg lsq_bus_busy_r;
always @(posedge clk) begin
    if (~rst) lsq_bus_busy_r <= 1'b0;
    else lsq_bus_busy_r <= (lsq_mem_memRead || lsq_mem_memWrite) && !mailbox_hit;
end
wire ptw_req_d = dtlb_stall;
wire ptw_req_i = itlb_miss && !dtlb_stall;
wire ptw_start = (ptw_req_i || ptw_req_d)
    && !((lsq_mem_memRead || lsq_mem_memWrite) && !mailbox_hit) && !lsq_bus_busy_r;
wire [XLEN-1:0] ptw_vaddr = ptw_req_d ? lsq_mem_address : pc_r;
wire ptw_is_fetch = ptw_req_i;
wire ptw_is_store = ptw_req_d && lsq_head_want_write;

wire ptw_busy, ptw_done, ptw_fault;
wire [XLEN-1:0] ptw_result_ppn;
wire ptw_result_perm_r, ptw_result_perm_w, ptw_result_perm_x, ptw_result_perm_u;
wire ptw_m_cyc, ptw_m_stb, ptw_m_we;
wire [XLEN-1:0] ptw_m_addr, ptw_m_data_o;
wire [`WB_SEL_WIDTH-1:0] ptw_m_sel;
wire [XLEN-1:0] ptw_m_data_i;
wire ptw_m_ack;

Ptw39 #(.XLEN(XLEN)) m_Ptw(
    .clk(clk), .rst(rst),
    .start(ptw_start), .vaddr(ptw_vaddr), .satp_ppn(csr_satp_ppn_val),
    .is_fetch(ptw_is_fetch), .is_store(ptw_is_store), .priv_is_u(priv_is_u),
    .busy(ptw_busy), .done(ptw_done), .fault(ptw_fault),
    .result_ppn(ptw_result_ppn),
    .result_perm_r(ptw_result_perm_r), .result_perm_w(ptw_result_perm_w),
    .result_perm_x(ptw_result_perm_x), .result_perm_u(ptw_result_perm_u),
    .m_cyc(ptw_m_cyc), .m_stb(ptw_m_stb), .m_we(ptw_m_we),
    .m_addr(ptw_m_addr), .m_data_o(ptw_m_data_o), .m_sel(ptw_m_sel),
    .m_data_i(ptw_m_data_i), .m_ack(ptw_m_ack)
);

// Which side a walk currently in progress was for -- Ptw39 itself doesn't
// report this (mirrors Divider.v's own precedent of the caller owning
// this bookkeeping). Only ptw_done_i is real this sub-phase (ptw_req_d
// tied 0 above); ptw_done_d is wired for Gen6-P2d.
reg ptw_servicing_d_r;
always @(posedge clk) begin
    if (~rst) ptw_servicing_d_r <= 1'b0;
    else if (ptw_start && !ptw_busy) ptw_servicing_d_r <= ptw_req_d;
end
wire ptw_done_i = ptw_done && !ptw_servicing_d_r;
wire ptw_done_d = ptw_done && ptw_servicing_d_r;

assign ptw_fill_valid   = (ptw_done_i || ptw_done_d) && !ptw_fault;
assign ptw_fill_vaddr   = ptw_servicing_d_r ? lsq_mem_address : pc_r;
assign ptw_fill_ppn     = ptw_result_ppn;
assign ptw_fill_perm_r  = ptw_result_perm_r;
assign ptw_fill_perm_w  = ptw_result_perm_w;
assign ptw_fill_perm_x  = ptw_result_perm_x;
assign ptw_fill_perm_u  = ptw_result_perm_u;

// docs/adr/0038's own established sfence.vma decode (isSfenceVma_c).
// Privilege check mirrors docs/adr/0032 P3's own sfence_priv_violation
// exactly (U-mode may never issue it); real future work, deliberately
// scoped narrow this phase (not independently directed-tested the way
// the translate-hit/-fault paths are -- flush_all's own mechanism,
// Tlb39.v's unconditional-whole-TLB-flush pulse, is already covered by
// that module's own unit test and is entirely translation-scheme-
// agnostic, so the marginal risk here is low): fires the flush pulse the
// SAME cycle it dispatches (this core's own frontend is purely
// combinational, no separate EX/retire delay the way PIPELINED's own
// reg2_hold-gated version needs), and folds the privilege violation into
// the SAME dispatch-time trap path itlb_fault_this_cycle already uses
// (illegal-instruction is the correct cause -- same as PIPELINED's own
// sfence_priv_violation, which docs/adr/0032 already treats as an
// ordinary illegal-instruction-shaped exception).
wire sfence_priv_violation = isSfenceVma_c && priv_is_u;
wire sfence_real = do_dispatch && isSfenceVma_c && !sfence_priv_violation;

// Ptw39's own Wishbone-master-shaped port, adapted to DataMemoryBRAM.v's
// plain synchronous memRead/memWrite/address/writeData/funct3/readData
// shape -- m_ack asserts exactly one cycle after m_cyc&&m_stb, matching
// DataMemoryBRAM.v's own documented fixed 1-cycle registered-read
// latency (confirmed by direct reading of its always block, not assumed).
// Sv39 PTEs are 8 bytes -- funct3 forced to F3_LOAD_LD regardless of
// ptw_m_sel (Ptw39.v's own header already flags m_sel as vestigial on a
// real adapter; width comes from funct3 here, same finding docs/adr/0032
// P3 made for RamWishboneAdapter.v).
reg ptw_m_ack_r;
always @(posedge clk) begin
    if (~rst) ptw_m_ack_r <= 1'b0;
    else ptw_m_ack_r <= ptw_m_cyc && ptw_m_stb;
end
assign ptw_m_ack = ptw_m_ack_r;

// Gen6-O (docs/adr/0051): lui/auipc/jal/jalr/csrrX's own operand-A
// override, captured once at DISPATCH time (this cycle's pc_r/csr old
// value, before either can possibly change) and carried through RS_ALU
// via the payload -- see this module's own PAYLOAD_BITS comment.
// use_link_b (jal/jalr only): forces operand B to the literal 4, giving
// alu_out = pc_r+4, the real link value written to rd -- jalr's own
// REAL target (rs1+imm) is computed separately, at resolve time, from
// prf_rdata2 (rs1's raw, untouched-by-this-override PRF read) further
// down (see jr_inflight_* below).
wire [XLEN-1:0] csr_old_value_captured;   // wired in the CSR section below (Gen6-O5)
wire [XLEN-1:0] vl_o;   // Gen7-V: wired in the CSR section below -- forward-declared
                          // here the same way csr_old_value_captured is.
// Gen7-V: fed to m_CSR's own new Task-2 side-channel input ports below --
// forward-declared here (same "declare early, drive later once its own
// dependencies are naturally available" pattern lsq_complete_valid etc.
// already established throughout this file), driven by real assigns in
// the vec_cfg_inflight tracker block near the execute section further
// down.
wire                 vec_cfg_write_en_w;
wire [7:0]           vec_cfg_new_vtype_w;
wire                 vec_cfg_new_vill_w;
wire [XLEN-1:0]      vec_cfg_new_vl_w;
// Gen7 Pillar V Phase 1 (docs/adr/0061): vsetvli's rs1==x0 special cases
// (real spec: rs1==x0,rd!=x0 -> AVL=VLMAX; rs1==x0,rd==x0 -> AVL=current
// vl) reuse this SAME forced-a-value mechanism -- rs1's PRF read is
// skipped entirely and operand A is forced directly, exactly like lui's
// own "0" or auipc/jal/jalr-link's own "pc_r".
wire use_forced_a0 = is_lui || is_auipc || is_jal || is_jalr || is_csr || (is_vec_cfg && rs1_areg == 5'd0);
wire use_link_b0   = is_jal || is_jalr;
wire [XLEN-1:0] forced_a_value0 =
    is_lui   ? {XLEN{1'b0}} :
    is_csr   ? csr_old_value_captured :
    (is_vec_cfg && rs1_areg == 5'd0) ? (rd_areg == 5'd0 ? vl_o : vec_cfg_vlmax) :
               pc_r;   // auipc/jal/jalr-link all want THIS instruction's own PC

// Dispatch-time readiness query -- rs1/rs2's CURRENT physical tags
// (rat_rpreg0/1, from the SAME-cycle RAT read above, still the
// pre-rename mapping) queried against PRF's own rvalid.
// Gen7-V: is_vec_cfg is the new leading payload bit; the imm slot is
// overridden with VLMAX (computed combinationally from this
// instruction's own bits, see vec_cfg_vlmax above) instead of ImmGen.v's
// own imm_d -- vsetvli/vsetivli need no ImmGen.v change at all.
wire [PAYLOAD_BITS-1:0] rs_disp_payload0 = {is_vec_cfg, use_forced_a0, use_link_b0, forced_a_value0, ALUSrc_c, ALUCtl_d, is_vec_cfg ? vec_cfg_vlmax : imm_d};

wire [PREG_BITS-1:0] issue_src1_preg, issue_src2_preg;
wire [PAYLOAD_BITS-1:0] issue_payload;
wire rs_alu_full;
wire [$clog2(RS_ALU_ENTRIES+1)-1:0] rs_alu_count;

// Gen6-K: slot1's own dispatch-time operand readiness. The same-bundle
// RAW bypass (slot1_src1_from_slot0/slot1_src2_from_slot0, computed in
// the decode block above) overrides BOTH the tag (use slot0's own
// fl_alloc_preg0 directly, since RAT's stored spec_map won't reflect
// slot0's write until next cycle) AND the ready bit (forced 0 -- slot0
// hasn't executed yet this cycle, so its result cannot possibly be
// ready no matter what PRF says about that (still-unallocated-at-decode-
// time) preg).
wire [PREG_BITS-1:0] rs_alu_disp1_src1_preg = slot1_src1_from_slot0 ? fl_alloc_preg0 : rat_rpreg2;
wire                 rs_alu_disp1_src1_ready = slot1_src1_from_slot0 ? 1'b0 : prf_rvalid9;
wire [PREG_BITS-1:0] rs_alu_disp1_src2_preg = slot1_src2_from_slot0 ? fl_alloc_preg0 : rat_rpreg3;
wire                 rs_alu_disp1_src2_ready = slot1_src2_from_slot0 ? 1'b0 : prf_rvalid10;
// Gen6-O: slot1 is never lui/auipc/jal/jalr/csrrX (slot1_is_plain_alu's
// own exclusion, see is_lui_auipc_jal_jalr_csr_1 above) -- these three
// fields are always irrelevant for slot1's own payload, tied off.
wire [PAYLOAD_BITS-1:0] rs_disp_payload1 = {1'b0, 1'b0, 1'b0, {XLEN{1'b0}}, ALUSrc_c_1, ALUCtl_d_1, imm_d_1};   // Gen7-V: slot1 is never vsetvli (slot0_is_plain_alu's own exclusion), leading bit tied 0

ReservationStation #(.RS_ENTRIES(RS_ALU_ENTRIES), .PREG_BITS(PREG_BITS), .ROB_IDX_BITS(ROB_IDX_BITS), .PAYLOAD_BITS(PAYLOAD_BITS)) m_RS_ALU(
    .clk(clk), .rst(rst),
    .disp_en0(do_dispatch && !is_mem_op && !is_div_op && !is_fp_op),
    .disp_src1_preg0(rat_rpreg0), .disp_src1_ready0(prf_rvalid0),
    .disp_src2_preg0(rat_rpreg1), .disp_src2_ready0(prf_rvalid1),
    .disp_dest_preg0(needs_dest ? fl_alloc_preg0 : {PREG_BITS{1'b0}}),
    .disp_rob_tag0(rob_alloc_tag0), .disp_payload0(rs_disp_payload0),
    .disp_en1(do_dispatch_slot1),
    .disp_src1_preg1(rs_alu_disp1_src1_preg), .disp_src1_ready1(rs_alu_disp1_src1_ready),
    .disp_src2_preg1(rs_alu_disp1_src2_preg), .disp_src2_ready1(rs_alu_disp1_src2_ready),
    .disp_dest_preg1(needs_dest_1 ? fl_alloc_preg1 : {PREG_BITS{1'b0}}),
    .disp_rob_tag1(rob_alloc_tag1), .disp_payload1(rs_disp_payload1),
    // CDB snoop: port0 is self (ALU results waking OTHER ALU-RS entries,
    // same as Gen6-D); port1 is Gen6-E's own addition -- a load's result
    // (lsq_complete_valid && is_load) can be exactly the operand an
    // ALU-RS entry is waiting on; port2 (Gen6-F) a completed DIV/REM's
    // result.
    .cdb_valid0(issue_valid), .cdb_preg0(issue_dest_preg),
    .cdb_valid1(lsq_complete_valid && lsq_complete_is_load), .cdb_preg1(lsq_complete_dest_preg),
    .cdb_valid2(div_complete_valid), .cdb_preg2(div_complete_dest_preg),
    // Gen6-P6: RS_ALU's own operands are always integer pregs -- none of
    // RS_FALU's own float-space completions can ever matter here.
    .cdb_valid3(1'b0), .cdb_preg3({PREG_BITS{1'b0}}),
    .issue_valid(issue_valid),
    .issue_src1_preg(issue_src1_preg), .issue_src2_preg(issue_src2_preg), .issue_dest_preg(issue_dest_preg),
    .issue_rob_tag(issue_rob_tag), .issue_payload(issue_payload),
    .issue_ack(issue_valid),   // the single ALU is combinational/never
                                 // busy -- always accept the same cycle
                                 // it's offered (no backpressure needed
                                 // for this functional-unit class)
    .rs_count(rs_alu_count), .rs_full(rs_alu_full)
);

// ==========================================================================
// Gen6-E: LoadStoreQueue.v (one instance) + a real DataMemoryBRAM.v --
// see LoadStoreQueue.v's own header for this phase's explicit in-order/
// single-outstanding scope cut and the DCache-tag-reuse research finding.
// rs1 (rat_rpreg0) is always the base register (loads AND stores);
// rs2 (rat_rpreg1) is the store data source (S-type; irrelevant, and
// never consulted, for loads). imm_d/funct3_c are already correctly
// I-type/S-type decoded by the SAME ImmGen.v/Control.v this cycle's
// dispatching instruction already went through above.
// ==========================================================================
wire [PREG_BITS-1:0] lsq_head_base_preg, lsq_head_store_data_preg;
wire [XLEN-1:0]      lsq_mem_address, lsq_mem_writeData, lsq_mem_readData;
wire                 lsq_mem_memRead, lsq_mem_memWrite;
wire [2:0]           lsq_mem_funct3;
wire [$clog2(8+1)-1:0] lsq_count;   // debug visibility only
// Gen6-P2 (docs/adr/0053): see head_want_access's own port comment on
// LoadStoreQueue.v.
wire                  lsq_head_want_access, lsq_head_want_write;
wire [ROB_IDX_BITS-1:0] lsq_head_rob_tag;
wire [XLEN-1:0]       lsq_head_pc;

LoadStoreQueue #(.XLEN(XLEN), .LSQ_ENTRIES(8), .PREG_BITS(PREG_BITS), .ROB_IDX_BITS(ROB_IDX_BITS)) m_LSQ(
    .clk(clk), .rst(rst),
    .disp_en0(do_dispatch && is_mem_op), .disp_op_type0(lsq_op_type0), .disp_amo_op0(funct7_c[6:2]),
    .disp_base_preg0(rat_rpreg0), .disp_base_ready0(prf_rvalid0),
    .disp_imm0(imm_d), .disp_funct3_0(funct3_c),
    .disp_store_data_preg0(rat_rpreg1), .disp_store_data_ready0(prf_rvalid1),
    .disp_dest_preg0(needs_dest ? fl_alloc_preg0 : {PREG_BITS{1'b0}}),
    .disp_rob_tag0(rob_alloc_tag0), .disp_pc0(pc_r),
    .disp_en1(1'b0), .disp_op_type1(2'd0), .disp_amo_op1(5'd0),
    .disp_base_preg1({PREG_BITS{1'b0}}), .disp_base_ready1(1'b0),
    .disp_imm1({XLEN{1'b0}}), .disp_funct3_1(3'd0),
    .disp_store_data_preg1({PREG_BITS{1'b0}}), .disp_store_data_ready1(1'b0),
    .disp_dest_preg1({PREG_BITS{1'b0}}), .disp_rob_tag1({ROB_IDX_BITS{1'b0}}), .disp_pc1({XLEN{1'b0}}),
    // CDB snoop: port0 an ALU result (e.g. a base register computed by a
    // prior addi still in flight); port1 self (an earlier queued load's
    // own result feeding a LATER entry's base/store-data operand); port2
    // (Gen6-F) a completed DIV/REM's result.
    .cdb_valid0(issue_valid), .cdb_preg0(issue_dest_preg),
    .cdb_valid1(lsq_complete_valid && lsq_complete_is_load), .cdb_preg1(lsq_complete_dest_preg),
    .cdb_valid2(div_complete_valid), .cdb_preg2(div_complete_dest_preg),
    .head_base_preg(lsq_head_base_preg), .head_store_data_preg(lsq_head_store_data_preg),
    .mem_base_value(prf_rdata4), .mem_store_data_value(prf_rdata5),
    // Gen6-P2 (docs/adr/0053): frozen for as long as ANY walk (I-side or
    // D-side) is using the shared m_DMem port, OR the head's own address
    // hasn't finished translating yet (dtlb_stall -- forward-referenced,
    // defined in the MMU section) -- the LSQ has no visibility into
    // Ptw39/Tlb39 at all (fully standalone modules, same "wire the
    // interlock in externally" shape DataMemoryBRAM.v's own header
    // already documents for riscvpipeline.v's mem_stall), so "wait your
    // turn, and wait for translation" is enforced entirely from this
    // side. dtlb_stall alone (before ptw_busy even goes high) is what
    // catches the very first cycle of a miss -- ptw_busy alone wouldn't
    // freeze the head until a walk has actually started.
    .mem_stall_ext(ptw_busy || dtlb_stall),
    // Gen6-P2: see LoadStoreQueue.v's own force_retire_ext port comment --
    // fires exactly once, the same cycle dside_fault_pulse (MMU section)
    // reports the fault to the ROB, closing what would otherwise be a
    // permanent LSQ deadlock (a frozen head that no other mechanism can
    // ever clear once the trap has already redirected execution away).
    .force_retire_ext(dside_fault_pulse),
    .mem_memRead(lsq_mem_memRead), .mem_memWrite(lsq_mem_memWrite),
    .mem_address(lsq_mem_address), .mem_writeData(lsq_mem_writeData), .mem_funct3(lsq_mem_funct3),
    .mem_readData(lsq_mem_readData),
    .complete_valid(lsq_complete_valid), .complete_is_load(lsq_complete_is_load),
    .complete_dest_preg(lsq_complete_dest_preg), .complete_data(lsq_complete_data),
    .complete_rob_tag(lsq_complete_rob_tag),
    .head_want_access(lsq_head_want_access), .head_want_write(lsq_head_want_write),
    .head_rob_tag(lsq_head_rob_tag), .head_pc(lsq_head_pc),
    .lsq_count(lsq_count), .lsq_full(lsq_full)
);

// Gen6-N (docs/adr/0050): address-range split -- an access inside
// MAILBOX_BASE/MAILBOX_SIZE routes to the external mailbox port instead
// of this core's own private m_DMem, mirroring WbDecoder.v's own
// BASE/SIZE hit-test idiom (a single fixed range, so a plain compare is
// simpler than pulling in the general N-slave module for one slave).
// Word-only (Mailbox.v's own scope) -- lsq_mem_funct3 is NOT checked
// here, matching Mailbox.v's own "no sub-word access" scope; a real
// caller only ever uses lw/sw against this range (same discipline the
// mailbox protocol itself already requires).
wire mailbox_hit = (lsq_mem_address >= `MAILBOX_BASE) && (lsq_mem_address < `MAILBOX_BASE + `MAILBOX_SIZE);
assign mailbox_memWrite = lsq_mem_memWrite && mailbox_hit;
assign mailbox_memRead  = lsq_mem_memRead && mailbox_hit;
assign mailbox_address  = lsq_mem_address;
assign mailbox_writeData = lsq_mem_writeData;

wire [XLEN-1:0] dmem_readData;
reg             mailbox_hit_r;
always @(posedge clk) begin
    if (~rst)
        mailbox_hit_r <= 1'b0;
    else if (lsq_mem_memRead || lsq_mem_memWrite)
        mailbox_hit_r <= mailbox_hit;
end
// Registered select, matching DataMemoryBRAM.v's/Mailbox.v's own
// (port B) 1-cycle registered-read latency exactly -- the request that
// determines mailbox_hit lands this cycle, but the DATA it produces
// (from whichever memory actually served it) isn't valid until next
// cycle, so the MUX select must be captured on the same edge, not read
// combinationally off this cycle's (already-advanced) mailbox_hit.
assign lsq_mem_readData = mailbox_hit_r ? mailbox_readData : dmem_readData;

// Gen6-P2 (docs/adr/0053): m_DMem's single synchronous port, arbitrated
// between the LSQ's own ordinary traffic and Ptw39's own page-table
// reads -- ptw_busy gets exclusive access whenever a walk is in progress
// (mem_stall_ext, wired into m_LSQ above, already guarantees the LSQ
// itself never tries to issue a competing access during that same
// window, so this mux has no real contention to arbitrate, just a clean
// selector). funct3 forced to F3_LOAD_LD for the walker's own accesses
// -- Sv39 PTEs are 8 bytes; see the MMU section's own comment on why
// ptw_m_sel itself is vestigial here (same finding docs/adr/0032 P3 made
// for RamWishboneAdapter.v).
// Gen6-P2: the LSQ-side branch translates when live and hit -- same
// X-avoidance reasoning imem_phys_addr's own comment already established
// (a stale/never-filled Tlb39 entry's data fields are meaningless without
// a qualifying hit; falling back to the untranslated VA on a miss/fault/
// disabled cycle is harmless since mem_stall_ext already prevents a real
// access from ever reaching m_DMem on any of those cycles anyway).
wire [XLEN-1:0] dmem_arb_address   = ptw_busy ? ptw_m_addr :
    ((translate_enable && ls_hit) ? {ls_ppn[19:0], lsq_mem_address[11:0]} : lsq_mem_address);
wire [XLEN-1:0] dmem_arb_writeData = ptw_busy ? ptw_m_data_o : lsq_mem_writeData;
wire [2:0]      dmem_arb_funct3    = ptw_busy ? `F3_LOAD_LD  : lsq_mem_funct3;
wire            dmem_arb_memWrite  = ptw_busy ? (ptw_m_cyc && ptw_m_stb && ptw_m_we)
                                               : (lsq_mem_memWrite && !mailbox_hit);
wire            dmem_arb_memRead   = ptw_busy ? (ptw_m_cyc && ptw_m_stb && !ptw_m_we)
                                               : (lsq_mem_memRead && !mailbox_hit);
assign ptw_m_data_i = dmem_readData;

DataMemoryBRAM #(.SIZE_BYTES(DMEM_SIZE_BYTES), .XLEN(XLEN)) m_DMem(
    .clk(clk), .rst(rst),
    .memWrite(dmem_arb_memWrite), .memRead(dmem_arb_memRead),
    .address(dmem_arb_address), .writeData(dmem_arb_writeData), .funct3(dmem_arb_funct3),
    .readData(dmem_readData)
);

// ==========================================================================
// Execute: the SAME existing ALU.v this project's PIPELINED core already
// uses, fed by PRF reads at the entry ReservationStation just selected
// (issue_src1_preg/issue_src2_preg) -- by construction, both are already
// PRF-valid the cycle they're selected (RS only selects entries whose
// ready bits are set), so this is always live, never garbage, data.
// ==========================================================================
// Gen6-O: use_forced_a/use_link_b/forced_a_value sit ABOVE the original
// {ALUSrc, ALUCtl, imm} sub-layout (which keeps its own original bit
// positions unchanged, [XLEN+6:0] -- widened from [XLEN+5:0] when ALUCtl
// grew 5->6 bits, docs/adr/0060) -- see this module's own
// PAYLOAD_BITS comment for the exact layout.
// Gen7-V Phase 1: is_vsetvl sits ABOVE use_forced_a/use_link_b/
// forced_a_value (a new top bit -- every extraction below shifted down
// by 1 vs. before this phase); the {ALUSrc,ALUCtl,imm} sub-layout keeps
// its own fixed low bit positions, untouched.
wire issue_is_vsetvl       = issue_payload[PAYLOAD_BITS-1];
wire issue_use_forced_a    = issue_payload[PAYLOAD_BITS-2];
wire issue_use_link_b      = issue_payload[PAYLOAD_BITS-3];
wire [XLEN-1:0] issue_forced_a_value = issue_payload[PAYLOAD_BITS-4 -: XLEN];
wire issue_alusrc         = issue_payload[XLEN+6];  // unchanged -- fixed low-position sub-layout
wire [5:0] issue_aluctl    = issue_payload[XLEN+5 -: 6];
wire [XLEN-1:0] issue_imm  = issue_payload[XLEN-1:0];

wire [XLEN-1:0] alu_a = issue_use_forced_a ? issue_forced_a_value : prf_rdata2;
wire [XLEN-1:0] alu_b = issue_use_link_b ? {{(XLEN-3){1'b0}}, 3'd4} : (issue_alusrc ? issue_imm : prf_rdata3);
wire [XLEN-1:0] alu_out_raw;
wire alu_zero, alu_branch_zero;

ALU #(.XLEN(XLEN)) m_ALU(
    .ALUCtl(issue_aluctl), .A(alu_a), .B(alu_b), .wordOp(1'b0),
    .ALUOut(alu_out_raw), .zero(alu_zero), .branch_zero(alu_branch_zero)
);

// Gen7 Pillar V Phase 1 (docs/adr/0061): vsetvli/vsetivli's real result
// (vl = min(AVL, VLMAX), unsigned -- both alu_a/alu_b are plain unsigned
// wires here regardless of which override produced them) overrides
// ALU.v's own (harmless, discarded) computation -- ALUCtl for this op is
// whatever ALUCtrl.v happens to resolve funct3=F3_VOPCFG/ALUOp=ITYPE to
// (real encoding collision with andi's own ITYPE funct3=111, intentional
// and harmless per docs/adr/0061's own Task 4 design note -- the real
// ALU result is never used for this op).
wire [XLEN-1:0] vsetvl_min_result = (alu_a < alu_b) ? alu_a : alu_b;
wire [XLEN-1:0] alu_out = issue_is_vsetvl ? vsetvl_min_result : alu_out_raw;

// ==========================================================================
// Gen7 Pillar V Phase 1 (docs/adr/0061). Single-outstanding, same shape
// as csr_inflight_valid_r above -- dispatch of EVERYTHING stalls once a
// vsetvli/vsetivli is in flight, until it resolves, so vtype/vl can never
// change mid-flight under any other vector instruction's own decode (a
// real correctness requirement once a future phase adds vector arithmetic
// ops that read vtype/vl at dispatch time). The CSR write fires at ISSUE
// (not retire) -- mirrors csr_write_fire's own exact timing: nothing else
// can dispatch until this entry retires regardless (dispatch_stall's own
// new vec_cfg_inflight_valid_r term below), so firing the moment the real
// result (vsetvl_min_result) is known, rather than waiting an extra
// retire-latency, changes nothing observable and needs no extra latch for
// the vl VALUE itself (only the vtype-field bits, known at dispatch, need
// their own small capture below).
// ==========================================================================
reg                  vec_cfg_inflight_valid_r;
reg [ROB_IDX_BITS-1:0] vec_cfg_inflight_rob_tag_r;
reg [7:0]            vec_cfg_inflight_vtype_r;
reg                  vec_cfg_inflight_vill_r;

wire vec_cfg_write_fire = issue_valid && issue_is_vsetvl && vec_cfg_inflight_valid_r
                           && (issue_rob_tag == vec_cfg_inflight_rob_tag_r);

always @(posedge clk) begin
    if (~rst) begin
        vec_cfg_inflight_valid_r <= 1'b0;
    end
    else begin
        if (do_dispatch && is_vec_cfg) begin
            vec_cfg_inflight_valid_r   <= 1'b1;
            vec_cfg_inflight_rob_tag_r <= rob_alloc_tag0;
            vec_cfg_inflight_vtype_r   <= {vec_cfg_vma_dec, vec_cfg_vta_dec, vec_cfg_vsew_dec, vec_cfg_vlmul_dec};
            vec_cfg_inflight_vill_r    <= vec_cfg_reserved;
        end
        else if (vec_cfg_write_fire) begin
            vec_cfg_inflight_valid_r <= 1'b0;
        end
    end
end

assign vec_cfg_write_en_w  = vec_cfg_write_fire;
assign vec_cfg_new_vtype_w = vec_cfg_inflight_vill_r ? 8'd0 : vec_cfg_inflight_vtype_r;
assign vec_cfg_new_vill_w  = vec_cfg_inflight_vill_r;
assign vec_cfg_new_vl_w    = vec_cfg_inflight_vill_r ? {XLEN{1'b0}} : vsetvl_min_result;

// ==========================================================================
// Gen6-F: MUL/DIV. MUL/MULH/MULHSU/MULHU need nothing new -- ALU.v (above)
// already computes them single-cycle, so they already flow through the
// ordinary RS_ALU path. DIV/DIVU/REM/REMU get their own reservation
// station (its own functional-unit class, per the plan) + a real instance
// of the SAME multi-cycle Divider.v riscvpipeline.v already uses.
//
// `start` only needs to pulse the ONE cycle Divider.v's own FSM accepts a
// fresh operation (traced directly against Divider.v's own logic: once
// `busy<=1` fires, its `else if (busy)` branch never looks at `start`
// again) -- riscvpipeline.v happens to hold it level for its own unrelated
// reason (its single in-flight instruction sits in EX for the whole
// division), not because Divider.v itself requires it.
//
// Divider.v's own dest_preg/rob_tag are NOT still available when `done`
// eventually fires (the RS_DIV entry that carried them was already
// cleared the cycle `start` accepted it, exactly like RS_ALU's own
// instant-issue entries) -- a small in-flight register latches them the
// SAME cycle `start` fires and holds until `done`, mirroring
// LoadStoreQueue.v's own "caller needs to remember what's in flight"
// shape but for a single always-serialized (single Divider instance)
// operation rather than a queue.
// ==========================================================================
wire [PREG_BITS-1:0] issue_src1_preg_div, issue_src2_preg_div, issue_dest_preg_div;
wire [ROB_IDX_BITS-1:0] issue_rob_tag_div;
wire [1:0] issue_payload_div;   // {select_remainder, isSigned}
wire issue_valid_div;
wire [$clog2(8+1)-1:0] rs_div_count;   // debug visibility only

// RV32M funct3 encoding for this family: bit1 distinguishes DIV/DIVU(0)
// from REM/REMU(1); bit0 distinguishes signed(0) from unsigned(1).
wire div_disp_select_rem = funct3_c[1];
wire div_disp_signed     = ~funct3_c[0];

ReservationStation #(.RS_ENTRIES(8), .PREG_BITS(PREG_BITS), .ROB_IDX_BITS(ROB_IDX_BITS), .PAYLOAD_BITS(2)) m_RS_DIV(
    .clk(clk), .rst(rst),
    .disp_en0(do_dispatch && is_div_op),
    .disp_src1_preg0(rat_rpreg0), .disp_src1_ready0(prf_rvalid0),
    .disp_src2_preg0(rat_rpreg1), .disp_src2_ready0(prf_rvalid1),
    .disp_dest_preg0(needs_dest ? fl_alloc_preg0 : {PREG_BITS{1'b0}}),
    .disp_rob_tag0(rob_alloc_tag0), .disp_payload0({div_disp_select_rem, div_disp_signed}),
    .disp_en1(1'b0),
    .disp_src1_preg1({PREG_BITS{1'b0}}), .disp_src1_ready1(1'b0),
    .disp_src2_preg1({PREG_BITS{1'b0}}), .disp_src2_ready1(1'b0),
    .disp_dest_preg1({PREG_BITS{1'b0}}), .disp_rob_tag1({ROB_IDX_BITS{1'b0}}), .disp_payload1(2'd0),
    .cdb_valid0(issue_valid), .cdb_preg0(issue_dest_preg),
    .cdb_valid1(lsq_complete_valid && lsq_complete_is_load), .cdb_preg1(lsq_complete_dest_preg),
    .cdb_valid2(div_complete_valid), .cdb_preg2(div_complete_dest_preg),
    // Gen6-P6: RS_DIV's own operands are always integer pregs -- same
    // reasoning as RS_ALU's own tie-off just above.
    .cdb_valid3(1'b0), .cdb_preg3({PREG_BITS{1'b0}}),
    .issue_valid(issue_valid_div),
    .issue_src1_preg(issue_src1_preg_div), .issue_src2_preg(issue_src2_preg_div), .issue_dest_preg(issue_dest_preg_div),
    .issue_rob_tag(issue_rob_tag_div), .issue_payload(issue_payload_div),
    .issue_ack(div_start),   // only accepted the cycle Divider.v itself is free
    .rs_count(rs_div_count), .rs_full(rs_div_full)
);

wire [XLEN-1:0] prf_rdata6, prf_rdata7;   // Divider.v's own dividend/divisor read

wire div_start = issue_valid_div && !div_busy && !div_done;
wire div_busy, div_done;
wire [XLEN-1:0] div_quotient, div_remainder;

// isSigned/dividend/divisor are all fed LIVE (issue_payload_div/
// prf_rdata6/prf_rdata7 -- combinational reads of whichever entry RS_DIV
// currently has selected), never from a registered snapshot: Divider.v
// samples them at the exact edge `start` is asserted, so anything fed
// from a register that only updates the cycle AFTER div_start fires
// would be one division's data late. A real bug this phase's own
// directed test caught by running: `isSigned` was originally wired to a
// registered div_inflight_signed_r instead, which meant a division only
// picked up its OWN signed-ness once the FOLLOWING division's `start`
// overwrote it -- invisible whenever consecutive divisions shared the
// same signed-ness (this test's own div/div/rem/rem run all-signed
// first), and only surfaced once a divu (unsigned) followed a rem
// (signed): the divu silently ran as a signed division instead, using
// the still-stale bit left over from the division before it.
Divider #(.XLEN(XLEN)) m_Divider(
    .clk(clk), .rst(rst),
    .start(div_start), .isSigned(issue_payload_div[0]),
    .dividend(prf_rdata6), .divisor(prf_rdata7),
    .busy(div_busy), .done(div_done),
    .quotient(div_quotient), .remainder(div_remainder)
);

// dest_preg/rob_tag/select_remainder genuinely DO need latching (unlike
// isSigned/dividend/divisor above) -- Divider.v itself has no concept of
// them, so nothing else keeps them alive across the many cycles between
// `start` and `done`, and the RS_DIV entry that originally carried them
// is long gone (cleared the same cycle `start`/issue_ack fired).
reg [ROB_IDX_BITS-1:0] div_inflight_rob_tag_r;
reg [PREG_BITS-1:0]    div_inflight_dest_preg_r;
reg                    div_inflight_select_rem_r;
always @(posedge clk) begin
    if (rst && div_start) begin
        div_inflight_rob_tag_r    <= issue_rob_tag_div;
        div_inflight_dest_preg_r  <= issue_dest_preg_div;
        div_inflight_select_rem_r <= issue_payload_div[1];
    end
end

assign div_complete_valid     = div_done;
assign div_complete_rob_tag   = div_inflight_rob_tag_r;
assign div_complete_dest_preg = div_inflight_dest_preg_r;
assign div_complete_data      = div_inflight_select_rem_r ? div_remainder : div_quotient;

// ==========================================================================
// Gen6-P4 (docs/adr/0055): fdiv.s/fsqrt.s -- RS_FDIV + FDivider.v/FSqrt.v,
// mirroring RS_DIV/Divider.v's own proven busy/done/in-flight-latch shape
// exactly (both modules were already built for PIPELINED, reused here
// completely unmodified, same "integration, not new hardware design"
// framing docs/adr/0053 already established for Tlb39.v/Ptw39.v). ONE
// shared RS entry type for both instructions (mirrors RS_DIV's own single
// entry type serving DIV/DIVU/REM/REMU via a payload bit) -- a payload
// bit picks which of the two REAL, SEPARATE hardware units `start`s;
// fsqrt.s's own rs2 field is unused by spec (must be 0), so its own
// src2_ready is simply tied always-ready rather than waiting on an
// operand the instruction never reads.
//
// `# ponytail`-tagged scope cut, same class Gen6-H's own header already
// flagged for RS_FALU: this RS's own CDB snoop covers self (fdiv/fsqrt
// chains) + RS_ALU's + LoadStoreQueue.v's completions, but NOT RS_FALU's
// own single-cycle results -- an fdiv.s/fsqrt.s whose operand is still an
// in-flight FADD/FSUB/FMUL/FSGNJ/FMINMAX/FMV.W.X result at dispatch time
// won't wake up from THAT specific completion. Narrow, real, bounded,
// same shape as the existing RS_FALU-side gap; this phase's own directed
// test sources its fdiv/fsqrt operands from already-committed values, not
// a same-window FALU result, so it doesn't hit this either. A real 4th
// CDB port on ReservationStation.v itself (affecting every RS instance)
// is the eventual fix, real future work, not attempted here.
wire [PREG_BITS-1:0] issue_src1_preg_fdiv, issue_src2_preg_fdiv;
wire [PREG_BITS-1:0] issue_dest_preg_fdiv_wide;
wire [FPREG_BITS-1:0] issue_dest_preg_fdiv;
wire [ROB_IDX_BITS-1:0] issue_rob_tag_fdiv;
wire [3:0] issue_payload_fdiv;   // {is_sqrt, rm[2:0]}
wire issue_valid_fdiv;
wire [$clog2(8+1)-1:0] rs_fdiv_count;   // debug visibility only
wire rs_fdiv_full;

// RM_DYN resolved once, at DISPATCH time, against frm_live -- mirrors
// PIPELINED's own single fpu_rm resolution point exactly (docs/adr/0019
// Phase C8's own finding: resolving once, before the FPU, is correct and
// sufficient, no need to re-resolve at issue time since frm can't change
// while this entry sits queued the same "captured once, trusted for the
// whole in-flight duration" reasoning Gen6-P1's own AMO-RMW old-value
// capture already relies on for a different register).
wire [2:0] fdiv_disp_rm = (funct3_c == `RM_DYN) ? frm_live : funct3_c;

ReservationStation #(.RS_ENTRIES(8), .PREG_BITS(PREG_BITS), .ROB_IDX_BITS(ROB_IDX_BITS), .PAYLOAD_BITS(4)) m_RS_FDIV(
    .clk(clk), .rst(rst),
    .disp_en0(do_dispatch && is_fp_multicycle),
    .disp_src1_preg0({{(PREG_BITS-FPREG_BITS){1'b0}}, rat_f_rpreg0}), .disp_src1_ready0(prf_f_rvalid0),
    .disp_src2_preg0({{(PREG_BITS-FPREG_BITS){1'b0}}, rat_f_rpreg1}),
    .disp_src2_ready0(is_fp_sqrt ? 1'b1 : prf_f_rvalid1),
    .disp_dest_preg0({{(PREG_BITS-FPREG_BITS){1'b0}}, fl_f_alloc_preg0}),
    .disp_rob_tag0(rob_alloc_tag0), .disp_payload0({is_fp_sqrt, fdiv_disp_rm}),
    .disp_en1(1'b0),
    .disp_src1_preg1({PREG_BITS{1'b0}}), .disp_src1_ready1(1'b0),
    .disp_src2_preg1({PREG_BITS{1'b0}}), .disp_src2_ready1(1'b0),
    .disp_dest_preg1({PREG_BITS{1'b0}}), .disp_rob_tag1({ROB_IDX_BITS{1'b0}}), .disp_payload1(4'd0),
    // Gen6-P4: cdb_valid1 is falu_complete_valid, NOT lsq_complete_valid
    // (unlike every OTHER RS instance's own copy of this port) -- a real
    // bug found by running, not anticipated in the design write-up:
    // fdiv.s/fsqrt.s's own operands are ALWAYS float pregs, and flw
    // doesn't exist yet (real future work, see this section's own
    // header), so lsq_complete_valid can never possibly matter here,
    // while FMV.W.X (the only way to get a float value from an integer
    // source right now, and this phase's own directed test's exact
    // operand path) completes via RS_FALU/falu_complete_valid instead --
    // completely uncovered by any of RS_FDIV's other two ports. Without
    // this, an fdiv.s/fsqrt.s whose operand was JUST produced by FMV.W.X
    // (dispatched too soon after it for the value to already be PRF-valid
    // at dispatch time) would never wake up, a genuine permanent
    // deadlock -- observed directly via cycle-by-cycle tracing of
    // fdiv_start/fsqrt_busy/rob_retire_valid0 (both f3 and f4 stuck at
    // their own reset-default identity preg mapping, never renamed),
    // root-caused before guessing at a fix.
    .cdb_valid0(issue_valid), .cdb_preg0(issue_dest_preg),
    .cdb_valid1(falu_complete_valid), .cdb_preg1({{(PREG_BITS-FPREG_BITS){1'b0}}, falu_complete_dest_preg}),
    .cdb_valid2(fdiv_complete_valid), .cdb_preg2({{(PREG_BITS-FPREG_BITS){1'b0}}, fdiv_complete_dest_preg}),
    // Gen6-P6: already covers self (port2) and RS_FALU (port1, the P4 fix
    // just above) -- nothing else can produce a float-space value RS_FDIV's
    // own operands could depend on.
    .cdb_valid3(1'b0), .cdb_preg3({PREG_BITS{1'b0}}),
    .issue_valid(issue_valid_fdiv),
    .issue_src1_preg(issue_src1_preg_fdiv), .issue_src2_preg(issue_src2_preg_fdiv), .issue_dest_preg(issue_dest_preg_fdiv_wide),
    .issue_rob_tag(issue_rob_tag_fdiv), .issue_payload(issue_payload_fdiv),
    .issue_ack(fdiv_start),   // only accepted the cycle BOTH units are free
    .rs_count(rs_fdiv_count), .rs_full(rs_fdiv_full)
);
assign issue_dest_preg_fdiv = issue_dest_preg_fdiv_wide[FPREG_BITS-1:0];

wire issue_fdiv_is_sqrt = issue_payload_fdiv[3];
wire [2:0] issue_fdiv_rm = issue_payload_fdiv[2:0];

wire [FLEN-1:0] prf_f_rdata4, prf_f_rdata5;   // FDivider.v's/FSqrt.v's own operand read, issue-time

// Real, genuinely separate hardware units (not one module with an
// internal mode bit) -- `start` is mutually exclusive by construction
// (issue_fdiv_is_sqrt picks exactly one), so busy/done/result/flags mux
// cleanly on the SAME registered selector bit the in-flight latch below
// already needs to keep alive regardless.
wire fdiv_start = issue_valid_fdiv && !fdivider_busy && !fdivider_done && !fsqrt_busy && !fsqrt_done;
wire fdivider_busy, fdivider_done;
wire [FLEN-1:0] fdivider_result;
wire [4:0] fdivider_flags;
wire fsqrt_busy, fsqrt_done;
wire [FLEN-1:0] fsqrt_result;
wire [4:0] fsqrt_flags;

FDivider #(.XLEN(FLEN)) m_FDivider(
    .clk(clk), .rst(rst),
    .start(fdiv_start && !issue_fdiv_is_sqrt), .rm(issue_fdiv_rm),
    .a(prf_f_rdata4), .b(prf_f_rdata5),
    .busy(fdivider_busy), .done(fdivider_done),
    .result(fdivider_result), .flags(fdivider_flags)
);

FSqrt #(.XLEN(FLEN)) m_FSqrt(
    .clk(clk), .rst(rst),
    .start(fdiv_start && issue_fdiv_is_sqrt), .rm(issue_fdiv_rm),
    .a(prf_f_rdata4),
    .busy(fsqrt_busy), .done(fsqrt_done),
    .result(fsqrt_result), .flags(fsqrt_flags)
);

wire fdiv_busy = fdivider_busy || fsqrt_busy;
wire fdiv_done = fdivider_done || fsqrt_done;

// dest_preg/rob_tag/is_sqrt genuinely DO need latching -- same reasoning
// div_inflight_*_r's own comment already gives: neither FDivider.v nor
// FSqrt.v has any concept of them, and the RS_FDIV entry that originally
// carried them is long gone (cleared the same cycle issue_ack fired).
// is_sqrt IS safe to latch (unlike Divider.v's own isSigned bug class)
// since it's only ever consumed AFTER done, to pick which unit's result/
// flags to read -- never fed live into either unit's own combinational
// input path the way isSigned/dividend/divisor need to be.
reg [ROB_IDX_BITS-1:0] fdiv_inflight_rob_tag_r;
reg [FPREG_BITS-1:0]   fdiv_inflight_dest_preg_r;
reg                    fdiv_inflight_is_sqrt_r;
always @(posedge clk) begin
    if (rst && fdiv_start) begin
        fdiv_inflight_rob_tag_r   <= issue_rob_tag_fdiv;
        fdiv_inflight_dest_preg_r <= issue_dest_preg_fdiv;
        fdiv_inflight_is_sqrt_r   <= issue_fdiv_is_sqrt;
    end
end

wire                    fdiv_complete_valid;
wire [FPREG_BITS-1:0]   fdiv_complete_dest_preg;
wire [FLEN-1:0]         fdiv_complete_data;
wire [ROB_IDX_BITS-1:0] fdiv_complete_rob_tag;
assign fdiv_complete_valid     = fdiv_done;
assign fdiv_complete_rob_tag   = fdiv_inflight_rob_tag_r;
assign fdiv_complete_dest_preg = fdiv_inflight_dest_preg_r;
assign fdiv_complete_data      = fdiv_inflight_is_sqrt_r ? fsqrt_result : fdivider_result;

// ==========================================================================
// Gen6-H: RS_FALU + the SAME existing FALU.v this project's PIPELINED
// core already uses -- single-cycle, exactly like RS_ALU/ALU.v, no
// in-flight tracking needed (unlike Divider.v).
//
// `# ponytail`-tagged scope cut: RS_FALU's own CDB snoop covers self
// (float-to-float chains) + RS_ALU's + Divider.v's completions (so
// FMV.W.X's own integer source can wake up if it's still an in-flight
// ALU/DIV result at dispatch time) but NOT LoadStoreQueue.v's -- a 4th
// snoop port would need ReservationStation.v itself widened from 3 to 4
// CDB ports for every instance, not just this one. Narrow, real,
// bounded: an FMV.W.X whose integer source is still an outstanding LOAD
// at dispatch time won't wake up when that load completes. This phase's
// own directed test doesn't hit it (sources its FMV.W.X operand from an
// already-committed/ALU-computed register, never directly from a fresh
// load) -- flagged as real future work alongside FLW/FSW themselves,
// which need LSQ float-awareness regardless.
wire [PREG_BITS-1:0] issue_src1_preg_falu, issue_src2_preg_falu;
wire [PREG_BITS-1:0] issue_dest_preg_falu_wide;
wire [FPREG_BITS-1:0] issue_dest_preg_falu;
wire [ROB_IDX_BITS-1:0] issue_rob_tag_falu;
wire [13:0] issue_payload_falu;   // {is_intmove, funct5[4:0], funct3[2:0], rs2sel[4:0]}
wire issue_valid_falu;
wire [$clog2(RS_FALU_ENTRIES+1)-1:0] rs_falu_count;

wire [PREG_BITS-1:0]  falu_disp_src1_preg = is_fp_intmove ? rat_rpreg0 : {{(PREG_BITS-FPREG_BITS){1'b0}}, rat_f_rpreg0};
wire                  falu_disp_src1_ready = is_fp_intmove ? prf_rvalid0 : prf_f_rvalid0;
wire [13:0]           falu_disp_payload = {is_fp_intmove, fp_funct5, funct3_c, rs2_areg};

ReservationStation #(.RS_ENTRIES(RS_FALU_ENTRIES), .PREG_BITS(PREG_BITS), .ROB_IDX_BITS(ROB_IDX_BITS), .PAYLOAD_BITS(14)) m_RS_FALU(
    .clk(clk), .rst(rst),
    // Gen6-P4: excludes is_fp_multicycle -- fdiv.s/fsqrt.s route to
    // RS_FDIV instead (below), never RS_FALU.
    .disp_en0(do_dispatch && is_fp_op && !is_fp_multicycle),
    .disp_src1_preg0(falu_disp_src1_preg), .disp_src1_ready0(falu_disp_src1_ready),
    .disp_src2_preg0({{(PREG_BITS-FPREG_BITS){1'b0}}, rat_f_rpreg1}), .disp_src2_ready0(is_fp_intmove ? 1'b1 : prf_f_rvalid1),
    .disp_dest_preg0({{(PREG_BITS-FPREG_BITS){1'b0}}, fl_f_alloc_preg0}),
    .disp_rob_tag0(rob_alloc_tag0), .disp_payload0(falu_disp_payload),
    .disp_en1(1'b0),
    .disp_src1_preg1({PREG_BITS{1'b0}}), .disp_src1_ready1(1'b0),
    .disp_src2_preg1({PREG_BITS{1'b0}}), .disp_src2_ready1(1'b0),
    .disp_dest_preg1({PREG_BITS{1'b0}}), .disp_rob_tag1({ROB_IDX_BITS{1'b0}}), .disp_payload1(14'd0),
    .cdb_valid0(falu_complete_valid), .cdb_preg0({{(PREG_BITS-FPREG_BITS){1'b0}}, falu_complete_dest_preg}),
    .cdb_valid1(issue_valid), .cdb_preg1(issue_dest_preg),
    .cdb_valid2(div_complete_valid), .cdb_preg2(div_complete_dest_preg),
    // Gen6-P6 (docs/adr/0057): the real fix -- a genuine hang found by
    // running the widened ooo fuzzer (docs/adr/0057's own second real
    // finding), root-caused by direct dispatch/retire tracing: an
    // ordinary FALU op (e.g. fmin.s) depending on a still-in-flight
    // FDIV/FSQRT result had no CDB port here that would EVER wake it,
    // permanently stuck (RS_FALU's other 3 ports were all already
    // spoken for by real, still-needed coverage -- self, ALU-for-FMV.W.X,
    // DIV-for-FMV.W.X -- see ReservationStation.v's own new cdb_valid3
    // header for why this needed a genuine 4th port rather than
    // displacing one of the existing three). Exactly the reverse-
    // direction gap docs/adr/0055's own Future improvements section
    // already flagged as "the eventual, correct fix" -- now real.
    .cdb_valid3(fdiv_complete_valid), .cdb_preg3({{(PREG_BITS-FPREG_BITS){1'b0}}, fdiv_complete_dest_preg}),
    .issue_valid(issue_valid_falu),
    .issue_src1_preg(issue_src1_preg_falu), .issue_src2_preg(issue_src2_preg_falu),
    .issue_dest_preg(issue_dest_preg_falu_wide), .issue_rob_tag(issue_rob_tag_falu), .issue_payload(issue_payload_falu),
    .issue_ack(issue_valid_falu),   // FALU.v is combinational/never busy
    .rs_count(rs_falu_count), .rs_full(rs_falu_full)
);
assign issue_dest_preg_falu = issue_dest_preg_falu_wide[FPREG_BITS-1:0];

wire                falu_issue_is_intmove = issue_payload_falu[13];
wire [4:0]          falu_issue_funct5     = issue_payload_falu[12:8];
wire [2:0]          falu_issue_funct3     = issue_payload_falu[7:5];
wire [4:0]          falu_issue_rs2sel     = issue_payload_falu[4:0];

wire [XLEN-1:0] prf_rdata8;   // FMV.W.X's own integer source, issue-time
wire [FLEN-1:0] prf_f_rdata2, prf_f_rdata3;
wire [FLEN-1:0] falu_a = falu_issue_is_intmove ? prf_rdata8[FLEN-1:0] : prf_f_rdata2;
wire [FLEN-1:0] falu_b = prf_f_rdata3;
wire [FLEN-1:0] falu_result;
wire [4:0] falu_flags;

FALU m_FALU(
    .funct5(falu_issue_funct5), .funct3(falu_issue_funct3), .rs2_sel(falu_issue_rs2sel),
    .a(falu_a), .b(falu_b),
    .result(falu_result), .flags(falu_flags)
);

assign falu_complete_valid     = issue_valid_falu;
assign falu_complete_rob_tag   = issue_rob_tag_falu;
assign falu_complete_dest_preg = issue_dest_preg_falu;
assign falu_complete_data      = falu_result;

wire [FLEN-1:0] prf_f_rdata0, prf_f_rdata1;
wire            prf_f_rvalid0, prf_f_rvalid1;

PhysicalRegisterFile #(.XLEN(FLEN), .NUM_PREGS(NUM_FPREGS), .NUM_AREGS(NUM_FREGS), .HARDWIRE_PREG0(0), .SP_INIT(0)) m_PRF_Float(
    .clk(clk), .rst(rst),
    // Port 0/1: dispatch-time readiness query. Port 2/3: RS_FALU's own
    // issue-time operand fetch. Port 4/5 (Gen6-P4): RS_FDIV's own
    // issue-time operand fetch (FDivider.v's dividend/divisor, or
    // FSqrt.v's single radicand via port 4 alone).
    .raddr0(rat_f_rpreg0), .raddr1(rat_f_rpreg1),
    .raddr2(issue_src1_preg_falu[FPREG_BITS-1:0]), .raddr3(issue_src2_preg_falu[FPREG_BITS-1:0]),
    .raddr4(issue_src1_preg_fdiv[FPREG_BITS-1:0]), .raddr5(issue_src2_preg_fdiv[FPREG_BITS-1:0]),
    .raddr6({FPREG_BITS{1'b0}}), .raddr7({FPREG_BITS{1'b0}}), .raddr8({FPREG_BITS{1'b0}}),
    // Gen6-K never dual-issues FP (slot1_is_plain_alu excludes is_fp_op_1
    // by construction) -- ports 9/10 are simply tied off here.
    .raddr9({FPREG_BITS{1'b0}}), .raddr10({FPREG_BITS{1'b0}}),
    .rdata0(prf_f_rdata0), .rdata1(prf_f_rdata1), .rdata2(prf_f_rdata2), .rdata3(prf_f_rdata3),
    .rdata4(prf_f_rdata4), .rdata5(prf_f_rdata5), .rdata6(), .rdata7(), .rdata8(), .rdata9(), .rdata10(),
    .rvalid0(prf_f_rvalid0), .rvalid1(prf_f_rvalid1), .rvalid2(), .rvalid3(), .rvalid4(), .rvalid5(), .rvalid6(), .rvalid7(), .rvalid8(), .rvalid9(), .rvalid10(),
    // CDB writeback -- port0 FALU's own instant result; port1 (Gen6-P4)
    // FDivider.v's/FSqrt.v's own multi-cycle completion (no FMADD/FLW
    // yet, so port2 stays tied off).
    .wen0(falu_complete_valid), .waddr0(falu_complete_dest_preg), .wdata0(falu_complete_data),
    .wen1(fdiv_complete_valid), .waddr1(fdiv_complete_dest_preg), .wdata1(fdiv_complete_data),
    .wen2(1'b0), .waddr2({FPREG_BITS{1'b0}}), .wdata2({FLEN{1'b0}}),
    .alloc_en0(do_dispatch && is_fp_op), .alloc_preg0(fl_f_alloc_preg0),
    .alloc_en1(1'b0), .alloc_preg1({FPREG_BITS{1'b0}})
);

wire [XLEN-1:0] prf_rdata4, prf_rdata5;
wire            prf_rvalid9, prf_rvalid10;

PhysicalRegisterFile #(.XLEN(XLEN), .NUM_PREGS(NUM_PREGS), .NUM_AREGS(NUM_AREGS), .SP_INIT(SP_INIT)) m_PRF(
    .clk(clk), .rst(rst),
    // Port 0/1: dispatch-time readiness query for THIS cycle's
    // dispatching instruction. Port 2/3: issue-time operand VALUE fetch
    // for whichever entry RS_ALU just selected. Port 4/5 (Gen6-E): the
    // LSQ's own head-entry base/store-data value fetch. Port 6/7
    // (Gen6-F): Divider.v's own dividend/divisor fetch for whichever
    // entry RS_DIV just selected. Port 8 (Gen6-H): FMV.W.X's own
    // integer source, issue-time, for whichever entry RS_FALU selected.
    // Port 9/10 (Gen6-K): dispatch-time readiness query for slot1's own
    // rs1/rs2 -- only the READY bit is used (rs_alu_disp1_src1/2_ready
    // above); the VALUE isn't needed at dispatch time, only later at
    // issue via the existing port 2/3 (whichever entry RS_ALU selects,
    // regardless of which slot originally dispatched it).
    .raddr0(rat_rpreg0), .raddr1(rat_rpreg1),
    .raddr2(issue_src1_preg), .raddr3(issue_src2_preg),
    .raddr4(lsq_head_base_preg), .raddr5(lsq_head_store_data_preg),
    .raddr6(issue_src1_preg_div), .raddr7(issue_src2_preg_div),
    .raddr8(issue_src1_preg_falu),
    .raddr9(rat_rpreg2), .raddr10(rat_rpreg3),
    .rdata0(prf_rdata0), .rdata1(prf_rdata1), .rdata2(prf_rdata2), .rdata3(prf_rdata3),
    .rdata4(prf_rdata4), .rdata5(prf_rdata5), .rdata6(prf_rdata6), .rdata7(prf_rdata7),
    .rdata8(prf_rdata8), .rdata9(), .rdata10(),
    .rvalid0(prf_rvalid0), .rvalid1(prf_rvalid1), .rvalid2(), .rvalid3(), .rvalid4(), .rvalid5(), .rvalid6(), .rvalid7(), .rvalid8(),
    .rvalid9(prf_rvalid9), .rvalid10(prf_rvalid10),
    // CDB writeback -- port0 the ALU's own result (single-cycle execute,
    // no latency); port1 (Gen6-E) a completed LOAD's result (a store has
    // no destination register, so lsq_complete_is_load gates this);
    // port2 (Gen6-F) a completed DIV/REM's result. (RS_FALU's own
    // results never target this, integer, PRF in this phase's scope.)
    .wen0(issue_valid), .waddr0(issue_dest_preg), .wdata0(alu_out),
    .wen1(lsq_complete_valid && lsq_complete_is_load), .waddr1(lsq_complete_dest_preg), .wdata1(lsq_complete_data),
    .wen2(div_complete_valid), .waddr2(div_complete_dest_preg), .wdata2(div_complete_data),
    // Rename allocation -- clears valid for the fresh preg(s) THIS
    // cycle's dispatching instruction(s) claim (if any). Gen6-K wires
    // alloc_en1/alloc_preg1 (already present on this module, previously
    // tied off) to slot1's own allocation.
    .alloc_en0(do_dispatch && needs_dest), .alloc_preg0(fl_alloc_preg0),
    .alloc_en1(do_dispatch_slot1 && needs_dest_1), .alloc_preg1(fl_alloc_preg1)
);

// ==========================================================================
// Fetch advance: single-issue, sequential PC, now with Gen6-G's own
// speculative redirect. Priority: a mispredict recovery (br_resolve &&
// br_mispredict) always wins -- it can only ever fire when do_dispatch is
// already guaranteed 0 this same cycle (br_inflight_valid_r, still its
// pre-edge 1, is folded into dispatch_stall above), so there's no real
// same-cycle conflict between the two branches below, just defensive
// ordering. A resource-exhaustion stall (dispatch_stall, including the
// single-outstanding-branch stall) holds PC and re-fetches/re-decodes the
// identical instruction next cycle instead (safe: nothing about fetch/
// decode has side effects on its own, only actually asserted dispatch/
// alloc pulses matter) -- this is also exactly what happens while a
// branch is in flight and CORRECTLY predicted: nothing here needs to redo
// anything once br_inflight_valid_r drops, since pc_r already sits at the
// right place from when the branch itself dispatched.
// ==========================================================================
always @(posedge clk) begin
    if (~rst)
        pc_r <= {XLEN{1'b0}};
    else if (interrupt_take)   // Gen6-P3 (docs/adr/0054): highest priority
                                 // of all -- genuinely independent of
                                 // trap_resolve (interrupt_take fires with
                                 // rob_empty, NOT tied to any retiring
                                 // rob_tag), so it needs its own arm here;
                                 // falling through to trap_resolve's own
                                 // branch below would never trigger for a
                                 // pure interrupt (nothing is retiring),
                                 // silently leaving pc_r frozen forever.
        pc_r <= csr_mtvec_val;
    else if (trap_resolve)   // Gen6-I: highest priority -- an exception/
                               // mret retiring always redirects, same
                               // "can't coincide with do_dispatch" argument
                               // as br_resolve's own (trap_inflight_valid_r
                               // is also folded into dispatch_stall)
        pc_r <= csr_trap_taken ? csr_mtvec_val : csr_mepc_val;
    else if (br_resolve && br_mispredict)
        pc_r <= br_correct_target;
    else if (jr_resolve && jr_mispredict)   // Gen6-P5: only redirects on a
                                              // genuine misprediction now
                                              // -- same "can't coincide
                                              // with do_dispatch" argument
                                              // as br_resolve/trap_resolve's
                                              // own (jr_inflight_valid_r is
                                              // folded into dispatch_stall
                                              // too). A CORRECT prediction
                                              // needs no action here: pc_r
                                              // already sits at jr_target
                                              // (written at DISPATCH time
                                              // now, below), same "correct
                                              // prediction -> no redirect
                                              // needed" shape br_resolve's
                                              // own br_mispredict gate
                                              // already established.
        pc_r <= jr_target;
    else if (do_dispatch)
        // Gen6-K: do_dispatch_slot1 only ever fires alongside try_dual_issue,
        // which by construction excludes is_branch/is_jal/is_jalr/is_csr
        // (slot0_is_plain_alu) -- so none of these arms ever actually
        // compete for the same cycle. Gen6-O3: is_jal's own target is
        // known unconditionally at decode (pc_r + the J-type immediate,
        // <<1 same as branch targets -- ImmGen.v's own J-type case
        // deliberately outputs the pre-shift value, see br_inflight_imm_r's
        // own identical comment above) -- no prediction needed, this is
        // always correct, unlike is_branch's own predicted_target.
        // Gen6-P5: is_jalr's own predicted target (jr_predicted_target,
        // the SAME value just latched into jr_inflight_predicted_target_r
        // above) speculatively redirects pc_r immediately, mirroring
        // is_branch's own predicted_target arm exactly.
        pc_r <= is_jal ? (pc_r + (imm_d << 1)) :
                is_jalr ? jr_predicted_target :
                (is_branch && predicted_taken) ? predicted_target :
                (do_dispatch_slot1 ? (pc_r + 8) : (pc_r + 4));
end

endmodule

`default_nettype wire
