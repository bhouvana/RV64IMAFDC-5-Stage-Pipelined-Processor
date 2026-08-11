`default_nettype none

module Forward #(
    parameter NUM_REGS = 32,   // docs/adr/0015-xlen-and-regcount-parameterization.md
    // docs/adr/0018-variable-pipeline-depth.md (Phase A5) -- number of
    // forwarding sources. Ports below flatten them into one bus, ordered
    // farthest-producer-first (index 0) to nearest-producer-last (index
    // NUM_FWD_SRC-1): the priority-encode loop overwrites unconditionally in
    // that order, so a later (nearer) match always wins ties, same as this
    // core's original explicit EX/MEM-checked-before-MEM/WB priority. Default
    // 2 (index 0 = MEM/WB, index 1 = EX/MEM) reproduces that original
    // two-source forwarding exactly -- infrastructure only, not exercised
    // above this default by any profile shipped so far.
    parameter NUM_FWD_SRC = 2
) (

    input wire [$clog2(NUM_REGS)-1:0] readReg1_regde,
    input wire [$clog2(NUM_REGS)-1:0] readReg2_regde,
    // Per-source forwarding candidates, farthest-producer-first (see
    // riscvpipeline.v's instantiation for the default NUM_FWD_SRC=2 mapping:
    // index 0 = MEM/WB, index 1 = EX/MEM).
    input wire [NUM_FWD_SRC-1:0] fwd_valid,
    input wire [NUM_FWD_SRC*$clog2(NUM_REGS)-1:0] fwd_dest,
    output reg [$clog2(NUM_FWD_SRC+1)-1:0] forwardA,
    output reg [$clog2(NUM_FWD_SRC+1)-1:0] forwardB
);

localparam REG_ADDR_WIDTH = $clog2(NUM_REGS);
localparam SEL_WIDTH = $clog2(NUM_FWD_SRC+1);

integer i;
always@(*)
begin
    forwardA = {SEL_WIDTH{1'b0}};  // everything is ok (no forward)
    forwardB = {SEL_WIDTH{1'b0}};
    for (i = 0; i < NUM_FWD_SRC; i = i + 1) begin
        if (fwd_valid[i] && (fwd_dest[i*REG_ADDR_WIDTH +: REG_ADDR_WIDTH] != {REG_ADDR_WIDTH{1'b0}})
            && (fwd_dest[i*REG_ADDR_WIDTH +: REG_ADDR_WIDTH] == readReg1_regde))
            forwardA = i[SEL_WIDTH-1:0] + 1'b1;  // nearer source (higher i) overwrites a farther match
        if (fwd_valid[i] && (fwd_dest[i*REG_ADDR_WIDTH +: REG_ADDR_WIDTH] != {REG_ADDR_WIDTH{1'b0}})
            && (fwd_dest[i*REG_ADDR_WIDTH +: REG_ADDR_WIDTH] == readReg2_regde))
            forwardB = i[SEL_WIDTH-1:0] + 1'b1;
    end
end

// Compiled in only with -DASSERT_ON (see sim/run_tests.sh) -- has no effect
// on synthesis or normal simulation. forwardA/forwardB only ever have
// NUM_FWD_SRC+1 live values (0..NUM_FWD_SRC, see MuxN's s0/src); this checks
// that invariant holds rather than assuming it from the logic above never
// producing an out-of-range value.
`ifdef ASSERT_ON
always @(*) begin
    if (forwardA > NUM_FWD_SRC)
        begin $display("ASSERTION FAILED @t=%0t: Forward.v forwardA=%0d out of range (0..%0d, see MuxN's s0/src)", $time, forwardA, NUM_FWD_SRC); $finish; end
    if (forwardB > NUM_FWD_SRC)
        begin $display("ASSERTION FAILED @t=%0t: Forward.v forwardB=%0d out of range (0..%0d, see MuxN's s0/src)", $time, forwardB, NUM_FWD_SRC); $finish; end
end
`endif

endmodule

`default_nettype wire
