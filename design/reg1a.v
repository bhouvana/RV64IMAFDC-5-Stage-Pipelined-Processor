`default_nettype none

// IF1/IF2 relay register (docs/adr/0018-variable-pipeline-depth.md,
// docs/ROADMAP.md Phase 6: "compare pipeline depths"). Only instantiated
// under PIPELINE_PROFILE == PROFILE_6STAGE_SPLIT_FETCH -- see
// riscvpipeline.v's generate/if selection, the same elaboration-time
// pattern docs/adr/0016 established for HAZARD_STRATEGY (the unselected
// branch isn't even instantiated, so PROFILE_5STAGE stays zero-cost).
//
// Carries only the PC, not an instruction -- InstructionMemory.v hasn't
// been read yet at this point in the pipe. Under the split-fetch profile,
// PC.v's output is registered here first; InstructionMemory.v then reads
// THIS register's output (one cycle later than PROFILE_5STAGE), and
// reg1.v (today's IF/ID register, unchanged) registers the resulting
// instruction one cycle after that. Net effect: one extra cycle of fetch
// latency between PC generation and instruction-memory access, decoupling
// the two -- the actual point of a split-fetch stage (e.g. groundwork for
// a future synchronous-read instruction memory, the same BRAM-retiming
// gap docs/adr/0013's Future Improvements already flagged for
// InstructionMemory.v specifically).
//
// Deliberately a PLAIN, unconditional relay -- no squash notion of its own
// at all, just reset and stall (the same pc_stall wire PC.v and reg1.v
// already take). Two earlier designs were tried and rejected, both found
// wrong by actually running jal_test.s/constrained-random programs at this
// profile, not reasoned out in advance (docs/adr/0018):
//   1. Squash to a constant (0): produces a genuine infinite loop, because
//      this register's output is unconditionally used as
//      InstructionMemory's read address every cycle, unlike reg1.v's
//      squashed output (safe to zero, since a decoded nop's own control
//      signals make its paired PC irrelevant downstream) -- address 0
//      contains real code, so the very next cycle re-fetches and
//      re-executes whatever sits there.
//   2. Squash to `redirect_target` directly (matching PC.v's own redirect
//      exactly, so both converge on the correct address the same cycle):
//      fixes the infinite loop, but *duplicates* the target fetch instead
//      -- this register reaches redirect_target via the explicit squash,
//      then reaches it AGAIN one cycle later via its own normal relay of
//      PC.v's already-corrected pc_o (which holds redirect_target
//      starting the same cycle), so the target address ends up fetched on
//      two consecutive cycles instead of one, and the resulting duplicate
//      instruction flows into reg1.v/reg2.v twice.
// The actual fix is architectural, not local to this module: a redirect
// legitimately costs one cycle more here than under PROFILE_5STAGE (the
// same honest cost any real hardware pays for a deeper fetch pipeline),
// and reg1.v's squash window needs to be extended by that one cycle under
// this profile instead -- see riscvpipeline.v's redirect_squash_extend_r.
module reg1a #(
    parameter XLEN = 32
)(
    input wire clk,
    input wire rst,
    input wire stall,
    input wire [XLEN-1:0] pc_o,
    output reg [XLEN-1:0] pc_o_reg1a,
    // docs/adr/0021-branch-prediction.md (Phase E4). The branch predictor's
    // guess for THIS pc_o, relayed alongside it with exactly the same
    // unconditional reset/stall/latch treatment pc_o itself already gets
    // above -- not a new mechanism, just two more fields riding the same
    // relay. Always 0/don't-care under PREDICTOR_STATIC (riscvpipeline.v
    // ties them off there). Squash handling for a redirect still lives
    // entirely in riscvpipeline.v's redirect_squash_extend_r / reg1.v's own
    // priority chain -- see this module's own header for why a second,
    // independent squash source must never be added here.
    input wire predict_taken,
    input wire [XLEN-1:0] predict_target,
    output reg predict_taken_reg1a,
    output reg [XLEN-1:0] predict_target_reg1a
);

always@(posedge clk)
begin
    if(~rst)
    begin
        pc_o_reg1a <= 0;
        predict_taken_reg1a <= 0;
        predict_target_reg1a <= 0;
    end
    else
        begin
            if(stall)
            begin
                pc_o_reg1a <= pc_o_reg1a;
                predict_taken_reg1a <= predict_taken_reg1a;
                predict_target_reg1a <= predict_target_reg1a;
            end
            else
            begin
                pc_o_reg1a <= pc_o;
                predict_taken_reg1a <= predict_taken;
                predict_target_reg1a <= predict_target;
            end
    end
end

endmodule

`default_nettype wire
