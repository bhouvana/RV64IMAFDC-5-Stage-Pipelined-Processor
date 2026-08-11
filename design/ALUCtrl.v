`default_nettype none

`include "riscv_defs.vh"

// Second-level ALU decoder: turns Control.v's coarse ALUOp (which
// instruction class this is: load/store, R-type, I-type, or branch) plus
// the instruction's own funct3/funct7 fields into the specific ALUCtl code
// ALU.v's case statement switches on.
//
// docs/adr/0060 (Gen7-B1): gained `rs2_c` (inst[24:20]) -- most B-ext I-type
// ops discriminate via funct6 (funct7[6:1]) same as the pre-existing SRL/SRA
// split, but clz/ctz/cpop/sext.b/sext.h share ONE funct6+funct3 combination
// and differ only in this rs2-like field, the same "rs2 field doubles as a
// sub-op selector" idiom riscvpipeline.v:1579 already uses for F-extension's
// fcvt.w.s/fcvt.wu.s.
module ALUCtrl (
    input [1:0] ALUOp,

    input [6:0] funct7_c,  // full funct7 field (inst[31:25]) -- widened from a
                            // single bit (inst[30]) to make room for RV32M's
                            // funct7=0000001, see docs/adr/0006-rv32m.md
    input [2:0] funct3_c,
    input [4:0] rs2_c,     // inst[24:20] -- shamt on shift-immediate ops,
                            // sub-op selector on the clz/ctz/cpop/sext family
    output reg [6:0] ALUCtl
);
wire [2:0] funct3 = funct3_c;
wire [6:0] funct7 = funct7_c;
wire [5:0] funct6 = funct7_c[6:1];
wire [4:0] concat2;

assign concat2 = {ALUOp,funct3};
always@(*)
begin
if(ALUOp == `ALUOP_LOAD_STORE)
    begin
        ALUCtl = `ALUCTL_ADD;
    end
else if(ALUOp == `ALUOP_RTYPE)
    begin
    case({funct7, funct3})
        {`FUNCT7_BASE, 3'b000}: ALUCtl = `ALUCTL_ADD;
        {`FUNCT7_ALT,  3'b000}: ALUCtl = `ALUCTL_SUB;
        {`FUNCT7_BASE, 3'b001}: ALUCtl = `ALUCTL_SLL;
        {`FUNCT7_BASE, 3'b010}: ALUCtl = `ALUCTL_SLT;
        {`FUNCT7_BASE, 3'b011}: ALUCtl = `ALUCTL_SLTU;
        {`FUNCT7_BASE, 3'b100}: ALUCtl = `ALUCTL_XOR;
        {`FUNCT7_BASE, 3'b101}: ALUCtl = `ALUCTL_SRL;
        {`FUNCT7_ALT,  3'b101}: ALUCtl = `ALUCTL_SRA;
        {`FUNCT7_BASE, 3'b110}: ALUCtl = `ALUCTL_OR;
        {`FUNCT7_BASE, 3'b111}: ALUCtl = `ALUCTL_AND;
        // RV32M (docs/adr/0006-rv32m.md)
        {`FUNCT7_MULDIV, 3'b000}: ALUCtl = `ALUCTL_MUL;
        {`FUNCT7_MULDIV, 3'b001}: ALUCtl = `ALUCTL_MULH;
        {`FUNCT7_MULDIV, 3'b010}: ALUCtl = `ALUCTL_MULHSU;
        {`FUNCT7_MULDIV, 3'b011}: ALUCtl = `ALUCTL_MULHU;
        {`FUNCT7_MULDIV, 3'b100}: ALUCtl = `ALUCTL_DIV;
        {`FUNCT7_MULDIV, 3'b101}: ALUCtl = `ALUCTL_DIVU;
        {`FUNCT7_MULDIV, 3'b110}: ALUCtl = `ALUCTL_REM;
        {`FUNCT7_MULDIV, 3'b111}: ALUCtl = `ALUCTL_REMU;
        // B extension (docs/adr/0060) -- FUNCT7_ALT+111 is now real `andn`,
        // not the retired custom ctz (see docs/adr/0060's own findings).
        {`FUNCT7_ALT, 3'b111}: ALUCtl = `ALUCTL_ANDN;
        {`FUNCT7_ALT, 3'b110}: ALUCtl = `ALUCTL_ORN;
        {`FUNCT7_ALT, 3'b100}: ALUCtl = `ALUCTL_XNOR;
        {`FUNCT7_ZBB_MINMAX, 3'b100}: ALUCtl = `ALUCTL_MIN;
        {`FUNCT7_ZBB_MINMAX, 3'b101}: ALUCtl = `ALUCTL_MINU;
        {`FUNCT7_ZBB_MINMAX, 3'b110}: ALUCtl = `ALUCTL_MAX;
        {`FUNCT7_ZBB_MINMAX, 3'b111}: ALUCtl = `ALUCTL_MAXU;
        {`FUNCT7_ZBB_ROTATE, 3'b001}: ALUCtl = `ALUCTL_ROL;
        {`FUNCT7_ZBB_ROTATE, 3'b101}: ALUCtl = `ALUCTL_ROR;
        {`FUNCT7_ZBA_SHADD, 3'b010}: ALUCtl = `ALUCTL_SH1ADD;
        {`FUNCT7_ZBA_SHADD, 3'b100}: ALUCtl = `ALUCTL_SH2ADD;
        {`FUNCT7_ZBA_SHADD, 3'b110}: ALUCtl = `ALUCTL_SH3ADD;
        {`FUNCT7_ZBS_BCLR_BEXT, 3'b001}: ALUCtl = `ALUCTL_BCLR;
        {`FUNCT7_ZBS_BCLR_BEXT, 3'b101}: ALUCtl = `ALUCTL_BEXT;
        {`FUNCT7_ZBS_BINV, 3'b001}: ALUCtl = `ALUCTL_BINV;
        {`FUNCT7_ZBS_BSET, 3'b001}: ALUCtl = `ALUCTL_BSET;
        // docs/adr/0060 (Gen7-B10 random-test finding): add.uw's funct7 is
        // genuinely unique (no collision with anything above -- this arm
        // was simply missing, causing a real illegal-instruction trap for
        // every add.uw). sh1add.uw/sh2add.uw/sh3add.uw deliberately have NO
        // arm here: their funct7/funct3 are bit-identical to sh1add/sh2add/
        // sh3add by REAL SPEC DESIGN (opcode alone disambiguates OP-32 from
        // OP, same as addw/add always shared ALUCTL_ADD) -- ALUCtrl has no
        // opcode visibility to split them, so they deliberately fall through
        // to the SAME ALUCTL_SH1ADD/SH2ADD/SH3ADD codes as their register-
        // width siblings, and ALU.v's own wordOp check (not a separate
        // ALUCtl code) supplies the zero-extend-A behavior, mirroring how
        // addw already reuses ALUCTL_ADD via wordOp.
        {`FUNCT7_ZBA_ADD_UW, 3'b000}: ALUCtl = `ALUCTL_ADD_UW;

        // Pillar K (docs/adr/0059 Gen7-K3/K5). Zbkc clmul/clmulh share
        // FUNCT7_ZBB_MINMAX's own still-free funct3 000/001/010/011 slots
        // (min/minu/max/maxu already use 100/101/110/111).
        {`FUNCT7_ZBB_MINMAX, 3'b001}: ALUCtl = `ALUCTL_CLMUL;
        {`FUNCT7_ZBB_MINMAX, 3'b011}: ALUCtl = `ALUCTL_CLMULH;
        // Zbkb pack/packh (packw shares ALUCTL_PACK via wordOp, decoded
        // identically here since ALUCtrl has no opcode visibility -- same
        // precedent as sh1add.uw sharing ALUCTL_SH1ADD above).
        {`FUNCT7_ZBKB_PACK, 3'b100}: ALUCtl = `ALUCTL_PACK;
        {`FUNCT7_ZBKB_PACK, 3'b111}: ALUCtl = `ALUCTL_PACKH;
        // Zbkx xperm4/xperm8 -- share FUNCT7_ZBS_BSET's own bit pattern with
        // a different, currently-unused funct3 (BSET itself is funct3=001).
        {`FUNCT7_ZBKX_XPERM, 3'b010}: ALUCtl = `ALUCTL_XPERM4;
        {`FUNCT7_ZBKX_XPERM, 3'b100}: ALUCtl = `ALUCTL_XPERM8;
        // Zkne+Zknd AES round/key-schedule ops (docs/adr/0059 Gen7-K6) -- all
        // funct3=000, distinguished purely by funct7.
        {`FUNCT7_ZKNE_AES64ESM, 3'b000}: ALUCtl = `ALUCTL_AES64ESM;
        {`FUNCT7_ZKNE_AES64ES,  3'b000}: ALUCtl = `ALUCTL_AES64ES;
        {`FUNCT7_ZKND_AES64DSM, 3'b000}: ALUCtl = `ALUCTL_AES64DSM;
        {`FUNCT7_ZKND_AES64DS,  3'b000}: ALUCtl = `ALUCTL_AES64DS;
        {`FUNCT7_ZKN_AES64KS2,  3'b000}: ALUCtl = `ALUCTL_AES64KS2;

        default:
        ALUCtl = `ALUCTL_ILLEGAL;  // unrecognized funct7/funct3 combination for this ALUOp
    endcase
    end


else if(ALUOp == `ALUOP_BRANCH)
    begin
    // Generation 3 prerequisite (Phase N, docs/adr/0030-branch-encoding-fix.md): blt/bge
    // moved to their real RISC-V spec funct3 positions (100/101); this core's own custom
    // ble/bgt moved to the now-vacant reserved positions (010/011). A real GCC-compiled
    // program's blt/bge previously misdecoded as this core's custom ble/bgt.
    case(concat2)
        5'b01000: //beq
        ALUCtl = `ALUCTL_BEQ;
        5'b01001: //bne
        ALUCtl = `ALUCTL_BNE;
        5'b01010: //ble (custom, moved here from 100)
        ALUCtl = `ALUCTL_BLE;
        5'b01011: //bgt (custom, moved here from 101)
        ALUCtl = `ALUCTL_BGT;
        5'b01100: //blt (real spec position, moved here from 010)
        ALUCtl = `ALUCTL_BLT;
        5'b01101: //bge (real spec position, moved here from 011)
        ALUCtl = `ALUCTL_BGE;
        5'b01110: //bltu
        ALUCtl = `ALUCTL_BLTU;
        5'b01111: //bgeu
        ALUCtl = `ALUCTL_BGEU;
        default:
        ALUCtl = `ALUCTL_ILLEGAL;  // unrecognized funct7/funct3 combination for this ALUOp
    endcase
    end
else if(ALUOp == `ALUOP_ITYPE)
    begin
    case(concat2)
        5'b11000: // add imm
        ALUCtl = `ALUCTL_ADD;
        5'b11001://shift left logical imm, OR B-ext bclri/binvi/bseti/clz-family (funct6-discriminated)
        begin
            if (funct6 == `FUNCT6_ZBS_BCLRI_BEXTI)
                ALUCtl = `ALUCTL_BCLR;   // bclri shares ALUCTL_BCLR with register-form bclr -- B operand already carries the shamt value via ImmGen either way
            else if (funct6 == `FUNCT6_ZBS_BINVI)
                ALUCtl = `ALUCTL_BINV;
            else if (funct6 == `FUNCT6_ZBS_BSETI)
                ALUCtl = `ALUCTL_BSET;
            else if (funct6 == `FUNCT6_ZBB_RORI_CLZFAM)
            begin
                case (rs2_c)
                    `RS2_CLZ:   ALUCtl = `ALUCTL_CLZ;
                    `RS2_CTZ:   ALUCtl = `ALUCTL_CTZ;
                    `RS2_CPOP:  ALUCtl = `ALUCTL_CPOP;
                    `RS2_SEXTB: ALUCtl = `ALUCTL_SEXTB;
                    `RS2_SEXTH: ALUCtl = `ALUCTL_SEXTH;
                    default:    ALUCtl = `ALUCTL_ILLEGAL;
                endcase
            end
            else if (funct6 == `FUNCT6_ZBA_SLLIUW)
                // docs/adr/0060 (Gen7-B10 random-test finding): this arm was
                // simply missing -- slli.uw's funct6 is unique (no collision),
                // it just needed decoding at all instead of falling to plain
                // SLL below.
                ALUCtl = `ALUCTL_SLLI_UW;
            else if (funct6 == `FUNCT6_ZKNE_AES64)
            begin
                // Pillar K (docs/adr/0059 Gen7-K6). aes64im's rs2_c is fixed
                // all-zero by spec; aes64ks1i's rs2_c[4] is always 1 (the
                // real encoding's fixed bit24=1) for every legal rnum 0-10.
                // KNOWN NARROW GAP (documented in docs/adr/0067, not fixed
                // here): these encodings are RV64-only by spec but share
                // OPCODE_I with RV32-valid ops -- unlike OPCODE_OP_32's own
                // clean Control.v XLEN gate, there is no funct6-level XLEN
                // trap here, so an XLEN=32 build would decode+execute these
                // (with truncated/meaningless results) instead of trapping
                // illegal. This project's actual Pillar K target is XLEN=64
                // throughout (matches Pillar V's own RV64 focus); random_gen.py
                // only emits these mnemonics on the --xlen 64 axis (Task 8).
                if (rs2_c == 5'b00000)
                    ALUCtl = `ALUCTL_AES64IM;
                else
                    ALUCtl = `ALUCTL_AES64KS1I;
            end
            else if (funct6 == `FUNCT6_ZKNH_SHA)
            begin
                // Pillar K (docs/adr/0059 Gen7-K4). All 8 sha256/512
                // sig0/1,sum0/1 share this one funct6 group, discriminated
                // entirely by rs2_c. sha256* (rs2_c 0-3) are real spec-valid
                // at XLEN=32 too; sha512* (rs2_c 4-7) are RV64-only -- same
                // known narrow gap as aes64ks1i/aes64im above (no XLEN trap
                // here), documented in docs/adr/0067.
                case (rs2_c)
                    `RS2_SHA256SUM0: ALUCtl = `ALUCTL_SHA256SUM0;
                    `RS2_SHA256SUM1: ALUCtl = `ALUCTL_SHA256SUM1;
                    `RS2_SHA256SIG0: ALUCtl = `ALUCTL_SHA256SIG0;
                    `RS2_SHA256SIG1: ALUCtl = `ALUCTL_SHA256SIG1;
                    `RS2_SHA512SUM0: ALUCtl = `ALUCTL_SHA512SUM0;
                    `RS2_SHA512SUM1: ALUCtl = `ALUCTL_SHA512SUM1;
                    `RS2_SHA512SIG0: ALUCtl = `ALUCTL_SHA512SIG0;
                    `RS2_SHA512SIG1: ALUCtl = `ALUCTL_SHA512SIG1;
                    default:         ALUCtl = `ALUCTL_ILLEGAL;
                endcase
            end
            else
                ALUCtl = `ALUCTL_SLL;  // ordinary slli, funct6==0
        end
        5'b11010://set less than imm
        ALUCtl = `ALUCTL_SLT;
        5'b11011://set less than unsigned imm
        ALUCtl = `ALUCTL_SLTU;
        5'b11100://xor imm
        ALUCtl = `ALUCTL_XOR;
        5'b11101://srl imm, sra imm, OR B-ext bexti/rori/orc.b/rev8 (funct6-discriminated)
        begin
            // Generation 2 (Phase M): compares only funct7[6:1], not the
            // full 7-bit funct7 == FUNCT7_ALT this used before. See
            // riscv_defs.vh's FUNCT6_ALT comment.
            if(funct6 == `FUNCT6_ALT)
                ALUCtl = `ALUCTL_SRA;
            else if (funct6 == `FUNCT6_ZBS_BCLRI_BEXTI)
                ALUCtl = `ALUCTL_BEXT;
            else if (funct6 == `FUNCT6_ZBB_RORI_CLZFAM)
                ALUCtl = `ALUCTL_ROR;   // rori shares ALUCTL_ROR with register-form ror
            else if (funct6 == `FUNCT6_ZBB_ORCB && rs2_c == 5'b00111)
                // FUNCT6_ZBB_ORCB(0x0A) is shared bit-pattern with BSETI's
                // funct6, disambiguated by funct3 already (this arm is
                // funct3=101, BSETI is funct3=001) -- orc.b's own rs2-field
                // is fixed 5'b00111 by spec, checked precisely for clarity.
                ALUCtl = `ALUCTL_ORCB;
            else if (funct6 == `FUNCT6_ZBB_REV8 && rs2_c == 5'b11000)
                ALUCtl = `ALUCTL_REV8;  // rev8's rs2-field(0x18) is fixed by spec regardless of XLEN; only ALU.v's own byte-count differs
            else if (funct6 == `FUNCT6_ZBB_REV8 && rs2_c == `RS2_BREV8)
                // brev8 shares REV8's own funct6(0x1A), rs2_c=0x07 disambiguates
                // (Pillar K, docs/adr/0059 Gen7-K3).
                ALUCtl = `ALUCTL_BREV8;
            else
                ALUCtl = `ALUCTL_SRL;
        end
        5'b11110:
        ALUCtl = `ALUCTL_OR;//OR imm
        5'b11111:
        ALUCtl = `ALUCTL_AND;//AND imm
        default:
        ALUCtl = `ALUCTL_ILLEGAL;  // unrecognized funct7/funct3 combination for this ALUOp
    endcase
    end

end
endmodule

`default_nettype wire
