`default_nettype none

// docs/adr/0019-f-extension.md (Phase C7): float-register-file counterpart
// to Forward.v -- same priority-encode shape (farthest-producer-first,
// index 0 = MEM/WB, index 1 = EX/MEM, a later/nearer match always wins
// ties), extended to a third read port (readReg3) for the R4-type FMADD
// family's rs3. Deliberately a sibling module rather than a generalized
// Forward.v: the integer file has no third read port to give one, and
// bolting an always-unused readReg3/forwardC onto Forward.v would be dead
// surface on every non-float instruction in the machine.
//
// The one real behavioral difference from Forward.v (beyond the extra
// port): no "forward only if dest != 0" guard. Register.v hardwires x0 to
// zero and never actually commits a write there, so Forward.v must refuse
// to forward a stale/meaningless "write to x0" match; FRegister.v hardwires
// nothing (docs/adr/0019's own design section) -- f0 is a completely
// ordinary, forwardable register, and adding that guard here would
// silently break any program that legitimately computes into f0.
module FForward #(
    parameter NUM_REGS = 32,   // docs/adr/0015-xlen-and-regcount-parameterization.md
    parameter NUM_FWD_SRC = 2  // see Forward.v's own parameter comment
) (

    input wire [$clog2(NUM_REGS)-1:0] readReg1_regde,
    input wire [$clog2(NUM_REGS)-1:0] readReg2_regde,
    input wire [$clog2(NUM_REGS)-1:0] readReg3_regde,
    // Per-source forwarding candidates, farthest-producer-first -- see
    // riscvpipeline.v's instantiation for the default NUM_FWD_SRC=2 mapping:
    // index 0 = MEM/WB, index 1 = EX/MEM.
    input wire [NUM_FWD_SRC-1:0] fwd_valid,
    input wire [NUM_FWD_SRC*$clog2(NUM_REGS)-1:0] fwd_dest,
    output reg [$clog2(NUM_FWD_SRC+1)-1:0] forwardA,
    output reg [$clog2(NUM_FWD_SRC+1)-1:0] forwardB,
    output reg [$clog2(NUM_FWD_SRC+1)-1:0] forwardC
);

localparam REG_ADDR_WIDTH = $clog2(NUM_REGS);
localparam SEL_WIDTH = $clog2(NUM_FWD_SRC+1);

integer i;
always@(*)
begin
    forwardA = {SEL_WIDTH{1'b0}};  // everything is ok (no forward)
    forwardB = {SEL_WIDTH{1'b0}};
    forwardC = {SEL_WIDTH{1'b0}};
    for (i = 0; i < NUM_FWD_SRC; i = i + 1) begin
        if (fwd_valid[i] && (fwd_dest[i*REG_ADDR_WIDTH +: REG_ADDR_WIDTH] == readReg1_regde))
            forwardA = i[SEL_WIDTH-1:0] + 1'b1;  // nearer source (higher i) overwrites a farther match
        if (fwd_valid[i] && (fwd_dest[i*REG_ADDR_WIDTH +: REG_ADDR_WIDTH] == readReg2_regde))
            forwardB = i[SEL_WIDTH-1:0] + 1'b1;
        if (fwd_valid[i] && (fwd_dest[i*REG_ADDR_WIDTH +: REG_ADDR_WIDTH] == readReg3_regde))
            forwardC = i[SEL_WIDTH-1:0] + 1'b1;
    end
end

// Compiled in only with -DASSERT_ON (see sim/run_tests.sh) -- mirrors
// Forward.v's own range-invariant check.
`ifdef ASSERT_ON
always @(*) begin
    if (forwardA > NUM_FWD_SRC)
        begin $display("ASSERTION FAILED @t=%0t: FForward.v forwardA=%0d out of range (0..%0d, see MuxN's s0/src)", $time, forwardA, NUM_FWD_SRC); $finish; end
    if (forwardB > NUM_FWD_SRC)
        begin $display("ASSERTION FAILED @t=%0t: FForward.v forwardB=%0d out of range (0..%0d, see MuxN's s0/src)", $time, forwardB, NUM_FWD_SRC); $finish; end
    if (forwardC > NUM_FWD_SRC)
        begin $display("ASSERTION FAILED @t=%0t: FForward.v forwardC=%0d out of range (0..%0d, see MuxN's s0/src)", $time, forwardC, NUM_FWD_SRC); $finish; end
end
`endif

endmodule

`default_nettype wire
