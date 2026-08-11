`default_nettype none

// MEM/WB pipeline register: latches the final writeback value and its
// destination register. `hold` freezes it during the MEM-stage
// load-latency interlock (docs/adr/0013's `mem_stall`) -- unlike reg3,
// this register is also the sole source of MEM/WB forwarding, so it must
// never be *bubbled* by a stall that doesn't concern its own occupant (see
// docs/adr/0013's Lessons: bubbling reg4 the same way reg3 is bubbled
// evicts a still-needed forwardable result one cycle early).
module reg4 #(
    parameter XLEN = 32,       // docs/adr/0015-xlen-and-regcount-parameterization.md
    parameter NUM_REGS = 32
) (
    input wire clk,
    input wire rst,
    input wire memtoReg_regem,
    input wire regWrite_regem,
    input wire fRegWrite_regem,  // docs/adr/0019-f-extension.md: writes FRegister.v, not Register.v
    // docs/adr/0027-formal-verification.md (Phase L2). Trivial passthrough,
    // identical shape to regWrite_regwb's own -- closes the loop reg2/reg3
    // already opened (docs/adr/0025 Phase J3's valid_regde/valid_regem) so
    // a WB-stage "this is a real, non-squashed instruction" signal exists
    // for the whole-pipeline formal property to assert against
    // (regWrite_regwb implies valid_regwb).
    input wire valid_regem,
    input wire [XLEN-1:0] readData,
    input wire [XLEN-1:0] ALUOut_regem,
    input wire [$clog2(NUM_REGS)-1:0] write_to_Reg_regem,
    input wire jump_regem,
    input wire [XLEN-1:0] pc_plus4_regem,
    // docs/adr/0038-a-extension-phase-v.md: gates the WB-stage writeback
    // mux's own new AMO arm (riscvpipeline.v reads amo_captured_read_r --
    // a plain top-level register, not threaded through this module -- once
    // this flag says the occupant now in WB really is the lr/sc/amo* that
    // register was captured for).
    input wire isAmo_regem,
    input wire hold,   // MEM-stage interlock (docs/adr/0013-mem-stage-retiming.md):
                  // freeze every field exactly as-is while a load sitting in
                  // reg3 (this register's own source) hasn't come back from
                  // DataMemoryBRAM yet. Same empty-branch idiom as reg2/reg3's
                  // `hold` -- NOT a bubble: whatever reg4 is currently holding
                  // (e.g. an instruction still within its MEM/WB forwarding
                  // window) must stay visible to Forward.v for exactly as long
                  // as reg2/reg3 are also held, or a completely unrelated
                  // instruction waiting behind the load can lose a forwarding
                  // match it would otherwise have had (see the ADR).
    output reg memtoReg_regwb,
    output reg regWrite_regwb,
    output reg fRegWrite_regwb,
    output reg valid_regwb,
    output reg [XLEN-1:0] readData_regwb,
    output reg [XLEN-1:0] ALUOut_regwb,
    output reg [$clog2(NUM_REGS)-1:0] write_to_Reg_regwb,
    output reg jump_regwb,
    output reg [XLEN-1:0] pc_plus4_regwb,
    output reg isAmo_regwb
);

always@(posedge clk)
begin
    if(~rst)
    begin
    memtoReg_regwb <= 0;
    regWrite_regwb <= 0;
    fRegWrite_regwb <= 0;
    valid_regwb <= 0;
    readData_regwb <= 0;
    ALUOut_regwb <= 0;
    write_to_Reg_regwb <=0;
    jump_regwb <= 0;
    pc_plus4_regwb <= 0;
    isAmo_regwb <= 0;

    end
    else if(hold)
    begin
    // Deliberately empty -- see the `hold` port comment above.
    end
    else
    begin
    memtoReg_regwb <= memtoReg_regem;
    regWrite_regwb <= regWrite_regem;
    fRegWrite_regwb <= fRegWrite_regem;
    valid_regwb <= valid_regem;
    readData_regwb <= readData;
    ALUOut_regwb <= ALUOut_regem;
    write_to_Reg_regwb <= write_to_Reg_regem;
    jump_regwb <= jump_regem;
    pc_plus4_regwb <= pc_plus4_regem;
    isAmo_regwb <= isAmo_regem;
    end
end
endmodule

`default_nettype wire
