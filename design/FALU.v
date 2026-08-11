`default_nettype none

`include "riscv_defs.vh"

// Combinational single-precision FPU datapath (docs/adr/0019-f-extension.md,
// Phase C). Covers every RV32F op that is neither multi-cycle (fdiv.s/
// fsqrt.s, see FDivider.v/FSqrt.v) nor fused-multiply-add (see FMADDUnit.v,
// Phase C5) -- fadd.s/fsub.s/fmul.s, sign injection, min/max, classify,
// compare, int<->float conversion, and the bit-pattern-only moves
// (fmv.x.w/fmv.w.x). Dispatched by OP-FP's funct5 (inst[31:27]), with
// funct3/rs2 sub-selecting within a shared funct5 group exactly as
// riscv_defs.vh documents.
//
// Two deliberate, documented simplifications (see docs/adr/0019's Design
// section for the full rationale, not repeated per-callsite here):
//   - No NaN-boxing: this core implements F only, never D, so FLEN==XLEN==32
//     exactly and every float register always holds a real 32-bit value.
//   - Subnormals are flushed to zero, both on input (any operand with a
//     zero exponent field is treated as +/-0 for arithmetic) and on output
//     (a result whose true exponent underflows below the minimum normal
//     exponent is flushed to a correctly-signed zero, with UF+NX set).
//     fclass.s is the one exception: it inspects the *raw encoding*, not
//     the arithmetically-flushed value, so a genuinely subnormal-encoded
//     input still classifies as subnormal even though arithmetic ops would
//     treat it as zero.
//
// `rm` is expected already resolved to a real IEEE rounding mode (RNE/RTZ/
// RDN/RUP/RMM) by the caller -- resolving RM_DYN against fcsr's live frm is
// riscvpipeline.v's job (docs/adr/0019 Phase C8), not this module's. An
// unrecognized rm value defensively falls back to RNE rather than risking
// X-propagation; this is not a spec requirement, just avoiding an
// unnecessary latch/X risk here.
module FALU (
    input wire [4:0] funct5,
    input wire [2:0] funct3,     // sub-selects within FUNCT5_FSGNJ/FMINMAX/FCMP/FMV_X_W_FCLASS, and doubles as the *rm* field for FADD/FSUB/FMUL/conversions
    input wire [4:0] rs2_sel,    // sub-selects within FUNCT5_FCVT_W_S/FUNCT5_FCVT_S_W (which is 0 unused elsewhere)
    input wire [31:0] a,         // rs1 (float bits, or integer bits for fcvt.s.w/fcvt.s.wu)
    input wire [31:0] b,         // rs2 (float bits; unused for single-operand ops)
    output reg [31:0] result,       // float bits, or an integer value -- caller (Control.v-driven routing) knows which
    output reg [4:0] flags          // {NV, DZ, OF, UF, NX} -- DZ never set here (FDIV/FSQRT-only)
);

localparam [2:0] RM_UNUSED = 3'b000;  // placeholder for ops with no rounding decision (sign-inject, min/max, compare, classify, fmv)

// ---- field extraction ----
wire sign_a = a[31];
wire [7:0] exp_a = a[30:23];
wire [22:0] frac_a = a[22:0];
wire sign_b = b[31];
wire [7:0] exp_b = b[30:23];
wire [22:0] frac_b = b[22:0];

function is_nan_f;
    input [31:0] x;
    is_nan_f = (x[30:23] == 8'hFF) && (x[22:0] != 0);
endfunction

function is_snan_f;
    input [31:0] x;
    is_snan_f = (x[30:23] == 8'hFF) && (x[22:0] != 0) && !x[22];
endfunction

function is_inf_f;
    input [31:0] x;
    is_inf_f = (x[30:23] == 8'hFF) && (x[22:0] == 0);
endfunction

// Arithmetic zero test -- true for a real zero AND for a (flushed) subnormal.
function is_zero_arith_f;
    input [31:0] x;
    is_zero_arith_f = (x[30:23] == 8'h00);
endfunction

localparam [31:0] CANONICAL_NAN = 32'h7FC00000;

`include "fp_round.vh"

// ==========================================================================
// FADD/FSUB
// ==========================================================================
wire is_sub = (funct5 == `FUNCT5_FSUB);
wire eff_sign_b = sign_b ^ is_sub;   // the sign b effectively contributes once fsub negates it

reg [31:0] addsub_result;
reg [4:0]  addsub_flags;

always @(*) begin
    addsub_flags = 5'b0;
    if (is_nan_f(a) || is_nan_f(b)) begin
        addsub_flags[4] = is_snan_f(a) || is_snan_f(b);  // NV
        addsub_result = CANONICAL_NAN;
    end
    else if (is_inf_f(a) && is_inf_f(b) && (sign_a != eff_sign_b)) begin
        addsub_flags[4] = 1'b1;  // inf + (-inf): invalid
        addsub_result = CANONICAL_NAN;
    end
    else if (is_inf_f(a)) begin
        addsub_result = {sign_a, 8'hFF, 23'h0};
    end
    else if (is_inf_f(b)) begin
        addsub_result = {eff_sign_b, 8'hFF, 23'h0};
    end
    else if (is_zero_arith_f(a) && is_zero_arith_f(b)) begin
        // x + (-x): +0 in every rounding mode except round-toward-negative,
        // where it's -0. Same-sign zeros just keep that sign.
        if (sign_a == eff_sign_b)
            addsub_result = {sign_a, 31'h0};
        else
            addsub_result = {(funct3 == `RM_RDN), 31'h0};
    end
    else if (is_zero_arith_f(a)) begin
        addsub_result = {eff_sign_b, exp_b, frac_b};
    end
    else if (is_zero_arith_f(b)) begin
        addsub_result = a;
    end
    else begin : blk_addsub_general
        // General case: both operands are real, nonzero, finite numbers.
        // Working frame per operand: 27 bits = {24-bit significand
        // (implicit-1 + 23 fraction), 3 bits of guard/round/sticky
        // tracking, initially 0, populated by shift_right_sticky below}.
        reg [23:0] mant_a, mant_b;
        reg signed [9:0] exp_a_u, exp_b_u, exp_diff;
        reg [26:0] big_al, small_al;  // "big"/"small" by magnitude, not by which operand (a or b) they came from
        reg [27:0] sum;               // 1 extra bit of headroom for an addition carry-out
        reg result_sign;
        reg signed [9:0] result_exp;
        reg swap;   // true if b's magnitude is >= a's -- decides which operand is the subtraction minuend so it never goes negative

        mant_a = {1'b1, frac_a};  // exp_a==0 already excluded above by is_zero_arith_f
        mant_b = {1'b1, frac_b};
        exp_a_u = $signed({2'b0, exp_a}) - 10'sd127;
        exp_b_u = $signed({2'b0, exp_b}) - 10'sd127;

        // Equal exponents don't imply equal magnitude -- the mantissas
        // still have to be compared directly, or a subtraction could try
        // to compute a negative unsigned difference.
        if (exp_a_u == exp_b_u)
            swap = (mant_b > mant_a);
        else
            swap = (exp_b_u > exp_a_u);

        if (!swap) begin
            exp_diff = exp_a_u - exp_b_u;
            result_exp = exp_a_u;
            big_al   = {mant_a, 3'b0};
            small_al = shift_right_sticky({mant_b, 3'b0}, exp_diff);
            result_sign = sign_a;
        end else begin
            exp_diff = exp_b_u - exp_a_u;
            result_exp = exp_b_u;
            big_al   = {mant_b, 3'b0};
            small_al = shift_right_sticky({mant_a, 3'b0}, exp_diff);
            result_sign = eff_sign_b;
        end

        if (sign_a == eff_sign_b)
            sum = {1'b0, big_al} + {1'b0, small_al};
        else
            sum = {1'b0, big_al} - {1'b0, small_al};  // big_al >= small_al by construction above, never underflows

        // Exact cancellation: the "x + (-x) = +0 (or -0 in RDN)" rule
        // applies here too, since the operands' own signs no longer mean
        // anything once they've fully cancelled.
        if (sum == 0) begin
            addsub_result = {(funct3 == `RM_RDN), 31'h0};
            addsub_flags = 5'b0;
        end else begin
            // Expected implicit-1 position (no addition carry) is sum[26].
            // A subtraction can cancel leading bits (result much smaller
            // than either operand) -- renormalize left before rounding (a
            // left shift never loses information, unlike the right shifts
            // alignment uses). An addition carrying out of sum[26] instead
            // sets sum[27], which round_and_pack's own carry-handling deals
            // with directly (it expects that bit at sig[24]).
            if (!sum[27] && !sum[26]) begin : blk_renorm
                integer shl;
                reg [27:0] renorm;
                shl = 0;
                renorm = sum;
                while (!renorm[26] && shl < 27) begin
                    renorm = renorm << 1;
                    shl = shl + 1;
                end
                sum = renorm;
                result_exp = result_exp - shl;
            end
            {addsub_flags[2], addsub_flags[1], addsub_flags[0], addsub_result} =
                round_and_pack(result_sign, result_exp, sum[27:3], sum[2], sum[1], sum[0], funct3);
        end
    end
end

// ==========================================================================
// FMUL
// ==========================================================================
reg [31:0] mul_result;
reg [4:0]  mul_flags;

always @(*) begin
    mul_flags = 5'b0;
    if (is_nan_f(a) || is_nan_f(b)) begin
        mul_flags[4] = is_snan_f(a) || is_snan_f(b);
        mul_result = CANONICAL_NAN;
    end
    else if ((is_inf_f(a) && is_zero_arith_f(b)) || (is_zero_arith_f(a) && is_inf_f(b))) begin
        mul_flags[4] = 1'b1;  // 0 * inf: invalid
        mul_result = CANONICAL_NAN;
    end
    else if (is_inf_f(a) || is_inf_f(b)) begin
        mul_result = {sign_a ^ sign_b, 8'hFF, 23'h0};
    end
    else if (is_zero_arith_f(a) || is_zero_arith_f(b)) begin
        mul_result = {sign_a ^ sign_b, 31'h0};
    end
    else begin : blk_mul_general
        reg [23:0] mant_a, mant_b;
        reg [47:0] product;
        reg signed [9:0] exp_a_u, exp_b_u, result_exp;
        reg [24:0] top25;
        reg g, r, st;

        mant_a = {1'b1, frac_a};
        mant_b = {1'b1, frac_b};
        exp_a_u = $signed({2'b0, exp_a}) - 10'sd127;
        exp_b_u = $signed({2'b0, exp_b}) - 10'sd127;
        product = mant_a * mant_b;  // 24x24 -> 48 bits; result in [1,4), so bit47 or bit46 is the top 1

        // Normalize explicitly here rather than leaning on round_and_pack's
        // own carry-handling (that mechanism is for a genuine arithmetic
        // carry-out during accumulation, e.g. FADD/FSUB -- product[47] vs
        // product[46] is instead a structural feature of where 1.a*1.b's
        // leading digit lands, and its guard/round/sticky bits sit one
        // position further down than a same-shaped adder carry would).
        // Always present top25[24]=0 (no carry) so round_and_pack applies
        // no further shift here.
        if (product[47]) begin
            top25 = {1'b0, product[47:24]};
            g = product[23]; r = product[22]; st = |product[21:0];
            result_exp = exp_a_u + exp_b_u + 1;
        end else begin
            top25 = {1'b0, product[46:23]};
            g = product[22]; r = product[21]; st = |product[20:0];
            result_exp = exp_a_u + exp_b_u;
        end

        {mul_flags[2], mul_flags[1], mul_flags[0], mul_result} =
            round_and_pack(sign_a ^ sign_b, result_exp, top25, g, r, st, funct3);
    end
end

// ==========================================================================
// Sign injection: fsgnj.s/fsgnjn.s/fsgnjx.s -- always exact, no rounding,
// no flags, propagates a's exponent/fraction verbatim (even if a is NaN --
// sign injection is a pure bit-pattern op, it does not quiet a signaling
// NaN or otherwise inspect validity).
// ==========================================================================
reg sgnj_sign;
always @(*) begin
    case (funct3)
        `F3_FSGNJ_J:  sgnj_sign = sign_b;
        `F3_FSGNJ_JN: sgnj_sign = ~sign_b;
        `F3_FSGNJ_JX: sgnj_sign = sign_a ^ sign_b;
        default:      sgnj_sign = sign_a;
    endcase
end
wire [31:0] sgnj_result = {sgnj_sign, exp_a, frac_a};

// ==========================================================================
// fmin.s/fmax.s -- IEEE 754-2008 minNum/maxNum semantics: a signaling NaN
// operand sets NV; if exactly one operand is NaN (signaling or quiet), the
// *other* operand wins outright (NaN never wins a min/max); if both are
// NaN, canonical NaN. -0.0 is treated as strictly less than +0.0 for min/
// max purposes specifically (unlike feq.s, where they compare equal).
// ==========================================================================
reg [31:0] minmax_result;
reg [4:0] minmax_flags;
always @(*) begin
    minmax_flags = 5'b0;
    if (is_nan_f(a) && is_nan_f(b)) begin
        minmax_flags[4] = is_snan_f(a) || is_snan_f(b);
        minmax_result = CANONICAL_NAN;
    end
    else if (is_nan_f(a)) begin
        minmax_flags[4] = is_snan_f(a);
        minmax_result = b;
    end
    else if (is_nan_f(b)) begin
        minmax_flags[4] = is_snan_f(b);
        minmax_result = a;
    end
    else begin : blk_minmax_general
        reg a_is_neg_zero, b_is_neg_zero;
        reg a_lt_b;
        a_is_neg_zero = is_zero_arith_f(a) && sign_a;
        b_is_neg_zero = is_zero_arith_f(b) && sign_b;
        if (is_zero_arith_f(a) && is_zero_arith_f(b))
            a_lt_b = a_is_neg_zero && !b_is_neg_zero;
        else if (sign_a != sign_b)
            a_lt_b = sign_a;  // negative < positive
        else if (sign_a)
            a_lt_b = ({exp_a, frac_a} > {exp_b, frac_b});  // both negative: bigger magnitude is smaller value
        else
            a_lt_b = ({exp_a, frac_a} < {exp_b, frac_b});
        if (funct3 == `F3_FMIN)
            minmax_result = a_lt_b ? a : b;
        else
            minmax_result = a_lt_b ? b : a;
    end
end

// ==========================================================================
// Compares: feq.s/flt.s/fle.s -- write an INTEGER result (0 or 1). feq.s
// only sets NV for a signaling NaN operand (a "quiet" comparison); flt.s/
// fle.s set NV for *any* NaN operand (signaling or quiet), since ordering
// is invalid for a quiet NaN too, unlike equality. Any NaN operand makes
// the comparison result false, per spec, in every case.
// ==========================================================================
reg [31:0] cmp_result;
reg [4:0] cmp_flags;
always @(*) begin
    cmp_flags = 5'b0;
    if (is_nan_f(a) || is_nan_f(b)) begin
        if (funct3 == `F3_FEQ)
            cmp_flags[4] = is_snan_f(a) || is_snan_f(b);
        else
            cmp_flags[4] = is_nan_f(a) || is_nan_f(b);
        cmp_result = 32'b0;
    end
    else begin : blk_cmp_general
        reg a_is_neg_zero, b_is_neg_zero, both_zero;
        reg eq, lt;
        a_is_neg_zero = is_zero_arith_f(a) && sign_a;
        b_is_neg_zero = is_zero_arith_f(b) && sign_b;
        both_zero = is_zero_arith_f(a) && is_zero_arith_f(b);
        eq = both_zero ? 1'b1 : (a == b);  // +0 == -0 for compares (unlike fmin/fmax)
        if (both_zero)
            lt = 1'b0;
        else if (sign_a != sign_b)
            lt = sign_a;
        else if (sign_a)
            lt = ({exp_a, frac_a} > {exp_b, frac_b});
        else
            lt = ({exp_a, frac_a} < {exp_b, frac_b});
        case (funct3)
            `F3_FEQ: cmp_result = {31'b0, eq};
            `F3_FLT: cmp_result = {31'b0, lt};
            `F3_FLE: cmp_result = {31'b0, lt || eq};
            default: cmp_result = 32'b0;
        endcase
    end
end

// ==========================================================================
// fclass.s -- pure bit-pattern classification (writes an INTEGER result).
// Deliberately does NOT apply this module's subnormal-flush-to-zero
// deviation: it inspects the raw encoding, so a genuinely subnormal-encoded
// operand reports as subnormal, not zero.
// ==========================================================================
reg [31:0] class_result;
always @(*) begin
    class_result = 32'b0;
    if (exp_a == 8'hFF && frac_a == 0 && sign_a)       class_result[0] = 1'b1;  // -infinity
    else if (exp_a != 8'h00 && exp_a != 8'hFF && sign_a) class_result[1] = 1'b1;  // -normal
    else if (exp_a == 8'h00 && frac_a != 0 && sign_a)  class_result[2] = 1'b1;  // -subnormal
    else if (exp_a == 8'h00 && frac_a == 0 && sign_a)  class_result[3] = 1'b1;  // -0
    else if (exp_a == 8'h00 && frac_a == 0 && !sign_a) class_result[4] = 1'b1;  // +0
    else if (exp_a == 8'h00 && frac_a != 0 && !sign_a) class_result[5] = 1'b1;  // +subnormal
    else if (exp_a != 8'h00 && exp_a != 8'hFF && !sign_a) class_result[6] = 1'b1;  // +normal
    else if (exp_a == 8'hFF && frac_a == 0 && !sign_a) class_result[7] = 1'b1;  // +infinity
    else if (exp_a == 8'hFF && frac_a != 0 && !frac_a[22]) class_result[8] = 1'b1;  // signaling NaN
    else if (exp_a == 8'hFF && frac_a != 0 && frac_a[22]) class_result[9] = 1'b1;  // quiet NaN
end

// ==========================================================================
// fcvt.w.s/fcvt.wu.s -- float -> integer (INTEGER result). Out-of-range and
// NaN inputs saturate to the destination format's canonical value per spec
// (not a wrapped/truncated bit pattern) and set NV; a merely-rounded
// in-range result sets NX instead, never both.
// ==========================================================================
reg [31:0] cvt_to_int_result;
reg [4:0] cvt_to_int_flags;
always @(*) begin
    cvt_to_int_flags = 5'b0;
    if (is_nan_f(a)) begin
        cvt_to_int_flags[4] = 1'b1;
        cvt_to_int_result = (rs2_sel == `RS2_FCVT_WU) ? 32'hFFFFFFFF : 32'h7FFFFFFF;
    end
    else if (is_zero_arith_f(a)) begin
        cvt_to_int_result = 32'b0;
    end
    else begin : blk_cvt_to_int_general
        reg [23:0] mant;
        reg signed [9:0] exp_u;
        reg [26:0] shifted;   // {24-bit magnitude-ish, guard, round, sticky} -- see below
        reg guard, round_bit, sticky_bit;
        reg [63:0] magnitude;
        reg round_up;
        reg out_of_range;

        mant = {1'b1, frac_a};
        exp_u = $signed({2'b0, exp_a}) - 10'sd127;

        if (is_inf_f(a) || exp_u > 31) begin
            cvt_to_int_flags[4] = 1'b1;
            if (rs2_sel == `RS2_FCVT_WU)
                cvt_to_int_result = sign_a ? 32'h00000000 : 32'hFFFFFFFF;
            else
                cvt_to_int_result = sign_a ? 32'h80000000 : 32'h7FFFFFFF;
        end
        else begin
            if (exp_u >= 23) begin
                // Exact: every one of mant's 23 fraction bits is already at
                // or above the integer boundary, so this is a plain left
                // shift, never a rounding decision. exp_u<=31 here, so the
                // shift is at most 8 -- mant (24 bits) << 8 fits in 32 bits.
                magnitude = {40'b0, mant} << (exp_u - 23);
                guard = 1'b0; round_bit = 1'b0; sticky_bit = 1'b0;
            end else begin
                // shift_right_sticky's frame is {24-bit mant, 3-bit
                // headroom} -- shifting right by (23-exp_u) correctly
                // lands the integer part at bits[26:3] of the result (the
                // 3-bit headroom is what bits[2:0] -- guard/round/sticky
                // -- come from), with every bit actually shifted past the
                // kept window folded into sticky by the function itself.
                // amt can reach up to 24 here (exp_u as low as -1); wider
                // underflow (exp_u<-1, i.e. magnitude<0.5) collapses
                // through the same >=27 sticky-only path shift_right_sticky
                // already handles, so no separate branch is needed for it.
                shifted = shift_right_sticky({mant, 3'b0}, 23 - exp_u);
                magnitude = {40'b0, shifted[26:3]};
                guard = shifted[2]; round_bit = shifted[1]; sticky_bit = shifted[0];
            end

            case (funct3)
                `RM_RNE: round_up = guard && (round_bit || sticky_bit || magnitude[0]);
                `RM_RTZ: round_up = 1'b0;
                `RM_RDN: round_up = sign_a && (guard || round_bit || sticky_bit);
                `RM_RUP: round_up = !sign_a && (guard || round_bit || sticky_bit);
                `RM_RMM: round_up = guard;
                default: round_up = guard && (round_bit || sticky_bit || magnitude[0]);
            endcase
            magnitude = round_up ? magnitude + 1 : magnitude;
            cvt_to_int_flags[0] = guard || round_bit || sticky_bit;

            out_of_range = 1'b0;
            if (rs2_sel == `RS2_FCVT_WU) begin
                if (sign_a && magnitude != 0) out_of_range = 1'b1;
                else if (magnitude > 64'hFFFFFFFF) out_of_range = 1'b1;
            end else begin
                if (!sign_a && magnitude > 64'h000000007FFFFFFF) out_of_range = 1'b1;
                else if (sign_a && magnitude > 64'h0000000080000000) out_of_range = 1'b1;
            end

            if (out_of_range) begin
                cvt_to_int_flags[4] = 1'b1;
                cvt_to_int_flags[0] = 1'b0;
                if (rs2_sel == `RS2_FCVT_WU)
                    cvt_to_int_result = sign_a ? 32'h00000000 : 32'hFFFFFFFF;
                else
                    cvt_to_int_result = sign_a ? 32'h80000000 : 32'h7FFFFFFF;
            end else begin
                cvt_to_int_result = sign_a ? (~magnitude[31:0] + 1'b1) : magnitude[31:0];
            end
        end
    end
end

// ==========================================================================
// fcvt.s.w/fcvt.s.wu -- integer -> float (FLOAT result). Exact whenever the
// integer's magnitude fits in 24 significant bits (every value up to
// +/-2^24 is exactly representable); rounded per rm otherwise, with NX set
// when rounding actually discards a nonzero bit.
// ==========================================================================
reg [31:0] cvt_from_int_result;
reg [4:0] cvt_from_int_flags;
always @(*) begin
    cvt_from_int_flags = 5'b0;
    if (a == 32'b0) begin
        cvt_from_int_result = 32'b0;
    end
    else begin : blk_cvt_from_int_general
        reg src_sign;
        reg [31:0] magnitude;
        reg [4:0] lead;
        reg [31:0] norm;
        reg [23:0] mant24;
        reg guard, round_bit, sticky_bit;
        reg signed [9:0] exp_unbiased;
        reg [24:0] sig25;

        if (rs2_sel == `RS2_FCVT_WU) begin
            src_sign = 1'b0;
            magnitude = a;
        end else begin
            src_sign = a[31];
            magnitude = a[31] ? (~a + 1'b1) : a;
        end

        lead = 0;
        norm = magnitude;
        while (!norm[31] && lead < 31) begin
            norm = norm << 1;
            lead = lead + 1;
        end
        exp_unbiased = 31 - lead;

        mant24 = norm[31:8];
        guard = norm[7];
        round_bit = norm[6];
        sticky_bit = |norm[5:0];

        sig25 = {1'b0, mant24};
        {cvt_from_int_flags[2], cvt_from_int_flags[1], cvt_from_int_flags[0], cvt_from_int_result} =
            round_and_pack(src_sign, exp_unbiased, sig25, guard, round_bit, sticky_bit, funct3);
    end
end

// ==========================================================================
// fmv.x.w/fmv.w.x -- pure bit-pattern reinterpretation, no arithmetic, no
// flags, never traps on any bit pattern (not even NaN payloads).
// ==========================================================================
wire [31:0] fmv_result = a;

// ==========================================================================
// Top-level dispatch
// ==========================================================================
always @(*) begin
    case (funct5)
        `FUNCT5_FADD, `FUNCT5_FSUB: begin result = addsub_result; flags = addsub_flags; end
        `FUNCT5_FMUL:               begin result = mul_result;    flags = mul_flags;    end
        `FUNCT5_FSGNJ:              begin result = sgnj_result;   flags = 5'b0;         end
        `FUNCT5_FMINMAX:            begin result = minmax_result; flags = minmax_flags; end
        `FUNCT5_FCMP:               begin result = cmp_result;    flags = cmp_flags;    end
        `FUNCT5_FCVT_W_S:           begin result = cvt_to_int_result;   flags = cvt_to_int_flags;   end
        `FUNCT5_FCVT_S_W:           begin result = cvt_from_int_result; flags = cvt_from_int_flags; end
        `FUNCT5_FMV_X_W_FCLASS:     begin
            if (funct3 == `F3_FCLASS) begin result = class_result; flags = 5'b0; end
            else                      begin result = fmv_result;   flags = 5'b0; end
        end
        `FUNCT5_FMV_W_X:            begin result = fmv_result; flags = 5'b0; end
        default:                    begin result = 32'b0; flags = 5'b0; end
    endcase
end

endmodule

`default_nettype wire
