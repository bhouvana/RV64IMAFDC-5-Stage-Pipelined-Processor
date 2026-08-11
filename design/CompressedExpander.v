`default_nettype none

// docs/adr/0037-rvc-compressed-instructions-phase-u.md. Combinational RVC
// (Standard "C" Extension) decompressor: expands a real 16-bit compressed
// instruction (the low half-word of whatever InstructionMemory.v's own
// byte-array fetch returned at the current PC -- that array already
// supports arbitrary byte-aligned reads, so a 2-byte-aligned-but-not-
// 4-byte-aligned fetch address just works, no new memory-side plumbing
// needed) into the bit-exact standard 32-bit RV64GC encoding for the
// equivalent instruction. Every existing downstream stage (ImmGen.v,
// Control.v, ALUCtrl.v, the register file's read/write ports) decodes the
// EXPANDED instruction exactly as if it had been fetched as a real 32-bit
// instruction -- this module is the only place that needs to know RVC
// exists at all.
//
// Register remap: compressed formats CIW/CL/CS/CA/CB restrict rd'/rs1'/rs2'
// to a 3-bit field selecting x8-x15 -- `{2'b01, field}` reconstructs the
// real 5-bit register number (adds 8) for every one of those forms.
//
// Reserved/not-yet-implemented encodings expand to 32'h0 (opcode 0000000),
// reusing this project's own existing "opcode 0000000 is a real illegal-
// instruction trap" convention (InstructionMemory.v's own out-of-bounds
// read does the same) rather than inventing a second illegal-instruction
// signal path.
module CompressedExpander (
    input  wire [15:0] c,
    output wire [31:0] exp
);

    wire [1:0] op = c[1:0];
    wire [2:0] f3 = c[15:13];

    // Register remaps (add 8 to the 3-bit compressed field).
    wire [4:0] rd_c_rs1_c = {2'b01, c[9:7]};   // CL/CS/CA source-1 / CB source, and CIW's implicit x2 aside
    wire [4:0] rs2_c      = {2'b01, c[4:2]};   // CL/CS/CA source-2, CIW dest
    wire [4:0] rd_full    = c[11:7];           // full 5-bit rd/rs1 field, quadrants 1/2's non-restricted forms

    // ---- Quadrant 0 (op=00) ----
    // C.ADDI4SPN: nzuimm[5:4]=c[12:11],[9:6]=c[10:7],[2]=c[6],[3]=c[5]
    wire [9:0] ciw_imm = {c[10:7], c[12:11], c[5], c[6], 2'b00};
    wire [31:0] exp_addi4spn = (ciw_imm == 10'b0) ? 32'h0 :  // reserved (nzuimm must be nonzero)
        {2'b0, ciw_imm, 5'h02, 3'b000, rs2_c, 7'b0010011};   // addi rs2_c, x2, ciw_imm

    // CL-form uimm for FLD/LD: uimm[5:3]=c[12:10], uimm[7:6]=c[6:5]
    wire [7:0] cl_ld_imm = {c[6:5], c[12:10], 3'b000};
    // CL-form uimm for LW: uimm[5:3]=c[12:10], uimm[2]=c[6], uimm[6]=c[5]
    wire [6:0] cl_lw_imm = {c[5], c[12:10], c[6], 2'b00};

    wire [31:0] exp_fld = {{4{cl_ld_imm[7]}}, cl_ld_imm, rd_c_rs1_c, 3'b011, rs2_c, 7'b0000111}; // fld rs2_c, imm(rd_c_rs1_c)
    wire [31:0] exp_lw  = {{5{cl_lw_imm[6]}}, cl_lw_imm, rd_c_rs1_c, 3'b010, rs2_c, 7'b0000011};  // lw
    wire [31:0] exp_ld  = {{4{cl_ld_imm[7]}}, cl_ld_imm, rd_c_rs1_c, 3'b011, rs2_c, 7'b0000011};  // ld

    wire [31:0] exp_fsd = {{4{cl_ld_imm[7]}}, cl_ld_imm[7:5], rs2_c, rd_c_rs1_c, 3'b011, cl_ld_imm[4:0], 7'b0100111}; // fsd
    wire [31:0] exp_sw  = {{5{cl_lw_imm[6]}}, cl_lw_imm[6:5], rs2_c, rd_c_rs1_c, 3'b010, cl_lw_imm[4:0], 7'b0100011}; // sw
    wire [31:0] exp_sd  = {{4{cl_ld_imm[7]}}, cl_ld_imm[7:5], rs2_c, rd_c_rs1_c, 3'b011, cl_ld_imm[4:0], 7'b0100011}; // sd

    wire [31:0] q0 =
        (f3 == 3'b000) ? exp_addi4spn :
        (f3 == 3'b001) ? exp_fld :
        (f3 == 3'b010) ? exp_lw :
        (f3 == 3'b011) ? exp_ld :
        (f3 == 3'b101) ? exp_fsd :
        (f3 == 3'b110) ? exp_sw :
        (f3 == 3'b111) ? exp_sd :
        32'h0;

    // ---- Quadrant 1 (op=01) ----
    wire [5:0] ci_imm6 = {c[12], c[6:2]};          // C.ADDI/ADDIW/LI/SLLI-style 6-bit signed field
    wire [31:0] exp_addi  = {{6{ci_imm6[5]}}, ci_imm6, rd_full, 3'b000, rd_full, 7'b0010011}; // addi rd,rd,imm (rd==0,imm==0 is real NOP)
    wire [31:0] exp_addiw = (rd_full == 5'd0) ? 32'h0 :  // reserved
        {{6{ci_imm6[5]}}, ci_imm6, rd_full, 3'b000, rd_full, 7'b0011011};
    wire [31:0] exp_li    = {{6{ci_imm6[5]}}, ci_imm6, 5'd0, 3'b000, rd_full, 7'b0010011}; // addi rd,x0,imm

    // C.ADDI16SP: nzimm[9]=c[12],[4]=c[6],[6]=c[5],[8:7]=c[4:3],[5]=c[2]
    wire [9:0] c16sp_imm = {c[12], c[4:3], c[5], c[2], c[6], 4'b0000};
    wire [31:0] exp_addi16sp = (c16sp_imm == 10'b0) ? 32'h0 :
        {{2{c16sp_imm[9]}}, c16sp_imm, 5'd2, 3'b000, 5'd2, 7'b0010011};
    // C.LUI: nzimm[17]=c[12], nzimm[16:12]=c[6:2] -- forms the standard
    // U-type's own imm[31:12] field directly (sign-extended 6-bit value
    // placed at bit position 17:12 of the result, i.e. bits 5:0 of the
    // 20-bit U-immediate field, sign-extended above that).
    wire [5:0] clui_imm6 = {c[12], c[6:2]};
    wire [31:0] exp_lui = (rd_full == 5'd0 || rd_full == 5'd2 || clui_imm6 == 6'b0) ? 32'h0 :
        {{14{clui_imm6[5]}}, clui_imm6, rd_full, 7'b0110111};
    wire [31:0] exp_q1_high = (rd_full == 5'd2) ? exp_addi16sp : exp_lui;

    // C.SRLI/SRAI/ANDI/SUB/XOR/OR/AND/SUBW/ADDW -- inst[11:10] sub-select,
    // rd'/rs1'=inst[9:7]+8.
    wire [5:0] cb_shamt = {c[12], c[6:2]};
    wire [5:0] cb_imm6  = {c[12], c[6:2]};
    wire [31:0] exp_srli = {6'b000000, cb_shamt, rd_c_rs1_c, 3'b101, rd_c_rs1_c, 7'b0010011};
    wire [31:0] exp_srai = {6'b010000, cb_shamt, rd_c_rs1_c, 3'b101, rd_c_rs1_c, 7'b0010011};
    wire [31:0] exp_andi = {{6{cb_imm6[5]}}, cb_imm6, rd_c_rs1_c, 3'b111, rd_c_rs1_c, 7'b0010011};
    wire [31:0] exp_sub  = {7'b0100000, rs2_c, rd_c_rs1_c, 3'b000, rd_c_rs1_c, 7'b0110011};
    wire [31:0] exp_xor  = {7'b0000000, rs2_c, rd_c_rs1_c, 3'b100, rd_c_rs1_c, 7'b0110011};
    wire [31:0] exp_or   = {7'b0000000, rs2_c, rd_c_rs1_c, 3'b110, rd_c_rs1_c, 7'b0110011};
    wire [31:0] exp_and  = {7'b0000000, rs2_c, rd_c_rs1_c, 3'b111, rd_c_rs1_c, 7'b0110011};
    wire [31:0] exp_subw = {7'b0100000, rs2_c, rd_c_rs1_c, 3'b000, rd_c_rs1_c, 7'b0111011};
    wire [31:0] exp_addw = {7'b0000000, rs2_c, rd_c_rs1_c, 3'b000, rd_c_rs1_c, 7'b0111011};

    wire [31:0] exp_arith =
        (c[11:10] == 2'b00) ? exp_srli :
        (c[11:10] == 2'b01) ? exp_srai :
        (c[11:10] == 2'b10) ? exp_andi :
        (c[12] == 1'b0) ? (
            (c[6:5] == 2'b00) ? exp_sub :
            (c[6:5] == 2'b01) ? exp_xor :
            (c[6:5] == 2'b10) ? exp_or  : exp_and
        ) : (
            (c[6:5] == 2'b00) ? exp_subw :
            (c[6:5] == 2'b01) ? exp_addw : 32'h0
        );

    // C.J / C.BEQZ / C.BNEZ -- real, differently-scrambled compressed
    // immediate encodings, reassembled into the standard J-type/B-type
    // immediate bit positions so ImmGen.v decodes the expanded instruction
    // completely unmodified.
    // imm[11|4|9:8|10|6|7|3:1|5] -- a real bug here (found by re-deriving
    // by hand, not yet exercised by any instruction hit so far since the
    // affected bits happened to be 0 every time): `c[10:9]` is a Verilog
    // bit-select, which yields {c[10],c[9]} in that MSB-first order --
    // correct for imm[9] (=c[9]) needing to come before imm[8] (=c[10]) in
    // the assembled sequence requires {c[9],c[10]}, the REVERSE of what a
    // plain `c[10:9]` slice gives.
    wire [10:0] cj_off = {c[12], c[8], c[9], c[10], c[6], c[7], c[2], c[11], c[5:3]}; // imm[11|4|9:8|10|6|7|3:1|5]
    wire [19:0] cj_imm20 = {{9{cj_off[10]}}, cj_off};
    wire [31:0] exp_j = {cj_imm20[19], cj_imm20[9:0], cj_imm20[10], cj_imm20[18:11], 5'd0, 7'b1101111}; // jal x0, offset

    // Real CB-format bit order: imm[8]=c12, imm[4:3]=c[11:10], imm[7:6]=c[6:5], imm[2:1]=c[4:3], imm[5]=c[2].
    // cb_off is imm[8:1] (8 bits, bit0 implicitly 0, matching cj_off's own
    // convention above) -- a real bug here (found by running: the Verilator
    // boot harness's own imm_sum debug tap showed exactly double the real
    // target offset) had this include an explicit extra trailing 1'b0
    // making it imm[8:0] (i.e. an already-real, already-doubled offset),
    // which ShiftLeftOne then doubled AGAIN downstream -- exp_beqz/exp_bnez
    // assemble a standard B-type encoding, whose own imm field is the
    // *pre-shift* value (bits[12:1] of the real offset, ShiftLeftOne
    // supplies the final <<1), so this must stay undoubled here.
    wire [7:0] cb_off = {c[12], c[6:5], c[2], c[11:10], c[4:3]};
    wire [19:0] cb_imm20 = {{12{cb_off[7]}}, cb_off};
    wire [31:0] exp_beqz = {cb_imm20[11], cb_imm20[9:4], 5'd0, rd_c_rs1_c, 3'b000, cb_imm20[3:0], cb_imm20[10], 7'b1100011};
    wire [31:0] exp_bnez = {cb_imm20[11], cb_imm20[9:4], 5'd0, rd_c_rs1_c, 3'b001, cb_imm20[3:0], cb_imm20[10], 7'b1100011};

    wire [31:0] q1 =
        (f3 == 3'b000) ? exp_addi :
        (f3 == 3'b001) ? exp_addiw :
        (f3 == 3'b010) ? exp_li :
        (f3 == 3'b011) ? exp_q1_high :
        (f3 == 3'b100) ? exp_arith :
        (f3 == 3'b101) ? exp_j :
        (f3 == 3'b110) ? exp_beqz :
        (f3 == 3'b111) ? exp_bnez :
        32'h0;

    // ---- Quadrant 2 (op=10) ----
    wire [5:0] ci_shamt = {c[12], c[6:2]};
    wire [31:0] exp_slli = (rd_full == 5'd0) ? 32'h0 :
        {6'b000000, ci_shamt, rd_full, 3'b001, rd_full, 7'b0010011};

    // CI-form stack-relative loads.
    wire [8:0] cldsp_imm = {c[4:2], c[12], c[6:5], 3'b000};  // uimm[5]=c12,[4:3]=c[6:5],[8:6]=c[4:2]
    wire [7:0] clwsp_imm = {c[3:2], c[12], c[6:4], 2'b00};   // uimm[5]=c12,[4:2]=c[6:4],[7:6]=c[3:2]
    wire [31:0] exp_fldsp = {{3{cldsp_imm[8]}}, cldsp_imm, 5'd2, 3'b011, rd_full, 7'b0000111}; // fld rd,imm(x2)
    wire [31:0] exp_lwsp  = (rd_full == 5'd0) ? 32'h0 :
        {{4{clwsp_imm[7]}}, clwsp_imm, 5'd2, 3'b010, rd_full, 7'b0000011};
    wire [31:0] exp_ldsp  = (rd_full == 5'd0) ? 32'h0 :
        {{3{cldsp_imm[8]}}, cldsp_imm, 5'd2, 3'b011, rd_full, 7'b0000011};

    // CR/CI-form register-indirect jumps + moves (funct3=100 quadrant).
    wire [4:0] cr_rs2 = c[6:2];
    wire [31:0] exp_jr    = {12'b0, rd_full, 3'b000, 5'd0, 7'b1100111};       // jalr x0, 0(rd_full)
    wire [31:0] exp_mv    = {7'b0000000, cr_rs2, 5'd0, 3'b000, rd_full, 7'b0110011}; // add rd,x0,rs2
    wire [31:0] exp_ebreak = 32'h00100073;
    wire [31:0] exp_jalr  = {12'b0, rd_full, 3'b000, 5'd1, 7'b1100111};      // jalr x1, 0(rd_full)
    wire [31:0] exp_add   = {7'b0000000, cr_rs2, rd_full, 3'b000, rd_full, 7'b0110011};

    wire [31:0] exp_q2_100 = (c[12] == 1'b0) ?
        ( (cr_rs2 == 5'd0) ? ( (rd_full == 5'd0) ? 32'h0 : exp_jr ) : exp_mv ) :
        ( (rd_full == 5'd0 && cr_rs2 == 5'd0) ? exp_ebreak :
          (cr_rs2 == 5'd0) ? exp_jalr :
          exp_add );

    // CSS-form stack-relative stores.
    wire [8:0] csdsp_imm = {c[9:7], c[12:10], 3'b000};   // uimm[5:3]=c[12:10],[8:6]=c[9:7]
    wire [7:0] cswsp_imm = {c[8:7], c[12:9], 2'b00};     // uimm[5:2]=c[12:9],[7:6]=c[8:7]
    wire [31:0] exp_fsdsp = {{3{csdsp_imm[8]}}, csdsp_imm[8:5], cr_rs2, 5'd2, 3'b011, csdsp_imm[4:0], 7'b0100111};
    wire [31:0] exp_swsp  = {{4{cswsp_imm[7]}}, cswsp_imm[7:5], cr_rs2, 5'd2, 3'b010, cswsp_imm[4:0], 7'b0100011};
    wire [31:0] exp_sdsp  = {{3{csdsp_imm[8]}}, csdsp_imm[8:5], cr_rs2, 5'd2, 3'b011, csdsp_imm[4:0], 7'b0100011};

    wire [31:0] q2 =
        (f3 == 3'b000) ? exp_slli :
        (f3 == 3'b001) ? exp_fldsp :
        (f3 == 3'b010) ? exp_lwsp :
        (f3 == 3'b011) ? exp_ldsp :
        (f3 == 3'b100) ? exp_q2_100 :
        (f3 == 3'b101) ? exp_fsdsp :
        (f3 == 3'b110) ? exp_swsp :
        (f3 == 3'b111) ? exp_sdsp :
        32'h0;

    assign exp =
        (op == 2'b00) ? q0 :
        (op == 2'b01) ? q1 :
        (op == 2'b10) ? q2 :
        32'h0;  // op==11 is never a compressed instruction -- caller must not select this path then

endmodule

`default_nettype wire
