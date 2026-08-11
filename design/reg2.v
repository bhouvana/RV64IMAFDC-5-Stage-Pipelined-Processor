`default_nettype none

// ID/EX pipeline register: latches every control signal and operand
// Control.v/ImmGen.v/Register.v produced in ID for EX/MEM/WB to consume
// downstream. Squashes to nop-equivalent control fields on a redirect or a
// load-use bubble (docs/adr/0009's convention -- bubble the *control*
// signals, not the data); `hold` freezes it during a multi-cycle EX
// operation or the MEM-stage load-latency interlock (docs/adr/0009,
// docs/adr/0013).
//
// Field-assignment macros factor out what was previously ~90 lines of
// near-identical repetition across the four arms below (docs/ARCHITECTURE.md
// sec 12 flagged this as the most duplicative code in the repository).
// Verilog-2001 has no struct/typedef to reach for here, so this uses plain
// `` `define`` text macros -- a portable, toolchain-agnostic way to get the
// same "assign this named group of fields" effect.
`define ZERO_CONTROL_FIELDS \
    valid_regde <= 0; \
    branch_regde <= 0; \
    memRead_regde <= 0; \
    memtoReg_regde <= 0; \
    memWrite_regde <= 0; \
    ALUSrc_regde <= 0; \
    regWrite_regde <= 0; \
    fRegWrite_regde <= 0; \
    ALUOp_regde <= 0; \
    write_to_Reg_regde <= 0; \
    jump_regde <= 0; \
    jalr_regde <= 0; \
    lui_regde <= 0; \
    auipc_regde <= 0; \
    isCsr_regde <= 0; \
    isEcall_regde <= 0; \
    isEbreak_regde <= 0; \
    isMret_regde <= 0; \
    isSret_regde <= 0; \
    isSfenceVma_regde <= 0; \
    isFence_regde <= 0; \
    isAmo_regde <= 0; \
    illegalOpcode_regde <= 0;

`define ZERO_DECODE_CONTEXT \
    pc_o_regde <= 0; \
    readData1_regde <= 0; \
    readData2_regde <= 0; \
    freadData1_regde <= 0; \
    freadData2_regde <= 0; \
    freadData3_regde <= 0; \
    imm_regde <= 0; \
    funct7_regde <= 0; \
    funct3_regde <= 0; \
    readReg1_regde <= 0; \
    readReg2_regde <= 0; \
    readReg3_regde <= 0; \
    predict_taken_regde <= 0; \
    predict_target_regde <= 0; \
    ifetch_fault_regde <= 0; \
    is_compressed_regde <= 0;

`define PASS_DECODE_CONTEXT \
    pc_o_regde <= pc_o_regfd; \
    readData1_regde <= readData1; \
    readData2_regde <= readData2; \
    freadData1_regde <= freadData1; \
    freadData2_regde <= freadData2; \
    freadData3_regde <= freadData3; \
    imm_regde <= imm; \
    funct7_regde <= funct7; \
    funct3_regde <= funct3; \
    readReg1_regde <= readReg1; \
    readReg2_regde <= readReg2; \
    readReg3_regde <= readReg3; \
    predict_taken_regde <= predict_taken; \
    predict_target_regde <= predict_target; \
    ifetch_fault_regde <= ifetch_fault; \
    is_compressed_regde <= is_compressed;

module reg2 #(
    parameter XLEN = 32,       // docs/adr/0015-xlen-and-regcount-parameterization.md
    parameter NUM_REGS = 32
) (
    input wire clk,
    input wire rst,
    input wire branch,
    input wire memRead,
    input wire memtoReg,
    input wire memWrite,
    input wire ALUSrc,
    input wire regWrite,
    input wire fRegWrite,  // docs/adr/0019-f-extension.md: writes FRegister.v instead of Register.v
    input wire [$clog2(NUM_REGS)-1:0] writeReg,
    input wire [6:0] funct7,
    input wire [2:0] funct3,
    input wire [1:0] ALUOp,
    input wire [XLEN-1:0] pc_o_regfd,
    input wire [XLEN-1:0] readData1,
    input wire [XLEN-1:0] readData2,
    // docs/adr/0019-f-extension.md (Phase C6): FRegister.v's own three read
    // ports, kept entirely separate from readData1/readData2 above rather
    // than muxed/shared -- these are NOT yet forwarded (that's Phase C7;
    // for now a conservative stall, not forwarding, protects float RAW
    // hazards). Deliberately not routed through Forward.v/MuxN's existing
    // integer-only forwarding network at all: that network's hazard
    // detection is keyed on plain 5-bit register *indices*, which can't
    // tell an integer register apart from a float one that happens to
    // share the same index -- keeping the two paths fully separate avoids
    // that cross-file ambiguity by construction instead of needing extra
    // logic to rule it out.
    input wire [XLEN-1:0] freadData1,
    input wire [XLEN-1:0] freadData2,
    input wire [XLEN-1:0] freadData3,
    input wire [XLEN-1:0] imm,
    input wire [XLEN-1:0] inst_regfd,
    input wire flush,
    input wire branch_taken,
    // docs/adr/0025-hpc-performance-csrs.md (Phase J3). "Is reg1's current
    // output a real fetched instruction, or a squash-produced bubble" --
    // wired to `!id_bubble_r` at the call site (riscvpipeline.v already
    // computes this, mirroring reg1's own squash>hold>fresh priority
    // exactly; see its own comment). Squashed to 0 by this stage's own
    // branch_taken/flush arms below (folded into ZERO_CONTROL_FIELDS,
    // same as every other control field), passed straight through
    // otherwise -- minstret counts a retiring instruction by this bit
    // surviving all the way to reg3 (see reg3.v/riscvpipeline.v).
    input wire valid,
    input wire hold,   // multi-cycle divide interlock (docs/adr/0009): freeze every
                  // field exactly as-is while a div/rem's result isn't ready
                  // yet. Distinct from `flush`: flush *bubbles* (zeros
                  // control, keeps decode context); hold changes nothing at
                  // all, because the div/rem instruction itself must stay
                  // put in EX until the divider finishes with it.
    input wire [$clog2(NUM_REGS)-1:0] readReg1,
    input wire [$clog2(NUM_REGS)-1:0] readReg2,
    // docs/adr/0019-f-extension.md (Phase C7): rs3's index (inst[31:27]),
    // latched the same "always read, harmless when unused" way readReg1/
    // readReg2 already are -- only the R4-type FMADD family has a real rs3,
    // but FForward.v needs this index for every instruction to correctly
    // report "no forward" (index 0) rather than an accidental stale match.
    input wire [$clog2(NUM_REGS)-1:0] readReg3,
    // docs/adr/0021-branch-prediction.md (Phase E4). The branch predictor's
    // guess for this instruction, latched alongside every other piece of
    // decode context (see ZERO_DECODE_CONTEXT/PASS_DECODE_CONTEXT above) so
    // it's available in EX, two cycles after fetch, to compare against the
    // real resolved outcome. Always 0/don't-care under PREDICTOR_STATIC.
    input wire predict_taken,
    input wire [XLEN-1:0] predict_target,
    // docs/adr/00NN-mmu-sv32.md (Phase F5). reg1's own ifetch_fault_regfd,
    // carried one more stage to EX -- same decode-context treatment as
    // predict_taken/predict_target above, for the same reason (see
    // reg1.v's own port comment).
    input wire ifetch_fault,
    // docs/adr/0037-rvc-compressed-instructions-phase-u.md. reg1's own
    // is_compressed_regfd, carried one more stage to EX -- same decode-
    // context treatment as ifetch_fault above, needed here because
    // riscvpipeline.v's own pc_plus4 adder (jal/jalr link value, and the
    // branch predictor's fallthrough-PC comparison) lives at this stage.
    input wire is_compressed,
    input wire jump,
    input wire jalr,
    input wire lui,
    input wire auipc,
    input wire isCsr,
    input wire isEcall,
    input wire isEbreak,
    input wire isMret,
    input wire isSret,        // docs/adr/00NN-mmu-sv32.md (Phase F2) -- no live consumer yet (F3)
    input wire isSfenceVma,    // docs/adr/00NN-mmu-sv32.md (Phase F2) -- no live consumer yet (F5)
    input wire isFence,        // docs/adr/0023-caches.md (Phase G1) -- no live consumer yet (G6)
    input wire isAmo,          // docs/adr/0038-a-extension-phase-v.md
    input wire illegalOpcode,

    output reg valid_regde,
    output reg branch_regde,
    output reg memRead_regde,
    output reg memtoReg_regde,
    output reg memWrite_regde,
    output reg ALUSrc_regde,
    output reg regWrite_regde,
    output reg fRegWrite_regde,
    output reg [1:0] ALUOp_regde,
    output reg [$clog2(NUM_REGS)-1:0] write_to_Reg_regde,
    output reg [XLEN-1:0] pc_o_regde,
    output reg [XLEN-1:0] readData1_regde,
    output reg [XLEN-1:0] readData2_regde,
    output reg [XLEN-1:0] freadData1_regde,
    output reg [XLEN-1:0] freadData2_regde,
    output reg [XLEN-1:0] freadData3_regde,
    output reg [XLEN-1:0] imm_regde,
    output reg [XLEN-1:0] inst_regde,
    output reg [6:0] funct7_regde,
    output reg [2:0] funct3_regde,
    output reg [$clog2(NUM_REGS)-1:0] readReg1_regde,
    output reg [$clog2(NUM_REGS)-1:0] readReg2_regde,
    output reg [$clog2(NUM_REGS)-1:0] readReg3_regde,
    output reg predict_taken_regde,
    output reg [XLEN-1:0] predict_target_regde,
    output reg ifetch_fault_regde,
    output reg is_compressed_regde,
    output reg jump_regde,
    output reg jalr_regde,
    output reg lui_regde,
    output reg auipc_regde,
    output reg isCsr_regde,
    output reg isEcall_regde,
    output reg isEbreak_regde,
    output reg isMret_regde,
    output reg isSret_regde,
    output reg isSfenceVma_regde,
    output reg isFence_regde,
    output reg isAmo_regde,
    output reg illegalOpcode_regde

);

always@(posedge clk)
begin
    if(~rst)
    begin
        // Power-on reset: every field, including decode context, starts at 0.
        `ZERO_CONTROL_FIELDS
        `ZERO_DECODE_CONTEXT
        inst_regde <= 0;
    end

    else if(hold)
    begin
        // Deliberately empty: assigning nothing to a `reg` in one branch of
        // a clocked if-else chain means it keeps its current value -- an
        // enable-gated flip-flop, synthesizable as-is, not a fall-through
        // bug. Checked before branch_taken/flush on the (today, unreachable
        // in practice) grounds that a held div/rem instruction can't also
        // be a branch/load -- see the `hold` port comment above.
    end

    else if(branch_taken)
    begin
        // Taken branch/jal resolved in EX: squash to a bubble. Decode
        // context is discarded (there's no real instruction here anymore),
        // same as reset, except inst_regde becomes an explicit nop rather
        // than 0 -- downstream stages (e.g. Control) decode 0 as a
        // (harmless) R-type op, but an explicit nop is clearer to read in
        // a trace/waveform and matches reg1.v's own squash value.
        `ZERO_CONTROL_FIELDS
        `ZERO_DECODE_CONTEXT
        inst_regde <= 32'h00000013;
    end

    else if(flush)
    begin
        // Load-use stall bubble: control fields squash (this cycle does
        // nothing architecturally), but decode context passes through --
        // unlike branch_taken, there's a real (stalled) instruction sitting
        // in IF/ID that will re-enter next cycle once the stall clears.
        `ZERO_CONTROL_FIELDS
        `PASS_DECODE_CONTEXT
        inst_regde <= inst_regfd;
    end

    else
    begin
        // Normal cycle: control fields take their real decoded values;
        // decode context passes straight through same as the flush arm.
        valid_regde <= valid;
        branch_regde <= branch;
        memRead_regde <= memRead;
        memtoReg_regde <= memtoReg;
        memWrite_regde <= memWrite;
        ALUSrc_regde <= ALUSrc;
        regWrite_regde <= regWrite;
        fRegWrite_regde <= fRegWrite;
        ALUOp_regde <= ALUOp;
        write_to_Reg_regde <= writeReg;
        jump_regde <= jump;
        jalr_regde <= jalr;
        lui_regde <= lui;
        auipc_regde <= auipc;
        isCsr_regde <= isCsr;
        isEcall_regde <= isEcall;
        isEbreak_regde <= isEbreak;
        isMret_regde <= isMret;
        isSret_regde <= isSret;
        isSfenceVma_regde <= isSfenceVma;
        isFence_regde <= isFence;
        isAmo_regde <= isAmo;
        illegalOpcode_regde <= illegalOpcode;
        `PASS_DECODE_CONTEXT
        inst_regde <= inst_regfd;
    end
end

`undef ZERO_CONTROL_FIELDS
`undef ZERO_DECODE_CONTEXT
`undef PASS_DECODE_CONTEXT

endmodule

`default_nettype wire
