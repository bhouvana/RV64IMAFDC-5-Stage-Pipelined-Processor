`default_nettype none

`include "riscv_defs.vh"

// Single-cycle execute unit: ALU arithmetic/logic ops, RV32M single-cycle
// multiply (mul/mulh/mulhsu/mulhu -- div/rem are NOT handled here, see
// Divider.v's dedicated multi-cycle unit), and branch-condition evaluation
// (`branch_zero`, which feeds `zero` and from there the fetch-stage
// redirect mux).
module ALU #(
    parameter XLEN = 32   // docs/adr/0015-xlen-and-regcount-parameterization.md
)(
    input [6:0] ALUCtl,
    input [XLEN-1:0] A,B,
    input wordOp,  // Generation 2 (Phase M, docs/adr/0028-rv64-migration-
                    // phase-m.md): RV64I's "w"-suffixed family (addw/subw/
                    // sllw/srlw/sraw/mulw, and addiw/slliw/srliw/sraiw via
                    // the same ADD/SLL/SRL/SRA arms) -- compute on the low
                    // 32 bits of A/B, sign-extend the 32-bit result to XLEN.
                    // Ignored by every other ALUCtl value (branches, SLT,
                    // XOR, OR, AND, MULH*, DIV/REM family, CTZ). At XLEN=32
                    // this input is always tied 0 (Control.v XLEN-gates the
                    // opcodes that would ever assert it), so it changes
                    // nothing there even though the logic below has no
                    // explicit XLEN guard -- truncate-to-32-then-sign-
                    // extend-to-32 is already a no-op at XLEN=32.
    output reg [XLEN-1:0] ALUOut,
    output reg zero,
    output reg branch_zero
);

// Register-register shift amounts (sll/srl/sra) use only the low
// $clog2(XLEN) bits of B, per spec -- see the SLL case below. The "w"-suffixed
// family's shift amount is always exactly 5 bits regardless of XLEN (spec-
// mandated, since it only ever shifts a 32-bit value) -- see wordOp above.
localparam SHAMT_WIDTH = $clog2(XLEN);

integer i;
integer count;
integer done;

// Generation 2 (Phase M) wordOp scratch: the 32-bit result before its
// sign-extension to XLEN, shared by the ADD/SUB/SLL/SRL/SRA/MUL arms below.
reg [31:0] w32;

// RV32M scratch (docs/adr/0006-rv32m.md). Widened to 2*XLEN bits *before*
// multiplying (not after) so the product is computed at full precision
// regardless of how a given tool self-determines `*`'s result width.
reg signed [2*XLEN-1:0] mul_ss;  // signed x signed  (mul, mulh)
reg signed [2*XLEN-1:0] mul_su;  // signed x unsigned (mulhsu)
reg        [2*XLEN-1:0] mul_uu;  // unsigned x unsigned (mulhu)

// Pillar K (Gen7-K3) Zbkc/Zbkb scratch
reg [XLEN-1:0] pack_lo, pack_hi;
reg [15:0] packw_lo, packw_hi;
reg [31:0] packw_res;
// Pillar K (Gen7-K4) SHA scratch
reg [31:0] sha32;
reg [63:0] sha64;
// Pillar K (Gen7-K5) xperm scratch
reg [3:0] xperm_idx4;
reg [7:0] xperm_idx8;
// Pillar K (Gen7-K6) AES scratch
reg [31:0] aes_tmp1, aes_tmp2, aes_tmp3, aes_rc, aes_w0, aes_w1;
reg [63:0] aes_sr, aes_sb;

always@(*)
begin
    ALUOut = 0;
    branch_zero =0;
case(ALUCtl)
    `ALUCTL_ADD:
    if (wordOp) begin
        w32 = A[31:0] + B[31:0];
        ALUOut = {{(XLEN-32){w32[31]}}, w32};  // addiw/addw
    end else
        ALUOut = A + B;//simply adding
    `ALUCTL_SUB:
    if (wordOp) begin
        w32 = A[31:0] - B[31:0];
        ALUOut = {{(XLEN-32){w32[31]}}, w32};  // subw
    end else
        ALUOut = A - B;//just subtracting
    `ALUCTL_SLL:
    // Per spec, register-register shifts only use the low $clog2(XLEN) bits
    // of rs2 as the shift amount -- rs2 holds a full XLEN-bit value, and B
    // here is that whole register for R-type sll/srl/sra (I-type
    // slli/srli/srai are unaffected: ImmGen.v already encodes their shamt as
    // a 5-bit zero-extended immediate, so B is already <=31 by construction
    // on that path). Without
    // masking, `A << B`/`A >> B` treat B as the *literal* shift count, and
    // Verilog shifts by >=32 discard every bit -- e.g. `sll rd,rs1,rs2` with
    // rs2 holding any value >=32 (utterly ordinary, rs2 is just a register)
    // silently produced 0 instead of a real shift. Found by constrained-
    // random testing (docs/ROADMAP.md V-4) hitting `srl x5,x25,x25`, not by
    // any directed test -- every hand-written shift test happened to use a
    // shift-amount register already holding a small value.
    if (wordOp) begin
        // slliw/sllw: shift amount always exactly 5 bits (B[4:0]), not
        // SHAMT_WIDTH-1:0 -- this arm only ever shifts a 32-bit value.
        w32 = A[31:0] << B[4:0];
        ALUOut = {{(XLEN-32){w32[31]}}, w32};
    end else
    ALUOut = (A << B[SHAMT_WIDTH-1:0]);//logical shift left
    `ALUCTL_SLT:
    // A/B are plain (unsigned) ports -- $signed() is required here, the same
    // way it is for SRA below, or this "signed" comparison would silently
    // run unsigned (e.g. slt with A=-1 would wrongly read as A > any
    // positive B). See docs/adr/0004-signed-arithmetic-casts.md.
    ALUOut = ($signed(A) < $signed(B)) ? 1 :0;//set less than
    `ALUCTL_SLTU:
    ALUOut = ($unsigned(A) < $unsigned(B)) ? 1 : 0;//set less than unsigned
    `ALUCTL_XOR:
    ALUOut = A ^ B;//xor
    `ALUCTL_SRL:
    if (wordOp) begin  // srliw/srlw -- shift amount always B[4:0], see SLL's wordOp comment
        w32 = A[31:0] >> B[4:0];
        ALUOut = {{(XLEN-32){w32[31]}}, w32};
    end else
    ALUOut = (A >> B[SHAMT_WIDTH-1:0]);//shift right logical -- see SLL's comment on the shift-amount width
    `ALUCTL_SRA:
    // See docs/adr/0004-signed-arithmetic-casts.md -- >>> only sign-extends
    // when the operand's *type* is signed, which A/B are not by default.
    // See SLL's comment above on the shift-amount width.
    if (wordOp) begin  // sraiw/sraw -- shift amount always B[4:0]
        w32 = $signed(A[31:0]) >>> B[4:0];
        ALUOut = {{(XLEN-32){w32[31]}}, w32};
    end else
    ALUOut = ($signed(A) >>> B[SHAMT_WIDTH-1:0]);//shift right arithmetic
    `ALUCTL_OR:
    ALUOut = ( A | B ) ;//OR
    `ALUCTL_AND:
    ALUOut = ( A & B );//AND
    `ALUCTL_BEQ:
        begin
            branch_zero = ( A == B ) ? 1 : 0;
            ALUOut = A & B;// beq
        end
    `ALUCTL_BNE:
        begin
            branch_zero = ( A != B ) ? 1 : 0;
            ALUOut = A & B;//bne
        end
    `ALUCTL_BLT:
        begin
            branch_zero = ( $signed(A) < $signed(B) ) ? 1 : 0;
            ALUOut = A & B;//blt (signed, per RV32I)
        end
    `ALUCTL_BGE:
        begin
            branch_zero = ( $signed(A) >= $signed(B) ) ? 1 : 0;
            ALUOut = A & B;//bge (signed, per RV32I)
        end
    `ALUCTL_BLE:
        begin
            branch_zero = ( $signed(A) <= $signed(B) ) ? 1 : 0;
            ALUOut = A & B;//ble (custom; signed, consistent with blt/bge)
        end
    `ALUCTL_BGT:
        begin
            branch_zero = ( $signed(A) > $signed(B) ) ? 1 : 0;
            ALUOut = A & B;//bgt (custom; signed, consistent with blt/bge)
        end
    `ALUCTL_BLTU:
        begin
            branch_zero = ( $unsigned(A) < $unsigned(B) ) ? 1 : 0;
            ALUOut = A & B;//bltu
        end
    `ALUCTL_BGEU:
        begin
            branch_zero = ( $unsigned(A) >= $unsigned(B) ) ? 1 : 0;
            ALUOut = A & B;//bgeu
        end
    `ALUCTL_CTZ:
        begin

            // ponytail fix (was `i<XLEN-1`, a real off-by-one that only
            // diverges from true ctz for A==0 exactly: any input with a set
            // bit already reaches the correct count by the time the loop
            // would have examined bit XLEN-1, so this only ever mattered
            // for the all-zero case, where the correct answer is XLEN, not
            // XLEN-1). See docs/adr/0041's own findings section.
            //
            // docs/adr/0060 (Gen7-B10 random-test finding): this case had
            // NO wordOp branch at all until now -- harmless while ctz was
            // reachable only via the retired custom opcode (no W-suffixed
            // sibling ever existed), but ctzw (docs/adr/0060) shares this
            // same ALUCTL code with wordOp=1 and needs the 32-bit-only
            // count, not the full XLEN count. Found by the constrained-
            // random harness (ctzw x18,x6 with x6==0 gave 64, not the
            // correct 32) -- mirrors CLZ's own wordOp split below.
            count = 0;
            done = 0;
            if (wordOp) begin
                for (i = 0; i < 32; i = i + 1)
                begin
                    if (A[i] == 0 && done == 0)
                        count = count + 1;
                    else
                    done = 1;
                end
            end else begin
                for (i = 0; i < XLEN; i = i + 1)
                begin
                    if (A[i] == 0 && done == 0)
                        count = count + 1;
                    else
                    done = 1;
                end
            end
            ALUOut = count;

        end

    // ---- B extension: Zba+Zbb+Zbs (docs/adr/0060) ----
    `ALUCTL_ANDN: ALUOut = A & ~B;
    `ALUCTL_ORN:  ALUOut = A | ~B;
    `ALUCTL_XNOR: ALUOut = ~(A ^ B);
    `ALUCTL_MIN:  ALUOut = ($signed(A) < $signed(B)) ? A : B;
    `ALUCTL_MINU: ALUOut = ($unsigned(A) < $unsigned(B)) ? A : B;
    `ALUCTL_MAX:  ALUOut = ($signed(A) > $signed(B)) ? A : B;
    `ALUCTL_MAXU: ALUOut = ($unsigned(A) > $unsigned(B)) ? A : B;
    `ALUCTL_ROL:
    if (wordOp) begin
        w32 = (B[4:0] == 0) ? A[31:0] : (A[31:0] << B[4:0]) | (A[31:0] >> (32 - B[4:0]));
        ALUOut = {{(XLEN-32){w32[31]}}, w32};  // rolw -- shamt always 5 bits
    end else
        ALUOut = (B[SHAMT_WIDTH-1:0] == 0) ? A :
                  (A << B[SHAMT_WIDTH-1:0]) | (A >> (XLEN - B[SHAMT_WIDTH-1:0]));
    `ALUCTL_ROR:
    if (wordOp) begin
        w32 = (B[4:0] == 0) ? A[31:0] : (A[31:0] >> B[4:0]) | (A[31:0] << (32 - B[4:0]));
        ALUOut = {{(XLEN-32){w32[31]}}, w32};  // rorw/roriw
    end else
        ALUOut = (B[SHAMT_WIDTH-1:0] == 0) ? A :
                  (A >> B[SHAMT_WIDTH-1:0]) | (A << (XLEN - B[SHAMT_WIDTH-1:0]));
    `ALUCTL_CLZ:
        begin
            count = 0;
            done = 0;
            if (wordOp) begin  // clzw: count from bit 31 downward, 32 is the all-zero answer
                for (i = 31; i >= 0; i = i - 1)
                    if (A[i] == 0 && done == 0) count = count + 1;
                    else done = 1;
            end else begin
                for (i = XLEN-1; i >= 0; i = i - 1)
                    if (A[i] == 0 && done == 0) count = count + 1;
                    else done = 1;
            end
            ALUOut = count;
        end
    `ALUCTL_CPOP:
        begin
            count = 0;
            if (wordOp) begin
                for (i = 0; i < 32; i = i + 1) count = count + A[i];
            end else begin
                for (i = 0; i < XLEN; i = i + 1) count = count + A[i];
            end
            ALUOut = count;
        end
    `ALUCTL_SEXTB: ALUOut = {{(XLEN-8){A[7]}}, A[7:0]};
    `ALUCTL_SEXTH: ALUOut = {{(XLEN-16){A[15]}}, A[15:0]};
    `ALUCTL_ORCB:
        begin
            for (i = 0; i < XLEN/8; i = i + 1)
                ALUOut[i*8 +: 8] = (A[i*8 +: 8] != 8'h00) ? 8'hFF : 8'h00;
        end
    `ALUCTL_REV8:
        begin
            for (i = 0; i < XLEN/8; i = i + 1)
                ALUOut[i*8 +: 8] = A[(XLEN/8-1-i)*8 +: 8];
        end
    `ALUCTL_BCLR: ALUOut = A & ~({{(XLEN-1){1'b0}},1'b1} << B[SHAMT_WIDTH-1:0]);
    `ALUCTL_BEXT: ALUOut = (A >> B[SHAMT_WIDTH-1:0]) & {{(XLEN-1){1'b0}},1'b1};
    `ALUCTL_BINV: ALUOut = A ^ ({{(XLEN-1){1'b0}},1'b1} << B[SHAMT_WIDTH-1:0]);
    `ALUCTL_BSET: ALUOut = A | ({{(XLEN-1){1'b0}},1'b1} << B[SHAMT_WIDTH-1:0]);
    // sh1add.uw/sh2add.uw/sh3add.uw share these SAME ALUCtl codes with
    // sh1add/sh2add/sh3add (ALUCtrl.v deliberately has no separate arm for
    // them -- see its own comment) -- wordOp supplies the zero-extend-A
    // behavior, exactly like addw already reuses ALUCTL_ADD (docs/adr/0060,
    // Gen7-B10 random-test finding: the dedicated _UW codes this used to
    // have collided with the plain forms and were unreachable).
    `ALUCTL_SH1ADD: ALUOut = wordOp ? (({{(XLEN-32){1'b0}}, A[31:0]} << 1) + B) : ((A << 1) + B);
    `ALUCTL_SH2ADD: ALUOut = wordOp ? (({{(XLEN-32){1'b0}}, A[31:0]} << 2) + B) : ((A << 2) + B);
    `ALUCTL_SH3ADD: ALUOut = wordOp ? (({{(XLEN-32){1'b0}}, A[31:0]} << 3) + B) : ((A << 3) + B);
    `ALUCTL_ADD_UW: ALUOut = {{(XLEN-32){1'b0}}, A[31:0]} + B;
    `ALUCTL_SLLI_UW:
        begin
            w32 = A[31:0] << B[4:0];
            ALUOut = {{(XLEN-32){1'b0}}, w32};  // zero-extended, NOT sign-extended -- distinct from ordinary wordOp shifts
        end

    // RV32M multiply -- single-cycle is a reasonable simplification for
    // multiply (real FPGA/ASIC flows commonly do support single- or
    // few-cycle pipelined multipliers). Division is NOT single-cycle-
    // friendly in real hardware and is handled by the dedicated multi-cycle
    // Divider.v unit + pipeline interlock in riscvpipeline.v instead --
    // ALUCtl never actually reaches this case block for div/rem (see
    // riscvpipeline.v's isDivRem), so there is deliberately no
    // `ALUCTL_DIV`/`ALUCTL_DIVU`/`ALUCTL_REM`/`ALUCTL_REMU` case here. See
    // docs/adr/0009-multicycle-divider.md.
    `ALUCTL_MUL:
        if (wordOp) begin  // mulw: low 32 bits of the 32x32 product, sign-extended
            w32 = A[31:0] * B[31:0];
            ALUOut = {{(XLEN-32){w32[31]}}, w32};
        end else
        ALUOut = A * B;  // low 32 bits of the true product -- correct
                          // regardless of signedness, so no cast needed
    `ALUCTL_MULH:
        begin
            mul_ss = $signed({{XLEN{A[XLEN-1]}}, A}) * $signed({{XLEN{B[XLEN-1]}}, B});
            ALUOut = mul_ss[2*XLEN-1:XLEN];
        end
    `ALUCTL_MULHSU:
        begin
            mul_su = $signed({{XLEN{A[XLEN-1]}}, A}) * $signed({{XLEN{1'b0}}, B});
            ALUOut = mul_su[2*XLEN-1:XLEN];
        end
    `ALUCTL_MULHU:
        begin
            mul_uu = {{XLEN{1'b0}}, A} * {{XLEN{1'b0}}, B};
            ALUOut = mul_uu[2*XLEN-1:XLEN];
        end

    // ---- Zbkc (docs/adr/0059 Pillar K) ----
    // Carry-less multiply: XOR-accumulate shifted copies of A selected by
    // B's set bits. Each term is truncated to XLEN bits by Verilog's own
    // shift-into-a-fixed-width-reg semantics before the XOR, which is
    // bit-exact with "compute the full untruncated product, then take the
    // low/high XLEN bits" since XOR is bitwise and truncation only drops
    // bits >= XLEN.
    `ALUCTL_CLMUL:
        begin
            ALUOut = 0;
            for (i = 0; i < XLEN; i = i + 1)
                if (B[i]) ALUOut = ALUOut ^ (A << i);
        end
    `ALUCTL_CLMULH:
        begin
            ALUOut = 0;
            for (i = 1; i < XLEN; i = i + 1)
                if (B[i]) ALUOut = ALUOut ^ (A >> (XLEN - i));
        end

    // ---- Zbkb (docs/adr/0059 Pillar K) ----
    `ALUCTL_PACK:
        if (wordOp) begin  // packw: low 16 bits of each register -> 32-bit result, sign-extended
            packw_lo = A[15:0];
            packw_hi = B[15:0];
            packw_res = {packw_hi, packw_lo};
            ALUOut = {{(XLEN-32){packw_res[31]}}, packw_res};
        end else begin      // pack: low XLEN/2 bits of each register -> XLEN-bit result, zero-extended
            pack_lo = {{(XLEN/2){1'b0}}, A[XLEN/2-1:0]};
            pack_hi = {{(XLEN/2){1'b0}}, B[XLEN/2-1:0]};
            ALUOut = (pack_hi << (XLEN/2)) | pack_lo;
        end
    `ALUCTL_PACKH:
        ALUOut = {{(XLEN-16){1'b0}}, B[7:0], A[7:0]};
    `ALUCTL_BREV8:
        begin
            for (i = 0; i < XLEN/8; i = i + 1)
                ALUOut[i*8 +: 8] = {A[i*8+0], A[i*8+1], A[i*8+2], A[i*8+3],
                                     A[i*8+4], A[i*8+5], A[i*8+6], A[i*8+7]};
        end

    // ---- Zknh (docs/adr/0059 Pillar K) ---- fixed-rotate XOR functions,
    // A only (B unused, same unary shape as CLZ). SHA-256 forms operate on
    // A[31:0] and sign-extend the 32-bit result to XLEN; SHA-512 forms
    // operate on the full 64-bit A directly. `{x[n-1:0],x[31:n]}` is this
    // file's existing ror32-by-n idiom (see ALUCTL_ROR), spelled as a
    // rotate-concatenation since n is a compile-time constant here.
    `ALUCTL_SHA256SUM0:
        begin
            sha32 = A[31:0];
            sha32 = {sha32[1:0],sha32[31:2]} ^ {sha32[12:0],sha32[31:13]} ^ {sha32[21:0],sha32[31:22]};
            ALUOut = {{(XLEN-32){sha32[31]}}, sha32};
        end
    `ALUCTL_SHA256SUM1:
        begin
            sha32 = A[31:0];
            sha32 = {sha32[5:0],sha32[31:6]} ^ {sha32[10:0],sha32[31:11]} ^ {sha32[24:0],sha32[31:25]};
            ALUOut = {{(XLEN-32){sha32[31]}}, sha32};
        end
    `ALUCTL_SHA256SIG0:
        begin
            sha32 = A[31:0];
            sha32 = {sha32[6:0],sha32[31:7]} ^ {sha32[17:0],sha32[31:18]} ^ (sha32 >> 3);
            ALUOut = {{(XLEN-32){sha32[31]}}, sha32};
        end
    `ALUCTL_SHA256SIG1:
        begin
            sha32 = A[31:0];
            sha32 = {sha32[16:0],sha32[31:17]} ^ {sha32[18:0],sha32[31:19]} ^ (sha32 >> 10);
            ALUOut = {{(XLEN-32){sha32[31]}}, sha32};
        end
    `ALUCTL_SHA512SUM0:
        begin
            sha64 = A;
            ALUOut = {sha64[27:0],sha64[63:28]} ^ {sha64[33:0],sha64[63:34]} ^ {sha64[38:0],sha64[63:39]};
        end
    `ALUCTL_SHA512SUM1:
        begin
            sha64 = A;
            ALUOut = {sha64[13:0],sha64[63:14]} ^ {sha64[17:0],sha64[63:18]} ^ {sha64[40:0],sha64[63:41]};
        end
    `ALUCTL_SHA512SIG0:
        begin
            sha64 = A;
            ALUOut = {sha64[0:0],sha64[63:1]} ^ {sha64[7:0],sha64[63:8]} ^ (sha64 >> 7);
        end
    `ALUCTL_SHA512SIG1:
        begin
            sha64 = A;
            ALUOut = {sha64[18:0],sha64[63:19]} ^ {sha64[60:0],sha64[63:61]} ^ (sha64 >> 6);
        end

endcase
            zero = branch_zero;
end

    // ALU has two operands, executes a different operation based on ALUCtl.
    // `zero` (really "branch condition true") feeds the fetch-stage redirect mux.

endmodule

`default_nettype wire
