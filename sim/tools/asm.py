#!/usr/bin/env python3
"""
Minimal assembler for this repository's RV32I-subset core (design/riscvpipeline.v).

This is NOT a general RISC-V assembler: it only encodes the instructions this
specific datapath implements, using this core's specific (partly custom)
encodings -- notably the branch funct3 map (ble/bgt instead of bltu/bgeu, see
docs/ARCHITECTURE.md sec 5) and the custom `ctz` op. Output is a byte stream
in the big-endian, $readmemb-compatible binary-ASCII format InstructionMemory.v
expects (one 8-bit binary string per line, most-significant byte first).

Usage: python asm.py program.s -o program.mem
"""
import argparse
import re
import sys

REG_RE = re.compile(r"^x(\d+)$")


def reg(tok):
    m = REG_RE.match(tok.strip())
    if not m:
        raise ValueError(f"expected register (x0-x31), got {tok!r}")
    n = int(m.group(1))
    if not (0 <= n <= 31):
        raise ValueError(f"register out of range: {tok!r}")
    return n


FREG_RE = re.compile(r"^f(\d+)$")


def freg(tok):
    # docs/adr/0019-f-extension.md (Phase C9). No x0-equivalent here --
    # FRegister.v hardwires nothing, f0 is a completely ordinary register.
    m = FREG_RE.match(tok.strip())
    if not m:
        raise ValueError(f"expected float register (f0-f31), got {tok!r}")
    n = int(m.group(1))
    if not (0 <= n <= 31):
        raise ValueError(f"float register out of range: {tok!r}")
    return n


def imm(tok, bits, signed=True):
    v = tok if isinstance(tok, int) else int(tok.strip(), 0)
    lo = -(1 << (bits - 1)) if signed else 0
    hi = (1 << (bits - 1)) - 1 if signed else (1 << bits) - 1
    if not (lo <= v <= hi):
        raise ValueError(f"immediate {v} out of range [{lo},{hi}]")
    return v & ((1 << bits) - 1)


def u(v, bits):
    return v & ((1 << bits) - 1)


# opcode constants (this core's decode table, see design/riscv_defs.vh)
OP_R = 0b0110011
OP_I = 0b0010011
OP_LOAD = 0b0000011
OP_STORE = 0b0100011
OP_BRANCH = 0b1100011
OP_JAL = 0b1101111
OP_JALR = 0b1100111
OP_LUI = 0b0110111
OP_AUIPC = 0b0010111
# docs/adr/0041: was 0b0101010 (bits[1:0]=10) -- a real bug, dormant since
# RVC support (docs/adr/0037) made is_compressed=(inst[1:0]!=2'b11) a live
# fetch-path check; any opcode not ending in 11 gets misdecoded as a 2-byte
# compressed instruction. Fixed to real spec custom-0 (bits[1:0]=11).
OP_CUSTOM = 0b0001011
OP_SYSTEM = 0b1110011
OP_MISC_MEM = 0b0001111  # fence (docs/adr/0023-caches.md, Phase G1)

# Generation 2 (Phase M, docs/adr/0028-rv64-migration-phase-m.md). RV64I's
# "w"-suffixed word family reuses OP/OP-IMM's own funct7/funct3 encodings
# byte-for-byte, just under these two new opcodes.
OP_32 = 0b0111011
OP_IMM_32 = 0b0011011

CSR_ADDR = {  # standard RISC-V machine-mode addresses (docs/adr/0011-csr-and-exceptions.md,
              # docs/adr/0020-soc-integration.md Phase D7 for mie/mip)
    "mstatus": 0x300, "mie": 0x304, "mtvec": 0x305, "mscratch": 0x340, "mepc": 0x341,
    "mcause": 0x342, "mip": 0x344,
    "satp": 0x180,  # docs/adr/0053 (Gen6-P2): standard RISC-V supervisor address, needed to write it directly
}
CSR_OP = {"csrrw": 0b001, "csrrs": 0b010, "csrrc": 0b011,
          "csrrwi": 0b101, "csrrsi": 0b110, "csrrci": 0b111}
SYSTEM_IMM12 = {"ecall": 0x000, "ebreak": 0x001, "mret": 0x302, "sret": 0x102}
FUNCT7_SFENCE_VMA = 0b0001001  # docs/adr/00NN-mmu-sv32.md (Phase F2)

FUNCT7_BASE = 0b0000000
FUNCT7_ALT = 0b0100000    # sub/sra, and (docs/adr/0060) real andn/orn/xnor
FUNCT7_MULDIV = 0b0000001  # RV32M

R_TYPE = {  # mnemonic: (full funct7, funct3)
    "add": (FUNCT7_BASE, 0b000), "sub": (FUNCT7_ALT, 0b000), "sll": (FUNCT7_BASE, 0b001),
    "slt": (FUNCT7_BASE, 0b010), "sltu": (FUNCT7_BASE, 0b011), "xor": (FUNCT7_BASE, 0b100),
    "srl": (FUNCT7_BASE, 0b101), "sra": (FUNCT7_ALT, 0b101), "or": (FUNCT7_BASE, 0b110), "and": (FUNCT7_BASE, 0b111),
    # RV32M (docs/adr/0006-rv32m.md) -- shares the R-type opcode, distinguished by funct7=0000001
    "mul": (FUNCT7_MULDIV, 0b000), "mulh": (FUNCT7_MULDIV, 0b001),
    "mulhsu": (FUNCT7_MULDIV, 0b010), "mulhu": (FUNCT7_MULDIV, 0b011),
    "div": (FUNCT7_MULDIV, 0b100), "divu": (FUNCT7_MULDIV, 0b101),
    "rem": (FUNCT7_MULDIV, 0b110), "remu": (FUNCT7_MULDIV, 0b111),
    # B extension: Zba+Zbb+Zbs (docs/adr/0060), verified against the real
    # riscv/riscv-opcodes tables -- FUNCT7_ALT+111/110/100 are real
    # andn/orn/xnor, NOT the retired custom ctz.
    "andn": (FUNCT7_ALT, 0b111), "orn": (FUNCT7_ALT, 0b110), "xnor": (FUNCT7_ALT, 0b100),
    "min": (0b0000101, 0b100), "minu": (0b0000101, 0b101), "max": (0b0000101, 0b110), "maxu": (0b0000101, 0b111),
    "rol": (0b0110000, 0b001), "ror": (0b0110000, 0b101),
    "sh1add": (0b0010000, 0b010), "sh2add": (0b0010000, 0b100), "sh3add": (0b0010000, 0b110),
    "bclr": (0b0100100, 0b001), "bext": (0b0100100, 0b101), "binv": (0b0110100, 0b001), "bset": (0b0010100, 0b001),
    # Pillar K (docs/adr/0059 Gen7-K7), full Zkn -- verified against
    # riscv-opcodes rv_zbc/rv_zbkb/rv_zbkx/rv64_zkne/rv64_zknd, same
    # sources design/riscv_defs.vh's own K-extension defines cite.
    "clmul": (0b0000101, 0b001), "clmulh": (0b0000101, 0b011),
    "pack": (0b0000100, 0b100), "packh": (0b0000100, 0b111),
    "xperm4": (0b0010100, 0b010), "xperm8": (0b0010100, 0b100),
    "aes64esm": (0b0011011, 0b000), "aes64es": (0b0011001, 0b000),
    "aes64dsm": (0b0011111, 0b000), "aes64ds": (0b0011101, 0b000),
    "aes64ks2": (0b0111111, 0b000),
}
I_TYPE = {  # mnemonic: funct3 (funct7[5] used only by srli/srai)
    "addi": 0b000, "slli": 0b001, "slti": 0b010, "sltiu": 0b011,
    "xori": 0b100, "srli": 0b101, "srai": 0b101, "ori": 0b110, "andi": 0b111,
}
# B extension (docs/adr/0060). bclri/bexti/binvi/bseti/rori share slli/srli/
# srai's own funct6+shamt shape (see i_type()'s own xlen-dependent split) --
# mnemonic: (funct6, funct3).
I_TYPE_BEXT_SHAMT = {
    "bclri": (0b010010, 0b001), "bexti": (0b010010, 0b101),
    "binvi": (0b011010, 0b001), "bseti": (0b001010, 0b001),
    "rori":  (0b011000, 0b101),
}
# clz/ctz/cpop/sext.b/sext.h -- rs1-only, no shamt at all, a fully fixed
# 12-bit immediate (funct6<<6 | rs2-field-as-selector). ctz moved here from
# its old custom-opcode encoding -- real Zbb slot now (docs/adr/0060).
I_TYPE_BEXT_FIXED = {
    "clz": (0x600, 0b001), "ctz": (0x601, 0b001), "cpop": (0x602, 0b001),
    "sext.b": (0x604, 0b001), "sext.h": (0x605, 0b001), "orc.b": (0x287, 0b101),
    # rev8's own immediate is XLEN-dependent (0x698 at 32, 0x6b8 at 64) --
    # handled separately in assemble(), not via this fixed dict.
    # Pillar K (docs/adr/0059 Gen7-K7) rs1-only, fixed-immediate ops -- same
    # shape as clz/ctz/cpop above, imm12 values taken directly from the
    # verified riscv-opcodes encodings (rv_zbkb's own literal 0x687 for
    # brev8; the sha256/512 group's imm12 = funct7(0001000)<<5 | rs2-selector,
    # matching design/riscv_defs.vh's FUNCT6_ZKNH_SHA/RS2_SHA* derivation;
    # aes64im's imm12 = funct7(0011000)<<5 | rs2=00000).
    "brev8": (0x687, 0b101),
    "sha256sum0": (0x100, 0b001), "sha256sum1": (0x101, 0b001),
    "sha256sig0": (0x102, 0b001), "sha256sig1": (0x103, 0b001),
    "sha512sum0": (0x104, 0b001), "sha512sum1": (0x105, 0b001),
    "sha512sig0": (0x106, 0b001), "sha512sig1": (0x107, 0b001),
    "aes64im": (0x300, 0b001),
}
BRANCH = {  # mnemonic: funct3 -- beq/bne/blt/bge/ble/bgt/bltu/bgeu. blt/bge at real RISC-V
    # spec positions (100/101); ble/bgt are this core's own custom ops, at the reserved
    # positions (010/011) real spec leaves unused (docs/adr/0030-branch-encoding-fix.md).
    "beq": 0b000, "bne": 0b001, "blt": 0b100, "bge": 0b101,
    "ble": 0b010, "bgt": 0b011, "bltu": 0b110, "bgeu": 0b111,
}
LOAD = {"lb": 0b000, "lh": 0b001, "lw": 0b010, "lbu": 0b100, "lhu": 0b101,
        "ld": 0b011, "lwu": 0b110}  # ld/lwu: Generation 2, real only at XLEN>=64
STORE = {"sb": 0b000, "sh": 0b001, "sw": 0b010, "sd": 0b011}  # sd: Generation 2

# Generation 2 (Phase M). addw/subw/sllw/srlw/sraw/mulw/divw/divuw/remw/remuw
# -- mnemonic: (full funct7, funct3), same shape as R_TYPE above, emitted
# against OP_32 instead of OP_R (see r_type_w).
R_TYPE_W = {
    "addw": (FUNCT7_BASE, 0b000), "subw": (FUNCT7_ALT, 0b000), "sllw": (FUNCT7_BASE, 0b001),
    "srlw": (FUNCT7_BASE, 0b101), "sraw": (FUNCT7_ALT, 0b101),
    "mulw": (FUNCT7_MULDIV, 0b000),
    "divw": (FUNCT7_MULDIV, 0b100), "divuw": (FUNCT7_MULDIV, 0b101),
    "remw": (FUNCT7_MULDIV, 0b110), "remuw": (FUNCT7_MULDIV, 0b111),
    # B extension, RV64-only word variants (docs/adr/0060).
    "rolw": (0b0110000, 0b001), "rorw": (0b0110000, 0b101),
    "add.uw": (0b0000100, 0b000),
    "sh1add.uw": (0b0010000, 0b010), "sh2add.uw": (0b0010000, 0b100), "sh3add.uw": (0b0010000, 0b110),
    # Pillar K (docs/adr/0059 Gen7-K7). packw shares ALUCTL_PACK with pack
    # via wordOp, same OP_32-reuse shape as add.uw/rolw above.
    "packw": (0b0000100, 0b100),
}
# addiw/slliw/srliw/sraiw -- shamt is always exactly 5 bits regardless of
# XLEN (spec-mandated, unlike the plain slli/srli/srai below, which widen to
# 6 bits at XLEN=64 -- see i_type()'s own xlen parameter).
I_TYPE_W = {"addiw": 0b000, "slliw": 0b001, "srliw": 0b101, "sraiw": 0b101}
# B extension, RV64-only word variants (docs/adr/0060). clzw/ctzw/cpopw: no
# shamt, fixed 12-bit immediate under OP_IMM_32. roriw/slli.uw handled
# separately in assemble() -- roriw keeps OP_32's own full-funct7+5-bit-shamt
# shape (not funct6-split), slli.uw genuinely needs a 6-bit shamt despite
# living on OP_IMM_32 (see riscv_defs.vh's own FUNCT6_ZBA_SLLIUW comment).
I_TYPE_W_BEXT_FIXED = {"clzw": 0x600, "ctzw": 0x601, "cpopw": 0x602}

# RV32F (docs/adr/0019-f-extension.md, Phase C9). Encodings mirror
# design/riscv_defs.vh exactly -- that file is the single source of truth
# this tooling extension is checked against, same as the base ISA tables
# above are checked against design/Control.v/ALUCtrl.v.
OP_FP = 0b1010011
OP_LOAD_FP = 0b0000111
OP_STORE_FP = 0b0100111
OP_MADD, OP_MSUB, OP_NMSUB, OP_NMADD = 0b1000011, 0b1000111, 0b1001011, 0b1001111
MADD_OPCODES = {"fmadd.s": OP_MADD, "fmsub.s": OP_MSUB, "fnmsub.s": OP_NMSUB, "fnmadd.s": OP_NMADD}

FUNCT5_FADD, FUNCT5_FSUB, FUNCT5_FMUL, FUNCT5_FDIV = 0b00000, 0b00001, 0b00010, 0b00011
FUNCT5_FSQRT = 0b01011
FUNCT5_FSGNJ = 0b00100
FUNCT5_FMINMAX = 0b00101
FUNCT5_FCMP = 0b10100
FUNCT5_FCVT_W_S = 0b11000
FUNCT5_FCVT_S_W = 0b11010
FUNCT5_FMV_X_W_FCLASS = 0b11100
FUNCT5_FMV_W_X = 0b11110

FP_ARITH = {"fadd.s": FUNCT5_FADD, "fsub.s": FUNCT5_FSUB, "fmul.s": FUNCT5_FMUL, "fdiv.s": FUNCT5_FDIV}
FP_SGNJ = {"fsgnj.s": 0b000, "fsgnjn.s": 0b001, "fsgnjx.s": 0b010}
FP_MINMAX = {"fmin.s": 0b000, "fmax.s": 0b001}
FP_CMP = {"fle.s": 0b000, "flt.s": 0b001, "feq.s": 0b010}
# Trailing optional rounding-mode operand (real RISC-V assembler
# convention): defaults to `dyn` (read fcsr's live frm, docs/adr/0019
# Phase C8) when omitted, same as every real RV32F assembler.
RM_NAMES = {"rne": 0b000, "rtz": 0b001, "rdn": 0b010, "rup": 0b011, "rmm": 0b100, "dyn": 0b111}


def parse_rm(args, idx):
    if len(args) > idx and args[idx].strip():
        name = args[idx].strip().lower()
        if name not in RM_NAMES:
            raise ValueError(f"unknown rounding mode {name!r}")
        return RM_NAMES[name]
    return RM_NAMES["dyn"]


def r_type(mn, rd, rs1, rs2):
    f7, f3 = R_TYPE[mn]
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OP_R


def i_type(mn, rd, rs1, immv, xlen=32):
    f3 = I_TYPE[mn]
    if mn in ("slli", "srli", "srai"):
        # Generation 2 (Phase M): at xlen>=64, shamt widens from 5 bits to 6
        # (inst[25:20]) to reach 63, and the discriminator shrinks from a
        # 7-bit funct7 to a 6-bit funct6 (inst[31:26]) -- bit-exact with the
        # original 5-bit/7-bit split at xlen=32 (the default). See
        # design/riscv_defs.vh's FUNCT6_ALT comment / design/ALUCtrl.v's
        # matching fix for the RTL side of this same split.
        if xlen >= 64:
            shamt = imm(immv, 6, signed=False)
            f6 = 0b010000 if mn == "srai" else 0b000000
            imm12 = (f6 << 6) | shamt
        else:
            shamt = imm(immv, 5, signed=False)
            f7 = FUNCT7_ALT if mn == "srai" else FUNCT7_BASE
            # imm12 covers inst[31:20] == funct7(7 bits) ++ shamt(5 bits).
            imm12 = (f7 << 5) | shamt
    else:
        imm12 = imm(immv, 12, signed=True)
    return (u(imm12, 12) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OP_I


def r_type_w(mn, rd, rs1, rs2):
    # Generation 2 (Phase M). addw/subw/sllw/srlw/sraw/mulw/divw/divuw/remw/
    # remuw -- same field layout as r_type(), OP_32 instead of OP_R.
    f7, f3 = R_TYPE_W[mn]
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OP_32


def i_type_w(mn, rd, rs1, immv):
    # Generation 2 (Phase M). addiw/slliw/srliw/sraiw -- shamt always 5 bits
    # (see I_TYPE_W's own comment), OP_IMM_32 instead of OP_I.
    f3 = I_TYPE_W[mn]
    if mn in ("slliw", "srliw", "sraiw"):
        shamt = imm(immv, 5, signed=False)
        f7 = FUNCT7_ALT if mn == "sraiw" else FUNCT7_BASE
        imm12 = (f7 << 5) | shamt
    else:
        imm12 = imm(immv, 12, signed=True)
    return (u(imm12, 12) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | OP_IMM_32


def load(mn, rd, offs, rs1):
    imm12 = imm(offs, 12, signed=True)
    return (u(imm12, 12) << 20) | (rs1 << 15) | (LOAD[mn] << 12) | (rd << 7) | OP_LOAD


def store(mn, rs2, offs, rs1):
    imm12 = imm(offs, 12, signed=True)
    hi = (imm12 >> 5) & 0x7F
    lo = imm12 & 0x1F
    return (hi << 25) | (rs2 << 20) | (rs1 << 15) | (STORE[mn] << 12) | (lo << 7) | OP_STORE


def jalr(rd, offs, rs1):
    imm12 = imm(offs, 12, signed=True)
    return (u(imm12, 12) << 20) | (rs1 << 15) | (rd << 7) | OP_JALR


def u_type(opcode, rd, imm20):
    # imm20 is inst[31:12] directly (i.e. already "the upper 20 bits"), not
    # left-shifted again here -- matches typical `lui rd, 0x12345` usage.
    v = imm(imm20, 20, signed=False)
    return (v << 12) | (rd << 7) | opcode


def branch(mn, rs1, rs2, offset_bytes):
    f3 = BRANCH[mn]
    v = imm(offset_bytes, 13, signed=True)
    if v & 1:
        raise ValueError("branch offset must be even")
    b12 = (v >> 12) & 1
    b11 = (v >> 11) & 1
    b10_5 = (v >> 5) & 0x3F
    b4_1 = (v >> 1) & 0xF
    return (b12 << 31) | (b10_5 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (b11 << 7) | (b4_1 << 8) | OP_BRANCH


def jal(rd, offset_bytes):
    v = imm(offset_bytes, 21, signed=True)
    if v & 1:
        raise ValueError("jal offset must be even")
    b20 = (v >> 20) & 1
    b10_1 = (v >> 1) & 0x3FF
    b11 = (v >> 11) & 1
    b19_12 = (v >> 12) & 0xFF
    return (b20 << 31) | (b19_12 << 12) | (b11 << 20) | (b10_1 << 21) | (rd << 7) | OP_JAL


def i_type_raw(imm12, f3, rd, rs1, opcode=OP_I):
    # Shared low-level I-type encoder: caller has already resolved the full
    # 12-bit immediate and funct3 -- used by every B-ext I-type helper below
    # instead of duplicating this one-liner four times (docs/adr/0060).
    return (u(imm12, 12) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | opcode


def i_type_bext_shamt(mn, rd, rs1, immv, xlen=32):
    # bclri/bexti/binvi/bseti/rori -- same funct6+shamt split as slli/srli/
    # srai (see i_type()'s own comment): 5-bit shamt/7-bit-view at XLEN=32,
    # 6-bit shamt/6-bit funct6 at XLEN=64 (docs/adr/0060).
    f6, f3 = I_TYPE_BEXT_SHAMT[mn]
    shamt = imm(immv, 6 if xlen >= 64 else 5, signed=False)
    imm12 = (f6 << 6) | shamt
    return i_type_raw(imm12, f3, rd, rs1)


def i_type_bext_fixed(mn, rd, rs1):
    imm12, f3 = I_TYPE_BEXT_FIXED[mn]
    return i_type_raw(imm12, f3, rd, rs1)


def aes64ks1i(rd, rs1, rnum):
    # Pillar K (docs/adr/0059 Gen7-K7). rnum (0-10, spec-legal range) is a
    # real operand, not a fixed selector -- imm12 = funct7(0011000) ++
    # rs2-field({1,rnum[3:0]}), verified against rv64_zknd's
    # `aes64ks1i rd rs1 rnum 31..30=0 29..25=0b11000 24=1`.
    r = imm(rnum, 4, signed=False)
    imm12 = (0b0011000 << 5) | 0b10000 | r
    return i_type_raw(imm12, 0b001, rd, rs1)


def rev8(rd, rs1, xlen=32):
    imm12 = 0x698 if xlen == 32 else 0x6B8
    return i_type_raw(imm12, 0b101, rd, rs1)


def i_type_w_bext_fixed(mn, rd, rs1):
    imm12 = I_TYPE_W_BEXT_FIXED[mn]
    return i_type_raw(imm12, 0b001, rd, rs1, opcode=OP_IMM_32)


def roriw(rd, rs1, immv):
    shamt = imm(immv, 5, signed=False)
    imm12 = (0b0110000 << 5) | shamt
    return i_type_raw(imm12, 0b101, rd, rs1, opcode=OP_IMM_32)


def slli_uw(rd, rs1, immv):
    shamt = imm(immv, 6, signed=False)
    imm12 = (0b000010 << 6) | shamt
    return i_type_raw(imm12, 0b001, rd, rs1, opcode=OP_IMM_32)


def fp_r_type(funct5, rd, rs1, rs2, rm):
    return (funct5 << 27) | (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | OP_FP


def fp_sqrt(rd, rs1, rm):
    return (FUNCT5_FSQRT << 27) | (0 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | OP_FP


def fp_sgnj(mn, rd, rs1, rs2):
    return (FUNCT5_FSGNJ << 27) | (rs2 << 20) | (rs1 << 15) | (FP_SGNJ[mn] << 12) | (rd << 7) | OP_FP


def fp_minmax(mn, rd, rs1, rs2):
    return (FUNCT5_FMINMAX << 27) | (rs2 << 20) | (rs1 << 15) | (FP_MINMAX[mn] << 12) | (rd << 7) | OP_FP


def fp_cmp(mn, rd, rs1, rs2):
    return (FUNCT5_FCMP << 27) | (rs2 << 20) | (rs1 << 15) | (FP_CMP[mn] << 12) | (rd << 7) | OP_FP


def fp_cvt_w_s(unsigned, rd, rs1, rm):
    rs2 = 0b00001 if unsigned else 0b00000
    return (FUNCT5_FCVT_W_S << 27) | (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | OP_FP


def fp_cvt_s_w(unsigned, rd, rs1, rm):
    rs2 = 0b00001 if unsigned else 0b00000
    return (FUNCT5_FCVT_S_W << 27) | (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | OP_FP


def fp_mv_x_w(rd, rs1):
    return (FUNCT5_FMV_X_W_FCLASS << 27) | (rs1 << 15) | (0b000 << 12) | (rd << 7) | OP_FP


def fp_class(rd, rs1):
    return (FUNCT5_FMV_X_W_FCLASS << 27) | (rs1 << 15) | (0b001 << 12) | (rd << 7) | OP_FP


def fp_mv_w_x(rd, rs1):
    return (FUNCT5_FMV_W_X << 27) | (rs1 << 15) | (rd << 7) | OP_FP


def flw(rd, offs, rs1):
    imm12 = imm(offs, 12, signed=True)
    return (u(imm12, 12) << 20) | (rs1 << 15) | (0b010 << 12) | (rd << 7) | OP_LOAD_FP


def fsw(rs2, offs, rs1):
    imm12 = imm(offs, 12, signed=True)
    hi = (imm12 >> 5) & 0x7F
    lo = imm12 & 0x1F
    return (hi << 25) | (rs2 << 20) | (rs1 << 15) | (0b010 << 12) | (lo << 7) | OP_STORE_FP


def fp_r4_type(opcode, rd, rs1, rs2, rs3, rm):
    # docs/adr/0019-f-extension.md (Phase C9). opcode[3:2] selects which of
    # fmadd.s/fmsub.s/fnmsub.s/fnmadd.s -- bit4 is 0 for all four (see
    # riscvpipeline.v's own Phase C9 bugfix comment for the story of
    # getting this bit position right).
    return (rs3 << 27) | (rs2 << 20) | (rs1 << 15) | (rm << 12) | (rd << 7) | opcode


def csr_lookup(csr):
    # dict.get(key, default) evaluates `default` eagerly even on a hit, so a
    # plain-name lookup like `.get(csr, int(csr, 0))` would try to int()
    # "mscratch" every time -- an explicit membership check avoids that.
    if csr in CSR_ADDR:
        return CSR_ADDR[csr]
    return csr if isinstance(csr, int) else int(csr, 0)


def csr_reg(mn, rd, csr, rs1):
    csr_addr = csr_lookup(csr)
    return (u(csr_addr, 12) << 20) | (rs1 << 15) | (CSR_OP[mn] << 12) | (rd << 7) | OP_SYSTEM


def csr_imm(mn, rd, csr, uimm):
    csr_addr = csr_lookup(csr)
    uimm5 = imm(uimm, 5, signed=False)
    return (u(csr_addr, 12) << 20) | (uimm5 << 15) | (CSR_OP[mn] << 12) | (rd << 7) | OP_SYSTEM


def system_noarg(mn):
    return (SYSTEM_IMM12[mn] << 20) | OP_SYSTEM


def sfence_vma(rs1, rs2):
    # docs/adr/00NN-mmu-sv32.md (Phase F2). Real rs1 (address, x0="all
    # addresses")/rs2 (ASID, x0="all ASIDs") fields -- unlike ecall/ebreak/
    # mret/sret, funct7 alone (not a fixed full inst[31:20]) identifies this
    # instruction, since rs2 varies. This project's own RTL always flushes
    # the whole TLB regardless of rs1/rs2 (a documented simplification, see
    # the phase plan), but the assembler still encodes them faithfully.
    return (FUNCT7_SFENCE_VMA << 25) | (rs2 << 20) | (rs1 << 15) | OP_SYSTEM


def fence():
    # docs/adr/0023-caches.md (Phase G1). rd=rs1=0, funct3=000 (the only
    # decoded MISC-MEM encoding this core recognizes -- see Control.v).
    # pred/succ (inst[27:20], all-1s = "order everything") and fm
    # (inst[31:28]=0) are encoded faithfully even though the RTL doesn't
    # read them yet (this phase always does a full flush, see the ADR).
    pred_succ_fm = 0b0000_1111_1111  # fm=0000, pred=1111, succ=1111
    return (pred_succ_fm << 20) | OP_MISC_MEM


def assemble(lines, xlen=32):
    # pass 1: strip comments/whitespace, record label addresses
    stmts = []
    addr = 0
    labels = {}
    for raw in lines:
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.endswith(":"):
            labels[line[:-1].strip()] = addr
            continue
        stmts.append((addr, line))
        addr += 4

    def resolve(tok, cur_addr):
        tok = tok.strip()
        if tok in labels:
            return labels[tok] - cur_addr
        return int(tok, 0)

    words = []
    for cur_addr, line in stmts:
        parts = re.split(r"[,\s]+", line.strip())
        mn = parts[0].lower()
        args = parts[1:]

        if mn == "nop":
            words.append(i_type("addi", 0, 0, 0))
        elif mn in R_TYPE:
            rd, rs1, rs2 = reg(args[0]), reg(args[1]), reg(args[2])
            words.append(r_type(mn, rd, rs1, rs2))
        elif mn in I_TYPE:
            rd, rs1 = reg(args[0]), reg(args[1])
            words.append(i_type(mn, rd, rs1, args[2], xlen=xlen))
        elif mn in I_TYPE_BEXT_SHAMT:  # bclri/bexti/binvi/bseti/rori (docs/adr/0060)
            rd, rs1 = reg(args[0]), reg(args[1])
            words.append(i_type_bext_shamt(mn, rd, rs1, args[2], xlen=xlen))
        elif mn in I_TYPE_BEXT_FIXED:  # clz/ctz/cpop/sext.b/sext.h/orc.b (docs/adr/0060)
            rd, rs1 = reg(args[0]), reg(args[1])
            words.append(i_type_bext_fixed(mn, rd, rs1))
        elif mn == "rev8":
            rd, rs1 = reg(args[0]), reg(args[1])
            words.append(rev8(rd, rs1, xlen=xlen))
        elif mn == "zext.w":  # pseudo-op: add.uw rd,rs1,x0 (RV64-only, docs/adr/0060)
            rd, rs1 = reg(args[0]), reg(args[1])
            words.append(r_type_w("add.uw", rd, rs1, 0))
        elif mn in R_TYPE_W:
            rd, rs1, rs2 = reg(args[0]), reg(args[1]), reg(args[2])
            words.append(r_type_w(mn, rd, rs1, rs2))
        elif mn in I_TYPE_W:
            rd, rs1 = reg(args[0]), reg(args[1])
            words.append(i_type_w(mn, rd, rs1, args[2]))
        elif mn in I_TYPE_W_BEXT_FIXED:  # clzw/ctzw/cpopw (docs/adr/0060)
            rd, rs1 = reg(args[0]), reg(args[1])
            words.append(i_type_w_bext_fixed(mn, rd, rs1))
        elif mn == "roriw":
            rd, rs1 = reg(args[0]), reg(args[1])
            words.append(roriw(rd, rs1, args[2]))
        elif mn == "slli.uw":
            rd, rs1 = reg(args[0]), reg(args[1])
            words.append(slli_uw(rd, rs1, args[2]))
        elif mn in LOAD:
            rd = reg(args[0])
            m = re.match(r"(-?\w+)\((x\d+)\)", args[1])
            words.append(load(mn, rd, m.group(1), reg(m.group(2))))
        elif mn in STORE:
            rs2 = reg(args[0])
            m = re.match(r"(-?\w+)\((x\d+)\)", args[1])
            words.append(store(mn, rs2, m.group(1), reg(m.group(2))))
        elif mn in BRANCH:
            rs1, rs2 = reg(args[0]), reg(args[1])
            words.append(branch(mn, rs1, rs2, resolve(args[2], cur_addr)))
        elif mn == "jal":
            rd = reg(args[0])
            words.append(jal(rd, resolve(args[1], cur_addr)))
        elif mn == "jalr":
            rd = reg(args[0])
            m = re.match(r"(-?\w+)\((x\d+)\)", args[1])
            words.append(jalr(rd, m.group(1), reg(m.group(2))))
        elif mn == "lui":
            rd = reg(args[0])
            words.append(u_type(OP_LUI, rd, args[1]))
        elif mn == "auipc":
            rd = reg(args[0])
            words.append(u_type(OP_AUIPC, rd, args[1]))
        elif mn in ("csrrw", "csrrs", "csrrc"):
            rd, csr, rs1 = reg(args[0]), args[1], reg(args[2])
            words.append(csr_reg(mn, rd, csr, rs1))
        elif mn in ("csrrwi", "csrrsi", "csrrci"):
            rd, csr, uimm = reg(args[0]), args[1], args[2]
            words.append(csr_imm(mn, rd, csr, uimm))
        elif mn in ("ecall", "ebreak", "mret", "sret"):
            words.append(system_noarg(mn))
        elif mn == "sfence.vma":
            rs1 = reg(args[0]) if len(args) > 0 else 0
            rs2 = reg(args[1]) if len(args) > 1 else 0
            words.append(sfence_vma(rs1, rs2))
        elif mn == "fence":
            words.append(fence())
        elif mn == "word":
            # Raw 32-bit word, for encodings this assembler has no mnemonic
            # for -- e.g. an opcode this core doesn't implement, to exercise
            # the illegal-instruction trap (docs/adr/0011-csr-and-exceptions.md).
            words.append(u(int(args[0], 0), 32))

        # docs/adr/0019-f-extension.md (Phase C9): RV32F mnemonics.
        elif mn == "flw":
            rd = freg(args[0])
            m = re.match(r"(-?\w+)\((x\d+)\)", args[1])
            words.append(flw(rd, m.group(1), reg(m.group(2))))
        elif mn == "fsw":
            rs2 = freg(args[0])
            m = re.match(r"(-?\w+)\((x\d+)\)", args[1])
            words.append(fsw(rs2, m.group(1), reg(m.group(2))))
        elif mn in FP_ARITH:
            rd, rs1, rs2 = freg(args[0]), freg(args[1]), freg(args[2])
            rm = parse_rm(args, 3)
            words.append(fp_r_type(FP_ARITH[mn], rd, rs1, rs2, rm))
        elif mn == "fsqrt.s":
            rd, rs1 = freg(args[0]), freg(args[1])
            rm = parse_rm(args, 2)
            words.append(fp_sqrt(rd, rs1, rm))
        elif mn in FP_SGNJ:
            rd, rs1, rs2 = freg(args[0]), freg(args[1]), freg(args[2])
            words.append(fp_sgnj(mn, rd, rs1, rs2))
        elif mn in FP_MINMAX:
            rd, rs1, rs2 = freg(args[0]), freg(args[1]), freg(args[2])
            words.append(fp_minmax(mn, rd, rs1, rs2))
        elif mn in FP_CMP:
            rd, rs1, rs2 = reg(args[0]), freg(args[1]), freg(args[2])  # writes the INTEGER file
            words.append(fp_cmp(mn, rd, rs1, rs2))
        elif mn in ("fcvt.w.s", "fcvt.wu.s"):
            rd, rs1 = reg(args[0]), freg(args[1])  # writes the INTEGER file
            rm = parse_rm(args, 2)
            words.append(fp_cvt_w_s(mn == "fcvt.wu.s", rd, rs1, rm))
        elif mn in ("fcvt.s.w", "fcvt.s.wu"):
            rd, rs1 = freg(args[0]), reg(args[1])  # reads the INTEGER file
            rm = parse_rm(args, 2)
            words.append(fp_cvt_s_w(mn == "fcvt.s.wu", rd, rs1, rm))
        elif mn == "fmv.x.w":
            rd, rs1 = reg(args[0]), freg(args[1])
            words.append(fp_mv_x_w(rd, rs1))
        elif mn == "fclass.s":
            rd, rs1 = reg(args[0]), freg(args[1])
            words.append(fp_class(rd, rs1))
        elif mn == "fmv.w.x":
            rd, rs1 = freg(args[0]), reg(args[1])
            words.append(fp_mv_w_x(rd, rs1))
        elif mn in MADD_OPCODES:
            rd, rs1, rs2, rs3 = freg(args[0]), freg(args[1]), freg(args[2]), freg(args[3])
            rm = parse_rm(args, 4)
            words.append(fp_r4_type(MADD_OPCODES[mn], rd, rs1, rs2, rs3, rm))
        elif mn == "aes64ks1i":  # Pillar K (docs/adr/0059 Gen7-K7) -- rnum is a plain immediate, not a register
            rd, rs1 = reg(args[0]), reg(args[1])
            words.append(aes64ks1i(rd, rs1, args[2]))
        elif mn == ".word":
            # Raw 32-bit instruction word, bypassing mnemonic parsing entirely --
            # Pillar K's own OoO integration test (Gen7-K7) uses this for K-extension
            # mnemonics asm.py doesn't parse yet, same "encode by hand, verified
            # against riscv-opcodes" discipline this project already applies before
            # writing RTL decode logic. Generic, reusable for any future raw-encoding
            # need (ponytail: one small directive beats a duplicated mnemonic table).
            words.append(int(args[0], 0) & 0xFFFFFFFF)

        else:
            raise ValueError(f"unknown mnemonic {mn!r} in line: {line!r}")
    return words


def write_mem(words, path, size_bytes=128):
    # docs/adr/0037-rvc-compressed-instructions-phase-u.md: plain little-
    # endian byte order (word's own low byte at the low array offset) --
    # matches design/InstructionMemory.v's own real read order as of that
    # phase (`{insts[addr+3],...,insts[addr]}`, LSB-first), which replaced
    # the old byte-reversed convention this function used to match. See
    # that module's own header comment for why RVC forced this (no fixed
    # per-4-byte-aligned swap can stay correct once a compressed
    # instruction shifts later instructions off the 4-byte grid).
    data = bytearray(size_bytes)
    for i, w in enumerate(words):
        off = i * 4
        if off + 4 > size_bytes:
            raise ValueError(f"program exceeds {size_bytes}-byte instruction memory")
        data[off + 0] = w & 0xFF
        data[off + 1] = (w >> 8) & 0xFF
        data[off + 2] = (w >> 16) & 0xFF
        data[off + 3] = (w >> 24) & 0xFF
    with open(path, "w") as f:
        for b in data:
            f.write(f"{b:08b}\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("source")
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--size", type=int, default=128)
    ap.add_argument("--xlen", type=int, default=32,
                     help="Generation 2: 64 widens slli/srli/srai's shamt to 6 bits (docs/adr/0028)")
    args = ap.parse_args()

    with open(args.source) as f:
        lines = f.readlines()
    try:
        words = assemble(lines, xlen=args.xlen)
    except ValueError as e:
        print(f"asm error: {e}", file=sys.stderr)
        sys.exit(1)
    write_mem(words, args.output, args.size)
    print(f"{args.source}: {len(words)} instructions -> {args.output}")


if __name__ == "__main__":
    main()
