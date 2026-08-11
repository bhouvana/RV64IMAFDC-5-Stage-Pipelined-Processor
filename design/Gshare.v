`default_nettype none

// docs/adr/0040-gshare-tournament-branch-predictor.md (Generation 4, Phase
// A). GShare direction predictor: the same 2-bit saturating (Smith)
// counter table shape as Bht.v, but indexed by a PC-bit slice XORed with a
// global history register (the outcome of the last INDEX_WIDTH resolved
// branches/jumps, taken=1/not-taken=0, newest bit at position 0) instead of
// the PC alone -- letting two different PCs that alias in a plain bimodal
// table train separate counters when reached via different recent branch
// history, and letting the same PC (a branch inside a loop, for example)
// get a different prediction depending on which recent path led to it.
//
// Deliberately untagged, same reasoning as Bht.v's own header (a
// misprediction from aliasing can never produce a wrong architectural
// result, only cost an extra bubble -- riscvpipeline.v's EX-stage
// comparison against ground truth always catches it).
//
// Deliberately RESOLVED-history-only, not speculative: the global history
// register updates synchronously from EX's own real resolution, one cycle
// behind, exactly the same "no same-cycle bypass" simplification Bht.v's
// own header already documents and accepts for its counter table. A real,
// deliberate scope decision, not an oversight: speculative-history update
// (folding in not-yet-resolved in-flight branch guesses, with rollback on
// misprediction) is a genuinely separate, larger feature this phase does
// not attempt -- see docs/adr/0040's Alternatives considered section.
//
// History width equals INDEX_WIDTH (reuses NUM_ENTRIES' own sizing, no new
// parameter) -- a real, deliberate simplification for this project's own
// small default table sizes; a wider history folded down via XOR would be
// a real future refinement if a much larger NUM_ENTRIES is ever benchmarked
// (see docs/adr/0040's Future improvements).
//
// Second, independent combinational read port (train_pc ->
// train_predict_taken), identical shape to Bht.v's own Task-1 addition, for
// Chooser.v to query this table's own opinion at the PC currently being
// trained.
module Gshare #(
    parameter XLEN = 32,
    parameter NUM_ENTRIES = 32   // must be a power of 2, same convention as Bht.v/Btb.v
)(
    input wire clk,
    input wire rst,

    input      wire [XLEN-1:0] query_pc,
    output                wire predict_taken,

    input      wire [XLEN-1:0] train_pc,
    output                 wire train_predict_taken,

    input                  wire update_valid,
    input      wire [XLEN-1:0]  update_pc,
    input                  wire update_taken
);

localparam INDEX_WIDTH = $clog2(NUM_ENTRIES);

reg [1:0] counters [0:NUM_ENTRIES-1];
reg [INDEX_WIDTH-1:0] ghr;   // global history register, newest outcome in bit 0
integer reset_i;

wire [INDEX_WIDTH-1:0] query_index  = query_pc[INDEX_WIDTH+1:2]  ^ ghr;
wire [INDEX_WIDTH-1:0] update_index = update_pc[INDEX_WIDTH+1:2] ^ ghr;
wire [INDEX_WIDTH-1:0] train_index  = train_pc[INDEX_WIDTH+1:2]  ^ ghr;

assign predict_taken = counters[query_index][1];
assign train_predict_taken = counters[train_index][1];

always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < NUM_ENTRIES; reset_i = reset_i + 1)
            counters[reset_i] <= 2'b00;
        ghr <= {INDEX_WIDTH{1'b0}};
    end else if (update_valid) begin
        if (update_taken)
            counters[update_index] <= (counters[update_index] == 2'b11) ? 2'b11 : counters[update_index] + 2'b01;
        else
            counters[update_index] <= (counters[update_index] == 2'b00) ? 2'b00 : counters[update_index] - 2'b01;
        ghr <= {ghr[INDEX_WIDTH-2:0], update_taken};
    end
end

endmodule

`default_nettype wire
