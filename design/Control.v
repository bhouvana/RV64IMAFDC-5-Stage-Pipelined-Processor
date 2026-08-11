`default_nettype none

`include "riscv_defs.vh"

// Main decoder: opcode (+funct3/funct7 pass-through, +the CSR/SYSTEM
// funct12 field) -> every control signal the rest of the pipeline
// conditions on. One `case` arm per opcode; an opcode with no arm here
// falls to `default`, asserting illegalOpcode -- a real trap
// (docs/adr/0011), not a silent no-op.
module Control #(
    parameter XLEN = 32   // Generation 2 (Phase M, docs/adr/0028-rv64-
                            // migration-phase-m.md): gates OPCODE_OP_32/
                            // OPCODE_OP_IMM_32 -- without this, an RV32
                            // build (XLEN=32) would silently start
                            // executing these previously-reserved opcodes
                            // as ordinary add/sub/shift instead of trapping
                            // illegal-instruction, a real behavior change.
)(
    input [6:0] opcode,
    //
    input [6:0] funt7,   // full funct7 field (inst[31:25]) -- was 1 bit (inst[30]
                          // only), just enough to tell add from sub. RV32M needs
                          // funct7=0000001 distinguished from add/sub's 0/0100000,
                          // which the single-bit version couldn't represent.
    input [2:0] funt3,
    input [11:0] csr_imm12,  // inst[31:20]: a CSR address for real csrrX ops,
                              // or the funct12 that distinguishes ecall/ebreak/mret
                              // when opcode=SYSTEM and funt3=000 (docs/adr/0011)
    //
    output reg branch,
    output reg memRead,
    output reg memtoReg,
    output reg [1:0] ALUOp,
    output reg memWrite,
    output reg ALUSrc,
    output reg regWrite,
    output reg [2:0] funct3,
    output reg [6:0] funct7,
    output reg jump,   // unconditional control transfer (jal/jalr); target computed in EX, link = PC+4
    output reg jalr,   // target = rs1+imm (vs. jal's PC+imm) -- see riscvpipeline.v's target-address mux
    output reg lui,    // ALU A operand forced to 0 (result = imm)
    output reg auipc,  // ALU A operand forced to PC (result = PC+imm)
    output reg isCsr,      // genuine csrrw/csrrs/csrrc(+i variants) -- rd gets the CSR's old value
    output reg isEcall,
    output reg isEbreak,
    output reg isMret,
    // docs/adr/00NN-mmu-sv32.md (Phase F2). No live behavior yet -- these
    // just decode correctly; riscvpipeline.v doesn't consume either until
    // F3 (isSret, folded into the redirect mux alongside isMret) and F5
    // (isSfenceVma, flushing Tlb.v).
    output reg isSret,
    output reg isSfenceVma,
    // docs/adr/0023-caches.md (Phase G1). No live behavior yet -- decodes
    // correctly, riscvpipeline.v doesn't consume it until G6 (real
    // cache-flush semantics).
    output reg isFence,
    // docs/adr/0038-a-extension-phase-v.md. lr/sc/amo* (opcode 0101111) --
    // riscvpipeline.v's own new 2-phase MEM-stage interlock owns the real
    // memRead/memWrite bus behavior for these (see its own comment); this
    // just flags "this is one of them" so that logic knows to take over
    // instead of the ordinary single-phase load/store path. regWrite is
    // still asserted normally here (every lr/sc/amo* writes rd).
    output reg isAmo,
    output reg illegalOpcode, // opcode itself unrecognized -- see riscvpipeline.v for the
                               // other exception source (ALUCtl==ILLEGAL, a recognized
                               // opcode with an unrecognized funct7/funct3)
    // docs/adr/0019-f-extension.md (Phase C6). `regWrite` keeps its
    // existing meaning (write Register.v, the integer file) unchanged --
    // `fRegWrite` is the parallel signal for writing FRegister.v instead,
    // since several float ops (feq.s/flt.s/fle.s/fclass.s/fcvt.w.s/
    // fcvt.wu.s/fmv.x.w) write an *integer* destination despite reading
    // float operands, and are the reason this can't just be "regWrite
    // means whichever file this op happens to target."
    output reg fRegWrite
    );

always@(*)begin

    branch    = 0;
    memRead   = 0;
    memtoReg  = 0;
    ALUOp     = `ALUOP_LOAD_STORE;
    memWrite  = 0;
    ALUSrc    = 0;
    regWrite  = 0;
    jump      = 0;
    jalr      = 0;
    lui       = 0;
    auipc     = 0;
    isCsr     = 0;
    isEcall   = 0;
    isEbreak  = 0;
    isMret    = 0;
    isSret    = 0;
    isSfenceVma = 0;
    isFence   = 0;
    isAmo     = 0;
    illegalOpcode = 0;
    fRegWrite = 0;


case(opcode)
    `OPCODE_LOAD:
    begin//load inst

        memRead =1;
        memtoReg =1;
        ALUSrc =1;
        regWrite =1;

    end
    `OPCODE_STORE://store inst
    begin
        memWrite =1;
        ALUSrc =1;

    end

    `OPCODE_AMO:  // docs/adr/0038-a-extension-phase-v.md: lr/sc/amo* --
                   // address = rs1 (ALUSrc=1, ImmGen.v returns imm=0 for
                   // this opcode, same "ALU always adds" ALUOP_LOAD_STORE
                   // shape load/store already use). memRead/memWrite
                   // deliberately NOT asserted here -- riscvpipeline.v's
                   // own isAmo_regem-gated interlock drives the real bus
                   // signals across this instruction's two real phases.
    begin
        ALUSrc = 1;
        regWrite = 1;
        isAmo = 1;
    end

    `OPCODE_I://immediate inst
    begin
        ALUOp =`ALUOP_ITYPE;
        ALUSrc =1;
        regWrite =1;

    end

    `OPCODE_R://add and sub R type inst
    begin
        ALUOp =`ALUOP_RTYPE;
        regWrite =1;

    end

    // Generation 2 (Phase M). OP-32/OP-IMM-32 reuse OP/OP-IMM's own
    // funct7/funct3 encodings byte-for-byte (see ALUCtrl.v) -- riscvpipeline.v
    // tells ALU.v to truncate-and-sign-extend via a separately-decoded
    // `wordOp` signal, not a new ALUOp/ALUCtl code. XLEN-gated: at XLEN=32
    // these are previously-reserved, unallocated opcodes and must keep
    // trapping illegal-instruction, not silently start executing.
    `OPCODE_OP_32:
    begin
        if (XLEN >= 64) begin
            ALUOp = `ALUOP_RTYPE;
            regWrite = 1;
        end else begin
            illegalOpcode = 1;
        end
    end

    `OPCODE_OP_IMM_32:
    begin
        if (XLEN >= 64) begin
            ALUOp = `ALUOP_ITYPE;
            ALUSrc = 1;
            regWrite = 1;
        end else begin
            illegalOpcode = 1;
        end
    end

    `OPCODE_BRANCH:
    begin
        branch =1;
        ALUOp =`ALUOP_BRANCH;

    end

    `OPCODE_JAL://jump and link (jal): target = PC+imm, link = PC+4
    begin
        ALUSrc =0;   // ALU result is unused for jal (target/link computed on dedicated adders)
        regWrite =1;
        jump = 1;

    end

    `OPCODE_JALR://jump and link register (jalr): target = rs1+imm, link = PC+4
    begin
        ALUSrc =0;
        regWrite =1;
        jump = 1;
        jalr = 1;

    end

    `OPCODE_LUI://load upper immediate (lui): rd = imm (ALU computes 0+imm)
    begin
        ALUOp = `ALUOP_LOAD_STORE;  // ALUCtl=ADD
        ALUSrc =1;
        regWrite =1;
        lui = 1;

    end

    `OPCODE_AUIPC://add upper immediate to pc (auipc): rd = PC+imm (ALU computes PC+imm)
    begin
        ALUOp = `ALUOP_LOAD_STORE;  // ALUCtl=ADD
        ALUSrc =1;
        regWrite =1;
        auipc = 1;

    end

    `OPCODE_SYSTEM:
    begin
        if (funt3 == `CSR_F3_NONE)
        begin
            // docs/adr/00NN-mmu-sv32.md (Phase F2). sfence.vma is checked
            // FIRST and separately, by funt7 alone (inst[31:25]) -- unlike
            // ecall/ebreak/mret/sret, it has real rs1 (address)/rs2 (ASID)
            // register fields (inst[24:20]/[19:15] respectively), so its
            // full inst[31:20] "csr_imm12" position is NOT a single fixed
            // value the way the case statement below assumes -- it varies
            // with whatever rs2 register the instruction happens to name.
            // (This phase always flushes the whole TLB regardless of
            // rs1/rs2's actual values -- see the phase plan's own scoping
            // default -- so decoding only needs to recognize the
            // instruction, not read those two fields for their real
            // address/ASID meaning.)
            if (funt7 == `FUNCT7_SFENCE_VMA)
                isSfenceVma = 1;
            else begin
                // Not a csrrX read/write at all -- inst[31:20] (csr_imm12
                // here) picks which of the four funct3=000, non-sfence.vma
                // instructions this is. Anything else in this position is a
                // reserved/unallocated SYSTEM encoding -- illegalOpcode
                // below, same exception riscvpipeline.v raises for any
                // other unrecognized instruction.
                case (csr_imm12)
                    `CSR_IMM12_ECALL:  isEcall  = 1;
                    `CSR_IMM12_EBREAK: isEbreak = 1;
                    `CSR_IMM12_MRET:   isMret   = 1;
                    `CSR_IMM12_SRET:   isSret   = 1;
                    default: illegalOpcode = 1;  // SYSTEM/funct3=0 but not ecall/ebreak/mret/sret/sfence.vma
                endcase
            end
        end
        else
        begin
            isCsr = 1;
            regWrite = 1;  // rd <- CSR's old value (see riscvpipeline.v's ex_result override)
        end
    end

    // docs/adr/0019-f-extension.md (Phase C6). funt7 (inst[31:25]) already
    // carries OP-FP's funct5 (inst[31:27]) in its top 5 bits regardless --
    // no new Control.v input needed to sub-decode it. rs1IsFloat/
    // rs2IsFloat/rdIsFloat aren't Control.v outputs at all: riscvpipeline.v
    // derives them directly from opcode/funt7 the same way this case
    // statement does here, since they're needed in more places (ID-stage
    // register-read routing, not just here) than a single new port each
    // would conveniently thread through.
    `OPCODE_FP:
    begin
        case (funt7[6:2])
            `FUNCT5_FCMP, `FUNCT5_FCVT_W_S, `FUNCT5_FMV_X_W_FCLASS:
                regWrite = 1;   // reads float operand(s), writes an INTEGER dest
            default:
                fRegWrite = 1;  // fadd.s/fsub.s/fmul.s/fdiv.s/fsqrt.s/fsgnj*/fmin/fmax/fcvt.s.w*/fmv.w.x
        endcase
    end

    `OPCODE_LOAD_FP:  // flw: same shape as OPCODE_LOAD, but the loaded value goes to FRegister.v
    begin
        memRead  = 1;
        memtoReg = 1;
        ALUSrc   = 1;
        fRegWrite = 1;
    end

    `OPCODE_STORE_FP:  // fsw: same shape as OPCODE_STORE (rs1 is still the INTEGER address base)
    begin
        memWrite = 1;
        ALUSrc   = 1;
    end

    `OPCODE_MADD, `OPCODE_MSUB, `OPCODE_NMSUB, `OPCODE_NMADD:  // fmadd.s/fmsub.s/fnmsub.s/fnmadd.s
    begin
        fRegWrite = 1;
    end

    // docs/adr/0023-caches.md (Phase G1). Only funct3=000 (the real `fence`
    // encoding) is recognized; every other MISC-MEM funct3 (e.g. fence.i,
    // Zifencei, unimplemented) falls to illegalOpcode below, same as any
    // other unrecognized encoding.
    `OPCODE_MISC_MEM:
    begin
        if (funt3 == 3'b000)
            isFence = 1;
        else
            illegalOpcode = 1;
    end

    default:
    begin

    branch    = 0;
    memRead   = 0;
    memtoReg  = 0;
    ALUOp     = `ALUOP_LOAD_STORE;
    memWrite  = 0;
    ALUSrc    = 0;
    regWrite  = 0;
    jump      = 0;
    jalr      = 0;
    lui       = 0;
    auipc     = 0;
    illegalOpcode = 1;

    end
endcase

 funct3 = funt3;
 funct7 = funt7;


end
endmodule

`default_nettype wire
