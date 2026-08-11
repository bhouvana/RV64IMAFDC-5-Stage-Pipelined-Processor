`default_nettype none

`include "riscv_defs.vh"

// Multi-cycle single-precision divider for fdiv.s (docs/adr/0019-
// f-extension.md, Phase C4). Mirrors design/Divider.v's proven busy/done
// interlock signature exactly (docs/adr/0009-multicycle-divider.md) --
// `start` is a level tied to "the instruction presented is an fdiv.s whose
// result isn't ready yet," held for the instruction's whole stay in EX, not
// a one-shot pulse; `busy`/`done` distinguish a fresh request from a stale
// one the same way, guarding against the exact re-triggering bug class
// docs/adr/0009/0013/0014 already found three times in this project.
//
// Algorithm: restoring shift-subtract division of the two 24-bit
// significands (adapting Divider.v's own proven mantissa-division shape,
// not inventing a new one), computed to enough extra bits of precision for
// correct rounding, plus separate exponent subtraction and IEEE special-
// case handling (NaN/inf/zero) that completes in the same cycle `start`
// first asserts -- mirroring Divider.v's own div-by-zero/overflow
// immediate-completion precedent, since those cases need no iteration.
module FDivider #(
    parameter XLEN = 32
)(
    input wire clk,
    input wire rst,
    input wire start,
    input wire [2:0] rm,           // already-resolved rounding mode (see FALU.v's header comment on RM_DYN resolution)
    input wire [XLEN-1:0] a,       // dividend (float bits)
    input wire [XLEN-1:0] b,       // divisor (float bits)
    output reg busy,
    output reg done,          // one-cycle pulse
    output reg [XLEN-1:0] result,
    output reg [4:0] flags    // {NV, DZ, OF, UF, NX}
);

localparam [31:0] CANONICAL_NAN = 32'h7FC00000;

wire sign_a = a[31];
wire [7:0] exp_a = a[30:23];
wire [22:0] frac_a = a[22:0];
wire sign_b = b[31];
wire [7:0] exp_b = b[30:23];
wire [22:0] frac_b = b[22:0];

function is_nan_fd;  input [31:0] x; is_nan_fd  = (x[30:23]==8'hFF) && (x[22:0]!=0); endfunction
function is_snan_fd; input [31:0] x; is_snan_fd = (x[30:23]==8'hFF) && (x[22:0]!=0) && !x[22]; endfunction
function is_inf_fd;  input [31:0] x; is_inf_fd  = (x[30:23]==8'hFF) && (x[22:0]==0); endfunction
function is_zero_fd; input [31:0] x; is_zero_fd = (x[30:23]==8'h00); endfunction

`include "fp_round.vh"

// Quotient/remainder shift register: Q_init = {mant_a (24 bits), 27'b0} --
// the 27-bit zero pad is what makes this a *fractional* extension of the
// division (24 real bits, then 27 more iterations effectively dividing in
// 27 extra zero bits), giving a 51-bit quotient whose true value always
// lands in (2^26, 2^28) -- enough headroom below the leading bit for a
// full 24-bit kept significand plus guard+round, with the final remainder
// serving as sticky (see NUM_ITERS below).
localparam PAD = 27;
localparam QW = 24 + PAD;  // 51
localparam CNT_WIDTH = $clog2(QW);

reg [24:0] R;                 // working remainder, 1 bit wider than D for safety headroom
reg [QW-1:0] Q;
reg [23:0] D;
reg [CNT_WIDTH-1:0] count;

reg result_sign;
reg signed [9:0] exp_a_u, exp_b_u;
reg [24:0] R_shifted, new_R;
reg [QW-1:0] new_Q;

always @(posedge clk) begin
    if (~rst) begin
        busy <= 1'b0;
        done <= 1'b0;
        result <= {XLEN{1'b0}};
        flags <= 5'b0;
    end
    else begin
        done <= 1'b0;  // default: one-cycle pulse, cleared unless set below

        // See Divider.v's identical comment: `start` stays asserted through
        // the exact cycle `done` pulses (the caller's hold only releases the
        // cycle after), so `&& !done` here prevents re-triggering a second,
        // bogus division against the same (stale, about-to-be-replaced)
        // operands before the real result is consumed.
        if (start && !busy && !done) begin
            if (is_nan_fd(a) || is_nan_fd(b)) begin
                done <= 1'b1;
                result <= CANONICAL_NAN;
                flags <= {(is_snan_fd(a) || is_snan_fd(b)), 4'b0};
            end
            else if (is_inf_fd(a) && is_inf_fd(b)) begin
                done <= 1'b1;
                result <= CANONICAL_NAN;
                flags <= 5'b10000;  // inf/inf: invalid
            end
            else if (is_zero_fd(a) && is_zero_fd(b)) begin
                done <= 1'b1;
                result <= CANONICAL_NAN;
                flags <= 5'b10000;  // 0/0: invalid
            end
            else if (is_inf_fd(a)) begin
                done <= 1'b1;
                result <= {sign_a ^ sign_b, 8'hFF, 23'h0};  // inf/finite -> inf
                flags <= 5'b0;
            end
            else if (is_inf_fd(b)) begin
                done <= 1'b1;
                result <= {sign_a ^ sign_b, 31'h0};  // finite/inf -> 0
                flags <= 5'b0;
            end
            else if (is_zero_fd(b)) begin
                done <= 1'b1;
                result <= {sign_a ^ sign_b, 8'hFF, 23'h0};  // finite-nonzero/0 -> inf
                flags <= 5'b01000;  // DZ
            end
            else if (is_zero_fd(a)) begin
                done <= 1'b1;
                result <= {sign_a ^ sign_b, 31'h0};  // 0/finite-nonzero -> 0
                flags <= 5'b0;
            end
            else begin
                // General case: both finite, nonzero -- start the iterative
                // mantissa division. flags is explicitly cleared here (not
                // just left to whatever round_and_pack sets at completion):
                // NV/DZ are only ever driven high by the special-case
                // branches above, never explicitly driven low again once
                // this path is taken, so without this a stale NV/DZ from a
                // *previous* division (e.g. an earlier divide-by-zero)
                // would silently persist into this one's result.
                flags <= 5'b0;
                result_sign <= sign_a ^ sign_b;
                exp_a_u <= $signed({2'b0, exp_a}) - 10'sd127;
                exp_b_u <= $signed({2'b0, exp_b}) - 10'sd127;
                R <= {25{1'b0}};
                Q <= {{1'b1, frac_a}, {PAD{1'b0}}};
                D <= {1'b1, frac_b};
                count <= {CNT_WIDTH{1'b0}};
                busy <= 1'b1;
            end
        end
        else if (busy) begin
            // One restoring-division step: shift {R,Q} left by 1 (pulling
            // Q's top bit into R), then either subtract D (if it fits,
            // recording quotient bit 1) or leave R alone (quotient bit 0)
            // -- the exact shape design/Divider.v already established and
            // verified (docs/adr/0009), just applied to the 24-bit
            // significands instead of full XLEN-wide integers.
            // new_Q/new_R are blocking locals so the final cycle's packing
            // step (below) can use this iteration's just-computed values
            // directly -- Q/R themselves only update via the nonblocking
            // assignment, which wouldn't be visible until the *next* clock
            // edge, one cycle too late for the last iteration (a real
            // off-by-one this caught: reading the stale, pre-this-cycle Q
            // on the final iteration silently used only QW-1 iterations'
            // worth of shifting, exactly halving the result).
            R_shifted = {R[23:0], Q[QW-1]};
            if (R_shifted >= {1'b0, D}) begin
                new_R = R_shifted - {1'b0, D};
                new_Q = {Q[QW-2:0], 1'b1};
            end else begin
                new_R = R_shifted;
                new_Q = {Q[QW-2:0], 1'b0};
            end
            R <= new_R;
            Q <= new_Q;

            if (count == QW - 1) begin
                busy <= 1'b0;
                done <= 1'b1;
                // Q's true value always lands in (2^26, 2^28) -- exactly one
                // of bit27/bit26 is the leading 1 (see module header),
                // decided explicitly here rather than leaned on
                // round_and_pack's own carry-handling (that mechanism is
                // for a genuine arithmetic carry-out during accumulation,
                // not this structural two-case ambiguity -- see docs/adr/
                // 0019's FALU.v FMUL bug for why conflating the two is a
                // real, previously-hit bug class).
                if (new_Q[27]) begin
                    {flags[2], flags[1], flags[0], result} <= round_and_pack(
                        result_sign, exp_a_u - exp_b_u,
                        {1'b0, new_Q[27:4]}, new_Q[3], new_Q[2], new_Q[1] | new_Q[0] | (new_R != 0), rm);
                end else begin
                    {flags[2], flags[1], flags[0], result} <= round_and_pack(
                        result_sign, exp_a_u - exp_b_u - 1,
                        {1'b0, new_Q[26:3]}, new_Q[2], new_Q[1], new_Q[0] | (new_R != 0), rm);
                end
                flags[4] <= 1'b0;  // NV: only ever set by the special-case branch above
            end
            count <= count + 1'b1;
        end
    end
end

endmodule

`default_nettype wire
