`default_nettype none

// IF/ID pipeline register: latches the fetched instruction and its PC.
// Squashes to a real nop (not a literal 0, see the reset comment below) on
// a taken branch or unconditional jump/redirect; holds on a stall. Under
// PROFILE_6STAGE_SPLIT_FETCH (docs/adr/0018), this register's own squash
// window is extended one extra cycle (riscvpipeline.v's
// redirect_squash_extend_r) instead of reg1a squashing itself.
module reg1 #(
    parameter XLEN = 32   // docs/adr/0015-xlen-and-regcount-parameterization.md --
                            // applies to inst/inst_regfd too, same simplification
                            // ImmGen.v already made (RV32I's instruction word
                            // happens to be XLEN bits wide, coincidentally, only
                            // because both are 32 for this ISA).
)(
    input wire clk,
    input wire rst,
    input wire stall,
    input wire [XLEN-1:0] inst,
    input wire [XLEN-1:0] pc_o,
    input wire branch_regde,
    input wire zero,
    input wire jump,       // unconditional redirect (jal) resolved in EX, same squash as a taken branch
    // docs/adr/0021-branch-prediction.md (Phase E4). The branch predictor's
    // guess for THIS specific fetch (queried at the same address `inst`
    // itself was fetched from), latched alongside it with exactly the same
    // squash/hold/fresh-latch priority as inst/pc_o above -- never a
    // second, independent squash source (see reg1a.v's own header for why
    // that distinction matters). Always 0/don't-care under
    // PREDICTOR_STATIC -- riscvpipeline.v ties them off there, and folds
    // the branch/jump redirect condition entirely into `jump` above instead
    // of this module's own branch_regde/zero ports in that case too (see
    // riscvpipeline.v's own comment at the reg1 instantiation).
    input wire predict_taken,
    input wire [XLEN-1:0] predict_target,
    // docs/adr/00NN-mmu-sv32.md (Phase F5). Whether THIS fetch attempt's
    // resolution (a same-cycle TLB-hit permission failure, or a just-
    // concluded Ptw.v walk) was a page fault -- the "instruction" bits
    // riscvpipeline.v is presenting alongside it are garbage (wrong/no
    // real translation) and must have zero architectural effect once
    // this reaches EX (see riscvpipeline.v's own exception_taken fold-in).
    // Decode-context group, not control-fields: a Hazard.v load-use flush
    // on this same cycle must not silently drop the fault tag (flush
    // passes decode context through, zeros only control fields) -- the
    // garbage instruction's rs1/rs2 could coincidentally trigger an
    // unrelated load-use hazard, and the fault flag must survive that.
    input wire ifetch_fault,
    // docs/adr/0037-rvc-compressed-instructions-phase-u.md. Whether THIS
    // fetch was a 2-byte compressed instruction (inst[1:0] != 2'b11) --
    // `inst` itself has already been expanded to its standard 32-bit
    // equivalent by the time it reaches this port (riscvpipeline.v's own
    // CompressedExpander sits upstream, at the fetch tap), so this flag's
    // only remaining job downstream is telling the decode-stage link-
    // address adder (pc_plus4, jal/jalr/branch-fallthrough) whether the
    // real next sequential PC is +2 or +4 -- same decode-context-group
    // reasoning ifetch_fault above already documents (must survive a
    // load-use flush unmolested).
    input wire is_compressed,
    output reg [XLEN-1:0] inst_regfd,
    output reg [XLEN-1:0] pc_o_regfd,
    output reg predict_taken_regfd,
    output reg [XLEN-1:0] predict_target_regfd,
    output reg ifetch_fault_regfd,
    output reg is_compressed_regfd
);

always@(posedge clk)
begin
    if(~rst)
    begin
    // A nop (0x13), not a literal 0 -- opcode 0000000 is a real illegal-
    // instruction trap since docs/adr/0011 (see squash below, which already
    // knew this). Reset didn't get the same treatment: for the one cycle
    // between reset releasing and the first real fetch reaching inst_regfd,
    // Control.v would otherwise decode this register's raw reset value as
    // opcode 0000000 and spuriously trap, corrupting mcause/mepc before any
    // real instruction ever executes (docs/adr/0013's random-testing pass,
    // once it started generating CSR reads, was the first thing to ever
    // read those registers early enough to notice).
    inst_regfd <= 32'h00000013;
    pc_o_regfd <= 0;
    predict_taken_regfd <= 0;
    predict_target_regfd <= 0;
    ifetch_fault_regfd <= 0;
    is_compressed_regfd <= 0;
    end
    else
        begin
            if((branch_regde & zero) | jump)
            begin

                inst_regfd <= 32'h00000013;
                pc_o_regfd <= 0;
                predict_taken_regfd <= 0;
                predict_target_regfd <= 0;
                ifetch_fault_regfd <= 0;
                is_compressed_regfd <= 0;
            end
            else if(stall)
            begin
                inst_regfd <= inst_regfd;
                pc_o_regfd <= pc_o_regfd;
                predict_taken_regfd <= predict_taken_regfd;
                predict_target_regfd <= predict_target_regfd;
                ifetch_fault_regfd <= ifetch_fault_regfd;
                is_compressed_regfd <= is_compressed_regfd;
            end
            else
            begin
                inst_regfd <= inst;
                pc_o_regfd <= pc_o;
                predict_taken_regfd <= predict_taken;
                predict_target_regfd <= predict_target;
                ifetch_fault_regfd <= ifetch_fault;
                is_compressed_regfd <= is_compressed;
            end
    end
end

endmodule

`default_nettype wire
