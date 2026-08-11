`default_nettype none

`include "riscv_defs.vh"

// Fused multiply-add for fmadd.s/fmsub.s/fnmsub.s/fnmadd.s (docs/adr/0019-
// f-extension.md, Phase C5). Combinational, like FALU.v -- the "fused"
// part only matters for *precision* (the full, unrounded 48-bit product is
// aligned against the addend and rounded once, at the very end, not
// rounded once for the multiply and again for the add), not for timing.
//
// op[1:0] selects which of the four ops, using the exact encoding RISC-V's
// own opcode assignment already provides: OPCODE_MADD/MSUB/NMSUB/NMADD's
// bits[3:2] are 00/01/10/11 in that order (bit4, easy to assume is part of
// this pair, is 0 for all four -- riscvpipeline.v's first wiring pass used
// [4:3] and got away with it only because fmadd.s's own op happens to be
// 00 regardless; caught by sim/tools/iss.py's independent model, Phase C9),
// so the caller passes `opcode[3:2]` directly. op[1]=negate the product,
// op[0]=negate the addend:
//   fmadd.s  (op=00): +(rs1*rs2) + rs3
//   fmsub.s  (op=01): +(rs1*rs2) - rs3
//   fnmsub.s (op=10): -(rs1*rs2) + rs3
//   fnmadd.s (op=11): -(rs1*rs2) - rs3
//
// Alignment uses a 112-bit common frame (48 bits for the full product +
// 64 bits of headroom, or 24 bits for the addend + 88 bits of headroom --
// whichever operand has the larger true exponent anchors the frame with
// its own leading bit fixed at bit 111, mirroring FALU.v's FADD/FSUB
// swap-for-subtraction technique exactly, just widened to accommodate the
// product's extra 24 bits of precision when the product is the anchor).
// The 112-bit width was chosen generously; a `wide_shift_right_sticky`
// helper (this module's own version of fp_round.vh's shift_right_sticky,
// just parameterized wider) collapses any shift beyond the frame to a pure
// sticky bit, which is mathematically correct, not an approximation: once
// an operand's magnitude is smaller than the frame's own precision floor,
// it cannot affect the final 24-bit rounded result except through
// inexactness.
module FMADDUnit (
    input wire [1:0] op,
    input wire [2:0] rm,
    input wire [31:0] a,    // rs1
    input wire [31:0] b,    // rs2
    input wire [31:0] c,    // rs3 (the addend)
    output reg [31:0] result,
    output reg [4:0] flags    // {NV, DZ, OF, UF, NX} -- DZ never set here
);

localparam [31:0] CANONICAL_NAN = 32'h7FC00000;
localparam FRAME = 112;

wire neg_prod = op[1];
wire neg_addend = op[0];

wire sign_a = a[31];
wire [7:0] exp_a = a[30:23];
wire [22:0] frac_a = a[22:0];
wire sign_b = b[31];
wire [7:0] exp_b = b[30:23];
wire [22:0] frac_b = b[22:0];
wire sign_c = c[31];
wire [7:0] exp_c = c[30:23];
wire [22:0] frac_c = c[22:0];

function is_nan_fm;  input [31:0] x; is_nan_fm  = (x[30:23]==8'hFF) && (x[22:0]!=0); endfunction
function is_snan_fm; input [31:0] x; is_snan_fm = (x[30:23]==8'hFF) && (x[22:0]!=0) && !x[22]; endfunction
function is_inf_fm;  input [31:0] x; is_inf_fm  = (x[30:23]==8'hFF) && (x[22:0]==0); endfunction
function is_zero_fm; input [31:0] x; is_zero_fm = (x[30:23]==8'h00); endfunction

`include "fp_round.vh"

// Same technique as shift_right_sticky, just for the wider 112-bit frame
// this module needs (the product alone is 48 bits, more than fp_round.vh's
// 27-bit version was ever sized for).
function [FRAME-1:0] wide_shift_right_sticky;
    input [FRAME-1:0] sig;
    input signed [11:0] amt;
    reg [FRAME-1:0] shifted;
    reg sticky_acc;
    integer k;
    begin
        if (amt <= 0) begin
            wide_shift_right_sticky = sig;
        end
        else if (amt >= FRAME) begin
            wide_shift_right_sticky = {{(FRAME-1){1'b0}}, |sig};
        end
        else begin
            sticky_acc = 1'b0;
            for (k = 0; k < FRAME; k = k + 1)
                if (k < amt) sticky_acc = sticky_acc | sig[k];
            shifted = sig >> amt;
            shifted[0] = shifted[0] | sticky_acc;
            wide_shift_right_sticky = shifted;
        end
    end
endfunction

always @(*) begin
    flags = 5'b0;
    if (is_nan_fm(a) || is_nan_fm(b) || is_nan_fm(c)) begin
        flags[4] = is_snan_fm(a) || is_snan_fm(b) || is_snan_fm(c);
        result = CANONICAL_NAN;
    end
    else if ((is_inf_fm(a) && is_zero_fm(b)) || (is_zero_fm(a) && is_inf_fm(b))) begin
        flags[4] = 1'b1;  // 0*inf: invalid, regardless of c
        result = CANONICAL_NAN;
    end
    else begin : blk_fmadd_general
        reg prod_inf, prod_sign, prod_is_special;
        reg eff_sign_p, eff_sign_c;
        reg [23:0] mant_a, mant_b, mant_c;
        reg [47:0] product;
        reg [47:0] prod_norm;
        reg signed [9:0] exp_a_u, exp_b_u, exp_c_u, prod_lead_exp, big_exp;
        reg [FRAME-1:0] big_frame, small_frame_aligned, small_frame_raw;
        reg [FRAME:0] sum;
        reg result_sign;
        reg c_is_big;
        reg signed [11:0] small_shift;

        mant_a = {1'b1, frac_a};
        mant_b = {1'b1, frac_b};
        mant_c = {1'b1, frac_c};
        product = mant_a * mant_b;
        prod_sign = sign_a ^ sign_b ^ neg_prod;
        prod_inf = is_inf_fm(a) || is_inf_fm(b);

        eff_sign_c = sign_c ^ neg_addend;

        if (prod_inf && is_inf_fm(c) && (prod_sign != eff_sign_c)) begin
            flags[4] = 1'b1;  // inf + (-inf): invalid
            result = CANONICAL_NAN;
        end
        else if (prod_inf) begin
            result = {prod_sign, 8'hFF, 23'h0};
        end
        else if (is_inf_fm(c)) begin
            result = {eff_sign_c, 8'hFF, 23'h0};
        end
        else if (is_zero_fm(a) || is_zero_fm(b)) begin
            // Product is exactly zero (and finite): result is just the
            // (signed) addend, same zero/sign rules as FALU.v's FADD.
            if (is_zero_fm(c)) begin
                if (prod_sign == eff_sign_c)
                    result = {prod_sign, 31'h0};
                else
                    result = {(rm == `RM_RDN), 31'h0};
            end else begin
                result = {eff_sign_c, exp_c, frac_c};
            end
        end
        else begin : blk_fmadd_finite
            exp_a_u = $signed({2'b0, exp_a}) - 10'sd127;
            exp_b_u = $signed({2'b0, exp_b}) - 10'sd127;

            if (product[47]) begin
                prod_norm = product;
                prod_lead_exp = exp_a_u + exp_b_u + 1;
            end else begin
                prod_norm = product << 1;
                prod_lead_exp = exp_a_u + exp_b_u;
            end

            if (is_zero_fm(c)) begin
                // Addend is exactly zero: result is just the product,
                // rounded once here (still needs proper rounding, unlike a
                // hypothetical "just return the exact product" shortcut).
                {flags[2], flags[1], flags[0], result} = round_and_pack(
                    prod_sign, prod_lead_exp, {1'b0, prod_norm[47:24]},
                    prod_norm[23], prod_norm[22], |prod_norm[21:0], rm);
            end
            else begin : blk_fmadd_nonzero_addend
                exp_c_u = $signed({2'b0, exp_c}) - 10'sd127;

                c_is_big = (exp_c_u > prod_lead_exp) ||
                           ((exp_c_u == prod_lead_exp) && ({mant_c, 24'b0} > {24'b0, prod_norm}));

                if (!c_is_big) begin
                    big_frame = {prod_norm, {(FRAME-48){1'b0}}};
                    big_exp = prod_lead_exp;
                    small_shift = prod_lead_exp - exp_c_u;
                    small_frame_raw = {mant_c, {(FRAME-24){1'b0}}};
                    result_sign = prod_sign;
                end else begin
                    big_frame = {mant_c, {(FRAME-24){1'b0}}};
                    big_exp = exp_c_u;
                    small_shift = exp_c_u - prod_lead_exp;
                    small_frame_raw = {prod_norm, {(FRAME-48){1'b0}}};
                    result_sign = eff_sign_c;
                end
                small_frame_aligned = wide_shift_right_sticky(small_frame_raw, small_shift);

                if (prod_sign == eff_sign_c)
                    sum = {1'b0, big_frame} + {1'b0, small_frame_aligned};
                else
                    sum = {1'b0, big_frame} - {1'b0, small_frame_aligned};  // big_frame >= small_frame_aligned by construction

                if (sum == 0) begin
                    result = {(rm == `RM_RDN), 31'h0};
                end
                else begin : blk_fmadd_renorm
                    integer shl;
                    reg [FRAME:0] renorm;
                    shl = 0;
                    if (!sum[FRAME] && !sum[FRAME-1]) begin
                        renorm = sum;
                        while (!renorm[FRAME-1] && shl < FRAME - 1) begin
                            renorm = renorm << 1;
                            shl = shl + 1;
                        end
                        sum = renorm;
                    end
                    {flags[2], flags[1], flags[0], result} = round_and_pack(
                        result_sign, big_exp - shl, sum[FRAME:FRAME-24],
                        sum[FRAME-25], sum[FRAME-26], |sum[FRAME-27:0], rm);
                end
            end
        end
    end
end

endmodule

`default_nettype wire
