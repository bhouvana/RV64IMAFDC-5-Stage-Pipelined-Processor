`default_nettype none

// docs/adr/0040-gshare-tournament-branch-predictor.md (Generation 4, Phase
// A). Tournament predictor's meta-predictor ("chooser"): a small,
// direct-mapped table of 2-bit saturating counters, PC-indexed exactly like
// Bht.v, but trained on which of two direction predictors (conventionally
// "A" = Bht.v's own bimodal table, "B" = Gshare.v's own history-indexed
// table) was actually correct -- not on the branch's own taken/not-taken
// outcome directly, unlike Bht.v/Gshare.v themselves.
//
// Classic tournament-predictor training rule: update ONLY when A and B
// actually disagreed (if they agreed, right or wrong, the chooser learns
// nothing about which is more reliable -- both moving together carries no
// signal); when they disagreed, nudge the counter toward whichever one was
// actually right. counter>=2 (MSB set) means "prefer B" (Gshare);
// counter<2 means "prefer A" (Bht) -- same counter-encoding/MSB-as-decision
// convention Bht.v's own predict_taken already uses, renamed prefer_b for
// what this table's own MSB means here.
//
// a_correct/b_correct are computed by the caller (riscvpipeline.v,
// Generation 4 Phase A wiring) by querying Bht.v's and Gshare.v's own
// second read ports (train_pc/train_predict_taken) at update_pc and
// comparing each against the real resolved outcome -- a real, deliberate
// design choice that avoids threading either sub-predictor's original
// at-fetch-time opinion through reg1/reg1a/reg2 as a new per-instruction
// latched signal (see docs/adr/0040's Design section). Same deliberately
// untagged, deliberately resolved-training-only simplifications as
// Bht.v/Gshare.v -- see their own header comments.
module Chooser #(
    parameter XLEN = 32,
    parameter NUM_ENTRIES = 32
)(
    input wire clk,
    input wire rst,

    input      wire [XLEN-1:0] query_pc,
    output                wire prefer_b,

    input                  wire update_valid,
    input      wire [XLEN-1:0]  update_pc,
    input                  wire a_correct,
    input                  wire b_correct
);

localparam INDEX_WIDTH = $clog2(NUM_ENTRIES);

reg [1:0] counters [0:NUM_ENTRIES-1];
integer reset_i;

wire [INDEX_WIDTH-1:0] query_index  = query_pc[INDEX_WIDTH+1:2];
wire [INDEX_WIDTH-1:0] update_index = update_pc[INDEX_WIDTH+1:2];

assign prefer_b = counters[query_index][1];

// Reset bias: strongly-prefer-A (2'b00) -- the same "cold table defaults
// to the simpler/already-existing option" bias Bht.v's own
// strongly-not-taken reset state uses (a cold chooser shouldn't gamble on
// the newer scheme before it has any evidence either way).
always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < NUM_ENTRIES; reset_i = reset_i + 1)
            counters[reset_i] <= 2'b00;
    end else if (update_valid && (a_correct != b_correct)) begin
        if (b_correct)
            counters[update_index] <= (counters[update_index] == 2'b11) ? 2'b11 : counters[update_index] + 2'b01;
        else
            counters[update_index] <= (counters[update_index] == 2'b00) ? 2'b00 : counters[update_index] - 2'b01;
    end
end

endmodule

`default_nettype wire
