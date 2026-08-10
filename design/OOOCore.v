`default_nettype none

`include "riscv_defs.vh"

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

    parameter AREG_BITS  = $clog2(NUM_AREGS),
    parameter PREG_BITS  = $clog2(NUM_PREGS),
    parameter FAREG_BITS = $clog2(NUM_FREGS),
    parameter FPREG_BITS = $clog2(NUM_FPREGS),
    parameter ROB_IDX_BITS = $clog2(ROB_ENTRIES),
    // Reservation-station payload: {ALUSrc, ALUCtl[4:0], imm[XLEN-1:0]}.
    // ALUSrc tells the execute step whether operand B is the decoded
    // immediate (I-type) or PhysicalRegisterFile's own src2 read
    // (R-type) -- see the execute section below.
    parameter PAYLOAD_BITS = 1 + 5 + XLEN
)(
    input wire clk,
    input wire rst    // active-low, same convention as every other
                        // module in this project (Register.v, DCache.v, ...)
);

// ==========================================================================
// Fetch (combinational read at pc_r; no cache/MMU yet -- Gen6-D scope)
// ==========================================================================
reg [XLEN-1:0] pc_r;

wire [XLEN-1:0] inst_full;
InstructionMemory #(.INIT_FILE(IMEM_INIT_FILE), .SIZE_BYTES(IMEM_SIZE_BYTES), .XLEN(XLEN)) m_IMem(
    .readAddr(pc_r),
    .inst(inst_full)
);
wire [31:0] inst_word = inst_full[31:0];   // instructions are always a
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
    .illegalOpcode(illegalOpcode_c), .fRegWrite(fRegWrite_c)
);

wire [4:0] ALUCtl_d;
ALUCtrl m_ALUCtrl(.ALUOp(ALUOp_c), .funct7_c(funct7_c), .funct3_c(funct3_c), .ALUCtl(ALUCtl_d));

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
// `# ponytail`-tagged scope cut: only LR is real this phase. SC.W/SC.D
// need a store PLUS a hardcoded rd=0 success write that doesn't come
// from memory at all (this LSQ has no concept of "a store that also
// writes an unrelated integer destination") -- a real LSQ interface
// change. The general AMOADD/AMOSWAP/etc. read-modify-write family needs
// real 2-phase sequencing (read old value -> compute new -> write new),
// its own in-flight state machine comparable to Divider.v's, interleaving
// an LSQ round trip with an ALU computation. Both are real, flagged
// future work -- this core's own single-hart simplification (every AMO
// is trivially atomic, no other hart can ever contend, ADR 0038's own
// finding) still applies whenever they're eventually built, same as it
// already does for LR here.
wire is_amo_lr = isAmo_c && (funct7_c[6:2] == `AMO_F5_LR);
wire is_mem_op  = memRead_c || memWrite_c || is_amo_lr;
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
wire is_trap_related = has_exception || isMret_c;

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
wire is_fp_op = is_fp_pure || is_fp_intmove;

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
Btb #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Btb(
    .clk(clk), .rst(rst),
    .query_pc(pc_r), .hit(btb_hit), .target(btb_target),
    .update_valid(br_resolve && br_actual_taken), .update_pc(br_inflight_pc_r), .update_target(br_actual_target)
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
    .illegalOpcode(illegalOpcode_c_1), .fRegWrite(fRegWrite_c_1)
);

wire [4:0] ALUCtl_d_1;
ALUCtrl m_ALUCtrl_1(.ALUOp(ALUOp_c_1), .funct7_c(funct7_c_1), .funct3_c(funct3_c_1), .ALUCtl(ALUCtl_d_1));

wire [XLEN-1:0] imm_d_1;
ImmGen #(.Width(XLEN)) m_ImmGen_1(.inst(inst_full1), .imm(imm_d_1));

wire needs_dest_1  = regWrite_c_1 && (rd_areg_1 != 5'd0);
wire is_amo_lr_1   = isAmo_c_1 && (funct7_c_1[6:2] == `AMO_F5_LR);
wire is_mem_op_1   = memRead_c_1 || memWrite_c_1 || is_amo_lr_1;
wire is_div_op_1   = (ALUCtl_d_1 == `ALUCTL_DIV) || (ALUCtl_d_1 == `ALUCTL_DIVU) ||
                     (ALUCtl_d_1 == `ALUCTL_REM) || (ALUCtl_d_1 == `ALUCTL_REMU);
wire is_branch_1   = branch_c_1;
wire has_exception_1 = illegalOpcode_c_1 || isEcall_c_1;
wire is_trap_related_1 = has_exception_1 || isMret_c_1;
wire [4:0] fp_funct5_1 = funct7_c_1[6:2];
wire is_fp_op_1 = fRegWrite_c_1 && (
    fp_funct5_1 == `FUNCT5_FADD || fp_funct5_1 == `FUNCT5_FSUB || fp_funct5_1 == `FUNCT5_FMUL ||
    fp_funct5_1 == `FUNCT5_FSGNJ || fp_funct5_1 == `FUNCT5_FMINMAX || fp_funct5_1 == `FUNCT5_FMV_W_X
);

// Both slots must be plain ALU (regWrite integer OP/OP-IMM, no other
// side effects) for dual-issue to even be considered this cycle.
wire slot0_is_plain_alu = !is_mem_op && !is_div_op && !is_fp_op && !is_branch && !is_trap_related;
wire slot1_is_plain_alu = !is_mem_op_1 && !is_div_op_1 && !is_fp_op_1 && !is_branch_1 && !is_trap_related_1;
wire try_dual_issue = slot0_is_plain_alu && slot1_is_plain_alu;

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
                      || (is_mem_op ? lsq_full : (is_div_op ? rs_div_full : (is_fp_op ? rs_falu_full : rs_alu_full)))
                      || (needs_dest && !fl_alloc_ok0)
                      || (is_fp_op && !fl_f_alloc_ok0)   // Gen6-H
                      || br_inflight_valid_r    // Gen6-G: single-outstanding-
                                                  // branch scope cut, see the
                                                  // branch-speculation
                                                  // section's own header
                                                  // comment
                      || trap_inflight_valid_r;  // Gen6-I: same scope cut,
                                                  // for exceptions/mret
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
    .free_en0(rob_retire_valid0 && rob_retire_has_dest0 && !rob_retire_is_fp_dest0), .free_preg0(rob_retire_old_preg0),
    .free_en1(rob_retire_valid1 && rob_retire_has_dest1 && !rob_retire_is_fp_dest1), .free_preg1(rob_retire_old_preg1),
    .free_count(fl_free_count)
);

RegisterAliasTable #(.NUM_AREGS(NUM_AREGS), .NUM_PREGS(NUM_PREGS)) m_RAT(
    .clk(clk), .rst(rst),
    .raddr0(rs1_areg), .raddr1(rs2_areg), .raddr2(rs1_areg_1), .raddr3(rs2_areg_1),
    .rpreg0(rat_rpreg0), .rpreg1(rat_rpreg1), .rpreg2(rat_rpreg2), .rpreg3(rat_rpreg3),
    .wen0(do_dispatch && needs_dest), .waddr0(rd_areg), .wpreg0(fl_alloc_preg0), .old_preg0(rat_old_preg0),
    .wen1(do_dispatch_slot1 && needs_dest_1), .waddr1(rd_areg_1), .wpreg1(fl_alloc_preg1), .old_preg1(rat_old_preg1),
    .cwen0(rob_retire_valid0 && rob_retire_has_dest0 && !rob_retire_is_fp_dest0), .cwaddr0(rob_retire_areg0), .cwpreg0(rob_retire_preg0),
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
    .complete_en1(lsq_complete_valid), .complete_tag1(lsq_complete_rob_tag),
    .complete_en2(div_complete_valid), .complete_tag2(div_complete_rob_tag),
    .complete_en3(falu_complete_valid), .complete_tag3(falu_complete_rob_tag),
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

wire trap_resolve = rob_retire_valid0 && trap_inflight_valid_r && (rob_retire_tag0 == trap_inflight_rob_tag_r);
wire csr_trap_taken = trap_resolve && !trap_inflight_is_mret_r;
wire csr_mret_taken = trap_resolve && trap_inflight_is_mret_r;

always @(posedge clk) begin
    if (~rst) begin
        trap_inflight_valid_r <= 1'b0;
    end
    else begin
        if (do_dispatch && is_trap_related) begin
            trap_inflight_valid_r   <= 1'b1;
            trap_inflight_is_mret_r <= isMret_c;
            trap_inflight_pc_r      <= pc_r;
            trap_inflight_cause_r   <= isEcall_c ? `MCAUSE_ECALL_FROM_M : `MCAUSE_ILLEGAL_INSTRUCTION;
            trap_inflight_rob_tag_r <= rob_alloc_tag0;
        end
        else if (trap_resolve) begin
            trap_inflight_valid_r <= 1'b0;
        end
    end
end

wire [XLEN-1:0] csr_mtvec_val, csr_mepc_val;

// Every HPC/performance-counter pulse input and every S-mode/MMU-only
// output is tied off/left open this phase -- CSR read/write instructions
// (csrrw/csrrs/csrrc) themselves aren't dispatched/executed yet either
// (csr_write_en permanently 0); only the trap-entry/mret machinery is
// live. Real future work alongside the MMU/interrupts noted above.
CSR #(.XLEN(XLEN)) m_CSR(
    .clk(clk), .rst(rst),
    .csr_write_en(1'b0), .csr_addr(12'd0), .csr_op(2'd0), .csr_wdata({XLEN{1'b0}}), .csr_rdata(),
    .trap_taken(csr_trap_taken), .trap_pc(trap_inflight_pc_r),
    .trap_cause({{(XLEN-32){1'b0}}, trap_inflight_cause_r}), .trap_is_interrupt(1'b0),
    .trap_value({XLEN{1'b0}}),
    .mret_taken(csr_mret_taken), .sret_taken(1'b0),
    .fp_flags_we(1'b0), .fp_flags_in(5'd0), .frm_val(),
    .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0),
    .mstatus_mie(), .mie_msie(), .mie_mtie(), .mie_meie(),
    .mie_ssie(), .mie_stie(), .mip_ssip(), .mip_stip(),
    .mstatus_mpie(), .mstatus_sie(), .mstatus_spie(), .mstatus_spp(), .mstatus_mpp(),
    .mtvec_val(csr_mtvec_val), .mepc_val(csr_mepc_val),
    .priv_mode_val(), .stvec_val(), .sepc_val(), .trap_target_is_s(),
    .satp_mode_val(), .satp_ppn_val(),
    .instret_pulse(1'b0), .branch_retired_pulse(1'b0), .mispredict_pulse(1'b0),
    .icache_hit_pulse(1'b0), .icache_miss_pulse(1'b0), .dcache_hit_pulse(1'b0), .dcache_miss_pulse(1'b0),
    .stall_cycle_pulse(1'b0), .interrupt_pulse(1'b0), .exception_pulse(1'b0),
    .stall_hazard_pulse(1'b0), .stall_div_pulse(1'b0), .stall_mem_pulse(1'b0), .stall_fp_pulse(1'b0),
    .stall_float_lu_pulse(1'b0), .stall_itlb_pulse(1'b0), .stall_dtlb_pulse(1'b0),
    .stall_icache_pulse(1'b0), .stall_imem_wait_pulse(1'b0)
);

// Dispatch-time readiness query -- rs1/rs2's CURRENT physical tags
// (rat_rpreg0/1, from the SAME-cycle RAT read above, still the
// pre-rename mapping) queried against PRF's own rvalid.
wire [PAYLOAD_BITS-1:0] rs_disp_payload0 = {ALUSrc_c, ALUCtl_d, imm_d};

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
wire [PAYLOAD_BITS-1:0] rs_disp_payload1 = {ALUSrc_c_1, ALUCtl_d_1, imm_d_1};

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

LoadStoreQueue #(.XLEN(XLEN), .LSQ_ENTRIES(8), .PREG_BITS(PREG_BITS), .ROB_IDX_BITS(ROB_IDX_BITS)) m_LSQ(
    .clk(clk), .rst(rst),
    .disp_en0(do_dispatch && is_mem_op), .disp_is_store0(memWrite_c),
    .disp_base_preg0(rat_rpreg0), .disp_base_ready0(prf_rvalid0),
    .disp_imm0(imm_d), .disp_funct3_0(funct3_c),
    .disp_store_data_preg0(rat_rpreg1), .disp_store_data_ready0(prf_rvalid1),
    .disp_dest_preg0(needs_dest ? fl_alloc_preg0 : {PREG_BITS{1'b0}}),
    .disp_rob_tag0(rob_alloc_tag0),
    .disp_en1(1'b0), .disp_is_store1(1'b0),
    .disp_base_preg1({PREG_BITS{1'b0}}), .disp_base_ready1(1'b0),
    .disp_imm1({XLEN{1'b0}}), .disp_funct3_1(3'd0),
    .disp_store_data_preg1({PREG_BITS{1'b0}}), .disp_store_data_ready1(1'b0),
    .disp_dest_preg1({PREG_BITS{1'b0}}), .disp_rob_tag1({ROB_IDX_BITS{1'b0}}),
    // CDB snoop: port0 an ALU result (e.g. a base register computed by a
    // prior addi still in flight); port1 self (an earlier queued load's
    // own result feeding a LATER entry's base/store-data operand); port2
    // (Gen6-F) a completed DIV/REM's result.
    .cdb_valid0(issue_valid), .cdb_preg0(issue_dest_preg),
    .cdb_valid1(lsq_complete_valid && lsq_complete_is_load), .cdb_preg1(lsq_complete_dest_preg),
    .cdb_valid2(div_complete_valid), .cdb_preg2(div_complete_dest_preg),
    .head_base_preg(lsq_head_base_preg), .head_store_data_preg(lsq_head_store_data_preg),
    .mem_base_value(prf_rdata4), .mem_store_data_value(prf_rdata5),
    .mem_memRead(lsq_mem_memRead), .mem_memWrite(lsq_mem_memWrite),
    .mem_address(lsq_mem_address), .mem_writeData(lsq_mem_writeData), .mem_funct3(lsq_mem_funct3),
    .mem_readData(lsq_mem_readData),
    .complete_valid(lsq_complete_valid), .complete_is_load(lsq_complete_is_load),
    .complete_dest_preg(lsq_complete_dest_preg), .complete_data(lsq_complete_data),
    .complete_rob_tag(lsq_complete_rob_tag),
    .lsq_count(lsq_count), .lsq_full(lsq_full)
);

DataMemoryBRAM #(.SIZE_BYTES(DMEM_SIZE_BYTES), .XLEN(XLEN)) m_DMem(
    .clk(clk), .rst(rst),
    .memWrite(lsq_mem_memWrite), .memRead(lsq_mem_memRead),
    .address(lsq_mem_address), .writeData(lsq_mem_writeData), .funct3(lsq_mem_funct3),
    .readData(lsq_mem_readData)
);

// ==========================================================================
// Execute: the SAME existing ALU.v this project's PIPELINED core already
// uses, fed by PRF reads at the entry ReservationStation just selected
// (issue_src1_preg/issue_src2_preg) -- by construction, both are already
// PRF-valid the cycle they're selected (RS only selects entries whose
// ready bits are set), so this is always live, never garbage, data.
// ==========================================================================
wire issue_alusrc         = issue_payload[PAYLOAD_BITS-1];
wire [4:0] issue_aluctl    = issue_payload[PAYLOAD_BITS-2 -: 5];
wire [XLEN-1:0] issue_imm  = issue_payload[XLEN-1:0];

wire [XLEN-1:0] alu_a = prf_rdata2;
wire [XLEN-1:0] alu_b = issue_alusrc ? issue_imm : prf_rdata3;
wire [XLEN-1:0] alu_out;
wire alu_zero, alu_branch_zero;

ALU #(.XLEN(XLEN)) m_ALU(
    .ALUCtl(issue_aluctl), .A(alu_a), .B(alu_b), .wordOp(1'b0),
    .ALUOut(alu_out), .zero(alu_zero), .branch_zero(alu_branch_zero)
);

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
    .disp_en0(do_dispatch && is_fp_op),
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
    // issue-time operand fetch.
    .raddr0(rat_f_rpreg0), .raddr1(rat_f_rpreg1),
    .raddr2(issue_src1_preg_falu[FPREG_BITS-1:0]), .raddr3(issue_src2_preg_falu[FPREG_BITS-1:0]),
    .raddr4({FPREG_BITS{1'b0}}), .raddr5({FPREG_BITS{1'b0}}), .raddr6({FPREG_BITS{1'b0}}), .raddr7({FPREG_BITS{1'b0}}), .raddr8({FPREG_BITS{1'b0}}),
    // Gen6-K never dual-issues FP (slot1_is_plain_alu excludes is_fp_op_1
    // by construction) -- ports 9/10 are simply tied off here.
    .raddr9({FPREG_BITS{1'b0}}), .raddr10({FPREG_BITS{1'b0}}),
    .rdata0(prf_f_rdata0), .rdata1(prf_f_rdata1), .rdata2(prf_f_rdata2), .rdata3(prf_f_rdata3),
    .rdata4(), .rdata5(), .rdata6(), .rdata7(), .rdata8(), .rdata9(), .rdata10(),
    .rvalid0(prf_f_rvalid0), .rvalid1(prf_f_rvalid1), .rvalid2(), .rvalid3(), .rvalid4(), .rvalid5(), .rvalid6(), .rvalid7(), .rvalid8(), .rvalid9(), .rvalid10(),
    // CDB writeback -- FALU's own instant result is the ONLY completion
    // source for the float PRF this phase (no FDIV/FSQRT/FMADD/FLW yet).
    .wen0(falu_complete_valid), .waddr0(falu_complete_dest_preg), .wdata0(falu_complete_data),
    .wen1(1'b0), .waddr1({FPREG_BITS{1'b0}}), .wdata1({FLEN{1'b0}}),
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
    else if (trap_resolve)   // Gen6-I: highest priority -- an exception/
                               // mret retiring always redirects, same
                               // "can't coincide with do_dispatch" argument
                               // as br_resolve's own (trap_inflight_valid_r
                               // is also folded into dispatch_stall)
        pc_r <= csr_trap_taken ? csr_mtvec_val : csr_mepc_val;
    else if (br_resolve && br_mispredict)
        pc_r <= br_correct_target;
    else if (do_dispatch)
        // Gen6-K: do_dispatch_slot1 only ever fires alongside try_dual_issue,
        // which by construction excludes is_branch (slot0_is_plain_alu) --
        // so the two arms below never actually compete for the same cycle.
        pc_r <= (is_branch && predicted_taken) ? predicted_target :
                (do_dispatch_slot1 ? (pc_r + 8) : (pc_r + 4));
end

endmodule

`default_nettype wire
