`default_nettype none

// docs/adr/0021-branch-prediction.md (Phase E3). Branch target buffer: a
// small, direct-mapped table storing the last resolved target address for
// whichever branch/jal/jalr last trained a given index, plus a valid bit
// (cleared on reset, so a cold PC's lookup misses cleanly rather than
// returning a stale/undefined target). Same indexing convention as Bht.v
// (a PC-bit slice, word-aligned, no modulo) and the same deliberate
// untagged-aliasing design: see Bht.v's header for why a table collision
// between two unrelated PCs can only ever cost an extra misprediction
// bubble, never a wrong architectural result -- riscvpipeline.v's EX-stage
// comparison against the real resolved target always catches it. Kept as
// a separate module from Bht.v (not one combined table) to mirror this
// project's consistent single-responsibility decomposition (e.g.
// FDivider.v/FSqrt.v staying separate despite both being multi-cycle FPU
// units) -- direction and target are logically independent facts trained
// and consumed slightly differently (a not-taken resolution never touches
// this table at all; see the `update_valid` gating at the call site).
//
// Query (`query_pc` -> `hit`/`target`) is purely combinational; update is a
// synchronous write from EX's resolution, one clock behind. No same-cycle
// write-to-read bypass, and no gating against a stale `target` bit-pattern
// on a `hit=0` entry's array slot -- both are the same deliberate
// simplification Bht.v documents, since every consumer of `target` already
// gates on `hit` (and, at the call site, on Bht.v's own `predict_taken`
// too) before ever trusting it.
module Btb #(
    parameter XLEN = 32,
    parameter NUM_ENTRIES = 32   // must be a power of 2 -- same convention as Bht.v
)(
    input wire clk,
    input wire rst,

    input      wire [XLEN-1:0] query_pc,
    output                 wire hit,
    output     wire [XLEN-1:0]  target,

    input                  wire update_valid,
    input      wire [XLEN-1:0]  update_pc,
    input      wire [XLEN-1:0]  update_target
);

localparam INDEX_WIDTH = $clog2(NUM_ENTRIES);

reg                 valid   [0:NUM_ENTRIES-1];
reg [XLEN-1:0]      targets [0:NUM_ENTRIES-1];
integer reset_i;

wire [INDEX_WIDTH-1:0] query_index  = query_pc[INDEX_WIDTH+1:2];
wire [INDEX_WIDTH-1:0] update_index = update_pc[INDEX_WIDTH+1:2];

assign hit    = valid[query_index];
assign target = targets[query_index];

always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < NUM_ENTRIES; reset_i = reset_i + 1) begin
            valid[reset_i]   <= 1'b0;
            targets[reset_i] <= {XLEN{1'b0}};
        end
    end else if (update_valid) begin
        valid[update_index]   <= 1'b1;
        targets[update_index] <= update_target;
    end
end

endmodule

`default_nettype wire
