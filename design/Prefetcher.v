`default_nettype none

// docs/adr/0046-hardware-prefetchers-phase-g.md (Generation 4, Phase G). A
// single-global-entry address predictor -- NOT a PC-indexed table. Neither
// ICache.v nor DCache.v has a per-access PC available at the point a miss
// is recognized (confirmed by direct research before writing this module,
// not assumed) -- adding one would mean new pipeline plumbing, out of scope
// for this phase. # ponytail: table-of-1, keyed on the raw miss-address
// stream, not per-PC -- upgrade to an N-entry PC-indexed table only if a
// future phase threads PC into the caches and multi-stream interleaving
// turns out to matter.
//
// Fires only on a genuine demand-miss (update_valid pulses once per real
// miss, reusing each caller's own existing miss-detection condition) --
// never on a hit. Fixed 1-line-ahead prediction for every mode (confirmed
// via AskUserQuestion: no PREFETCH_DEGREE parameter, this project's own
// tiny benchmark kernels can't meaningfully validate a different value
// either way).
//
// pf_valid/pf_addr are driven ENTIRELY from registered state
// (last_addr_r/last_stride_r/stride_confirmed_r/run_count_r) -- never
// combinationally re-derived from the live update_addr input outside a
// cycle update_valid is actually asserted. update_addr is only meaningful
// the exact cycle update_valid pulses; a caller sampling pf_valid/pf_addr
// while otherwise idle (the normal case -- most cycles) must see a stable
// answer regardless of whatever update_addr happens to be driving at that
// moment.
module Prefetcher #(
    parameter XLEN = 32,
    parameter LINE_BYTES = 16,
    parameter MODE = 0   // PF_OFF=0 / PF_NEXT_LINE=1 / PF_STRIDE=2 / PF_STREAM=3
)(
    input clk, rst,
    input                  update_valid,  // pulses once per genuine demand miss
    input      [XLEN-1:0]  update_addr,   // that miss's line-aligned address
    output                 pf_valid,
    output     [XLEN-1:0]  pf_addr        // predicted next line-aligned address
);

localparam PF_OFF       = 0;
localparam PF_NEXT_LINE = 1;
localparam PF_STRIDE    = 2;
localparam PF_STREAM    = 3;

// A stream is only trusted after this many CONSECUTIVE confirmed strides --
// distinguishes a genuine sequential/strided pattern from a one-off
// coincidental stride match. Stride mode (2) trusts the first confirmation;
// stream mode (3) needs a longer, more confident run before it starts
// prefetching ahead -- same more-confidence-for-a-stronger-claim
// distinction real HW stream detectors make.
localparam STREAM_CONFIRM_RUN = 2;

reg                   have_last_r;        // seen at least one update ever
reg [XLEN-1:0]        last_addr_r;        // address of the most recent update
reg                   have_stride_r;      // last_stride_r holds a real (not reset-default) estimate
reg signed [XLEN-1:0] last_stride_r;      // most recently OBSERVED stride (not yet necessarily confirmed twice)
reg                   stride_confirmed_r; // this cycle's stride estimate repeated the PRIOR one
reg [7:0]             run_count_r;        // consecutive confirmations, saturates informally (never realistically overflows at 8 bits for this project's own tiny test programs)

// Computed live from update_addr -- only ever CONSUMED on a cycle
// update_valid is high (inside the always block below), never leaks into
// pf_valid/pf_addr directly.
wire signed [XLEN-1:0] observed_stride    = $signed(update_addr) - $signed(last_addr_r);
wire                   this_update_confirms = have_stride_r && (observed_stride == last_stride_r) && (observed_stride != 0);

always @(posedge clk) begin
    if (~rst) begin
        have_last_r        <= 1'b0;
        have_stride_r       <= 1'b0;
        stride_confirmed_r  <= 1'b0;
        run_count_r         <= 8'd0;
        last_addr_r         <= {XLEN{1'b0}};
        last_stride_r       <= {XLEN{1'b0}};
    end
    else if (update_valid) begin
        if (have_last_r) begin
            stride_confirmed_r <= this_update_confirms;
            run_count_r        <= this_update_confirms ? (run_count_r + 8'd1) : 8'd0;
            last_stride_r      <= observed_stride;
            have_stride_r      <= 1'b1;
        end
        last_addr_r <= update_addr;
        have_last_r <= 1'b1;
    end
end

// LINE_BYTES is a plain (default-width) parameter -- zero-extend explicitly
// before adding, rather than a direct `LINE_BYTES[XLEN-1:0]` part-select,
// which would be a real out-of-range slice at XLEN==64 (same warning-
// flagged bug class docs/adr/0045's own req_wdata_ext64 comment documents;
// this idiom mirrors DataMemoryBRAM.v's own established zero-extend-first
// pattern instead).
wire [XLEN-1:0] next_line_addr = last_addr_r + {{(XLEN-32){1'b0}}, LINE_BYTES[31:0]};
wire [XLEN-1:0] strided_addr   = last_addr_r + last_stride_r;

assign pf_valid = (MODE == PF_NEXT_LINE) ? have_last_r
                 : (MODE == PF_STRIDE)   ? stride_confirmed_r
                 : (MODE == PF_STREAM)   ? (run_count_r >= STREAM_CONFIRM_RUN[7:0])
                 : 1'b0;
assign pf_addr  = (MODE == PF_NEXT_LINE) ? next_line_addr : strided_addr;

endmodule

`default_nettype wire
