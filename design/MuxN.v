`default_nettype none

// docs/adr/0018-variable-pipeline-depth.md (Phase A5) -- generalized
// replacement for the two forwarding Mux4to1 instances in riscvpipeline.v,
// paired with Forward.v's own NUM_FWD_SRC generalization: NUM_SRC forwarding
// candidates (flattened into one bus, farthest-producer-first at index 0,
// matching Forward.v's fwd_dest ordering) plus the always-present s0
// "no forward, use the value read from the register file" input. sel=0
// selects s0; sel=i+1 selects forwarding source i. An out-of-range sel
// (possible when NUM_SRC+1 isn't a power of 2, e.g. NUM_SRC=2's sel=2'b11)
// falls back to s0, same as Mux4to1's own s0 default.
//
// riscvpipeline.v's lui/auipc select mux is a separate, unrelated use of
// Mux4to1 (not forwarding) and is untouched by this module.
module MuxN #(
    parameter size = 32,
    parameter NUM_SRC = 2
) (
    input wire [$clog2(NUM_SRC+1)-1:0] sel,
    input wire signed [size-1:0] s0,
    input wire signed [NUM_SRC*size-1:0] src,
    output reg signed [size-1:0] out
);

integer i;
always @(*) begin
    out = s0;
    for (i = 0; i < NUM_SRC; i = i + 1)
        if (sel == (i + 1))
            out = src[i*size +: size];
end

endmodule

`default_nettype wire
