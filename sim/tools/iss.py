#!/usr/bin/env python3
"""
Minimal functional reference model (instruction set simulator) for this
core's exact ISA -- RV32I + RV32M + the B extension (Zba+Zbb+Zbs, docs/
adr/0060) plus its specific deviations from standard RISC-V (the ble/bgt
custom branches; ctz(0)==XLEN, matching real ctz semantics, since docs/
adr/0041 fixed the prior ctz(0)==XLEN-1 off-by-one -- ctz itself now lives
at its real Zbb encoding, not a custom opcode, since docs/adr/0060).
Sequential, one instruction at a time --
no pipeline, no hazards, because a sequential model has none by
construction. Used by sim/tools/random_gen.py to compute expected final
architectural state for constrained-random programs (docs/ROADMAP.md V-4),
since hand-computing expected values doesn't scale past directed tests.

This is deliberately a *second, independent* implementation of the ISA
semantics, not a reuse of design/*.v or sim/tools/asm.py's encoding tables
beyond the opcode constants -- the whole point is to catch RTL/model
disagreements, which an implementation that shares its logic with the
thing it's checking cannot do.
"""


def s32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


def u32(v):
    return v & 0xFFFFFFFF


# Generation 2 (Phase M, docs/adr/0028-rv64-migration-phase-m.md). s32/u32
# above stay fixed-32-bit forever -- deliberately reused as-is wherever a
# value is ALWAYS 32 bits regardless of the core's own XLEN (F-extension
# float bit patterns, this core's own CSR storage, which docs/adr/0028's own
# MMU-forced-off-at-XLEN=64 scoping decision keeps exactly RV32-shaped, and
# the "w"-suffixed family's own 32-bit intermediate computation before its
# final sign-extension to XLEN). sXLEN/uXLEN below are the *register-width*
# analogues, consulting an ISS instance's own self.xlen -- Python's
# arbitrary-precision ints make these correct at any width for free (a
# negative Python int's bitwise AND with a mask is already real two's-
# complement truncation, no special-casing needed).
def sXLEN(v, xlen):
    v &= (1 << xlen) - 1
    return v - (1 << xlen) if v & (1 << (xlen - 1)) else v


def uXLEN(v, xlen):
    return v & ((1 << xlen) - 1)


def sext(v, bits):
    # Sign-extend a `bits`-wide field to a full-width signed value -- NOT
    # the same as s32(), which only correctly sign-extends a value that is
    # already a full 32-bit two's-complement quantity (checks bit 31).
    # Applying s32() directly to a narrower immediate field (12-bit I/S-type,
    # 13-bit B-type, 21-bit J-type) silently does nothing, since those
    # values are always < 0x80000000 before extension.
    v &= (1 << bits) - 1
    if v & (1 << (bits - 1)):
        v -= (1 << bits)
    return v


CSR_MSTATUS, CSR_MTVEC, CSR_MSCRATCH, CSR_MEPC, CSR_MCAUSE = 0x300, 0x305, 0x340, 0x341, 0x342
MCAUSE_ILLEGAL_INSTRUCTION, MCAUSE_BREAKPOINT, MCAUSE_ECALL_FROM_M = 2, 3, 11

# docs/adr/0020-soc-integration.md (Phase D10). Matches design/riscv_defs.vh's
# MCAUSE_INT_MACHINE_TIMER/MCAUSE_INT_MACHINE_EXTERNAL (7/11) with bit31 (the
# interrupt-vs-exception bit) set -- the two interrupt causes an externally
# scheduled trap() call below can raise.
MCAUSE_INT_MACHINE_TIMER = 0x80000007
MCAUSE_INT_MACHINE_EXTERNAL = 0x8000000B

# ==========================================================================
# docs/adr/00NN-mmu-sv32.md (Phase F6). Sv32 MMU: a from-scratch, independent
# page-table walker matching design/Ptw.v bit-for-bit (same fault
# conditions, same cause codes, same 20-bit PPN truncation -- see Ptw.v's
# own header for why this core truncates PPN to 20 bits instead of the full
# spec 22), plus the S-mode CSR storage design/CSR.v gained in F1 and the
# real privilege-aware trap/mret/sret machinery riscvpipeline.v/CSR.v gained
# in F3. Unlike branch prediction's zero-ISS-change case, address
# translation affects every memory access, not scheduled points -- this is
# not optional or reducible, per the phase plan's own assessment.
# ==========================================================================
CSR_SSTATUS, CSR_SIE, CSR_STVEC, CSR_SSCRATCH = 0x100, 0x104, 0x105, 0x140
CSR_SEPC, CSR_SCAUSE, CSR_STVAL, CSR_SIP, CSR_SATP = 0x141, 0x142, 0x143, 0x144, 0x180
CSR_MIE, CSR_MIP, CSR_MTVAL, CSR_MEDELEG, CSR_MIDELEG = 0x304, 0x344, 0x343, 0x302, 0x303

MCAUSE_ECALL_FROM_U, MCAUSE_ECALL_FROM_S = 8, 9
MCAUSE_INSTRUCTION_PAGE_FAULT, MCAUSE_LOAD_PAGE_FAULT, MCAUSE_STORE_PAGE_FAULT = 12, 13, 15

# 2-bit privilege encoding, matches design/riscv_defs.vh's PRIV_U/PRIV_S/PRIV_M
# exactly -- numerically ordered so a plain `<` comparison (CSR access-
# privilege checks below) works the same way riscvpipeline.v's own
# csr_priv_violation does.
PRIV_U, PRIV_S, PRIV_M = 0b00, 0b01, 0b11

MSTATUS_SIE_BIT, MSTATUS_SPIE_BIT, MSTATUS_SPP_BIT, MSTATUS_MPP_LO = 1, 5, 8, 11
MIE_SSIE_BIT, MIE_STIE_BIT, MIE_SEIE_BIT = 1, 5, 9
MIE_MSIE_BIT = 3  # docs/adr/0034-uart-clint-register-compat-phase-r.md (Phase R)

# Generation 3, Phase O (docs/adr/0031). RV64-only mstatus.UXL/SXL, matches
# design/riscv_defs.vh's MSTATUS_UXL_LO/MSTATUS_SXL_LO -- fixed WARL-to-2
# ("64-bit") read-mux constants, not real storage, matching CSR.v exactly.
MSTATUS_UXL_LO, MSTATUS_SXL_LO = 32, 34
MXL_XLEN64 = 2

# Sv32 PTE bit positions, matches design/riscv_defs.vh's PTE_*_BIT exactly.
# Identical positions in the Sv39 PTE format too (design/Ptw39.v's own
# header documents this -- PPN starts at bit 10 in both formats regardless
# of total width), so these are reused verbatim by _translate_sv39 below.
PTE_V_BIT, PTE_R_BIT, PTE_W_BIT, PTE_X_BIT, PTE_U_BIT = 0, 1, 2, 3, 4
SATP_MODE_BIT = 31

# docs/adr/00NN-sv39-mmu-phase-p.md (Phase P4). Sv39 satp layout (RV64
# only), matches design/riscv_defs.vh's SATP64_MODE_HI/LO, SATP64_PPN_HI/LO,
# SATP_MODE_SV39 exactly.
SATP64_MODE_LO = 60
SATP_MODE_SV39 = 8


# ==========================================================================
# docs/adr/0019-f-extension.md (Phase C9): RV32F reference model. Independent
# of design/*.v's own logic by construction (same reason the integer ISS
# above is independent of design/*.v/asm.py): every arithmetic op here is
# computed with exact rational arithmetic (fractions.Fraction) and rounded
# once, at the very end, rather than mirroring the RTL's internal bit-level
# mechanics (guard/round/sticky bits, alignment shifts, digit-recurrence
# division/sqrt) -- an independent *result*, not an independent copy of the
# same algorithm. This is the same "exact Fraction arithmetic, then round"
# approach the standalone Python reference models used to verify
# FALU.v/FDivider.v/FSqrt.v/FMADDUnit.v during C3-C5, reused here as the
# live oracle for random cross-checks instead of a one-off verification
# script.
#
# Mirrors this core's two documented IEEE 754 deviations exactly (not
# textbook-correct float32, which would produce spurious mismatches against
# a bug-free RTL): no NaN-boxing (moot -- F-only, FLEN==XLEN==32), and
# subnormals flushed to zero on both input and output (docs/adr/0019's
# Design section). Validated against numpy.float32 (3000/3000 matched for
# fadd/fsub/fmul/fdiv/fsqrt each, RNE) and against every existing directed
# float testbench's hand-computed expected values before being wired in
# below as the live ISS.step() dispatch.
# ==========================================================================
import math
from fractions import Fraction

RM_RNE, RM_RTZ, RM_RDN, RM_RUP, RM_RMM, RM_DYN = 0, 1, 2, 3, 4, 7

CSR_FFLAGS, CSR_FRM, CSR_FCSR = 0x001, 0x002, 0x003

CANONICAL_NAN = 0x7FC00000

# {NV, DZ, OF, UF, NX} bit positions, matching design/fp_round.vh exactly.
F_NV, F_DZ, F_OF, F_UF, F_NX = 0b10000, 0b01000, 0b00100, 0b00010, 0b00001


def f32_decode(bits):
    """bits -> (sign, is_zero, is_inf, is_nan, is_snan, magnitude:Fraction|None).
    Subnormal-encoded inputs (exp==0, mant!=0) flush to signed zero on input
    (design/FALU.v's documented simplification) -- magnitude is None for
    inf/nan, a Fraction (possibly 0) otherwise."""
    bits &= 0xFFFFFFFF
    sign = (bits >> 31) & 1
    exp = (bits >> 23) & 0xFF
    mant = bits & 0x7FFFFF
    if exp == 0xFF:
        if mant == 0:
            return sign, False, True, False, False, None
        is_snan = ((mant >> 22) & 1) == 0
        return sign, False, False, True, is_snan, None
    if exp == 0:
        return sign, True, False, False, False, Fraction(0)
    magnitude = Fraction((1 << 23) | mant, 1 << 23) * (Fraction(2) ** (exp - 127))
    return sign, False, False, False, False, magnitude


def f32_is_zero_arith(bits):
    # True for a real zero AND a (flushed) subnormal -- matches FALU.v's
    # is_zero_arith_f exactly (checks only the exponent field).
    return ((bits >> 23) & 0xFF) == 0


def f32_pack_zero(sign):
    return (sign & 1) << 31


def f32_pack_inf(sign):
    return ((sign & 1) << 31) | (0xFF << 23)


def _f32_round_up_decision(cls, sig_floor, sign, rm):
    # cls: 'exact' | 'below' | 'tie' | 'above' -- classification of the
    # exact fractional remainder against 1/2. Mirrors design/fp_round.vh's
    # round_and_pack case statement bit-for-bit, including its defensive
    # RNE fallback for an unrecognized rm.
    if cls == "exact":
        return False, False
    if rm == RM_RTZ:
        return False, True
    if rm == RM_RDN:
        return (sign == 1), True
    if rm == RM_RUP:
        return (sign == 0), True
    if rm == RM_RMM:
        return (cls != "below"), True
    # RM_RNE, and the defensive fallback for anything else
    if cls == "above":
        return True, True
    if cls == "below":
        return False, True
    return bool(sig_floor & 1), True  # exact tie -> round to even


def _f32_pack_rounded(sign, e, sig_floor, cls, rm):
    """sig_floor: 24-bit int (2^23 <= sig_floor < 2^24) already normalized
    against unbiased exponent e. Returns (bits, flags) with only OF/UF/NX
    ever set (NV/DZ are the caller's concern, per every RTL module's own
    `flags` convention)."""
    round_up, inexact = _f32_round_up_decision(cls, sig_floor, sign, rm)
    if round_up:
        sig_floor += 1
        if sig_floor == (1 << 24):
            sig_floor >>= 1
            e += 1

    if e > 127:
        # Overflow does NOT always mean infinity -- RTZ always truncates to
        # the largest finite value, and RDN/RUP only overflow to infinity in
        # the direction they round toward (docs/fp_round.vh's own comment).
        if rm == RM_RTZ or (rm == RM_RDN and sign == 0) or (rm == RM_RUP and sign == 1):
            bits = (sign << 31) | (0xFE << 23) | 0x7FFFFF
        else:
            bits = (sign << 31) | (0xFF << 23)
        return bits, F_OF | F_NX
    if e < -126:
        return f32_pack_zero(sign), F_UF | F_NX
    exp_biased = e + 127
    bits = (sign << 31) | (exp_biased << 23) | (sig_floor & 0x7FFFFF)
    return bits, (F_NX if inexact else 0)


def _f32_normalize_fraction(magnitude):
    """Positive exact Fraction -> (e, sig_floor, remainder_cls) with
    2^23 <= sig_floor < 2^24 and magnitude == (sig_floor + r) * 2^(e-23)."""
    two = Fraction(2)
    e = magnitude.numerator.bit_length() - magnitude.denominator.bit_length() - 1
    while magnitude >= two ** (e + 1):
        e += 1
    while magnitude < two ** e:
        e -= 1
    sig_exact = magnitude * (two ** (23 - e))
    sig_floor = sig_exact.numerator // sig_exact.denominator
    remainder = sig_exact - sig_floor
    half = Fraction(1, 2)
    if remainder == 0:
        cls = "exact"
    elif remainder < half:
        cls = "below"
    elif remainder > half:
        cls = "above"
    else:
        cls = "tie"
    return e, sig_floor, cls


def _f32_sqrt_normalize(magnitude):
    """Positive exact (dyadic) Fraction -> (e, sig_floor, cls) for
    sqrt(magnitude), via exact integer sqrt (math.isqrt) -- no irrational
    approximation, no precision loss."""
    two = Fraction(2)
    e = (magnitude.numerator.bit_length() - magnitude.denominator.bit_length()) // 2 - 1
    while magnitude >= two ** (2 * (e + 1)):
        e += 1
    while magnitude < two ** (2 * e):
        e -= 1
    scaled = magnitude * (two ** (2 * (23 - e)))
    assert scaled.denominator == 1, "fsqrt input expected dyadic (a single decoded float32)"
    n = scaled.numerator
    sig_floor = math.isqrt(n)
    if sig_floor * sig_floor == n:
        cls = "exact"
    else:
        mid_sq = (2 * sig_floor + 1) ** 2
        four_n = 4 * n
        cls = "below" if four_n < mid_sq else ("above" if four_n > mid_sq else "tie")
    return e, sig_floor, cls


def f32_round_from_fraction(sign, magnitude, rm):
    """Shared entry point for add/sub/mul/div/fma: magnitude is the exact
    nonnegative Fraction result (0 handled by the caller before this)."""
    e, sig_floor, cls = _f32_normalize_fraction(magnitude)
    return _f32_pack_rounded(sign, e, sig_floor, cls, rm)


def f32_round_from_sqrt(sign, magnitude, rm):
    e, sig_floor, cls = _f32_sqrt_normalize(magnitude)
    return _f32_pack_rounded(sign, e, sig_floor, cls, rm)


# ---- per-op semantics -- special-case dispatch order/results mirror
# design/FALU.v / FDivider.v / FSqrt.v / FMADDUnit.v exactly (they are the
# spec this model is checked against, not textbook IEEE 754 in the
# abstract -- e.g. the documented subnormal-flush-to-zero deviation). ----

def f_add(a_bits, b_bits, rm, is_sub):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    sb, zb, ib, nb, snb, mb = f32_decode(b_bits)
    eff_sb = sb ^ (1 if is_sub else 0)
    if na or nb:
        return CANONICAL_NAN, (F_NV if (sna or snb) else 0)
    if ia and ib and (sa != eff_sb):
        return CANONICAL_NAN, F_NV
    if ia:
        return f32_pack_inf(sa), 0
    if ib:
        return f32_pack_inf(eff_sb), 0
    if za and zb:
        if sa == eff_sb:
            return f32_pack_zero(sa), 0
        return f32_pack_zero(1 if rm == RM_RDN else 0), 0
    if za:
        return (eff_sb << 31) | (b_bits & 0x7FFFFFFF), 0
    if zb:
        return a_bits, 0
    va = ma if sa == 0 else -ma
    vb = mb if eff_sb == 0 else -mb
    total = va + vb
    if total == 0:
        return f32_pack_zero(1 if rm == RM_RDN else 0), 0
    sign = 1 if total < 0 else 0
    return f32_round_from_fraction(sign, abs(total), rm)


def f_mul(a_bits, b_bits, rm):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    sb, zb, ib, nb, snb, mb = f32_decode(b_bits)
    if na or nb:
        return CANONICAL_NAN, (F_NV if (sna or snb) else 0)
    if (ia and zb) or (za and ib):
        return CANONICAL_NAN, F_NV
    if ia or ib:
        return f32_pack_inf(sa ^ sb), 0
    if za or zb:
        return f32_pack_zero(sa ^ sb), 0
    return f32_round_from_fraction(sa ^ sb, ma * mb, rm)


def f_div(a_bits, b_bits, rm):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    sb, zb, ib, nb, snb, mb = f32_decode(b_bits)
    if na or nb:
        return CANONICAL_NAN, (F_NV if (sna or snb) else 0)
    if ia and ib:
        return CANONICAL_NAN, F_NV
    if za and zb:
        return CANONICAL_NAN, F_NV
    if ia:
        return f32_pack_inf(sa ^ sb), 0
    if ib:
        return f32_pack_zero(sa ^ sb), 0
    if zb:
        return f32_pack_inf(sa ^ sb), F_DZ
    if za:
        return f32_pack_zero(sa ^ sb), 0
    return f32_round_from_fraction(sa ^ sb, ma / mb, rm)


def f_sqrt(a_bits, rm):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    if na:
        return CANONICAL_NAN, (F_NV if sna else 0)
    if za:
        return a_bits, 0  # sqrt(+/-0) = +/-0, a defined special case
    if sa:
        return CANONICAL_NAN, F_NV  # sqrt of any negative, nonzero, finite (or -inf) value
    if ia:
        return a_bits, 0  # sqrt(+inf) = +inf
    return f32_round_from_sqrt(0, ma, rm)


def f_madd(a_bits, b_bits, c_bits, rm, neg_prod, neg_addend):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    sb, zb, ib, nb, snb, mb = f32_decode(b_bits)
    sc, zc, ic, nc, snc, mc = f32_decode(c_bits)
    if na or nb or nc:
        return CANONICAL_NAN, (F_NV if (sna or snb or snc) else 0)
    if (ia and zb) or (za and ib):
        return CANONICAL_NAN, F_NV
    prod_sign = sa ^ sb ^ (1 if neg_prod else 0)
    prod_inf = ia or ib
    eff_sc = sc ^ (1 if neg_addend else 0)
    if prod_inf and ic and (prod_sign != eff_sc):
        return CANONICAL_NAN, F_NV
    if prod_inf:
        return f32_pack_inf(prod_sign), 0
    if ic:
        return f32_pack_inf(eff_sc), 0
    if za or zb:
        # product is exactly zero (and finite)
        if zc:
            if prod_sign == eff_sc:
                return f32_pack_zero(prod_sign), 0
            return f32_pack_zero(1 if rm == RM_RDN else 0), 0
        return (eff_sc << 31) | (c_bits & 0x7FFFFFFF), 0
    # General finite case: exact product +/- exact addend, rounded once.
    prod_val = ma * mb  # exact, nonnegative
    prod_signed = prod_val if prod_sign == 0 else -prod_val
    addend_signed = mc if eff_sc == 0 else -mc
    total = prod_signed + addend_signed
    if total == 0:
        return f32_pack_zero(1 if rm == RM_RDN else 0), 0
    sign = 1 if total < 0 else 0
    return f32_round_from_fraction(sign, abs(total), rm)


def f_sgnj(a_bits, b_bits, funct3):
    sa = (a_bits >> 31) & 1
    sb = (b_bits >> 31) & 1
    if funct3 == 0b000:
        sign = sb
    elif funct3 == 0b001:
        sign = sb ^ 1
    else:
        sign = sa ^ sb
    return (sign << 31) | (a_bits & 0x7FFFFFFF), 0


def f_minmax(a_bits, b_bits, funct3):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    sb, zb, ib, nb, snb, mb = f32_decode(b_bits)
    if na and nb:
        return CANONICAL_NAN, (F_NV if (sna or snb) else 0)
    if na:
        return b_bits, (F_NV if sna else 0)
    if nb:
        return a_bits, (F_NV if snb else 0)
    a_ez, b_ez = f32_is_zero_arith(a_bits), f32_is_zero_arith(b_bits)
    a_nz = a_ez and ((a_bits >> 31) & 1)
    b_nz = b_ez and ((b_bits >> 31) & 1)
    if a_ez and b_ez:
        a_lt_b = a_nz and not b_nz
    elif sa != sb:
        a_lt_b = bool(sa)
    elif sa:
        a_lt_b = (a_bits & 0x7FFFFFFF) > (b_bits & 0x7FFFFFFF)
    else:
        a_lt_b = (a_bits & 0x7FFFFFFF) < (b_bits & 0x7FFFFFFF)
    is_min = (funct3 == 0b000)
    if is_min:
        return (a_bits if a_lt_b else b_bits), 0
    return (b_bits if a_lt_b else a_bits), 0


def f_cmp(a_bits, b_bits, funct3):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    sb, zb, ib, nb, snb, mb = f32_decode(b_bits)
    if na or nb:
        if funct3 == 0b010:  # feq.s: only sNaN raises NV
            flags = F_NV if (sna or snb) else 0
        else:  # flt.s/fle.s: any NaN raises NV
            flags = F_NV
        return 0, flags
    a_ez, b_ez = f32_is_zero_arith(a_bits), f32_is_zero_arith(b_bits)
    both_zero = a_ez and b_ez
    eq = True if both_zero else (a_bits == b_bits)
    if both_zero:
        lt = False
    elif sa != sb:
        lt = bool(sa)
    elif sa:
        lt = (a_bits & 0x7FFFFFFF) > (b_bits & 0x7FFFFFFF)
    else:
        lt = (a_bits & 0x7FFFFFFF) < (b_bits & 0x7FFFFFFF)
    if funct3 == 0b010:
        res = 1 if eq else 0
    elif funct3 == 0b001:
        res = 1 if lt else 0
    else:
        res = 1 if (lt or eq) else 0
    return res, 0


def f_class(a_bits):
    sa = (a_bits >> 31) & 1
    exp = (a_bits >> 23) & 0xFF
    frac = a_bits & 0x7FFFFF
    if exp == 0xFF and frac == 0 and sa:
        return 1 << 0
    if exp not in (0, 0xFF) and sa:
        return 1 << 1
    if exp == 0 and frac != 0 and sa:
        return 1 << 2
    if exp == 0 and frac == 0 and sa:
        return 1 << 3
    if exp == 0 and frac == 0 and not sa:
        return 1 << 4
    if exp == 0 and frac != 0 and not sa:
        return 1 << 5
    if exp not in (0, 0xFF) and not sa:
        return 1 << 6
    if exp == 0xFF and frac == 0 and not sa:
        return 1 << 7
    if exp == 0xFF and frac != 0 and not (frac >> 22 & 1):
        return 1 << 8
    return 1 << 9


def f_cvt_to_int(a_bits, rm, unsigned):
    sa, za, ia, na, sna, ma = f32_decode(a_bits)
    if na:
        return (0xFFFFFFFF if unsigned else 0x7FFFFFFF), F_NV
    if za:
        return 0, 0
    if ia:
        res = (0 if sa else 0xFFFFFFFF) if unsigned else (0x80000000 if sa else 0x7FFFFFFF)
        return res, F_NV
    # Round the exact magnitude directly to the nearest *integer* -- this is
    # integer-target rounding (absolute precision at bit 0), a different
    # target precision than f32_round_from_fraction's float32-significand
    # rounding (relative precision at 23 fraction bits), so it must use its
    # own floor/remainder classification against magnitude itself, not go
    # through _f32_normalize_fraction. Python's arbitrary-precision ints make
    # the RTL's own "is_inf(a) || exp_u > 31" pre-check unnecessary here --
    # an astronomically large exact magnitude just produces an
    # astronomically large Python int, still caught correctly by the same
    # out-of-range bounds check used for every other case.
    floor_mag = ma.numerator // ma.denominator
    remainder = ma - floor_mag
    half = Fraction(1, 2)
    if remainder == 0:
        cls = "exact"
    elif remainder < half:
        cls = "below"
    elif remainder > half:
        cls = "above"
    else:
        cls = "tie"
    round_up, inexact = _f32_round_up_decision(cls, floor_mag, sa, rm)
    magnitude = floor_mag + (1 if round_up else 0)
    if unsigned:
        out_of_range = (sa and magnitude != 0) or magnitude > 0xFFFFFFFF
    else:
        out_of_range = (not sa and magnitude > 0x7FFFFFFF) or (sa and magnitude > 0x80000000)
    if out_of_range:
        res = (0 if sa else 0xFFFFFFFF) if unsigned else (0x80000000 if sa else 0x7FFFFFFF)
        return res, F_NV
    res = (magnitude & 0xFFFFFFFF) if not sa else ((-magnitude) & 0xFFFFFFFF)
    return res, (F_NX if inexact else 0)


def f_cvt_from_int(a_bits, rm, unsigned):
    if a_bits == 0:
        return 0, 0
    if unsigned:
        sign = 0
        magnitude = a_bits & 0xFFFFFFFF
    else:
        sign = (a_bits >> 31) & 1
        magnitude = ((~a_bits + 1) & 0xFFFFFFFF) if sign else a_bits
    return f32_round_from_fraction(sign, Fraction(magnitude), rm)


# ---- Pillar K (docs/adr/0059 Gen7-K7) AES support functions ----
# Same source as design/ALU.v's own AES ROMs/functions: the ratified
# scalar-crypto spec's reference Sail model (riscv/sail-riscv,
# model/riscv_types_kext.sail, at the exact commit riscv/riscv-crypto's own
# .gitmodules pins -- 4feadb75cff594db27ba94c586e0ad6895f9fa50). Kept as an
# independent transcription (not imported from the RTL) so this ISS is a
# genuine cross-check, not a copy that would silently agree with an RTL bug.
_AES_SBOX_FWD = [
    0x63,0x7c,0x77,0x7b,0xf2,0x6b,0x6f,0xc5,0x30,0x01,0x67,0x2b,0xfe,0xd7,0xab,0x76,
    0xca,0x82,0xc9,0x7d,0xfa,0x59,0x47,0xf0,0xad,0xd4,0xa2,0xaf,0x9c,0xa4,0x72,0xc0,
    0xb7,0xfd,0x93,0x26,0x36,0x3f,0xf7,0xcc,0x34,0xa5,0xe5,0xf1,0x71,0xd8,0x31,0x15,
    0x04,0xc7,0x23,0xc3,0x18,0x96,0x05,0x9a,0x07,0x12,0x80,0xe2,0xeb,0x27,0xb2,0x75,
    0x09,0x83,0x2c,0x1a,0x1b,0x6e,0x5a,0xa0,0x52,0x3b,0xd6,0xb3,0x29,0xe3,0x2f,0x84,
    0x53,0xd1,0x00,0xed,0x20,0xfc,0xb1,0x5b,0x6a,0xcb,0xbe,0x39,0x4a,0x4c,0x58,0xcf,
    0xd0,0xef,0xaa,0xfb,0x43,0x4d,0x33,0x85,0x45,0xf9,0x02,0x7f,0x50,0x3c,0x9f,0xa8,
    0x51,0xa3,0x40,0x8f,0x92,0x9d,0x38,0xf5,0xbc,0xb6,0xda,0x21,0x10,0xff,0xf3,0xd2,
    0xcd,0x0c,0x13,0xec,0x5f,0x97,0x44,0x17,0xc4,0xa7,0x7e,0x3d,0x64,0x5d,0x19,0x73,
    0x60,0x81,0x4f,0xdc,0x22,0x2a,0x90,0x88,0x46,0xee,0xb8,0x14,0xde,0x5e,0x0b,0xdb,
    0xe0,0x32,0x3a,0x0a,0x49,0x06,0x24,0x5c,0xc2,0xd3,0xac,0x62,0x91,0x95,0xe4,0x79,
    0xe7,0xc8,0x37,0x6d,0x8d,0xd5,0x4e,0xa9,0x6c,0x56,0xf4,0xea,0x65,0x7a,0xae,0x08,
    0xba,0x78,0x25,0x2e,0x1c,0xa6,0xb4,0xc6,0xe8,0xdd,0x74,0x1f,0x4b,0xbd,0x8b,0x8a,
    0x70,0x3e,0xb5,0x66,0x48,0x03,0xf6,0x0e,0x61,0x35,0x57,0xb9,0x86,0xc1,0x1d,0x9e,
    0xe1,0xf8,0x98,0x11,0x69,0xd9,0x8e,0x94,0x9b,0x1e,0x87,0xe9,0xce,0x55,0x28,0xdf,
    0x8c,0xa1,0x89,0x0d,0xbf,0xe6,0x42,0x68,0x41,0x99,0x2d,0x0f,0xb0,0x54,0xbb,0x16,
]
_AES_SBOX_INV = [
    0x52,0x09,0x6a,0xd5,0x30,0x36,0xa5,0x38,0xbf,0x40,0xa3,0x9e,0x81,0xf3,0xd7,0xfb,
    0x7c,0xe3,0x39,0x82,0x9b,0x2f,0xff,0x87,0x34,0x8e,0x43,0x44,0xc4,0xde,0xe9,0xcb,
    0x54,0x7b,0x94,0x32,0xa6,0xc2,0x23,0x3d,0xee,0x4c,0x95,0x0b,0x42,0xfa,0xc3,0x4e,
    0x08,0x2e,0xa1,0x66,0x28,0xd9,0x24,0xb2,0x76,0x5b,0xa2,0x49,0x6d,0x8b,0xd1,0x25,
    0x72,0xf8,0xf6,0x64,0x86,0x68,0x98,0x16,0xd4,0xa4,0x5c,0xcc,0x5d,0x65,0xb6,0x92,
    0x6c,0x70,0x48,0x50,0xfd,0xed,0xb9,0xda,0x5e,0x15,0x46,0x57,0xa7,0x8d,0x9d,0x84,
    0x90,0xd8,0xab,0x00,0x8c,0xbc,0xd3,0x0a,0xf7,0xe4,0x58,0x05,0xb8,0xb3,0x45,0x06,
    0xd0,0x2c,0x1e,0x8f,0xca,0x3f,0x0f,0x02,0xc1,0xaf,0xbd,0x03,0x01,0x13,0x8a,0x6b,
    0x3a,0x91,0x11,0x41,0x4f,0x67,0xdc,0xea,0x97,0xf2,0xcf,0xce,0xf0,0xb4,0xe6,0x73,
    0x96,0xac,0x74,0x22,0xe7,0xad,0x35,0x85,0xe2,0xf9,0x37,0xe8,0x1c,0x75,0xdf,0x6e,
    0x47,0xf1,0x1a,0x71,0x1d,0x29,0xc5,0x89,0x6f,0xb7,0x62,0x0e,0xaa,0x18,0xbe,0x1b,
    0xfc,0x56,0x3e,0x4b,0xc6,0xd2,0x79,0x20,0x9a,0xdb,0xc0,0xfe,0x78,0xcd,0x5a,0xf4,
    0x1f,0xdd,0xa8,0x33,0x88,0x07,0xc7,0x31,0xb1,0x12,0x10,0x59,0x27,0x80,0xec,0x5f,
    0x60,0x51,0x7f,0xa9,0x19,0xb5,0x4a,0x0d,0x2d,0xe5,0x7a,0x9f,0x93,0xc9,0x9c,0xef,
    0xa0,0xe0,0x3b,0x4d,0xae,0x2a,0xf5,0xb0,0xc8,0xeb,0xbb,0x3c,0x83,0x53,0x99,0x61,
    0x17,0x2b,0x04,0x7e,0xba,0x77,0xd6,0x26,0xe1,0x69,0x14,0x63,0x55,0x21,0x0c,0x7d,
]
_AES_RCON = [1,2,4,8,0x10,0x20,0x40,0x80,0x1b,0x36] + [0]*6


def _aes_xt2(x):
    x <<= 1
    if x & 0x100:
        x ^= 0x11b
    return x & 0xff


def _aes_xt3(x):
    return x ^ _aes_xt2(x)


def _aes_mixcolumn_fwd(x):
    s0, s1, s2, s3 = x & 0xff, (x >> 8) & 0xff, (x >> 16) & 0xff, (x >> 24) & 0xff
    b0 = _aes_xt2(s0) ^ _aes_xt3(s1) ^ s2 ^ s3
    b1 = s0 ^ _aes_xt2(s1) ^ _aes_xt3(s2) ^ s3
    b2 = s0 ^ s1 ^ _aes_xt2(s2) ^ _aes_xt3(s3)
    b3 = _aes_xt3(s0) ^ s1 ^ s2 ^ _aes_xt2(s3)
    return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0


def _aes_gfmul(x, y):
    r = 0
    if y & 1: r ^= x
    if y & 2: r ^= _aes_xt2(x)
    if y & 4: r ^= _aes_xt2(_aes_xt2(x))
    if y & 8: r ^= _aes_xt2(_aes_xt2(_aes_xt2(x)))
    return r


def _aes_mixcolumn_inv(x):
    s0, s1, s2, s3 = x & 0xff, (x >> 8) & 0xff, (x >> 16) & 0xff, (x >> 24) & 0xff
    b0 = _aes_gfmul(s0,0xE) ^ _aes_gfmul(s1,0xB) ^ _aes_gfmul(s2,0xD) ^ _aes_gfmul(s3,0x9)
    b1 = _aes_gfmul(s0,0x9) ^ _aes_gfmul(s1,0xE) ^ _aes_gfmul(s2,0xB) ^ _aes_gfmul(s3,0xD)
    b2 = _aes_gfmul(s0,0xD) ^ _aes_gfmul(s1,0x9) ^ _aes_gfmul(s2,0xE) ^ _aes_gfmul(s3,0xB)
    b3 = _aes_gfmul(s0,0xB) ^ _aes_gfmul(s1,0xD) ^ _aes_gfmul(s2,0x9) ^ _aes_gfmul(s3,0xE)
    return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0


def _aes_subword_fwd(x):
    return ((_AES_SBOX_FWD[(x >> 24) & 0xff] << 24) | (_AES_SBOX_FWD[(x >> 16) & 0xff] << 16) |
            (_AES_SBOX_FWD[(x >> 8) & 0xff] << 8) | _AES_SBOX_FWD[x & 0xff])


def _aes_getbyte(x, i):
    return (x >> (8 * i)) & 0xff


def _aes_sbox_bytes64(x, inv=False):
    tbl = _AES_SBOX_INV if inv else _AES_SBOX_FWD
    r = 0
    for i in range(8):
        r |= tbl[_aes_getbyte(x, i)] << (8 * i)
    return r


def _aes_shiftrows_fwd(rs2, rs1):
    g = _aes_getbyte
    return ((g(rs1,3)<<56)|(g(rs2,6)<<48)|(g(rs2,1)<<40)|(g(rs1,4)<<32)|
            (g(rs2,7)<<24)|(g(rs2,2)<<16)|(g(rs1,5)<<8)|g(rs1,0))


def _aes_shiftrows_inv(rs2, rs1):
    g = _aes_getbyte
    return ((g(rs2,3)<<56)|(g(rs2,6)<<48)|(g(rs1,1)<<40)|(g(rs1,4)<<32)|
            (g(rs1,7)<<24)|(g(rs2,2)<<16)|(g(rs2,5)<<8)|g(rs1,0))


def aes64esm(rs1, rs2):
    sr = _aes_shiftrows_fwd(rs2, rs1)
    sb = _aes_sbox_bytes64(sr)
    return (_aes_mixcolumn_fwd((sb >> 32) & 0xffffffff) << 32) | _aes_mixcolumn_fwd(sb & 0xffffffff)


def aes64es(rs1, rs2):
    return _aes_sbox_bytes64(_aes_shiftrows_fwd(rs2, rs1))


def aes64dsm(rs1, rs2):
    sr = _aes_shiftrows_inv(rs2, rs1)
    sb = _aes_sbox_bytes64(sr, inv=True)
    return (_aes_mixcolumn_inv((sb >> 32) & 0xffffffff) << 32) | _aes_mixcolumn_inv(sb & 0xffffffff)


def aes64ds(rs1, rs2):
    return _aes_sbox_bytes64(_aes_shiftrows_inv(rs2, rs1), inv=True)


def aes64ks1i(rs1, rnum):
    tmp1 = (rs1 >> 32) & 0xffffffff
    rc = _AES_RCON[rnum]
    tmp2 = tmp1 if rnum == 0xA else (((tmp1 >> 8) | (tmp1 << 24)) & 0xffffffff)
    tmp3 = _aes_subword_fwd(tmp2)
    v = (tmp3 ^ rc) & 0xffffffff
    return (v << 32) | v


def aes64ks2(rs1, rs2):
    w0 = ((rs1 >> 32) ^ (rs2 & 0xffffffff)) & 0xffffffff
    w1 = (w0 ^ (rs2 >> 32)) & 0xffffffff
    return (w1 << 32) | w0


def aes64im(rs1):
    return (_aes_mixcolumn_inv((rs1 >> 32) & 0xffffffff) << 32) | _aes_mixcolumn_inv(rs1 & 0xffffffff)


def _ror(x, n, bits):
    return ((x >> n) | (x << (bits - n))) & ((1 << bits) - 1)


def sha256sig0(x):
    x &= 0xffffffff
    return (_ror(x,7,32) ^ _ror(x,18,32) ^ (x >> 3)) & 0xffffffff


def sha256sig1(x):
    x &= 0xffffffff
    return (_ror(x,17,32) ^ _ror(x,19,32) ^ (x >> 10)) & 0xffffffff


def sha256sum0(x):
    x &= 0xffffffff
    return (_ror(x,2,32) ^ _ror(x,13,32) ^ _ror(x,22,32)) & 0xffffffff


def sha256sum1(x):
    x &= 0xffffffff
    return (_ror(x,6,32) ^ _ror(x,11,32) ^ _ror(x,25,32)) & 0xffffffff


def sha512sig0(x):
    x &= 0xffffffffffffffff
    return (_ror(x,1,64) ^ _ror(x,8,64) ^ (x >> 7)) & 0xffffffffffffffff


def sha512sig1(x):
    x &= 0xffffffffffffffff
    return (_ror(x,19,64) ^ _ror(x,61,64) ^ (x >> 6)) & 0xffffffffffffffff


def sha512sum0(x):
    x &= 0xffffffffffffffff
    return (_ror(x,28,64) ^ _ror(x,34,64) ^ _ror(x,39,64)) & 0xffffffffffffffff


def sha512sum1(x):
    x &= 0xffffffffffffffff
    return (_ror(x,14,64) ^ _ror(x,18,64) ^ _ror(x,41,64)) & 0xffffffffffffffff


def brev8(x, xl):
    out = 0
    for i in range(xl // 8):
        byte = (x >> (i * 8)) & 0xFF
        rev = int(f"{byte:08b}"[::-1], 2)
        out |= rev << (i * 8)
    return out


class ISS:
    def __init__(self, mem_size=128, xlen=32):
        # Generation 2 (Phase M). Default 32 is bit-exact with every prior
        # caller. self.sxlen/self.uxlen are the register-width analogues of
        # the module-level s32/u32 (which stay fixed-32-bit -- see their own
        # comment above).
        self.xlen = xlen
        self.regs = [0] * 32
        # sp reset default -- matches design/Register.v's SP_INIT parameter,
        # which riscvpipeline.v ties directly to MEM_SIZE_BYTES, not a fixed
        # 128 (docs/adr/0020-soc-integration.md Phase D10 caught this: the
        # non-interrupt corpus never varies mem_size away from 128, so this
        # was silently correct by coincidence until interrupt-mode runs
        # actually changed it).
        self.regs[2] = mem_size
        self.mem = bytearray(mem_size)
        self.mem_mask = mem_size - 1  # mem_size is always a power of 2 (128, 256, ...)
        self.pc = 0
        self.halted = False
        # CSR state (docs/adr/0011-csr-and-exceptions.md) -- only the 5
        # machine-mode CSRs design/CSR.v implements. mstatus models just the
        # MIE (bit3) / MPIE (bit7) trap-enable stack, matching that module.
        self.csr = {CSR_MSTATUS: 0, CSR_MTVEC: 0, CSR_MSCRATCH: 0, CSR_MEPC: 0, CSR_MCAUSE: 0}
        # docs/adr/00NN-mmu-sv32.md (Phase F6). Phase F1's own CSR.v storage
        # additions, mirrored here. priv_mode resets to M (spec boot
        # behavior, matches CSR.v exactly). mip is real storage here (unlike
        # CSR.v's own mip, which ORs in two hardware-driven bits from
        # Timer.v/Uart.v) since this ISS has no peripheral model at all --
        # external interrupts are injected directly via schedule_interrupt/
        # trap(), never derived from a simulated mip read, so plain
        # software-writable storage for mip is sufficient and correct here.
        self.priv_mode = PRIV_M
        self.csr.update({
            CSR_SSCRATCH: 0, CSR_SEPC: 0, CSR_SCAUSE: 0, CSR_STVAL: 0, CSR_MTVAL: 0,
            CSR_STVEC: 0, CSR_SATP: 0, CSR_MIDELEG: 0, CSR_MEDELEG: 0, CSR_MIE: 0, CSR_MIP: 0,
        })
        # docs/adr/0019-f-extension.md (Phase C9). fregs has no x0-equivalent
        # (FRegister.v hardwires nothing). frm/fflags mirror CSR.v's own
        # separate registers, not folded into self.csr, since fflags needs
        # sticky-OR semantics distinct from every other CSR's plain
        # read/write (see set_fflags below).
        self.fregs = [0] * 32
        self.frm = 0
        self.fflags = 0
        # docs/adr/0020-soc-integration.md (Phase D10). Externally scheduled
        # interrupt injection, set via schedule_interrupt() below -- None
        # (default) means no interrupt-mode testing is active, run() behaves
        # exactly as it always has. This is deliberately NOT a real timing
        # model (the ISS has no notion of cycles): the RTL side independently
        # arms real hardware (a genuinely reachable MTIMECMP, or the test
        # rig's own driven UART byte) that will, with a generous timing
        # margin, actually fire somewhere during the same window this fires
        # in on the ISS side. The two sides deliberately do NOT need to agree
        # on the *exact* instruction boundary -- see random_gen.py's
        # interrupt-mode docstring for why a minimal, architecturally-inert
        # handler (mie<-0 then mret, no register/memory footprint at all)
        # makes the final compared state independent of exactly which
        # instruction got interrupted, as long as it fires (at most) once.
        self.pending_interrupt = None

    def schedule_interrupt(self, after_steps, cause):
        self.pending_interrupt = {"after": after_steps, "cause": cause}

    def sxlen(self, v):
        return sXLEN(v, self.xlen)

    def uxlen(self, v):
        return uXLEN(v, self.xlen)

    def wr(self, rd, val):
        if rd != 0:
            self.regs[rd] = self.uxlen(val)

    def set_fflags(self, flags):
        # docs/adr/0019 Phase C8/C9: sticky hardware accumulation -- every
        # F-extension instruction that executes ORs its own flags in,
        # matching design/CSR.v's fp_flags_we path exactly.
        self.fflags = (self.fflags | flags) & 0x1F

    def resolve_rm(self, rm_field):
        return self.frm if rm_field == RM_DYN else rm_field

    def csr_read(self, addr):
        if addr == CSR_FFLAGS:
            return self.fflags & 0x1F
        if addr == CSR_FRM:
            return self.frm & 0x7
        if addr == CSR_FCSR:
            return ((self.frm & 0x7) << 5) | (self.fflags & 0x1F)
        # docs/adr/00NN-mmu-sv32.md (Phase F6). sstatus/sie/sip are NOT
        # separate storage -- masked VIEWS onto mstatus/mie/mip's S-visible
        # bit subset, matching design/CSR.v's own sstatus_view/sie_view/
        # sip_view exactly (the same relationship fcsr already has onto
        # {frm,fflags}).
        if addr == CSR_SSTATUS:
            m = self.csr[CSR_MSTATUS]
            return (((m >> MSTATUS_SIE_BIT) & 1) << MSTATUS_SIE_BIT |
                    ((m >> MSTATUS_SPIE_BIT) & 1) << MSTATUS_SPIE_BIT |
                    ((m >> MSTATUS_SPP_BIT) & 1) << MSTATUS_SPP_BIT)
        if addr == CSR_SIE:
            e = self.csr[CSR_MIE]
            return (((e >> MIE_SSIE_BIT) & 1) << MIE_SSIE_BIT |
                    ((e >> MIE_STIE_BIT) & 1) << MIE_STIE_BIT |
                    ((e >> MIE_SEIE_BIT) & 1) << MIE_SEIE_BIT)
        if addr == CSR_SIP:
            p = self.csr[CSR_MIP]
            return (((p >> MIE_SSIE_BIT) & 1) << MIE_SSIE_BIT |
                    ((p >> MIE_STIE_BIT) & 1) << MIE_STIE_BIT |
                    ((p >> MIE_SEIE_BIT) & 1) << MIE_SEIE_BIT)
        # Generation 3, Phase O (docs/adr/0031). Matches design/CSR.v's own
        # read-mux override exactly: mstatus.UXL/SXL read as fixed 2 at
        # XLEN=64, applied at read time only (self.csr[CSR_MSTATUS] itself
        # never gains these bits -- not real storage).
        if addr == CSR_MSTATUS and self.xlen == 64:
            return (self.csr.get(addr, 0) |
                    (MXL_XLEN64 << MSTATUS_UXL_LO) | (MXL_XLEN64 << MSTATUS_SXL_LO))
        return self.csr.get(addr, 0)

    def csr_write(self, addr, val):
        if addr == CSR_FFLAGS:
            self.fflags = val & 0x1F
            return
        if addr == CSR_FRM:
            self.frm = val & 0x7
            return
        if addr == CSR_FCSR:
            self.frm = (val >> 5) & 0x7
            self.fflags = val & 0x1F
            return
        if addr == CSR_MSTATUS:
            # docs/adr/00NN-mmu-sv32.md (Phase F1/F6): SIE/SPIE/SPP/MPP join
            # the pre-existing MIE(3)/MPIE(7) as real bits, matching
            # design/CSR.v's mstatus_masked exactly.
            val &= ((1 << 3) | (1 << 7) | (1 << MSTATUS_SIE_BIT) | (1 << MSTATUS_SPIE_BIT) |
                    (1 << MSTATUS_SPP_BIT) | (0b11 << MSTATUS_MPP_LO))
        elif addr == CSR_SSTATUS:
            # A write THROUGH sstatus only ever touches the S-visible subset
            # -- never MIE/MPIE/MPP -- matching CSR.v's own
            # sstatus_write_masked/read-modify-write preservation.
            keep = self.csr[CSR_MSTATUS] & ~((1 << MSTATUS_SIE_BIT) | (1 << MSTATUS_SPIE_BIT) | (1 << MSTATUS_SPP_BIT))
            new = val & ((1 << MSTATUS_SIE_BIT) | (1 << MSTATUS_SPIE_BIT) | (1 << MSTATUS_SPP_BIT))
            self.csr[CSR_MSTATUS] = u32(keep | new)
            return
        elif addr == CSR_MIE:
            # docs/adr/0034-uart-clint-register-compat-phase-r.md (Phase R):
            # MIE_MSIE_BIT(3) joins the mask, matching design/CSR.v's own
            # mie_masked exactly.
            val &= ((1 << MIE_MSIE_BIT) | (1 << 7) | (1 << 11) |
                    (1 << MIE_SSIE_BIT) | (1 << MIE_STIE_BIT) | (1 << MIE_SEIE_BIT))
        elif addr == CSR_SIE:
            keep = self.csr[CSR_MIE] & ~((1 << MIE_SSIE_BIT) | (1 << MIE_STIE_BIT) | (1 << MIE_SEIE_BIT))
            new = val & ((1 << MIE_SSIE_BIT) | (1 << MIE_STIE_BIT) | (1 << MIE_SEIE_BIT))
            self.csr[CSR_MIE] = u32(keep | new)
            return
        elif addr in (CSR_MIP, CSR_SIP):
            # Only SSIP/STIP/SEIP are software-writable (MTIP/MEIP are
            # hardware-only in CSR.v, meaningless here -- see __init__'s own
            # comment). Reachable via either mip or sip's own address, same
            # as CSR.v.
            val &= ((1 << MIE_SSIE_BIT) | (1 << MIE_STIE_BIT) | (1 << MIE_SEIE_BIT))
            self.csr[CSR_MIP] = u32(val)
            return
        elif addr == CSR_MEDELEG:
            # Matches CSR.v's medeleg_masked: only the causes this core can
            # actually raise are real bits.
            val &= ((1 << 2) | (1 << 3) | (1 << 8) | (1 << 9) | (1 << 11) | (1 << 12) | (1 << 13) | (1 << 15))
        elif addr == CSR_MIDELEG:
            # Matches CSR.v's mideleg_masked (Phase R added MIE_MSIE_BIT(3)
            # alongside the pre-existing bits 7/11).
            val &= ((1 << MIE_SSIE_BIT) | (1 << MIE_STIE_BIT) | (1 << MIE_MSIE_BIT) |
                    (1 << 7) | (1 << MIE_SEIE_BIT) | (1 << 11))
        if addr in self.csr:
            self.csr[addr] = u32(val)

    def trap(self, cause, tval=0):
        # docs/adr/00NN-mmu-sv32.md (Phase F3/F6): cause's own bit31 is the
        # interrupt-vs-exception flag (already baked into every interrupt
        # cause constant, e.g. MCAUSE_INT_MACHINE_TIMER), so is_interrupt is
        # derived from it rather than a separate parameter -- keeps every
        # pre-existing call site (schedule_interrupt's own trap() call, the
        # plain exception ones below) unchanged. Delegation target (M vs S)
        # matches design/CSR.v's trap_target_is_s exactly: never delegated
        # if the trap is sourced in M itself, regardless of the delegation
        # bits. Bit-level mstatus updates (not a blanket overwrite) --
        # unlike the pre-Phase-F version, mstatus now has real bits
        # (SIE/SPIE/SPP) an M-targeted trap must leave untouched, and vice
        # versa for an S-targeted one, matching CSR.v's own per-bit
        # nonblocking assigns exactly.
        is_interrupt = bool(cause & 0x80000000)
        low_cause = cause & 0x1F
        deleg = self.csr[CSR_MIDELEG] if is_interrupt else self.csr[CSR_MEDELEG]
        to_s = (self.priv_mode != PRIV_M) and bool((deleg >> low_cause) & 1)
        mcause_val = u32(cause)
        m = self.csr[CSR_MSTATUS]
        if to_s:
            self.csr[CSR_SEPC] = self.pc
            self.csr[CSR_SCAUSE] = mcause_val
            self.csr[CSR_STVAL] = u32(tval)
            sie = (m >> MSTATUS_SIE_BIT) & 1
            m &= ~((1 << MSTATUS_SIE_BIT) | (1 << MSTATUS_SPIE_BIT) | (1 << MSTATUS_SPP_BIT))
            m |= (sie << MSTATUS_SPIE_BIT) | ((self.priv_mode & 1) << MSTATUS_SPP_BIT)
            self.csr[CSR_MSTATUS] = u32(m)
            self.priv_mode = PRIV_S
            self.pc = self.csr[CSR_STVEC]
        else:
            self.csr[CSR_MEPC] = self.pc
            self.csr[CSR_MCAUSE] = mcause_val
            self.csr[CSR_MTVAL] = u32(tval)
            mie = (m >> 3) & 1
            m &= ~((1 << 3) | (1 << 7) | (0b11 << MSTATUS_MPP_LO))
            m |= (mie << 7) | (self.priv_mode << MSTATUS_MPP_LO)
            self.csr[CSR_MSTATUS] = u32(m)
            self.priv_mode = PRIV_M
            self.pc = self.csr[CSR_MTVEC]

    def mret(self):
        # Matches design/CSR.v's mret_taken path: mstatus.MIE <- mstatus.MPIE,
        # mstatus.MPIE <- 1, mstatus.MPP <- U, priv_mode <- (old) MPP, pc <- mepc.
        m = self.csr[CSR_MSTATUS]
        mpie = (m >> 7) & 1
        mpp = (m >> MSTATUS_MPP_LO) & 0b11
        m &= ~((1 << 3) | (1 << 7) | (0b11 << MSTATUS_MPP_LO))
        m |= (mpie << 3) | (1 << 7) | (PRIV_U << MSTATUS_MPP_LO)
        self.csr[CSR_MSTATUS] = u32(m)
        self.priv_mode = mpp
        self.pc = self.csr[CSR_MEPC]

    def sret(self):
        # docs/adr/00NN-mmu-sv32.md (Phase F3/F6). Matches CSR.v's
        # sret_taken path: mstatus.SIE <- mstatus.SPIE, mstatus.SPIE <- 1,
        # mstatus.SPP <- U, priv_mode <- (old) SPP (a single bit, U=0/S=1,
        # coincides with PRIV_U/PRIV_S directly), pc <- sepc.
        m = self.csr[CSR_MSTATUS]
        spie = (m >> MSTATUS_SPIE_BIT) & 1
        spp = (m >> MSTATUS_SPP_BIT) & 1
        m &= ~((1 << MSTATUS_SIE_BIT) | (1 << MSTATUS_SPIE_BIT) | (1 << MSTATUS_SPP_BIT))
        m |= (spie << MSTATUS_SIE_BIT) | (1 << MSTATUS_SPIE_BIT)
        self.csr[CSR_MSTATUS] = u32(m)
        self.priv_mode = spp
        self.pc = self.csr[CSR_SEPC]

    def _read_pte(self, addr):
        addr &= 0xFFFFFFFF
        return (self.load_mem_byte(addr) | (self.load_mem_byte(addr + 1) << 8) |
                (self.load_mem_byte(addr + 2) << 16) | (self.load_mem_byte(addr + 3) << 24))

    def _pte_perm_ok(self, pte, access):
        # access: 'fetch'|'load'|'store'. Matches design/Ptw.v's own
        # permission check exactly -- no SUM/MXR (this phase's own scoping
        # default, design/riscv_defs.vh's PTE_U_BIT comment).
        access_bit = PTE_X_BIT if access == "fetch" else (PTE_W_BIT if access == "store" else PTE_R_BIT)
        if not ((pte >> access_bit) & 1):
            return False
        priv_is_u = (self.priv_mode == PRIV_U)
        pte_u = (pte >> PTE_U_BIT) & 1
        return bool(pte_u) if priv_is_u else not bool(pte_u)

    def translate(self, vaddr, access):
        """Dispatches to Sv32 (XLEN=32) or Sv39 (XLEN=64, Phase P4) real
        translation, or bypasses (M-mode always does, either XLEN, and
        satp.MODE=Bare does at either XLEN). access: 'fetch'|'load'|'store'.
        Returns the translated physical address on success; on a page
        fault, traps internally (mcause + mtval/stval = the faulting VA,
        matching design/riscvpipeline.v's trap_value wiring) and returns
        None -- the caller must check for None and stop (mirrors an
        ifetch_fault_regde/dtlb_page_fault redirect: the access itself
        never completes)."""
        satp = self.csr[CSR_SATP]
        if self.priv_mode == PRIV_M:
            return self.uxlen(vaddr)
        if self.xlen == 32:
            if not ((satp >> SATP_MODE_BIT) & 1):
                return self.uxlen(vaddr)
            return self._translate_sv32(vaddr, access, satp)
        else:
            if ((satp >> SATP64_MODE_LO) & 0xF) != SATP_MODE_SV39:
                return self.uxlen(vaddr)
            return self._translate_sv39(vaddr, access, satp)

    def _translate_sv32(self, vaddr, access, satp):
        """Sv32 translation, matching design/Ptw.v's own 2-level walk +
        design/riscvpipeline.v's permission check bit-for-bit."""
        vaddr = u32(vaddr)
        vpn1 = (vaddr >> 22) & 0x3FF
        vpn0 = (vaddr >> 12) & 0x3FF
        offset = vaddr & 0xFFF
        satp_ppn20 = satp & 0xFFFFF  # low 20 bits meaningful -- see Ptw.v's own header
        fault_cause = {
            "fetch": MCAUSE_INSTRUCTION_PAGE_FAULT,
            "load": MCAUSE_LOAD_PAGE_FAULT,
            "store": MCAUSE_STORE_PAGE_FAULT,
        }[access]

        def fault():
            self.trap(fault_cause, tval=vaddr)
            return None

        l1_addr = (satp_ppn20 << 12) | (vpn1 << 2)
        pte1 = self._read_pte(l1_addr)
        if not ((pte1 >> PTE_V_BIT) & 1):
            return fault()
        if (pte1 >> PTE_R_BIT) & 1 or (pte1 >> PTE_W_BIT) & 1 or (pte1 >> PTE_X_BIT) & 1:
            # Leaf at level 1: a megapage. PPN[0] (pte1[19:10]) must be 0.
            ppn20 = (pte1 >> 10) & 0xFFFFF
            if ppn20 & 0x3FF:
                return fault()
            if not self._pte_perm_ok(pte1, access):
                return fault()
            result_ppn20 = ((ppn20 >> 10) << 10) | vpn0  # {pte1[29:20], vpn0}
            return u32((result_ppn20 << 12) | offset)
        # Non-leaf: descend to level 0.
        l0_addr = (((pte1 >> 10) & 0xFFFFF) << 12) | (vpn0 << 2)
        pte0 = self._read_pte(l0_addr)
        if not ((pte0 >> PTE_V_BIT) & 1):
            return fault()
        if not ((pte0 >> PTE_R_BIT) & 1 or (pte0 >> PTE_W_BIT) & 1 or (pte0 >> PTE_X_BIT) & 1):
            # Non-leaf at level 0: Sv32 is exactly 2 levels -- malformed.
            return fault()
        if not self._pte_perm_ok(pte0, access):
            return fault()
        ppn20 = (pte0 >> 10) & 0xFFFFF
        return u32((ppn20 << 12) | offset)

    def _read_pte64(self, addr):
        # docs/adr/00NN-sv39-mmu-phase-p.md (Phase P4). Sv39 PTEs are 8
        # bytes (RV64), unlike Sv32's 4 -- see _read_pte's own byte-order
        # convention, extended to 8 bytes.
        addr &= 0xFFFFFFFF
        val = 0
        for i in range(8):
            val |= self.load_mem_byte(addr + i) << (8 * i)
        return val

    def _translate_sv39(self, vaddr, access, satp):
        """Sv39 translation, matching design/Ptw39.v's own 3-level walk +
        design/riscvpipeline.v's permission check bit-for-bit (Phase P4,
        docs/adr/00NN-sv39-mmu-phase-p.md). Same low-20-bits PPN truncation
        Ptw39.v itself documents (this core's real memory is tiny) -- the
        `pte_ppn20 = (pte >> 10) & 0xFFFFF` slice sits at the identical bit
        position Sv32's own _translate_sv32 uses, since PPN starts at bit
        10 in both PTE formats regardless of total width."""
        vpn2 = (vaddr >> 30) & 0x1FF
        vpn1 = (vaddr >> 21) & 0x1FF
        vpn0 = (vaddr >> 12) & 0x1FF
        offset = vaddr & 0xFFF
        satp_ppn20 = satp & 0xFFFFF
        fault_cause = {
            "fetch": MCAUSE_INSTRUCTION_PAGE_FAULT,
            "load": MCAUSE_LOAD_PAGE_FAULT,
            "store": MCAUSE_STORE_PAGE_FAULT,
        }[access]

        def fault():
            self.trap(fault_cause, tval=vaddr)
            return None

        l2_addr = (satp_ppn20 << 12) | (vpn2 << 3)
        pte2 = self._read_pte64(l2_addr)
        if not ((pte2 >> PTE_V_BIT) & 1):
            return fault()
        if (pte2 >> PTE_R_BIT) & 1 or (pte2 >> PTE_W_BIT) & 1 or (pte2 >> PTE_X_BIT) & 1:
            # Leaf at level 2: a gigapage. Real PPN[1:0] (pte2[27:10], the
            # low 18 bits of pte_ppn20) must be 0.
            pte_ppn20 = (pte2 >> 10) & 0xFFFFF
            if pte_ppn20 & 0x3FFFF:
                return fault()
            if not self._pte_perm_ok(pte2, access):
                return fault()
            result_ppn20 = ((pte_ppn20 >> 18) << 18) | (vpn1 << 9) | vpn0
            return self.uxlen((result_ppn20 << 12) | offset)
        # Non-leaf: descend to level 1.
        l1_addr = (((pte2 >> 10) & 0xFFFFF) << 12) | (vpn1 << 3)
        pte1 = self._read_pte64(l1_addr)
        if not ((pte1 >> PTE_V_BIT) & 1):
            return fault()
        if (pte1 >> PTE_R_BIT) & 1 or (pte1 >> PTE_W_BIT) & 1 or (pte1 >> PTE_X_BIT) & 1:
            # Leaf at level 1: a megapage. Real PPN[0] (pte1[18:10], the
            # low 9 bits of pte_ppn20) must be 0.
            pte_ppn20 = (pte1 >> 10) & 0xFFFFF
            if pte_ppn20 & 0x1FF:
                return fault()
            if not self._pte_perm_ok(pte1, access):
                return fault()
            result_ppn20 = ((pte_ppn20 >> 9) << 9) | vpn0
            return self.uxlen((result_ppn20 << 12) | offset)
        # Non-leaf: descend to level 0.
        l0_addr = (((pte1 >> 10) & 0xFFFFF) << 12) | (vpn0 << 3)
        pte0 = self._read_pte64(l0_addr)
        if not ((pte0 >> PTE_V_BIT) & 1):
            return fault()
        if not ((pte0 >> PTE_R_BIT) & 1 or (pte0 >> PTE_W_BIT) & 1 or (pte0 >> PTE_X_BIT) & 1):
            # Non-leaf at level 0: Sv39 is exactly 3 levels -- malformed.
            return fault()
        if not self._pte_perm_ok(pte0, access):
            return fault()
        ppn20 = (pte0 >> 10) & 0xFFFFF
        return self.uxlen((ppn20 << 12) | offset)

    def load_mem_byte(self, addr):
        # docs/adr/0020-soc-integration.md (Phase D10). MMIO_BASE (design/
        # riscv_defs.vh, 0x1000_0000) and above is real peripheral address
        # space on the RTL side (WbDecoder routes it away from RAM
        # entirely) -- this ISS has no peripheral model at all (interrupt
        # firing is scheduled externally, not derived from simulated
        # peripheral state, see schedule_interrupt), so an MMIO address must
        # NOT alias into self.mem via the mask below the way an ordinary
        # RAM address does, or a real MMIO store/load would corrupt (or a
        # load would silently fabricate) unrelated compared memory state.
        # Reads at an unmodeled address are simply 0, the same convention
        # csr_read already uses for an unimplemented CSR.
        if addr >= 0x10000000:
            return 0
        return self.mem[addr & self.mem_mask]

    def store_mem_byte(self, addr, val):
        if addr >= 0x10000000:
            return
        self.mem[addr & self.mem_mask] = val & 0xFF

    def step(self, word):
        if word == 0:
            self.pc += 4
            return
        op = word & 0x7F
        rd = (word >> 7) & 0x1F
        f3 = (word >> 12) & 0x7
        rs1 = (word >> 15) & 0x1F
        rs2 = (word >> 20) & 0x1F
        f7 = (word >> 25) & 0x7F
        imm_i = sext((word >> 20) & 0xFFF, 12)
        A = self.regs[rs1]
        B = self.regs[rs2]
        next_pc = self.pc + 4

        xl = self.xlen

        if op == 0b0110011:  # R-type (base + RV32M/RV64M)
            if f7 == 0b0000001:  # M extension
                if f3 == 0b000:
                    res = self.uxlen(A * B)
                elif f3 == 0b001:
                    # Python's >> on a negative int is a floor shift, which is
                    # exactly two's-complement arithmetic right shift -- no
                    # masking first needed at any width.
                    res = self.uxlen((self.sxlen(A) * self.sxlen(B)) >> xl)
                elif f3 == 0b010:
                    res = self.uxlen((self.sxlen(A) * self.uxlen(B)) >> xl)
                elif f3 == 0b011:
                    res = (self.uxlen(A) * self.uxlen(B)) >> xl
                elif f3 == 0b100:  # div
                    if B == 0:
                        res = self.uxlen(-1)
                    elif self.sxlen(A) == -(1 << (xl - 1)) and self.sxlen(B) == -1:
                        res = A
                    else:
                        q = abs(self.sxlen(A)) // abs(self.sxlen(B))
                        if (self.sxlen(A) < 0) != (self.sxlen(B) < 0):
                            q = -q
                        res = self.uxlen(q)
                elif f3 == 0b101:  # divu
                    res = self.uxlen(-1) if B == 0 else (self.uxlen(A) // self.uxlen(B))
                elif f3 == 0b110:  # rem
                    if B == 0:
                        res = A
                    elif self.sxlen(A) == -(1 << (xl - 1)) and self.sxlen(B) == -1:
                        res = 0
                    else:
                        r = abs(self.sxlen(A)) % abs(self.sxlen(B))
                        if self.sxlen(A) < 0:
                            r = -r
                        res = self.uxlen(r)
                else:  # remu
                    res = A if B == 0 else (self.uxlen(A) % self.uxlen(B))
                self.wr(rd, res)
            # B extension (docs/adr/0060) -- FUNCT7_ALT+111 is now real
            # `andn`, not the retired custom ctz (real ctz moved to its own
            # Zbb I-type encoding under op==0b0010011 below).
            elif f7 == 0b0100000 and f3 == 0b111:  # andn
                self.wr(rd, A & (~B))
            elif f7 == 0b0100000 and f3 == 0b110:  # orn
                self.wr(rd, A | (~B))
            elif f7 == 0b0100000 and f3 == 0b100:  # xnor
                self.wr(rd, ~(A ^ B))
            elif f7 == 0b0000101 and f3 == 0b100:  # min
                self.wr(rd, A if self.sxlen(A) < self.sxlen(B) else B)
            elif f7 == 0b0000101 and f3 == 0b101:  # minu
                self.wr(rd, A if self.uxlen(A) < self.uxlen(B) else B)
            elif f7 == 0b0000101 and f3 == 0b110:  # max
                self.wr(rd, A if self.sxlen(A) > self.sxlen(B) else B)
            elif f7 == 0b0000101 and f3 == 0b111:  # maxu
                self.wr(rd, A if self.uxlen(A) > self.uxlen(B) else B)
            elif f7 == 0b0110000 and f3 == 0b001:  # rol
                sh = B & (xl - 1)
                a = self.uxlen(A)
                self.wr(rd, ((a << sh) | (a >> (xl - sh))) if sh else a)
            elif f7 == 0b0110000 and f3 == 0b101:  # ror
                sh = B & (xl - 1)
                a = self.uxlen(A)
                self.wr(rd, ((a >> sh) | (a << (xl - sh))) if sh else a)
            elif f7 == 0b0010000 and f3 == 0b010:  # sh1add
                self.wr(rd, (A << 1) + B)
            elif f7 == 0b0010000 and f3 == 0b100:  # sh2add
                self.wr(rd, (A << 2) + B)
            elif f7 == 0b0010000 and f3 == 0b110:  # sh3add
                self.wr(rd, (A << 3) + B)
            elif f7 == 0b0100100 and f3 == 0b001:  # bclr
                self.wr(rd, A & ~(1 << (B & (xl - 1))))
            elif f7 == 0b0100100 and f3 == 0b101:  # bext
                self.wr(rd, (A >> (B & (xl - 1))) & 1)
            elif f7 == 0b0110100 and f3 == 0b001:  # binv
                self.wr(rd, A ^ (1 << (B & (xl - 1))))
            elif f7 == 0b0010100 and f3 == 0b001:  # bset
                self.wr(rd, A | (1 << (B & (xl - 1))))
            # Pillar K (docs/adr/0059 Gen7-K7). clmul/clmulh land in
            # FUNCT7_ZBB_MINMAX's own free funct3 slots (see design/
            # riscv_defs.vh); truncate-then-XOR is bit-exact with the real
            # full-width carry-less product's low/high XLEN bits.
            elif f7 == 0b0000101 and f3 == 0b001:  # clmul
                res = 0
                for i in range(xl):
                    if (B >> i) & 1:
                        res ^= (A << i)
                self.wr(rd, self.uxlen(res))
            elif f7 == 0b0000101 and f3 == 0b011:  # clmulh
                res = 0
                for i in range(1, xl):
                    if (B >> i) & 1:
                        res ^= (A >> (xl - i))
                self.wr(rd, self.uxlen(res))
            elif f7 == 0b0000100 and f3 == 0b100:  # pack
                half = xl // 2
                self.wr(rd, self.uxlen(((B & ((1 << half) - 1)) << half) | (A & ((1 << half) - 1))))
            elif f7 == 0b0000100 and f3 == 0b111:  # packh
                self.wr(rd, ((B & 0xFF) << 8) | (A & 0xFF))
            elif f7 == 0b0010100 and f3 == 0b010:  # xperm4
                res = 0
                for i in range(xl // 4):
                    idx = (B >> (4 * i)) & 0xF
                    if idx < xl // 4:
                        res |= ((A >> (4 * idx)) & 0xF) << (4 * i)
                self.wr(rd, res)
            elif f7 == 0b0010100 and f3 == 0b100:  # xperm8
                res = 0
                for i in range(xl // 8):
                    idx = (B >> (8 * i)) & 0xFF
                    if idx < xl // 8:
                        res |= ((A >> (8 * idx)) & 0xFF) << (8 * i)
                self.wr(rd, res)
            elif f7 == 0b0011011 and f3 == 0b000:  # aes64esm
                self.wr(rd, aes64esm(A, B))
            elif f7 == 0b0011001 and f3 == 0b000:  # aes64es
                self.wr(rd, aes64es(A, B))
            elif f7 == 0b0011111 and f3 == 0b000:  # aes64dsm
                self.wr(rd, aes64dsm(A, B))
            elif f7 == 0b0011101 and f3 == 0b000:  # aes64ds
                self.wr(rd, aes64ds(A, B))
            elif f7 == 0b0111111 and f3 == 0b000:  # aes64ks2
                self.wr(rd, aes64ks2(A, B))
            else:
                if f3 == 0 and f7 == 0:
                    res = self.uxlen(A + B)
                elif f3 == 0 and f7 == 0b0100000:
                    res = self.uxlen(A - B)
                elif f3 == 1:
                    res = self.uxlen(A << (B & (xl - 1)))
                elif f3 == 2:
                    res = 1 if self.sxlen(A) < self.sxlen(B) else 0
                elif f3 == 3:
                    res = 1 if self.uxlen(A) < self.uxlen(B) else 0
                elif f3 == 4:
                    res = self.uxlen(A ^ B)
                elif f3 == 5 and f7 == 0:
                    res = self.uxlen(A) >> (B & (xl - 1))
                elif f3 == 5 and f7 == 0b0100000:
                    res = self.uxlen(self.sxlen(A) >> (B & (xl - 1)))
                elif f3 == 6:
                    res = self.uxlen(A | B)
                elif f3 == 7:
                    res = self.uxlen(A & B)
                else:
                    raise ValueError(f"unknown R-type f3={f3} f7={f7}")
                self.wr(rd, res)
            self.pc = next_pc

        elif op == 0b0111011:  # Generation 2: OP-32 -- addw/subw/sllw/srlw/
            # sraw/mulw/divw/divuw/remw/remuw. Same field layout as R-type
            # above (reuses OP's own funct7/funct3 byte-for-byte), but every
            # op computes on the low 32 bits (via the fixed-32-bit s32/u32,
            # NOT self.sxlen/self.uxlen) and sign-extends the 32-bit result
            # to XLEN via self.wr (which calls self.uxlen -- self.sxlen(...)
            # first, matching the spec's "always sign-extend the word
            # result" rule regardless of the op's own signedness, same as
            # design/ALU.v's wordOp arms and design/riscvpipeline.v's
            # div_result wrapping).
            if f7 == 0b0000001:  # divw/divuw/remw/remuw/mulw
                if f3 == 0b000:  # mulw
                    res32 = u32(A * B)
                elif f3 == 0b100:  # divw
                    if u32(B) == 0:
                        res32 = 0xFFFFFFFF
                    elif s32(A) == -2147483648 and s32(B) == -1:
                        res32 = u32(A)
                    else:
                        q = abs(s32(A)) // abs(s32(B))
                        if (s32(A) < 0) != (s32(B) < 0):
                            q = -q
                        res32 = u32(q)
                elif f3 == 0b101:  # divuw
                    res32 = 0xFFFFFFFF if u32(B) == 0 else (u32(A) // u32(B))
                elif f3 == 0b110:  # remw
                    if u32(B) == 0:
                        res32 = u32(A)
                    elif s32(A) == -2147483648 and s32(B) == -1:
                        res32 = 0
                    else:
                        r = abs(s32(A)) % abs(s32(B))
                        if s32(A) < 0:
                            r = -r
                        res32 = u32(r)
                else:  # remuw
                    res32 = u32(A) if u32(B) == 0 else (u32(A) % u32(B))
            else:
                if f3 == 0 and f7 == 0:  # addw
                    res32 = u32(A + B)
                elif f3 == 0 and f7 == 0b0100000:  # subw
                    res32 = u32(A - B)
                elif f3 == 1:  # sllw -- shamt always B[4:0], regardless of XLEN
                    res32 = u32(u32(A) << (B & 0x1F))
                elif f3 == 5 and f7 == 0:  # srlw
                    res32 = u32(A) >> (B & 0x1F)
                elif f3 == 5 and f7 == 0b0100000:  # sraw
                    res32 = u32(s32(A) >> (B & 0x1F))
                # B extension (docs/adr/0060) -- RV64-only word variants
                elif f7 == 0b0110000 and f3 == 0b001:  # rolw
                    a = u32(A)
                    sh = B & 0x1F
                    res32 = ((a << sh) | (a >> (32 - sh))) & 0xFFFFFFFF if sh else a
                elif f7 == 0b0110000 and f3 == 0b101:  # rorw
                    a = u32(A)
                    sh = B & 0x1F
                    res32 = ((a >> sh) | (a << (32 - sh))) & 0xFFFFFFFF if sh else a
                elif f7 == 0b0000100 and f3 == 0b000:  # add.uw (rs1=x0 form is the zext.w pseudo-op)
                    self.wr(rd, (u32(A) + B))
                    self.pc = next_pc
                    return
                elif f7 == 0b0010000 and f3 == 0b010:  # sh1add.uw
                    self.wr(rd, (u32(A) << 1) + B)
                    self.pc = next_pc
                    return
                elif f7 == 0b0010000 and f3 == 0b100:  # sh2add.uw
                    self.wr(rd, (u32(A) << 2) + B)
                    self.pc = next_pc
                    return
                elif f7 == 0b0010000 and f3 == 0b110:  # sh3add.uw
                    self.wr(rd, (u32(A) << 3) + B)
                    self.pc = next_pc
                    return
                elif f7 == 0b0000100 and f3 == 0b100:  # packw (Pillar K, docs/adr/0059 Gen7-K7)
                    lo = A & 0xFFFF
                    hi = B & 0xFFFF
                    self.wr(rd, sext((hi << 16) | lo, 32))
                    self.pc = next_pc
                    return
                else:
                    raise ValueError(f"unknown OP-32 f3={f3} f7={f7}")
            self.wr(rd, s32(res32))
            self.pc = next_pc

        elif op == 0b0010011:  # I-type ALU
            imm12 = (word >> 20) & 0xFFF
            f6 = (word >> 26) & 0x3F  # funct7[6:1] -- real for every XLEN, see riscv_defs.vh's FUNCT6_ALT comment
            if f3 in (1, 5) and f6 == 0b010010:  # bclri(f3=001) / bexti(f3=101)
                sh = imm12 & (xl - 1)
                if f3 == 1:
                    self.wr(rd, A & ~(1 << sh))
                else:
                    self.wr(rd, (A >> sh) & 1)
                self.pc = next_pc
                return
            elif f3 == 1 and f6 == 0b011010:  # binvi
                sh = imm12 & (xl - 1)
                self.wr(rd, A ^ (1 << sh))
                self.pc = next_pc
                return
            elif f3 == 1 and f6 == 0b001010:  # bseti
                sh = imm12 & (xl - 1)
                self.wr(rd, A | (1 << sh))
                self.pc = next_pc
                return
            elif f3 == 1 and f6 == 0b011000 and (imm12 & 0x1F) == 0b00000:  # clz
                count = 0
                for i in range(xl - 1, -1, -1):
                    if (A >> i) & 1:
                        break
                    count += 1
                self.wr(rd, count)
                self.pc = next_pc
                return
            elif f3 == 1 and f6 == 0b011000 and (imm12 & 0x1F) == 0b00001:  # ctz -- real Zbb encoding (docs/adr/0060)
                count = 0
                done = False
                for i in range(xl):
                    if (A >> i) & 1 == 0 and not done:
                        count += 1
                    else:
                        done = True
                self.wr(rd, count)
                self.pc = next_pc
                return
            elif f3 == 1 and f6 == 0b011000 and (imm12 & 0x1F) == 0b00010:  # cpop
                self.wr(rd, bin(self.uxlen(A)).count("1"))
                self.pc = next_pc
                return
            elif f3 == 1 and f6 == 0b011000 and (imm12 & 0x1F) == 0b00100:  # sext.b
                self.wr(rd, sext(A & 0xFF, 8))
                self.pc = next_pc
                return
            elif f3 == 1 and f6 == 0b011000 and (imm12 & 0x1F) == 0b00101:  # sext.h
                self.wr(rd, sext(A & 0xFFFF, 16))
                self.pc = next_pc
                return
            elif f3 == 5 and f6 == 0b011000:  # rori
                sh = imm12 & (xl - 1)
                a = self.uxlen(A)
                self.wr(rd, ((a >> sh) | (a << (xl - sh))) if sh else a)
                self.pc = next_pc
                return
            elif f3 == 5 and imm12 == 0x287:  # orc.b
                a = self.uxlen(A)
                nbytes = xl // 8
                out = 0
                for i in range(nbytes):
                    byte = (a >> (i * 8)) & 0xFF
                    out |= (0xFF if byte != 0 else 0x00) << (i * 8)
                self.wr(rd, out)
                self.pc = next_pc
                return
            elif f3 == 5 and imm12 == (0x698 if xl == 32 else 0x6B8):  # rev8
                a = self.uxlen(A)
                nbytes = xl // 8
                out = 0
                for i in range(nbytes):
                    out |= ((a >> (i * 8)) & 0xFF) << ((nbytes - 1 - i) * 8)
                self.wr(rd, out)
                self.pc = next_pc
                return
            elif f3 == 5 and imm12 == 0x687:  # brev8 (Pillar K, docs/adr/0059 Gen7-K7)
                self.wr(rd, brev8(self.uxlen(A), xl))
                self.pc = next_pc
                return
            elif f3 == 1 and f6 == 0b000100:  # sha256/512 sig0/1,sum0/1 -- rs2_c selects which
                rs2_c = (word >> 20) & 0x1F
                sha_fn = {0:sha256sum0, 1:sha256sum1, 2:sha256sig0, 3:sha256sig1,
                          4:sha512sum0, 5:sha512sum1, 6:sha512sig0, 7:sha512sig1}.get(rs2_c)
                if sha_fn is None:
                    raise ValueError(f"unknown sha rs2_c={rs2_c}")
                res = sha_fn(A)
                # sha256* return a 32-bit result, sign-extended to XLEN; sha512* are already XLEN-wide.
                self.wr(rd, sext(res, 32) if rs2_c < 4 else res)
                self.pc = next_pc
                return
            elif f3 == 1 and f6 == 0b001100:  # aes64im (rs2_c==0) / aes64ks1i (rs2_c[4]=1)
                rs2_c = (word >> 20) & 0x1F
                if rs2_c == 0:
                    self.wr(rd, aes64im(A))
                else:
                    self.wr(rd, aes64ks1i(A, rs2_c & 0xF))
                self.pc = next_pc
                return
            elif f3 in (1, 5):
                # Generation 2: 6-bit shamt/6-bit funct6 at xlen>=64,
                # matching design/ImmGen.v/design/ALUCtrl.v's own split --
                # bit-exact with the original 5-bit/7-bit form at xlen=32.
                if xl >= 64:
                    shamt = (word >> 20) & 0x3F
                    is_alt = (f6 == 0b010000)
                else:
                    shamt = (word >> 20) & 0x1F
                    is_alt = (f7 == 0b0100000)
                if f3 == 1:
                    res = self.uxlen(A << shamt)
                elif is_alt:
                    res = self.uxlen(self.sxlen(A) >> shamt)
                else:
                    res = self.uxlen(A) >> shamt
            elif f3 == 0:
                res = self.uxlen(A + imm_i)
            elif f3 == 2:
                res = 1 if self.sxlen(A) < imm_i else 0
            elif f3 == 3:
                res = 1 if self.uxlen(A) < self.uxlen(imm_i) else 0
            elif f3 == 4:
                res = self.uxlen(A ^ self.uxlen(imm_i))
            elif f3 == 6:
                res = self.uxlen(A | self.uxlen(imm_i))
            elif f3 == 7:
                res = self.uxlen(A & self.uxlen(imm_i))
            else:
                raise ValueError(f"unknown I-type f3={f3}")
            self.wr(rd, res)
            self.pc = next_pc

        elif op == 0b0011011:  # Generation 2: OP-IMM-32 -- addiw/slliw/
            # srliw/sraiw. shamt always exactly 5 bits regardless of XLEN
            # (unlike OPCODE_I's shamt above) -- this opcode only ever means
            # a 32-bit result.
            # B extension (docs/adr/0060) -- RV64-only word variants.
            if f3 == 1 and f7 == 0b0110000 and rs2 == 0b00000:  # clzw
                count = 0
                for i in range(31, -1, -1):
                    if (A >> i) & 1:
                        break
                    count += 1
                self.wr(rd, count)
                self.pc = next_pc
                return
            elif f3 == 1 and f7 == 0b0110000 and rs2 == 0b00001:  # ctzw
                v = u32(A)
                count = 0
                done = False
                for i in range(32):
                    if (v >> i) & 1 == 0 and not done:
                        count += 1
                    else:
                        done = True
                self.wr(rd, count)
                self.pc = next_pc
                return
            elif f3 == 1 and f7 == 0b0110000 and rs2 == 0b00010:  # cpopw
                self.wr(rd, bin(u32(A)).count("1"))
                self.pc = next_pc
                return
            elif f3 == 5 and f7 == 0b0110000:  # roriw
                sh = (word >> 20) & 0x1F
                a = u32(A)
                res32 = ((a >> sh) | (a << (32 - sh))) & 0xFFFFFFFF if sh else a
                self.wr(rd, s32(res32))
                self.pc = next_pc
                return
            elif f3 == 1 and ((word >> 26) & 0x3F) == 0b000010:  # slli.uw -- 6-bit shamt, zero-extended result (not sign-extended)
                sh = (word >> 20) & 0x3F
                self.wr(rd, (u32(A) << sh))
                self.pc = next_pc
                return
            elif f3 in (1, 5):
                shamt = (word >> 20) & 0x1F
                if f3 == 1:
                    res32 = u32(u32(A) << shamt)
                elif f7 == 0b0100000:
                    res32 = u32(s32(A) >> shamt)
                else:
                    res32 = u32(A) >> shamt
            elif f3 == 0:  # addiw
                res32 = u32(A + imm_i)
            else:
                raise ValueError(f"unknown OP-IMM-32 f3={f3}")
            self.wr(rd, s32(res32))
            self.pc = next_pc

        elif op == 0b0000011:  # loads
            addr = self.translate(self.uxlen(A + imm_i), "load")
            if addr is None:
                return  # page fault already trapped inside translate()
            if f3 == 0:  # lb
                v = self.load_mem_byte(addr)
                res = s32(v | (0xFFFFFF00 if v & 0x80 else 0))
            elif f3 == 1:  # lh
                v = self.load_mem_byte(addr) | (self.load_mem_byte(addr + 1) << 8)
                res = s32(v | (0xFFFF0000 if v & 0x8000 else 0))
            elif f3 == 2:  # lw -- Generation 2: sign-extends to XLEN (was a
                # real RTL bug fixed in design/DataMemoryBRAM.v -- lw used
                # to zero-extend; lwu exists specifically because lw doesn't).
                v = (self.load_mem_byte(addr) | (self.load_mem_byte(addr + 1) << 8) |
                     (self.load_mem_byte(addr + 2) << 16) | (self.load_mem_byte(addr + 3) << 24))
                res = s32(v)
            elif f3 == 4:  # lbu
                res = self.load_mem_byte(addr)
            elif f3 == 5:  # lhu
                res = self.load_mem_byte(addr) | (self.load_mem_byte(addr + 1) << 8)
            elif f3 == 3:  # ld -- Generation 2, real only at xlen>=64
                v = 0
                for i in range(8):
                    v |= self.load_mem_byte(addr + i) << (8 * i)
                res = v
            elif f3 == 6:  # lwu -- Generation 2, zero-extends (vs. lw's sign-extend)
                res = (self.load_mem_byte(addr) | (self.load_mem_byte(addr + 1) << 8) |
                       (self.load_mem_byte(addr + 2) << 16) | (self.load_mem_byte(addr + 3) << 24))
            else:
                raise ValueError(f"unknown load f3={f3}")
            self.wr(rd, res)
            self.pc = next_pc

        elif op == 0b0100011:  # stores
            imm_s = sext(((word >> 25) << 5) | ((word >> 7) & 0x1F), 12)
            addr = self.translate(self.uxlen(A + imm_s), "store")
            if addr is None:
                return  # page fault already trapped inside translate()
            if f3 == 0:
                self.store_mem_byte(addr, B)
            elif f3 == 1:
                self.store_mem_byte(addr, B)
                self.store_mem_byte(addr + 1, B >> 8)
            elif f3 == 2:
                for i in range(4):
                    self.store_mem_byte(addr + i, B >> (8 * i))
            elif f3 == 3:  # sd -- Generation 2, real only at xlen>=64
                for i in range(8):
                    self.store_mem_byte(addr + i, B >> (8 * i))
            else:
                raise ValueError(f"unknown store f3={f3}")
            self.pc = next_pc

        elif op == 0b1100011:  # branches
            b12 = (word >> 31) & 1
            b11 = (word >> 7) & 1
            b10_5 = (word >> 25) & 0x3F
            b4_1 = (word >> 8) & 0xF
            off = sext((b12 << 12) | (b11 << 11) | (b10_5 << 5) | (b4_1 << 1), 13)
            taken = {
                0: self.sxlen(A) == self.sxlen(B), 1: self.sxlen(A) != self.sxlen(B),
                2: self.sxlen(A) <= self.sxlen(B), 3: self.sxlen(A) > self.sxlen(B),
                4: self.sxlen(A) < self.sxlen(B), 5: self.sxlen(A) >= self.sxlen(B),
                6: self.uxlen(A) < self.uxlen(B), 7: self.uxlen(A) >= self.uxlen(B),
            }[f3]
            self.pc = self.uxlen(self.pc + off) if taken else next_pc

        elif op == 0b1101111:  # jal
            b20 = (word >> 31) & 1
            b19_12 = (word >> 12) & 0xFF
            b11 = (word >> 20) & 1
            b10_1 = (word >> 21) & 0x3FF
            off = sext((b20 << 20) | (b19_12 << 12) | (b11 << 11) | (b10_1 << 1), 21)
            self.wr(rd, next_pc)
            self.pc = self.uxlen(self.pc + off)

        elif op == 0b1100111:  # jalr
            target = self.uxlen((A + imm_i) & ~1)
            self.wr(rd, next_pc)
            self.pc = target

        elif op == 0b0110111:  # lui -- Generation 2: the 32-bit result is
            # sign-extended to XLEN per spec (was a real RTL bug fixed in
            # design/ImmGen.v -- bit-exact at xlen=32 since s32() is a no-op
            # there once self.wr's self.uxlen re-masks to 32 bits).
            self.wr(rd, s32(word & 0xFFFFF000))
            self.pc = next_pc

        elif op == 0b0010111:  # auipc -- same sign-extension reasoning as lui.
            self.wr(rd, self.uxlen(self.pc + s32(word & 0xFFFFF000)))
            self.pc = next_pc

        elif op == 0b1110011:  # SYSTEM: csrrw/rs/rc(+i), ecall, ebreak, mret, sret, sfence.vma
            csr_addr = (word >> 20) & 0xFFF
            if f3 == 0b000:
                # docs/adr/00NN-mmu-sv32.md (Phase F2/F6). sfence.vma is
                # SYSTEM/funct3=000 like ecall/ebreak/mret/sret, but unlike
                # those four it has real rs1/rs2 fields, so its own
                # inst[31:20] position isn't fixed -- distinguished by
                # funct7 alone, checked before the fixed-immediate cases
                # below, matching design/Control.v's own decode exactly.
                if f7 == 0b0001001:  # sfence.vma
                    if self.priv_mode == PRIV_U:
                        self.trap(MCAUSE_ILLEGAL_INSTRUCTION)
                    else:
                        # No-op otherwise -- this ISS models no TLB cache to
                        # flush, a full walk happens on every translate()
                        # call already.
                        self.pc = next_pc
                elif csr_addr == 0x000:  # ecall
                    # docs/adr/00NN-mmu-sv32.md (Phase F3/F6): privilege-
                    # dependent cause, matching riscvpipeline.v's own
                    # ecall trap_cause selection exactly (was unconditionally
                    # FROM_M before this phase, when M was the only
                    # privilege that existed).
                    cause = {PRIV_M: MCAUSE_ECALL_FROM_M, PRIV_S: MCAUSE_ECALL_FROM_S,
                             PRIV_U: MCAUSE_ECALL_FROM_U}[self.priv_mode]
                    self.trap(cause)
                elif csr_addr == 0x001:
                    self.trap(MCAUSE_BREAKPOINT)
                elif csr_addr == 0x302:  # mret
                    if self.priv_mode != PRIV_M:
                        self.trap(MCAUSE_ILLEGAL_INSTRUCTION)
                    else:
                        self.mret()
                elif csr_addr == 0x102:  # sret
                    if self.priv_mode == PRIV_U:
                        self.trap(MCAUSE_ILLEGAL_INSTRUCTION)
                    else:
                        self.sret()
                else:
                    self.trap(MCAUSE_ILLEGAL_INSTRUCTION)  # SYSTEM/f3=0, not any recognized form
            else:
                # docs/adr/00NN-mmu-sv32.md (Phase F3/F6): a CSR access below
                # its own required privilege (addr bits[9:8], per spec --
                # already numerically ordered the same way PRIV_U/S/M are,
                # matching riscvpipeline.v's csr_priv_violation exactly)
                # illegal-traps instead of committing.
                required_priv = (csr_addr >> 8) & 0b11
                if self.priv_mode < required_priv:
                    self.trap(MCAUSE_ILLEGAL_INSTRUCTION)
                else:
                    # rs1's raw 5-bit field doubles as the zero-extended uimm
                    # for the *i variants -- matches design/riscvpipeline.v's
                    # csr_wdata = funct3[2] ? {27'b0, inst[19:15]} : readData1.
                    old = self.csr_read(csr_addr)
                    src = rs1 if (f3 & 0b100) else A
                    csr_op = f3 & 0b011  # 01=write, 10=set, 11=clear -- matches design/CSR.v
                    if csr_op == 0b01:
                        new_val = src
                    elif csr_op == 0b10:
                        new_val = old | src
                    else:
                        new_val = old & ~src
                    self.csr_write(csr_addr, new_val)
                    self.wr(rd, old)
                    self.pc = next_pc

        # docs/adr/0019-f-extension.md (Phase C9): RV32F dispatch.
        elif op == 0b0000111:  # flw
            addr = self.translate(self.uxlen(A + imm_i), "load")
            if addr is None:
                return  # page fault already trapped inside translate()
            v = (self.load_mem_byte(addr) | (self.load_mem_byte(addr + 1) << 8) |
                 (self.load_mem_byte(addr + 2) << 16) | (self.load_mem_byte(addr + 3) << 24))
            self.fregs[rd] = v
            self.pc = next_pc

        elif op == 0b0100111:  # fsw
            imm_s = sext(((word >> 25) << 5) | ((word >> 7) & 0x1F), 12)
            addr = self.translate(self.uxlen(A + imm_s), "store")
            if addr is None:
                return  # page fault already trapped inside translate()
            v = self.fregs[rs2]
            for i in range(4):
                self.store_mem_byte(addr + i, v >> (8 * i))
            self.pc = next_pc

        elif op == 0b1010011:  # OP-FP
            funct5 = (word >> 27) & 0x1F
            rm = self.resolve_rm(f3)
            fa, fb = self.fregs[rs1], self.fregs[rs2]
            if funct5 == 0b00000:  # fadd.s
                res, flags = f_add(fa, fb, rm, is_sub=False)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b00001:  # fsub.s
                res, flags = f_add(fa, fb, rm, is_sub=True)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b00010:  # fmul.s
                res, flags = f_mul(fa, fb, rm)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b00011:  # fdiv.s
                res, flags = f_div(fa, fb, rm)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b01011:  # fsqrt.s
                res, flags = f_sqrt(fa, rm)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b00100:  # fsgnj.s/fsgnjn.s/fsgnjx.s
                res, _ = f_sgnj(fa, fb, f3)
                self.fregs[rd] = res
            elif funct5 == 0b00101:  # fmin.s/fmax.s
                res, flags = f_minmax(fa, fb, f3)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b10100:  # fle.s/flt.s/feq.s -- writes the INTEGER file
                res, flags = f_cmp(fa, fb, f3)
                self.wr(rd, res)
                self.set_fflags(flags)
            elif funct5 == 0b11000:  # fcvt.w.s/fcvt.wu.s -- writes the INTEGER file
                unsigned = (rs2 == 0b00001)
                res, flags = f_cvt_to_int(fa, rm, unsigned)
                self.wr(rd, res)
                self.set_fflags(flags)
            elif funct5 == 0b11010:  # fcvt.s.w/fcvt.s.wu -- reads the INTEGER
                # file. Generation 2: fcvt.s.w(u) converts the LOW 32 bits of
                # an XLEN-wide integer register (spec) -- u32(A) truncates
                # before f_cvt_from_int's own sign/magnitude split (which
                # reads bit31 as the 32-bit sign bit either way, so this is
                # a no-op at xlen=32).
                unsigned = (rs2 == 0b00001)
                res, flags = f_cvt_from_int(u32(A), rm, unsigned)
                self.fregs[rd] = res
                self.set_fflags(flags)
            elif funct5 == 0b11100:  # fmv.x.w/fclass.s -- both write the INTEGER file
                if f3 == 0b001:
                    self.wr(rd, f_class(fa))
                else:
                    # Generation 2: real spec text for RV64F's fmv.x.w --
                    # "the higher 32 bits of the destination register are
                    # filled with copies of the floating-point number's sign
                    # bit" -- i.e. sign-extended from bit31 of the raw float
                    # bit pattern, not zero-extended. s32() reinterprets the
                    # bit pattern as signed; self.wr's self.uxlen re-masks it
                    # correctly at any width (a no-op at xlen=32).
                    self.wr(rd, s32(fa))
            elif funct5 == 0b11110:  # fmv.w.x -- reads the INTEGER file.
                # Generation 2: spec takes the LOW 32 bits of rs1 (moot at
                # xlen=32, real at 64 -- e.g. after a sign-extending lui
                # loaded a negative-looking 32-bit float bit pattern into a
                # 64-bit register, only its low 32 bits are the real payload).
                self.fregs[rd] = u32(A)
            else:
                raise ValueError(f"unknown OP-FP funct5={funct5:#07b}")
            self.pc = next_pc

        elif op in (0b1000011, 0b1000111, 0b1001011, 0b1001111):  # fmadd.s/fmsub.s/fnmsub.s/fnmadd.s
            rs3 = (word >> 27) & 0x1F
            rm = self.resolve_rm(f3)
            # docs/adr/0019 (Phase C9 bugfix): opcode[3:2], not [4:3] -- see
            # design/riscvpipeline.v's own Phase C9 bugfix comment.
            op2 = (op >> 2) & 0b11
            neg_prod = bool(op2 & 0b10)
            neg_addend = bool(op2 & 0b01)
            res, flags = f_madd(self.fregs[rs1], self.fregs[rs2], self.fregs[rs3], rm, neg_prod, neg_addend)
            self.fregs[rd] = res
            self.set_fflags(flags)
            self.pc = next_pc

        elif op == 0b0001111 and f3 == 0b000:  # fence (docs/adr/0023-caches.md,
            # Phase G1). A cache changes timing only, never architectural
            # values (same "zero ISS changes" category as branch prediction,
            # docs/adr/0021) -- a literal no-op is the correct model here,
            # not a placeholder pending future work. Any other MISC-MEM
            # funct3 (e.g. fence.i) is unrecognized and falls to the trap
            # below, matching design/Control.v's own decode.
            self.pc = next_pc

        else:
            # Matches design/Control.v's outer default case (docs/adr/0011):
            # any opcode this core doesn't implement traps as an illegal
            # instruction rather than being a simulator-level error.
            self.trap(MCAUSE_ILLEGAL_INSTRUCTION)

    def run(self, words, max_steps=20000):
        # Every generated/hand-written test program (docs/adr/0011) now ends
        # in a deliberate `jal x0, <self>` rather than running off the end
        # into instruction memory's zero-filled remainder (opcode 0000000 is
        # not a valid instruction and correctly traps as of that ADR) --
        # detect that specific self-loop and stop cleanly there instead of
        # spinning for the full step budget. Reaching max_steps *without*
        # hitting a self-loop is still treated as a genuine runaway: nothing
        # else should be able to loop, since sim/tools/random_gen.py only
        # ever generates forward-only branches/jumps.
        byte_len = len(words) * 4
        steps = 0
        while steps < max_steps:
            # docs/adr/0020-soc-integration.md (Phase D10). Externally
            # scheduled interrupt injection -- checked *before* the
            # self-loop-halt detection below, deliberately: if `after_steps`
            # happens to land exactly on (or past) the halt loop, the
            # interrupt must still fire rather than the halt check breaking
            # out first and silently skipping it. Single-shot by
            # construction (pending_interrupt is cleared the instant it
            # fires) -- no separate re-trigger-prevention logic needed on
            # this side the way the RTL's own handler needs one (mip is a
            # real level signal there; this is just a one-time scheduled
            # event here).
            if (self.pending_interrupt is not None
                    and steps >= self.pending_interrupt["after"]
                    and ((self.csr[CSR_MSTATUS] >> 3) & 1)):
                self.trap(self.pending_interrupt["cause"])
                self.pending_interrupt = None
                continue
            # docs/adr/00NN-mmu-sv32.md (Phase F6). self.pc is always the
            # VIRTUAL address (architecturally, PC is a virtual concept --
            # translation only affects where the fetch reads FROM, matching
            # design/riscvpipeline.v's own design: pc_o/pc_o_regde etc are
            # never translated themselves). `words` is this ISS's own
            # instruction-memory array, indexed by the PHYSICAL fetch
            # address -- bit-exact with the pre-Phase-F behavior when
            # translation is disabled (translate() returns vaddr unchanged,
            # so fetch_addr == self.pc exactly, same as the old `self.pc //
            # 4` indexing and the old `self.pc < byte_len` loop bound).
            fetch_addr = self.translate(self.pc, "fetch")
            if fetch_addr is None:
                continue  # page fault already trapped inside translate(); retry with the new (redirected) pc
            if fetch_addr >= byte_len:
                break
            word = words[fetch_addr // 4]
            if word & 0x7F == 0b1101111:  # jal
                b20 = (word >> 31) & 1
                b19_12 = (word >> 12) & 0xFF
                b11 = (word >> 20) & 1
                b10_1 = (word >> 21) & 0x3FF
                off = sext((b20 << 20) | (b19_12 << 12) | (b11 << 11) | (b10_1 << 1), 21)
                if off == 0:
                    break  # self-loop halt, see comment above
            self.step(word)
            steps += 1
        else:
            if steps >= max_steps:
                raise RuntimeError(f"exceeded {max_steps} steps without reaching a self-loop -- program likely loops forever unexpectedly")
        return steps
