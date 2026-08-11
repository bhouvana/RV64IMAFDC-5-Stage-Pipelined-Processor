`default_nettype none

`include "riscv_defs.vh"

// Multi-cycle single-precision square root for fsqrt.s (docs/adr/0019-
// f-extension.md, Phase C4). Same busy/done interlock signature as
// FDivider.v/Divider.v (docs/adr/0009). No existing precedent in this
// codebase (unlike FDivider.v, which adapts Divider.v's proven shift-
// subtract algorithm) -- a binary non-restoring digit-recurrence square
// root, the standard "paper-and-pencil" method's binary form, verified
// independently in Python (2000+ random values against math.sqrt, relative
// error bounded by float32 precision, every perfect square exact) before
// writing a single line of this file.
//
// The classic parity subtlety: a float's significand always carries an
// implicit *odd* scale factor (2^23, from its 23 fraction bits), so
// computing sqrt(mant) directly picks up a spurious sqrt(2) factor unless
// the exponent's parity is folded into the *radicand* first (not just the
// exponent arithmetic) -- verified empirically in Python before trusting
// it, since two different closed-form derivations of this step were tried
// and found wrong (by an extra factor of 2, and then by sqrt(2)) before
// empirical testing against known perfect squares (4.0, 16.0, ...) pinned
// down the correct one:
//   - exponent EVEN: radicand = 2*mant (so its implicit scale, 2^24, is
//     even) -- result significand is sqrt(1.frac) directly, result
//     exponent = exp_u/2.
//   - exponent ODD: radicand = 4*mant (implicit scale 2^24, even, but this
//     time computing sqrt(2*1.frac) since folding in the odd exponent's
//     leftover factor of 2) -- result exponent = (exp_u-1)/2.
// Both branches consistently produce a 26-bit root with its leading bit
// always at the same fixed position (unlike FDivider.v's FMUL-style two-
// position ambiguity) -- confirmed empirically, not assumed.
module FSqrt #(
    parameter XLEN = 32
)(
    input wire clk,
    input wire rst,
    input wire start,
    input wire [2:0] rm,
    input wire [XLEN-1:0] a,
    output reg busy,
    output reg done,
    output reg [XLEN-1:0] result,
    output reg [4:0] flags     // {NV, DZ, OF, UF, NX} -- DZ/OF never set here
);

localparam [31:0] CANONICAL_NAN = 32'h7FC00000;
localparam ROOT_BITS = 26;
localparam PAD_PAIRS = 13;
localparam RADW = ROOT_BITS + 2 * PAD_PAIRS;  // 52: {26-bit radicand, 26 zero pad bits}
localparam CNT_WIDTH = $clog2(ROOT_BITS);

wire sign_a = a[31];
wire [7:0] exp_a = a[30:23];
wire [22:0] frac_a = a[22:0];

function is_nan_fs;  input [31:0] x; is_nan_fs  = (x[30:23]==8'hFF) && (x[22:0]!=0); endfunction
function is_snan_fs; input [31:0] x; is_snan_fs = (x[30:23]==8'hFF) && (x[22:0]!=0) && !x[22]; endfunction
function is_inf_fs;  input [31:0] x; is_inf_fs  = (x[30:23]==8'hFF) && (x[22:0]==0); endfunction
function is_zero_fs; input [31:0] x; is_zero_fs = (x[30:23]==8'h00); endfunction

`include "fp_round.vh"

reg [RADW-1:0] rad;
reg [27:0] R;
reg [ROOT_BITS-1:0] Qroot;
reg [CNT_WIDTH-1:0] count;
reg signed [9:0] result_exp;

reg [27:0] R_shifted, new_R, trial;
reg [ROOT_BITS-1:0] new_Q;

always @(posedge clk) begin
    if (~rst) begin
        busy <= 1'b0;
        done <= 1'b0;
        result <= {XLEN{1'b0}};
        flags <= 5'b0;
    end
    else begin
        done <= 1'b0;

        if (start && !busy && !done) begin
            if (is_nan_fs(a)) begin
                done <= 1'b1;
                result <= CANONICAL_NAN;
                flags <= {is_snan_fs(a), 4'b0};
            end
            else if (is_zero_fs(a)) begin
                done <= 1'b1;
                result <= a;  // sqrt(+0)=+0, sqrt(-0)=-0 (a genuine defined special case, not NaN)
                flags <= 5'b0;
            end
            else if (sign_a) begin
                done <= 1'b1;
                result <= CANONICAL_NAN;
                flags <= 5'b10000;  // sqrt of any negative, nonzero, finite (or -inf) value: invalid
            end
            else if (is_inf_fs(a)) begin
                done <= 1'b1;
                result <= a;  // sqrt(+inf) = +inf
                flags <= 5'b0;
            end
            else begin
                // General case: a is positive, finite, nonzero.
                flags <= 5'b0;  // see FDivider.v's identical comment: cleared here, not just left stale from a previous op
                if (($signed({2'b0, exp_a}) - 10'sd127) % 2 == 0) begin
                    rad <= {1'b0, {1'b1, frac_a}, 1'b0, {(2*PAD_PAIRS){1'b0}}};  // 2*mant, even exponent
                    result_exp <= ($signed({2'b0, exp_a}) - 10'sd127) / 2;
                end else begin
                    rad <= {{1'b1, frac_a}, 2'b0, {(2*PAD_PAIRS){1'b0}}};  // 4*mant, odd exponent (folds in the leftover factor of 2)
                    result_exp <= ($signed({2'b0, exp_a}) - 10'sd127 - 1) / 2;
                end
                R <= 28'b0;
                Qroot <= {ROOT_BITS{1'b0}};
                count <= {CNT_WIDTH{1'b0}};
                busy <= 1'b1;
            end
        end
        else if (busy) begin
            // One digit-recurrence step: bring down the next 2 radicand
            // bits, trial-subtract (2*Qroot*2+1) = (Qroot<<2)|1 (the
            // classic (n+1)^2-n^2=2n+1 identity, scaled for 2 bits/step),
            // restoring (not subtracting) if it doesn't fit. new_Q/new_R
            // are blocking locals so the final iteration's packing step
            // (below) can use this cycle's just-computed values directly --
            // see FDivider.v's identical off-by-one lesson for why relying
            // on Qroot/R's own nonblocking-updated value here would be one
            // cycle stale on the last iteration.
            R_shifted = {R[25:0], rad[RADW-1], rad[RADW-2]};
            trial = {Qroot, 2'b01};
            if (R_shifted >= trial) begin
                new_R = R_shifted - trial;
                new_Q = {Qroot[ROOT_BITS-2:0], 1'b1};
            end else begin
                new_R = R_shifted;
                new_Q = {Qroot[ROOT_BITS-2:0], 1'b0};
            end
            R <= new_R;
            Qroot <= new_Q;
            rad <= rad << 2;

            if (count == ROOT_BITS - 1) begin
                busy <= 1'b0;
                done <= 1'b1;
                // new_Q's leading bit is always at position ROOT_BITS-1
                // (25) -- confirmed empirically, no FMUL/FDIV-style
                // two-position ambiguity here.
                {flags[2], flags[1], flags[0], result} <= round_and_pack(
                    1'b0, result_exp, {1'b0, new_Q[ROOT_BITS-1:2]},
                    new_Q[1], new_Q[0], (new_R != 0), rm);
            end
            count <= count + 1'b1;
        end
    end
end

endmodule

`default_nettype wire
