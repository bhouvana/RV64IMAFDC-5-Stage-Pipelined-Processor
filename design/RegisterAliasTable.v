`default_nettype none

// Generation 6 (out-of-order core), Gen6-A rename-stage skeleton
// (C:\Users\poorn\.claude\plans\gen6-ooo-core.md). Two register-alias
// tables sharing one module: a SPECULATIVE table (updated every cycle a
// rename write fires, read by rename to find each source operand's
// current physical register) and an ARCHITECTURAL/retire table (updated
// only when an instruction actually retires). This is deliberately
// exactly what a future ROB needs for precise-exception recovery: on a
// misprediction/exception, `restore_en` bulk-copies the architectural
// table back over the speculative one, instantly discarding every
// in-flight rename -- no per-instruction undo log needed, matching this
// project's own established "the simplest structure that gives the
// exact needed guarantee" bias (VictimCache.v's FIFO-only precedent,
// docs/adr/0042).
//
// x0 is never renamed: areg 0 always reads/maps to preg 0 in both
// tables (explicit hardwire on the read side, write-discard on waddr==0,
// same two-independent-places belt-and-suspenders style as Register.v's
// own x0 handling) -- FreeList.v/PhysicalRegisterFile.v mirror this by
// reserving preg 0 the same way.
//
// Reset state: identity mapping, areg i -> preg i, for BOTH tables --
// matches FreeList.v's own reset assumption that only pregs
// [NUM_AREGS, NUM_PREGS) start in the free list (pregs 0..NUM_AREGS-1
// are "in use" by this initial mapping from the very first cycle).
module RegisterAliasTable #(
    parameter NUM_AREGS = 32,
    parameter NUM_PREGS = 64,
    parameter AREG_BITS = $clog2(NUM_AREGS),
    parameter PREG_BITS = $clog2(NUM_PREGS)
)(
    input  wire                 clk,
    input  wire                 rst,

    // Combinational reads against the SPECULATIVE table -- 2 dispatch
    // slots x 2 source registers each.
    input  wire [AREG_BITS-1:0] raddr0,
    input  wire [AREG_BITS-1:0] raddr1,
    input  wire [AREG_BITS-1:0] raddr2,
    input  wire [AREG_BITS-1:0] raddr3,
    output wire [PREG_BITS-1:0] rpreg0,
    output wire [PREG_BITS-1:0] rpreg1,
    output wire [PREG_BITS-1:0] rpreg2,
    output wire [PREG_BITS-1:0] rpreg3,

    // Rename write, up to 2/cycle, SPECULATIVE table only. If both slots
    // target the same architectural register the same cycle, slot1 (the
    // program-order-later instruction) wins -- old_preg1 correctly
    // reflects slot0's own fresh mapping as ITS old value in that case,
    // not the pre-cycle table contents.
    input  wire                 wen0,
    input  wire [AREG_BITS-1:0] waddr0,
    input  wire [PREG_BITS-1:0] wpreg0,
    output wire [PREG_BITS-1:0] old_preg0,
    input  wire                 wen1,
    input  wire [AREG_BITS-1:0] waddr1,
    input  wire [PREG_BITS-1:0] wpreg1,
    output wire [PREG_BITS-1:0] old_preg1,

    // Retire commit, up to 2/cycle, ARCHITECTURAL table only.
    input  wire                 cwen0,
    input  wire [AREG_BITS-1:0] cwaddr0,
    input  wire [PREG_BITS-1:0] cwpreg0,
    input  wire                 cwen1,
    input  wire [AREG_BITS-1:0] cwaddr1,
    input  wire [PREG_BITS-1:0] cwpreg1,

    // Misprediction/exception recovery: bulk-copy architectural ->
    // speculative the cycle this pulses. Takes priority over any
    // same-cycle rename write (squash wins, matching docs/adr/0021's own
    // established "squash > stall-hold > fresh-latch" priority). Does
    // NOT touch the architectural table itself, and does not reclaim any
    // physical registers -- that's the caller's job (walk the ROB's own
    // old_preg bookkeeping for every discarded entry and push each into
    // FreeList.v), this module only owns the two mappings.
    input  wire                 restore_en
);

reg [PREG_BITS-1:0] spec_map [0:NUM_AREGS-1];
reg [PREG_BITS-1:0] arch_map [0:NUM_AREGS-1];

assign rpreg0 = (raddr0 == 0) ? {PREG_BITS{1'b0}} : spec_map[raddr0];
assign rpreg1 = (raddr1 == 0) ? {PREG_BITS{1'b0}} : spec_map[raddr1];
assign rpreg2 = (raddr2 == 0) ? {PREG_BITS{1'b0}} : spec_map[raddr2];
assign rpreg3 = (raddr3 == 0) ? {PREG_BITS{1'b0}} : spec_map[raddr3];

assign old_preg0 = spec_map[waddr0];
assign old_preg1 = (wen0 && waddr0 == waddr1) ? wpreg0 : spec_map[waddr1];

integer reset_i;
always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < NUM_AREGS; reset_i = reset_i + 1) begin
            spec_map[reset_i] <= reset_i[PREG_BITS-1:0];
            arch_map[reset_i] <= reset_i[PREG_BITS-1:0];
        end
    end
    else begin
        if (restore_en) begin
            for (reset_i = 0; reset_i < NUM_AREGS; reset_i = reset_i + 1)
                spec_map[reset_i] <= arch_map[reset_i];
        end
        else begin
            if (wen0 && waddr0 != 0)
                spec_map[waddr0] <= wpreg0;
            if (wen1 && waddr1 != 0)
                spec_map[waddr1] <= wpreg1;
        end

        // Architectural table: independent of restore_en/spec writes --
        // retirement keeps committing even the same cycle a LATER
        // (not-yet-retired) speculative instruction is being squashed.
        if (cwen0 && cwaddr0 != 0)
            arch_map[cwaddr0] <= cwpreg0;
        if (cwen1 && cwaddr1 != 0)
            arch_map[cwaddr1] <= cwpreg1;
    end
end

`ifdef ASSERT_ON
always @(posedge clk) begin
    if (rst && (spec_map[0] !== {PREG_BITS{1'b0}} || arch_map[0] !== {PREG_BITS{1'b0}}))
        begin $display("ASSERTION FAILED @t=%0t: areg x0 must always map to preg 0 in both tables", $time); $finish; end
end
`endif

endmodule

`default_nettype wire
