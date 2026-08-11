#!/usr/bin/env python3
"""
Shared disassembler for this core's exact ISA (RV32I + RV32M + the B
extension, docs/adr/0060, + its specific deviations -- ble/bgt custom
branches, CSR/ecall/ebreak/mret). ctz used to be a custom op; it now
disassembles via its real Zbb encoding (docs/adr/0060).
Single source of truth for turning a raw instruction word into a mnemonic
string, used by sim/tools/gen_trace.py (pipeline viewer) and
sim/tools/debugger.py (interactive ISS debugger, docs/ROADMAP.md Phase 8) --
previously gen_trace.py had its own copy that never learned RV32M or
CSR/SYSTEM encodings (an R-type instruction with funct7=0000001 only
differs from add/sub in the bit gen_trace.py's old disasm() didn't check,
so `mul x3,x1,x2` silently disassembled as `add x3,x1,x2` in the pipeline
viewer -- fixed here by checking the full 7-bit funct7 like design/ALUCtrl.v
does, not just bit 30).

Mirrors design/riscv_defs.vh's opcode/funct7 constants and design/ALUCtrl.v's
decode table -- kept as a second, independent reading of the encoding (like
sim/tools/iss.py) rather than importing anything RTL-side.
"""

OPCODE_R = 0b0110011
OPCODE_I = 0b0010011
OPCODE_LOAD = 0b0000011
OPCODE_STORE = 0b0100011
OPCODE_BRANCH = 0b1100011
OPCODE_JAL = 0b1101111
OPCODE_JALR = 0b1100111
OPCODE_LUI = 0b0110111
OPCODE_AUIPC = 0b0010111
OPCODE_CUSTOM = 0b0001011  # reserved (real RISC-V custom-0 space) -- unused since docs/adr/0060 moved ctz to its real Zbb encoding
OPCODE_SYSTEM = 0b1110011

# Generation 2 (Phase M, docs/adr/0028-rv64-migration-phase-m.md).
OPCODE_OP_32 = 0b0111011
OPCODE_OP_IMM_32 = 0b0011011

# docs/adr/0019-f-extension.md (Phase C9).
OPCODE_FP = 0b1010011
OPCODE_LOAD_FP = 0b0000111
OPCODE_STORE_FP = 0b0100111
OPCODE_MADD, OPCODE_MSUB, OPCODE_NMSUB, OPCODE_NMADD = 0b1000011, 0b1000111, 0b1001011, 0b1001111
MADD_NAMES = {OPCODE_MADD: "fmadd.s", OPCODE_MSUB: "fmsub.s", OPCODE_NMSUB: "fnmsub.s", OPCODE_NMADD: "fnmadd.s"}

FUNCT5_FADD, FUNCT5_FSUB, FUNCT5_FMUL, FUNCT5_FDIV = 0b00000, 0b00001, 0b00010, 0b00011
FUNCT5_FSQRT = 0b01011
FUNCT5_FSGNJ = 0b00100
FUNCT5_FMINMAX = 0b00101
FUNCT5_FCMP = 0b10100
FUNCT5_FCVT_W_S = 0b11000
FUNCT5_FCVT_S_W = 0b11010
FUNCT5_FMV_X_W_FCLASS = 0b11100
FUNCT5_FMV_W_X = 0b11110

RM_NAMES = {0b000: "rne", 0b001: "rtz", 0b010: "rdn", 0b011: "rup", 0b100: "rmm", 0b111: "dyn"}

FUNCT7_BASE = 0b0000000
FUNCT7_ALT = 0b0100000
FUNCT7_MULDIV = 0b0000001

CSR_NAMES = {0x300: "mstatus", 0x305: "mtvec", 0x340: "mscratch", 0x341: "mepc", 0x342: "mcause",
             0x001: "fflags", 0x002: "frm", 0x003: "fcsr"}


def rm_name(rm):
    return RM_NAMES.get(rm, f"rm?{rm}")


def sext(v, bits):
    v &= (1 << bits) - 1
    if v & (1 << (bits - 1)):
        v -= (1 << bits)
    return v


def csr_name(addr):
    return CSR_NAMES.get(addr, f"0x{addr:03x}")


def disasm(word, xlen=32):
    """word: raw 32-bit instruction as an int. Returns a mnemonic string.

    xlen (Generation 2, docs/adr/0028-rv64-migration-phase-m.md): only
    affects the plain (non-"w") slli/srli/srai shamt width -- 5 bits at 32
    (default, bit-exact with every prior call site), 6 at 64. The "w"-
    suffixed family's own shamt is always exactly 5 bits regardless, so it
    doesn't consult this parameter at all.
    """
    if word == 0x00000013:
        return "nop"
    if word == 0:
        return "—"  # only ever the reset/bubble value now (docs/adr/0014) -- a real
                     # program never actually contains a zero word (traps if fetched)

    op = word & 0x7F
    rd = (word >> 7) & 0x1F
    f3 = (word >> 12) & 0x7
    rs1 = (word >> 15) & 0x1F
    rs2 = (word >> 20) & 0x1F
    f7 = (word >> 25) & 0x7F
    imm_i = sext(word >> 20, 12)

    if op == OPCODE_R:
        if f7 == FUNCT7_MULDIV:
            names = {0: "mul", 1: "mulh", 2: "mulhsu", 3: "mulhu",
                      4: "div", 5: "divu", 6: "rem", 7: "remu"}
            return f"{names[f3]} x{rd},x{rs1},x{rs2}"
        # B extension (docs/adr/0060) -- FUNCT7_ALT+111/110/100 are real
        # andn/orn/xnor, not the retired custom ctz.
        bext_names = {(FUNCT7_ALT, 0b111): "andn", (FUNCT7_ALT, 0b110): "orn", (FUNCT7_ALT, 0b100): "xnor",
                      (0b0000101, 0b100): "min", (0b0000101, 0b101): "minu", (0b0000101, 0b110): "max", (0b0000101, 0b111): "maxu",
                      (0b0110000, 0b001): "rol", (0b0110000, 0b101): "ror",
                      (0b0010000, 0b010): "sh1add", (0b0010000, 0b100): "sh2add", (0b0010000, 0b110): "sh3add",
                      (0b0100100, 0b001): "bclr", (0b0100100, 0b101): "bext", (0b0110100, 0b001): "binv", (0b0010100, 0b001): "bset",
                      # Pillar K (docs/adr/0059 Gen7-K7)
                      (0b0000101, 0b001): "clmul", (0b0000101, 0b011): "clmulh",
                      (0b0000100, 0b100): "pack", (0b0000100, 0b111): "packh",
                      (0b0010100, 0b010): "xperm4", (0b0010100, 0b100): "xperm8",
                      (0b0011011, 0b000): "aes64esm", (0b0011001, 0b000): "aes64es",
                      (0b0011111, 0b000): "aes64dsm", (0b0011101, 0b000): "aes64ds",
                      (0b0111111, 0b000): "aes64ks2"}
        if (f7, f3) in bext_names:
            return f"{bext_names[(f7, f3)]} x{rd},x{rs1},x{rs2}"
        names = {(FUNCT7_BASE, 0): "add", (FUNCT7_ALT, 0): "sub", (FUNCT7_BASE, 1): "sll",
                  (FUNCT7_BASE, 2): "slt", (FUNCT7_BASE, 3): "sltu", (FUNCT7_BASE, 4): "xor",
                  (FUNCT7_BASE, 5): "srl", (FUNCT7_ALT, 5): "sra", (FUNCT7_BASE, 6): "or",
                  (FUNCT7_BASE, 7): "and"}
        mn = names.get((f7, f3), f"r-type?(f7={f7:#04x},f3={f3})")
        return f"{mn} x{rd},x{rs1},x{rs2}"

    if op == OPCODE_I:
        imm12 = (word >> 20) & 0xFFF
        f6 = (word >> 26) & 0x3F  # funct7[6:1] -- real for every XLEN, see riscv_defs.vh's FUNCT6_ALT comment
        # B extension (docs/adr/0060).
        if f3 == 1 and f6 == 0b010010:
            return f"bclri x{rd},x{rs1},{imm12 & 0x3F}"
        if f3 == 5 and f6 == 0b010010:
            return f"bexti x{rd},x{rs1},{imm12 & 0x3F}"
        if f3 == 1 and f6 == 0b011010:
            return f"binvi x{rd},x{rs1},{imm12 & 0x3F}"
        if f3 == 1 and f6 == 0b001010:
            return f"bseti x{rd},x{rs1},{imm12 & 0x3F}"
        if f3 == 1 and f6 == 0b011000:
            sub = imm12 & 0x1F
            sub_names = {0: "clz", 1: "ctz", 2: "cpop", 4: "sext.b", 5: "sext.h"}
            if sub in sub_names:
                return f"{sub_names[sub]} x{rd},x{rs1}"
        if f3 == 5 and f6 == 0b011000:
            return f"rori x{rd},x{rs1},{imm12 & 0x3F}"
        if f3 == 5 and imm12 == 0x287:
            return f"orc.b x{rd},x{rs1}"
        if f3 == 5 and imm12 in (0x698, 0x6B8):
            return f"rev8 x{rd},x{rs1}"
        # Pillar K (docs/adr/0059 Gen7-K7)
        if f3 == 5 and imm12 == 0x687:
            return f"brev8 x{rd},x{rs1}"
        if f3 == 1 and imm12 in (0x100, 0x101, 0x102, 0x103, 0x104, 0x105, 0x106, 0x107):
            names_sha = {0x100: "sha256sum0", 0x101: "sha256sum1", 0x102: "sha256sig0", 0x103: "sha256sig1",
                         0x104: "sha512sum0", 0x105: "sha512sum1", 0x106: "sha512sig0", 0x107: "sha512sig1"}
            return f"{names_sha[imm12]} x{rd},x{rs1}"
        if f3 == 1 and f6 == 0b001100:  # aes64im (rs2_c==0) / aes64ks1i (rs2_c[4]=1)
            rs2_c = (word >> 20) & 0x1F
            if rs2_c == 0:
                return f"aes64im x{rd},x{rs1}"
            return f"aes64ks1i x{rd},x{rs1},{rs2_c & 0xF}"
        if f3 in (1, 5):
            # Generation 2: 6-bit shamt (inst[25:20]) + 6-bit funct6
            # (inst[31:26]) at xlen>=64, matching design/ImmGen.v/
            # design/ALUCtrl.v's own split -- 5-bit shamt/7-bit funct7 at
            # the default xlen=32 (bit-exact with every prior call site).
            if xlen >= 64:
                shamt = (word >> 20) & 0x3F
                mn = {1: "slli", 5: ("srai" if f6 == 0b010000 else "srli")}[f3]
            else:
                shamt = (word >> 20) & 0x1F
                mn = {1: "slli", 5: ("srai" if f7 == FUNCT7_ALT else "srli")}[f3]
            return f"{mn} x{rd},x{rs1},{shamt}"
        names = {0: "addi", 2: "slti", 3: "sltiu", 4: "xori", 6: "ori", 7: "andi"}
        return f"{names.get(f3, 'i-type?')} x{rd},x{rs1},{imm_i}"

    if op == OPCODE_OP_32:
        # Generation 2. Reuses OP's own funct7/funct3 encodings byte-for-byte.
        if f7 == FUNCT7_MULDIV:
            names = {0: "mulw", 4: "divw", 5: "divuw", 6: "remw", 7: "remuw"}
            return f"{names.get(f3, 'op32muldiv?')} x{rd},x{rs1},x{rs2}"
        # B extension, RV64-only word variants (docs/adr/0060).
        w_bext = {(0b0110000, 0b001): "rolw", (0b0110000, 0b101): "rorw",
                  (0b0000100, 0b000): "add.uw",
                  (0b0010000, 0b010): "sh1add.uw", (0b0010000, 0b100): "sh2add.uw", (0b0010000, 0b110): "sh3add.uw",
                  (0b0000100, 0b100): "packw"}  # Pillar K (docs/adr/0059 Gen7-K7)
        if (f7, f3) in w_bext:
            return f"{w_bext[(f7, f3)]} x{rd},x{rs1},x{rs2}"
        names = {(FUNCT7_BASE, 0): "addw", (FUNCT7_ALT, 0): "subw", (FUNCT7_BASE, 1): "sllw",
                  (FUNCT7_BASE, 5): "srlw", (FUNCT7_ALT, 5): "sraw"}
        mn = names.get((f7, f3), f"op32?(f7={f7:#04x},f3={f3})")
        return f"{mn} x{rd},x{rs1},x{rs2}"

    if op == OPCODE_OP_IMM_32:
        # Generation 2. shamt always exactly 5 bits, unlike OPCODE_I's
        # xlen-dependent split above (this opcode only ever means a 32-bit
        # result, regardless of xlen).
        imm12 = (word >> 20) & 0xFFF
        f6 = (word >> 26) & 0x3F
        # B extension, RV64-only word variants (docs/adr/0060).
        if f3 == 1 and f7 == 0b0110000:
            sub = imm12 & 0x1F
            sub_names = {0: "clzw", 1: "ctzw", 2: "cpopw"}
            if sub in sub_names:
                return f"{sub_names[sub]} x{rd},x{rs1}"
        if f3 == 5 and f7 == 0b0110000:
            return f"roriw x{rd},x{rs1},{imm12 & 0x1F}"
        if f3 == 1 and f6 == 0b000010:
            return f"slli.uw x{rd},x{rs1},{imm12 & 0x3F}"
        if f3 in (1, 5):
            shamt = (word >> 20) & 0x1F
            mn = {1: "slliw", 5: ("sraiw" if f7 == FUNCT7_ALT else "srliw")}[f3]
            return f"{mn} x{rd},x{rs1},{shamt}"
        names = {0: "addiw"}
        return f"{names.get(f3, 'opimm32?')} x{rd},x{rs1},{imm_i}"

    if op == OPCODE_LOAD:
        names = {0: "lb", 1: "lh", 2: "lw", 3: "ld", 4: "lbu", 5: "lhu", 6: "lwu"}
        return f"{names.get(f3, 'load?')} x{rd},{imm_i}(x{rs1})"

    if op == OPCODE_STORE:
        imm_s = sext(((word >> 25) << 5) | ((word >> 7) & 0x1F), 12)
        names = {0: "sb", 1: "sh", 2: "sw", 3: "sd"}
        return f"{names.get(f3, 'store?')} x{rs2},{imm_s}(x{rs1})"

    if op == OPCODE_BRANCH:
        b12 = (word >> 31) & 1
        b11 = (word >> 7) & 1
        b10_5 = (word >> 25) & 0x3F
        b4_1 = (word >> 8) & 0xF
        off = sext((b12 << 12) | (b11 << 11) | (b10_5 << 5) | (b4_1 << 1), 13)
        names = {0: "beq", 1: "bne", 2: "ble", 3: "bgt", 4: "blt", 5: "bge", 6: "bltu", 7: "bgeu"}
        return f"{names.get(f3, 'branch?')} x{rs1},x{rs2},{off:+d}"

    if op == OPCODE_JAL:
        b20 = (word >> 31) & 1
        b19_12 = (word >> 12) & 0xFF
        b11 = (word >> 20) & 1
        b10_1 = (word >> 21) & 0x3FF
        off = sext((b20 << 20) | (b19_12 << 12) | (b11 << 11) | (b10_1 << 1), 21)
        return f"jal x{rd},{off:+d}"

    if op == OPCODE_JALR:
        return f"jalr x{rd},{imm_i}(x{rs1})"

    if op == OPCODE_LUI:
        return f"lui x{rd},0x{(word >> 12) & 0xFFFFF:x}"

    if op == OPCODE_AUIPC:
        return f"auipc x{rd},0x{(word >> 12) & 0xFFFFF:x}"

    if op == OPCODE_SYSTEM:
        csr_addr = (word >> 20) & 0xFFF
        if f3 == 0:
            return {0x000: "ecall", 0x001: "ebreak", 0x302: "mret"}.get(csr_addr, f"system?(imm12={csr_addr:#x})")
        names = {0b001: "csrrw", 0b010: "csrrs", 0b011: "csrrc",
                  0b101: "csrrwi", 0b110: "csrrsi", 0b111: "csrrci"}
        mn = names.get(f3, "csr?")
        if f3 & 0b100:  # *i variants: rs1's field position is a 5-bit zero-extended uimm
            return f"{mn} x{rd},{csr_name(csr_addr)},{rs1}"
        return f"{mn} x{rd},{csr_name(csr_addr)},x{rs1}"

    if op == OPCODE_LOAD_FP:
        return f"flw f{rd},{imm_i}(x{rs1})"

    if op == OPCODE_STORE_FP:
        imm_s = sext(((word >> 25) << 5) | ((word >> 7) & 0x1F), 12)
        return f"fsw f{rs2},{imm_s}(x{rs1})"

    if op in MADD_NAMES:
        rs3 = (word >> 27) & 0x1F
        return f"{MADD_NAMES[op]} f{rd},f{rs1},f{rs2},f{rs3},{rm_name(f3)}"

    if op == OPCODE_FP:
        funct5 = (word >> 27) & 0x1F
        if funct5 in (FUNCT5_FADD, FUNCT5_FSUB, FUNCT5_FMUL, FUNCT5_FDIV):
            mn = {FUNCT5_FADD: "fadd.s", FUNCT5_FSUB: "fsub.s",
                  FUNCT5_FMUL: "fmul.s", FUNCT5_FDIV: "fdiv.s"}[funct5]
            return f"{mn} f{rd},f{rs1},f{rs2},{rm_name(f3)}"
        if funct5 == FUNCT5_FSQRT:
            return f"fsqrt.s f{rd},f{rs1},{rm_name(f3)}"
        if funct5 == FUNCT5_FSGNJ:
            mn = {0b000: "fsgnj.s", 0b001: "fsgnjn.s", 0b010: "fsgnjx.s"}.get(f3, "fsgnj?")
            return f"{mn} f{rd},f{rs1},f{rs2}"
        if funct5 == FUNCT5_FMINMAX:
            mn = {0b000: "fmin.s", 0b001: "fmax.s"}.get(f3, "fminmax?")
            return f"{mn} f{rd},f{rs1},f{rs2}"
        if funct5 == FUNCT5_FCMP:
            mn = {0b000: "fle.s", 0b001: "flt.s", 0b010: "feq.s"}.get(f3, "fcmp?")
            return f"{mn} x{rd},f{rs1},f{rs2}"
        if funct5 == FUNCT5_FCVT_W_S:
            mn = "fcvt.wu.s" if rs2 == 0b00001 else "fcvt.w.s"
            return f"{mn} x{rd},f{rs1},{rm_name(f3)}"
        if funct5 == FUNCT5_FCVT_S_W:
            mn = "fcvt.s.wu" if rs2 == 0b00001 else "fcvt.s.w"
            return f"{mn} f{rd},x{rs1},{rm_name(f3)}"
        if funct5 == FUNCT5_FMV_X_W_FCLASS:
            return f"fclass.s x{rd},f{rs1}" if f3 == 0b001 else f"fmv.x.w x{rd},f{rs1}"
        if funct5 == FUNCT5_FMV_W_X:
            return f"fmv.w.x f{rd},x{rs1}"
        return f"op-fp?(funct5={funct5:#07b})"

    return f"0x{word:08x}?"
