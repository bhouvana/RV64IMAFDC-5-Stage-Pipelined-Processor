`default_nettype none

module Hazard #(
    parameter NUM_REGS = 32,   // docs/adr/0015-xlen-and-regcount-parameterization.md
    // docs/adr/0018-variable-pipeline-depth.md (Phase A5) -- number of
    // in-flight producer slots checked for a load-use hazard against the
    // instruction currently in ID. Ports below flatten them into one bus,
    // nearest-producer-first (index 0). Default 1 (today's single ID/EX-
    // stage check, the one instruction directly ahead) reproduces this
    // core's original load-use detection exactly -- infrastructure only,
    // not exercised above this default by any profile shipped so far (every
    // other RAW-hazard gap is covered by Forward.v's forwarding or
    // Register.v's write-first bypass, not by stalling here).
    parameter NUM_LOOKAHEAD = 1
) (

    input wire [$clog2(NUM_REGS)-1:0] readReg1_fd,
    input wire [$clog2(NUM_REGS)-1:0] readReg2_fd,
    // Per-lookahead-slot hazard sources, nearest-producer-first (see
    // riscvpipeline.v's instantiation for the default NUM_LOOKAHEAD=1
    // mapping: index 0 = the instruction now entering EX, "regde").
    input wire [NUM_LOOKAHEAD-1:0] la_memRead,
    input wire [NUM_LOOKAHEAD*$clog2(NUM_REGS)-1:0] la_dest,
    output wire flush,
    output wire stall
);

localparam REG_ADDR_WIDTH = $clog2(NUM_REGS);

wire [NUM_LOOKAHEAD-1:0] hazard_per_slot;
genvar g;
generate
for (g = 0; g < NUM_LOOKAHEAD; g = g + 1) begin : gen_lookahead
    assign hazard_per_slot[g] = la_memRead[g] &&
        ((la_dest[g*REG_ADDR_WIDTH +: REG_ADDR_WIDTH] == readReg1_fd) ||
         (la_dest[g*REG_ADDR_WIDTH +: REG_ADDR_WIDTH] == readReg2_fd));
end
endgenerate

assign flush = |hazard_per_slot;
assign stall = flush;

// Compiled in only with -DASSERT_ON (see sim/run_tests.sh). stall/flush are
// assigned identically above by construction; this makes that an explicitly
// checked invariant instead of something a future edit could quietly break
// (e.g. if load-use handling ever needs to diverge stall from flush).
`ifdef ASSERT_ON
always @(*) begin
    if (stall !== flush)
        begin $display("ASSERTION FAILED @t=%0t: Hazard.v stall(%b) != flush(%b), expected equal", $time, stall, flush); $finish; end
end
`endif

endmodule

`default_nettype wire
