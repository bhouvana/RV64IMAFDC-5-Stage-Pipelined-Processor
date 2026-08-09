`default_nettype none

// docs/adr/0024-variable-latency-memory.md (Phase I1). Generic wait-state
// delay-line primitive, reusing this project's own established
// start/busy/done one-shot contract (Divider.v/Ptw.v's shape) rather than
// inventing a new interlock idiom. LATENCY==0 is a pure combinational
// passthrough -- the bit-exact default every other axis in this project
// already follows (HAZARD_STRATEGY/PIPELINE_PROFILE/BRANCH_PREDICTOR/
// CACHE_MODE). A caller wanting to re-trigger for a new request must gate
// its own `start` on `!busy` (same convention Ptw.v/Divider.v already
// require of their own callers) -- this module ignores a `start` pulse
// that arrives while already busy, rather than restarting the count.
// docs/adr/0043-memory-controller-phase-d.md (Generation 4, Phase D). This
// module itself is unchanged -- LATENCY stays a plain elaboration-time
// constant, one fixed wait-state count per instance. Modeling "a burst
// continuation beat costs less than the first beat" (a genuinely
// per-transaction, runtime-varying choice) is the CALLER's job: instantiate
// this module TWICE (one at MEM_LATENCY_D, one at MEM_LATENCY_D_BURST) and
// mux which instance's start/done to use based on the current beat's own
// Wishbone CTI value -- see riscvpipeline.v's D-side latency wrapper. Kept
// this way rather than adding a runtime latency-select input here, since
// the existing start/busy/done contract (Divider.v/Ptw.v's own shape) is
// already proven and this avoids touching a working primitive.
module MemoryLatencyModel #(
    parameter LATENCY = 0   // additional wait-state cycles beyond the caller's own baseline
)(
    input  wire clk,
    input  wire rst,

    input  wire start,   // pulse: begin a new LATENCY-cycle wait (ignored while busy)
    output wire busy,
    output wire done      // one-cycle pulse, LATENCY cycles after start (same cycle when LATENCY==0)
);

generate
if (LATENCY == 0) begin : gen_passthrough
    assign done = start;
    assign busy = 1'b0;
end else begin : gen_delay
    localparam CTR_BITS = $clog2(LATENCY + 1);

    reg [CTR_BITS-1:0] count_r;
    reg                busy_r, done_r;

    always @(posedge clk) begin
        if (~rst) begin
            busy_r <= 1'b0;
            done_r <= 1'b0;
            count_r <= {CTR_BITS{1'b0}};
        end
        else begin
            done_r <= 1'b0;   // default: one-cycle pulse, cleared unless set below

            if (start && !busy_r) begin
                busy_r  <= 1'b1;
                count_r <= LATENCY[CTR_BITS-1:0] - 1'b1;
            end
            else if (busy_r) begin
                if (count_r == {CTR_BITS{1'b0}}) begin
                    busy_r <= 1'b0;
                    done_r <= 1'b1;
                end
                else begin
                    count_r <= count_r - 1'b1;
                end
            end
        end
    end

    assign busy = busy_r;
    assign done = done_r;
end
endgenerate

endmodule

`default_nettype wire
