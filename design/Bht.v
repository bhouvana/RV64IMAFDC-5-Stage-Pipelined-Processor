`default_nettype none

// docs/adr/0021-branch-prediction.md (Phase E2). Branch history table: a
// small, direct-mapped table of 2-bit saturating (Smith) counters, indexed
// by a slice of the instruction's own PC, predicting the *direction*
// (taken/not-taken) of whichever branch last trained a given index.
// Deliberately untagged -- two different PCs that happen to share an index
// simply share one counter. This is safe, not merely convenient: a
// misprediction from aliasing (or from a completely unrelated instruction
// that never was a branch at all) can never produce a wrong architectural
// result -- riscvpipeline.v's own EX-stage comparison against the real,
// ground-truth outcome always catches it and redirects/squashes exactly as
// it already does for a genuine misprediction (see docs/adr/0021's
// correctness note). Aliasing costs at most an extra bubble, never a wrong
// answer, so a tag isn't needed for correctness -- only for prediction
// *accuracy*, which isn't this phase's scope (see the ADR's Explicitly out
// of scope section).
//
// Counter encoding (standard 2-bit Smith predictor):
//   2'b00 strongly not-taken   2'b01 weakly not-taken
//   2'b10 weakly taken         2'b11 strongly taken
// `predict_taken` is simply the counter's MSB. Reset state is all-zero
// (strongly not-taken) -- the same bias PREDICTOR_STATIC's own "always
// guess not-taken" behavior already has, so a cold table's very first
// prediction for any PC is the least surprising possible default, not an
// arbitrary one.
//
// Query (`query_pc` -> `predict_taken`) is purely combinational, read every
// cycle at fetch; update (`update_valid`/`update_pc`/`update_taken`) is a
// synchronous write from EX's resolution, one clock behind whatever cycle
// resolved it. No same-cycle write-to-read bypass exists: if `query_pc` and
// `update_pc` land on the same index the same cycle (a tight loop resolving
// and immediately re-fetching its own branch), the query sees the
// pre-update value. This is a deliberate simplification, not an oversight
// -- exactly like the aliasing case above, the only cost is one possibly-
// avoidable extra bubble on that specific edge, never an architectural
// error.
module Bht #(
    parameter XLEN = 32,
    parameter NUM_ENTRIES = 32   // must be a power of 2 -- indexed by a
                                   // direct PC-bit slice, no modulo
)(
    input wire clk,
    input wire rst,

    input      wire [XLEN-1:0] query_pc,
    output                wire predict_taken,

    // Second, independent combinational read port -- same array, a
    // different index, purely additive (existing BRANCH_PREDICTOR=1
    // wiring simply never connects it, zero behavior change there).
    // Mirrors Tlb.v's own precedent (docs/adr/0022) for a small array with
    // two independent read ports. Lets a tournament predictor's Chooser.v
    // (Generation 4, Phase A, docs/adr/0040) query this table's own
    // opinion for whichever PC is currently being trained, without
    // threading a new per-instruction latched prediction bit through
    // reg1/reg1a/reg2 -- a real, deliberate scope decision (see that
    // ADR's Design section) that keeps this phase's pipeline-wiring risk
    // to zero new latched signals.
    input      wire [XLEN-1:0] train_pc,
    output                 wire train_predict_taken,

    input                  wire update_valid,
    input      wire [XLEN-1:0]  update_pc,
    input                  wire update_taken
);

localparam INDEX_WIDTH = $clog2(NUM_ENTRIES);

reg [1:0] counters [0:NUM_ENTRIES-1];
integer reset_i;

// Word-aligned index: bits [1:0] are always 0 for this core's fixed-width
// 32-bit instructions, so they carry no information and are skipped, the
// same convention riscv_defs.vh's own address-decode constants use.
wire [INDEX_WIDTH-1:0] query_index  = query_pc[INDEX_WIDTH+1:2];
wire [INDEX_WIDTH-1:0] update_index = update_pc[INDEX_WIDTH+1:2];
wire [INDEX_WIDTH-1:0] train_index  = train_pc[INDEX_WIDTH+1:2];

assign predict_taken = counters[query_index][1];
assign train_predict_taken = counters[train_index][1];

always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < NUM_ENTRIES; reset_i = reset_i + 1)
            counters[reset_i] <= 2'b00;
    end else if (update_valid) begin
        if (update_taken)
            counters[update_index] <= (counters[update_index] == 2'b11) ? 2'b11 : counters[update_index] + 2'b01;
        else
            counters[update_index] <= (counters[update_index] == 2'b00) ? 2'b00 : counters[update_index] - 2'b01;
    end
end

endmodule

`default_nettype wire
