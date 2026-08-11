`default_nettype none

// Architectural float register file (f0-f31), docs/adr/0019-f-extension.md
// (Phase C of the redesign). Mirrors design/Register.v's shape (write-first
// bypass, XLEN/NUM_REGS parameterization) with two real differences:
//   - No f0-hardwired-to-zero special-casing at all. Unlike the integer
//     file's x0, every one of f0-f31 is a plain, independently writable
//     register -- RV32F has no hardwired-zero float register.
//   - A third read port (readReg3/readData3), needed from the start for
//     the fused multiply-add family (fmadd.s/fmsub.s/fnmsub.s/fnmadd.s),
//     which read three float source operands (rs1, rs2, rs3) in one
//     instruction -- nothing in the existing integer pipeline needs a
//     third read port, so this has no analogue in Register.v.
// Reset value 0 needs no special handling here the way reg1.v's instruction
// reset does (docs/adr/0011): 32'h00000000 bit-for-bit *is* IEEE 754
// single-precision +0.0, a genuinely valid float value, not a decode trap
// in disguise -- there is no "obviously inert" concern to re-derive for a
// plain data register the way there was for an instruction register.
module FRegister #(
    parameter XLEN = 32,
    parameter NUM_REGS = 32
) (
    input wire clk,
    input wire rst,
    input wire regWrite,
    input wire [$clog2(NUM_REGS)-1:0] readReg1,
    input wire [$clog2(NUM_REGS)-1:0] readReg2,
    input wire [$clog2(NUM_REGS)-1:0] readReg3,
    input wire [$clog2(NUM_REGS)-1:0] writeReg,
    input wire [XLEN-1:0] writeData,
    output wire [XLEN-1:0] readData1,
    output wire [XLEN-1:0] readData2,
    output wire [XLEN-1:0] readData3
);
    reg [XLEN-1:0] regs [0:NUM_REGS-1];
    integer reset_i;

    // Write-first bypass, same rationale as Register.v's (docs/adr/0002):
    // without it, a same-cycle write/read collision on the same register
    // would return the pre-write (stale) value, since the write below is a
    // synchronous posedge update while reads are combinational.
    assign readData1 = (regWrite && writeReg == readReg1) ? writeData : regs[readReg1];
    assign readData2 = (regWrite && writeReg == readReg2) ? writeData : regs[readReg2];
    assign readData3 = (regWrite && writeReg == readReg3) ? writeData : regs[readReg3];

    always @(posedge clk) begin
        if (~rst) begin
            for (reset_i = 0; reset_i < NUM_REGS; reset_i = reset_i + 1)
                regs[reset_i] <= {XLEN{1'b0}};
        end
        else if (regWrite)
            regs[writeReg] <= writeData;
    end

endmodule

`default_nettype wire
