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
    input wire [6:0] ALUCtl,
    input wire [XLEN-1:0] A,B,
    input wire wordOp,  // Generation 2 (Phase M, docs/adr/0028-rv64-migration-
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
// Pillar K (Gen7-K6): AES support functions. Every table/formula below is
// copied verbatim from the ratified RISC-V scalar-crypto spec's own
// reference Sail model (riscv/sail-riscv, model/riscv_types_kext.sail, at
// the exact commit riscv/riscv-crypto's own .gitmodules pins --
// 4feadb75cff594db27ba94c586e0ad6895f9fa50 -- fetched directly this
// session, not from memory). This IS the ground truth the ratified spec's
// own prose is generated from, not a third-party reimplementation.

// GF(2^8) xtime (multiply-by-2 reduced mod the AES field polynomial 0x11B)
function [7:0] aes_xt2;
    input [7:0] x;
    aes_xt2 = {x[6:0], 1'b0} ^ (x[7] ? 8'h1b : 8'h00);
endfunction
function [7:0] aes_xt3;
    input [7:0] x;
    aes_xt3 = x ^ aes_xt2(x);
endfunction

function [31:0] aes_mixcolumn_fwd;
    input [31:0] x;
    reg [7:0] s0, s1, s2, s3, b0, b1, b2, b3;
    begin
        s0 = x[7:0];   s1 = x[15:8];  s2 = x[23:16]; s3 = x[31:24];
        b0 = aes_xt2(s0) ^ aes_xt3(s1) ^ s2          ^ s3;
        b1 = s0          ^ aes_xt2(s1) ^ aes_xt3(s2) ^ s3;
        b2 = s0          ^ s1          ^ aes_xt2(s2) ^ aes_xt3(s3);
        b3 = aes_xt3(s0) ^ s1          ^ s2          ^ aes_xt2(s3);
        aes_mixcolumn_fwd = {b3, b2, b1, b0};
    end
endfunction

function [7:0] aes_gfmul;
    input [7:0] x;
    input [3:0] y;
    aes_gfmul = (y[0] ? x : 8'h0)
              ^ (y[1] ? aes_xt2(x) : 8'h0)
              ^ (y[2] ? aes_xt2(aes_xt2(x)) : 8'h0)
              ^ (y[3] ? aes_xt2(aes_xt2(aes_xt2(x))) : 8'h0);
endfunction

function [31:0] aes_mixcolumn_inv;
    input [31:0] x;
    reg [7:0] s0, s1, s2, s3, b0, b1, b2, b3;
    begin
        s0 = x[7:0];   s1 = x[15:8];  s2 = x[23:16]; s3 = x[31:24];
        b0 = aes_gfmul(s0,4'hE) ^ aes_gfmul(s1,4'hB) ^ aes_gfmul(s2,4'hD) ^ aes_gfmul(s3,4'h9);
        b1 = aes_gfmul(s0,4'h9) ^ aes_gfmul(s1,4'hE) ^ aes_gfmul(s2,4'hB) ^ aes_gfmul(s3,4'hD);
        b2 = aes_gfmul(s0,4'hD) ^ aes_gfmul(s1,4'h9) ^ aes_gfmul(s2,4'hE) ^ aes_gfmul(s3,4'hB);
        b3 = aes_gfmul(s0,4'hB) ^ aes_gfmul(s1,4'hD) ^ aes_gfmul(s2,4'h9) ^ aes_gfmul(s3,4'hE);
        aes_mixcolumn_inv = {b3, b2, b1, b0};
    end
endfunction

function [31:0] aes_decode_rcon;
    input [3:0] rnum;
    case (rnum)
        4'h0: aes_decode_rcon = 32'h00000001;
        4'h1: aes_decode_rcon = 32'h00000002;
        4'h2: aes_decode_rcon = 32'h00000004;
        4'h3: aes_decode_rcon = 32'h00000008;
        4'h4: aes_decode_rcon = 32'h00000010;
        4'h5: aes_decode_rcon = 32'h00000020;
        4'h6: aes_decode_rcon = 32'h00000040;
        4'h7: aes_decode_rcon = 32'h00000080;
        4'h8: aes_decode_rcon = 32'h0000001b;
        4'h9: aes_decode_rcon = 32'h00000036;
        default: aes_decode_rcon = 32'h00000000;  // 0xA-0xF (0xA = the real "no-rotate" case, rc=0)
    endcase
endfunction

// Forward/inverse S-box, stored as 256-entry ROMs (16 values/line, matching
// the reference model's own row layout for easy cross-checking).
reg [7:0] aes_sbox_fwd_rom [0:255];
reg [7:0] aes_sbox_inv_rom [0:255];
initial begin
    aes_sbox_fwd_rom[8'h00]=8'h63; aes_sbox_fwd_rom[8'h01]=8'h7c; aes_sbox_fwd_rom[8'h02]=8'h77; aes_sbox_fwd_rom[8'h03]=8'h7b;
    aes_sbox_fwd_rom[8'h04]=8'hf2; aes_sbox_fwd_rom[8'h05]=8'h6b; aes_sbox_fwd_rom[8'h06]=8'h6f; aes_sbox_fwd_rom[8'h07]=8'hc5;
    aes_sbox_fwd_rom[8'h08]=8'h30; aes_sbox_fwd_rom[8'h09]=8'h01; aes_sbox_fwd_rom[8'h0a]=8'h67; aes_sbox_fwd_rom[8'h0b]=8'h2b;
    aes_sbox_fwd_rom[8'h0c]=8'hfe; aes_sbox_fwd_rom[8'h0d]=8'hd7; aes_sbox_fwd_rom[8'h0e]=8'hab; aes_sbox_fwd_rom[8'h0f]=8'h76;
    aes_sbox_fwd_rom[8'h10]=8'hca; aes_sbox_fwd_rom[8'h11]=8'h82; aes_sbox_fwd_rom[8'h12]=8'hc9; aes_sbox_fwd_rom[8'h13]=8'h7d;
    aes_sbox_fwd_rom[8'h14]=8'hfa; aes_sbox_fwd_rom[8'h15]=8'h59; aes_sbox_fwd_rom[8'h16]=8'h47; aes_sbox_fwd_rom[8'h17]=8'hf0;
    aes_sbox_fwd_rom[8'h18]=8'had; aes_sbox_fwd_rom[8'h19]=8'hd4; aes_sbox_fwd_rom[8'h1a]=8'ha2; aes_sbox_fwd_rom[8'h1b]=8'haf;
    aes_sbox_fwd_rom[8'h1c]=8'h9c; aes_sbox_fwd_rom[8'h1d]=8'ha4; aes_sbox_fwd_rom[8'h1e]=8'h72; aes_sbox_fwd_rom[8'h1f]=8'hc0;
    aes_sbox_fwd_rom[8'h20]=8'hb7; aes_sbox_fwd_rom[8'h21]=8'hfd; aes_sbox_fwd_rom[8'h22]=8'h93; aes_sbox_fwd_rom[8'h23]=8'h26;
    aes_sbox_fwd_rom[8'h24]=8'h36; aes_sbox_fwd_rom[8'h25]=8'h3f; aes_sbox_fwd_rom[8'h26]=8'hf7; aes_sbox_fwd_rom[8'h27]=8'hcc;
    aes_sbox_fwd_rom[8'h28]=8'h34; aes_sbox_fwd_rom[8'h29]=8'ha5; aes_sbox_fwd_rom[8'h2a]=8'he5; aes_sbox_fwd_rom[8'h2b]=8'hf1;
    aes_sbox_fwd_rom[8'h2c]=8'h71; aes_sbox_fwd_rom[8'h2d]=8'hd8; aes_sbox_fwd_rom[8'h2e]=8'h31; aes_sbox_fwd_rom[8'h2f]=8'h15;
    aes_sbox_fwd_rom[8'h30]=8'h04; aes_sbox_fwd_rom[8'h31]=8'hc7; aes_sbox_fwd_rom[8'h32]=8'h23; aes_sbox_fwd_rom[8'h33]=8'hc3;
    aes_sbox_fwd_rom[8'h34]=8'h18; aes_sbox_fwd_rom[8'h35]=8'h96; aes_sbox_fwd_rom[8'h36]=8'h05; aes_sbox_fwd_rom[8'h37]=8'h9a;
    aes_sbox_fwd_rom[8'h38]=8'h07; aes_sbox_fwd_rom[8'h39]=8'h12; aes_sbox_fwd_rom[8'h3a]=8'h80; aes_sbox_fwd_rom[8'h3b]=8'he2;
    aes_sbox_fwd_rom[8'h3c]=8'heb; aes_sbox_fwd_rom[8'h3d]=8'h27; aes_sbox_fwd_rom[8'h3e]=8'hb2; aes_sbox_fwd_rom[8'h3f]=8'h75;
    aes_sbox_fwd_rom[8'h40]=8'h09; aes_sbox_fwd_rom[8'h41]=8'h83; aes_sbox_fwd_rom[8'h42]=8'h2c; aes_sbox_fwd_rom[8'h43]=8'h1a;
    aes_sbox_fwd_rom[8'h44]=8'h1b; aes_sbox_fwd_rom[8'h45]=8'h6e; aes_sbox_fwd_rom[8'h46]=8'h5a; aes_sbox_fwd_rom[8'h47]=8'ha0;
    aes_sbox_fwd_rom[8'h48]=8'h52; aes_sbox_fwd_rom[8'h49]=8'h3b; aes_sbox_fwd_rom[8'h4a]=8'hd6; aes_sbox_fwd_rom[8'h4b]=8'hb3;
    aes_sbox_fwd_rom[8'h4c]=8'h29; aes_sbox_fwd_rom[8'h4d]=8'he3; aes_sbox_fwd_rom[8'h4e]=8'h2f; aes_sbox_fwd_rom[8'h4f]=8'h84;
    aes_sbox_fwd_rom[8'h50]=8'h53; aes_sbox_fwd_rom[8'h51]=8'hd1; aes_sbox_fwd_rom[8'h52]=8'h00; aes_sbox_fwd_rom[8'h53]=8'hed;
    aes_sbox_fwd_rom[8'h54]=8'h20; aes_sbox_fwd_rom[8'h55]=8'hfc; aes_sbox_fwd_rom[8'h56]=8'hb1; aes_sbox_fwd_rom[8'h57]=8'h5b;
    aes_sbox_fwd_rom[8'h58]=8'h6a; aes_sbox_fwd_rom[8'h59]=8'hcb; aes_sbox_fwd_rom[8'h5a]=8'hbe; aes_sbox_fwd_rom[8'h5b]=8'h39;
    aes_sbox_fwd_rom[8'h5c]=8'h4a; aes_sbox_fwd_rom[8'h5d]=8'h4c; aes_sbox_fwd_rom[8'h5e]=8'h58; aes_sbox_fwd_rom[8'h5f]=8'hcf;
    aes_sbox_fwd_rom[8'h60]=8'hd0; aes_sbox_fwd_rom[8'h61]=8'hef; aes_sbox_fwd_rom[8'h62]=8'haa; aes_sbox_fwd_rom[8'h63]=8'hfb;
    aes_sbox_fwd_rom[8'h64]=8'h43; aes_sbox_fwd_rom[8'h65]=8'h4d; aes_sbox_fwd_rom[8'h66]=8'h33; aes_sbox_fwd_rom[8'h67]=8'h85;
    aes_sbox_fwd_rom[8'h68]=8'h45; aes_sbox_fwd_rom[8'h69]=8'hf9; aes_sbox_fwd_rom[8'h6a]=8'h02; aes_sbox_fwd_rom[8'h6b]=8'h7f;
    aes_sbox_fwd_rom[8'h6c]=8'h50; aes_sbox_fwd_rom[8'h6d]=8'h3c; aes_sbox_fwd_rom[8'h6e]=8'h9f; aes_sbox_fwd_rom[8'h6f]=8'ha8;
    aes_sbox_fwd_rom[8'h70]=8'h51; aes_sbox_fwd_rom[8'h71]=8'ha3; aes_sbox_fwd_rom[8'h72]=8'h40; aes_sbox_fwd_rom[8'h73]=8'h8f;
    aes_sbox_fwd_rom[8'h74]=8'h92; aes_sbox_fwd_rom[8'h75]=8'h9d; aes_sbox_fwd_rom[8'h76]=8'h38; aes_sbox_fwd_rom[8'h77]=8'hf5;
    aes_sbox_fwd_rom[8'h78]=8'hbc; aes_sbox_fwd_rom[8'h79]=8'hb6; aes_sbox_fwd_rom[8'h7a]=8'hda; aes_sbox_fwd_rom[8'h7b]=8'h21;
    aes_sbox_fwd_rom[8'h7c]=8'h10; aes_sbox_fwd_rom[8'h7d]=8'hff; aes_sbox_fwd_rom[8'h7e]=8'hf3; aes_sbox_fwd_rom[8'h7f]=8'hd2;
    aes_sbox_fwd_rom[8'h80]=8'hcd; aes_sbox_fwd_rom[8'h81]=8'h0c; aes_sbox_fwd_rom[8'h82]=8'h13; aes_sbox_fwd_rom[8'h83]=8'hec;
    aes_sbox_fwd_rom[8'h84]=8'h5f; aes_sbox_fwd_rom[8'h85]=8'h97; aes_sbox_fwd_rom[8'h86]=8'h44; aes_sbox_fwd_rom[8'h87]=8'h17;
    aes_sbox_fwd_rom[8'h88]=8'hc4; aes_sbox_fwd_rom[8'h89]=8'ha7; aes_sbox_fwd_rom[8'h8a]=8'h7e; aes_sbox_fwd_rom[8'h8b]=8'h3d;
    aes_sbox_fwd_rom[8'h8c]=8'h64; aes_sbox_fwd_rom[8'h8d]=8'h5d; aes_sbox_fwd_rom[8'h8e]=8'h19; aes_sbox_fwd_rom[8'h8f]=8'h73;
    aes_sbox_fwd_rom[8'h90]=8'h60; aes_sbox_fwd_rom[8'h91]=8'h81; aes_sbox_fwd_rom[8'h92]=8'h4f; aes_sbox_fwd_rom[8'h93]=8'hdc;
    aes_sbox_fwd_rom[8'h94]=8'h22; aes_sbox_fwd_rom[8'h95]=8'h2a; aes_sbox_fwd_rom[8'h96]=8'h90; aes_sbox_fwd_rom[8'h97]=8'h88;
    aes_sbox_fwd_rom[8'h98]=8'h46; aes_sbox_fwd_rom[8'h99]=8'hee; aes_sbox_fwd_rom[8'h9a]=8'hb8; aes_sbox_fwd_rom[8'h9b]=8'h14;
    aes_sbox_fwd_rom[8'h9c]=8'hde; aes_sbox_fwd_rom[8'h9d]=8'h5e; aes_sbox_fwd_rom[8'h9e]=8'h0b; aes_sbox_fwd_rom[8'h9f]=8'hdb;
    aes_sbox_fwd_rom[8'ha0]=8'he0; aes_sbox_fwd_rom[8'ha1]=8'h32; aes_sbox_fwd_rom[8'ha2]=8'h3a; aes_sbox_fwd_rom[8'ha3]=8'h0a;
    aes_sbox_fwd_rom[8'ha4]=8'h49; aes_sbox_fwd_rom[8'ha5]=8'h06; aes_sbox_fwd_rom[8'ha6]=8'h24; aes_sbox_fwd_rom[8'ha7]=8'h5c;
    aes_sbox_fwd_rom[8'ha8]=8'hc2; aes_sbox_fwd_rom[8'ha9]=8'hd3; aes_sbox_fwd_rom[8'haa]=8'hac; aes_sbox_fwd_rom[8'hab]=8'h62;
    aes_sbox_fwd_rom[8'hac]=8'h91; aes_sbox_fwd_rom[8'had]=8'h95; aes_sbox_fwd_rom[8'hae]=8'he4; aes_sbox_fwd_rom[8'haf]=8'h79;
    aes_sbox_fwd_rom[8'hb0]=8'he7; aes_sbox_fwd_rom[8'hb1]=8'hc8; aes_sbox_fwd_rom[8'hb2]=8'h37; aes_sbox_fwd_rom[8'hb3]=8'h6d;
    aes_sbox_fwd_rom[8'hb4]=8'h8d; aes_sbox_fwd_rom[8'hb5]=8'hd5; aes_sbox_fwd_rom[8'hb6]=8'h4e; aes_sbox_fwd_rom[8'hb7]=8'ha9;
    aes_sbox_fwd_rom[8'hb8]=8'h6c; aes_sbox_fwd_rom[8'hb9]=8'h56; aes_sbox_fwd_rom[8'hba]=8'hf4; aes_sbox_fwd_rom[8'hbb]=8'hea;
    aes_sbox_fwd_rom[8'hbc]=8'h65; aes_sbox_fwd_rom[8'hbd]=8'h7a; aes_sbox_fwd_rom[8'hbe]=8'hae; aes_sbox_fwd_rom[8'hbf]=8'h08;
    aes_sbox_fwd_rom[8'hc0]=8'hba; aes_sbox_fwd_rom[8'hc1]=8'h78; aes_sbox_fwd_rom[8'hc2]=8'h25; aes_sbox_fwd_rom[8'hc3]=8'h2e;
    aes_sbox_fwd_rom[8'hc4]=8'h1c; aes_sbox_fwd_rom[8'hc5]=8'ha6; aes_sbox_fwd_rom[8'hc6]=8'hb4; aes_sbox_fwd_rom[8'hc7]=8'hc6;
    aes_sbox_fwd_rom[8'hc8]=8'he8; aes_sbox_fwd_rom[8'hc9]=8'hdd; aes_sbox_fwd_rom[8'hca]=8'h74; aes_sbox_fwd_rom[8'hcb]=8'h1f;
    aes_sbox_fwd_rom[8'hcc]=8'h4b; aes_sbox_fwd_rom[8'hcd]=8'hbd; aes_sbox_fwd_rom[8'hce]=8'h8b; aes_sbox_fwd_rom[8'hcf]=8'h8a;
    aes_sbox_fwd_rom[8'hd0]=8'h70; aes_sbox_fwd_rom[8'hd1]=8'h3e; aes_sbox_fwd_rom[8'hd2]=8'hb5; aes_sbox_fwd_rom[8'hd3]=8'h66;
    aes_sbox_fwd_rom[8'hd4]=8'h48; aes_sbox_fwd_rom[8'hd5]=8'h03; aes_sbox_fwd_rom[8'hd6]=8'hf6; aes_sbox_fwd_rom[8'hd7]=8'h0e;
    aes_sbox_fwd_rom[8'hd8]=8'h61; aes_sbox_fwd_rom[8'hd9]=8'h35; aes_sbox_fwd_rom[8'hda]=8'h57; aes_sbox_fwd_rom[8'hdb]=8'hb9;
    aes_sbox_fwd_rom[8'hdc]=8'h86; aes_sbox_fwd_rom[8'hdd]=8'hc1; aes_sbox_fwd_rom[8'hde]=8'h1d; aes_sbox_fwd_rom[8'hdf]=8'h9e;
    aes_sbox_fwd_rom[8'he0]=8'he1; aes_sbox_fwd_rom[8'he1]=8'hf8; aes_sbox_fwd_rom[8'he2]=8'h98; aes_sbox_fwd_rom[8'he3]=8'h11;
    aes_sbox_fwd_rom[8'he4]=8'h69; aes_sbox_fwd_rom[8'he5]=8'hd9; aes_sbox_fwd_rom[8'he6]=8'h8e; aes_sbox_fwd_rom[8'he7]=8'h94;
    aes_sbox_fwd_rom[8'he8]=8'h9b; aes_sbox_fwd_rom[8'he9]=8'h1e; aes_sbox_fwd_rom[8'hea]=8'h87; aes_sbox_fwd_rom[8'heb]=8'he9;
    aes_sbox_fwd_rom[8'hec]=8'hce; aes_sbox_fwd_rom[8'hed]=8'h55; aes_sbox_fwd_rom[8'hee]=8'h28; aes_sbox_fwd_rom[8'hef]=8'hdf;
    aes_sbox_fwd_rom[8'hf0]=8'h8c; aes_sbox_fwd_rom[8'hf1]=8'ha1; aes_sbox_fwd_rom[8'hf2]=8'h89; aes_sbox_fwd_rom[8'hf3]=8'h0d;
    aes_sbox_fwd_rom[8'hf4]=8'hbf; aes_sbox_fwd_rom[8'hf5]=8'he6; aes_sbox_fwd_rom[8'hf6]=8'h42; aes_sbox_fwd_rom[8'hf7]=8'h68;
    aes_sbox_fwd_rom[8'hf8]=8'h41; aes_sbox_fwd_rom[8'hf9]=8'h99; aes_sbox_fwd_rom[8'hfa]=8'h2d; aes_sbox_fwd_rom[8'hfb]=8'h0f;
    aes_sbox_fwd_rom[8'hfc]=8'hb0; aes_sbox_fwd_rom[8'hfd]=8'h54; aes_sbox_fwd_rom[8'hfe]=8'hbb; aes_sbox_fwd_rom[8'hff]=8'h16;

    aes_sbox_inv_rom[8'h00]=8'h52; aes_sbox_inv_rom[8'h01]=8'h09; aes_sbox_inv_rom[8'h02]=8'h6a; aes_sbox_inv_rom[8'h03]=8'hd5;
    aes_sbox_inv_rom[8'h04]=8'h30; aes_sbox_inv_rom[8'h05]=8'h36; aes_sbox_inv_rom[8'h06]=8'ha5; aes_sbox_inv_rom[8'h07]=8'h38;
    aes_sbox_inv_rom[8'h08]=8'hbf; aes_sbox_inv_rom[8'h09]=8'h40; aes_sbox_inv_rom[8'h0a]=8'ha3; aes_sbox_inv_rom[8'h0b]=8'h9e;
    aes_sbox_inv_rom[8'h0c]=8'h81; aes_sbox_inv_rom[8'h0d]=8'hf3; aes_sbox_inv_rom[8'h0e]=8'hd7; aes_sbox_inv_rom[8'h0f]=8'hfb;
    aes_sbox_inv_rom[8'h10]=8'h7c; aes_sbox_inv_rom[8'h11]=8'he3; aes_sbox_inv_rom[8'h12]=8'h39; aes_sbox_inv_rom[8'h13]=8'h82;
    aes_sbox_inv_rom[8'h14]=8'h9b; aes_sbox_inv_rom[8'h15]=8'h2f; aes_sbox_inv_rom[8'h16]=8'hff; aes_sbox_inv_rom[8'h17]=8'h87;
    aes_sbox_inv_rom[8'h18]=8'h34; aes_sbox_inv_rom[8'h19]=8'h8e; aes_sbox_inv_rom[8'h1a]=8'h43; aes_sbox_inv_rom[8'h1b]=8'h44;
    aes_sbox_inv_rom[8'h1c]=8'hc4; aes_sbox_inv_rom[8'h1d]=8'hde; aes_sbox_inv_rom[8'h1e]=8'he9; aes_sbox_inv_rom[8'h1f]=8'hcb;
    aes_sbox_inv_rom[8'h20]=8'h54; aes_sbox_inv_rom[8'h21]=8'h7b; aes_sbox_inv_rom[8'h22]=8'h94; aes_sbox_inv_rom[8'h23]=8'h32;
    aes_sbox_inv_rom[8'h24]=8'ha6; aes_sbox_inv_rom[8'h25]=8'hc2; aes_sbox_inv_rom[8'h26]=8'h23; aes_sbox_inv_rom[8'h27]=8'h3d;
    aes_sbox_inv_rom[8'h28]=8'hee; aes_sbox_inv_rom[8'h29]=8'h4c; aes_sbox_inv_rom[8'h2a]=8'h95; aes_sbox_inv_rom[8'h2b]=8'h0b;
    aes_sbox_inv_rom[8'h2c]=8'h42; aes_sbox_inv_rom[8'h2d]=8'hfa; aes_sbox_inv_rom[8'h2e]=8'hc3; aes_sbox_inv_rom[8'h2f]=8'h4e;
    aes_sbox_inv_rom[8'h30]=8'h08; aes_sbox_inv_rom[8'h31]=8'h2e; aes_sbox_inv_rom[8'h32]=8'ha1; aes_sbox_inv_rom[8'h33]=8'h66;
    aes_sbox_inv_rom[8'h34]=8'h28; aes_sbox_inv_rom[8'h35]=8'hd9; aes_sbox_inv_rom[8'h36]=8'h24; aes_sbox_inv_rom[8'h37]=8'hb2;
    aes_sbox_inv_rom[8'h38]=8'h76; aes_sbox_inv_rom[8'h39]=8'h5b; aes_sbox_inv_rom[8'h3a]=8'ha2; aes_sbox_inv_rom[8'h3b]=8'h49;
    aes_sbox_inv_rom[8'h3c]=8'h6d; aes_sbox_inv_rom[8'h3d]=8'h8b; aes_sbox_inv_rom[8'h3e]=8'hd1; aes_sbox_inv_rom[8'h3f]=8'h25;
    aes_sbox_inv_rom[8'h40]=8'h72; aes_sbox_inv_rom[8'h41]=8'hf8; aes_sbox_inv_rom[8'h42]=8'hf6; aes_sbox_inv_rom[8'h43]=8'h64;
    aes_sbox_inv_rom[8'h44]=8'h86; aes_sbox_inv_rom[8'h45]=8'h68; aes_sbox_inv_rom[8'h46]=8'h98; aes_sbox_inv_rom[8'h47]=8'h16;
    aes_sbox_inv_rom[8'h48]=8'hd4; aes_sbox_inv_rom[8'h49]=8'ha4; aes_sbox_inv_rom[8'h4a]=8'h5c; aes_sbox_inv_rom[8'h4b]=8'hcc;
    aes_sbox_inv_rom[8'h4c]=8'h5d; aes_sbox_inv_rom[8'h4d]=8'h65; aes_sbox_inv_rom[8'h4e]=8'hb6; aes_sbox_inv_rom[8'h4f]=8'h92;
    aes_sbox_inv_rom[8'h50]=8'h6c; aes_sbox_inv_rom[8'h51]=8'h70; aes_sbox_inv_rom[8'h52]=8'h48; aes_sbox_inv_rom[8'h53]=8'h50;
    aes_sbox_inv_rom[8'h54]=8'hfd; aes_sbox_inv_rom[8'h55]=8'hed; aes_sbox_inv_rom[8'h56]=8'hb9; aes_sbox_inv_rom[8'h57]=8'hda;
    aes_sbox_inv_rom[8'h58]=8'h5e; aes_sbox_inv_rom[8'h59]=8'h15; aes_sbox_inv_rom[8'h5a]=8'h46; aes_sbox_inv_rom[8'h5b]=8'h57;
    aes_sbox_inv_rom[8'h5c]=8'ha7; aes_sbox_inv_rom[8'h5d]=8'h8d; aes_sbox_inv_rom[8'h5e]=8'h9d; aes_sbox_inv_rom[8'h5f]=8'h84;
    aes_sbox_inv_rom[8'h60]=8'h90; aes_sbox_inv_rom[8'h61]=8'hd8; aes_sbox_inv_rom[8'h62]=8'hab; aes_sbox_inv_rom[8'h63]=8'h00;
    aes_sbox_inv_rom[8'h64]=8'h8c; aes_sbox_inv_rom[8'h65]=8'hbc; aes_sbox_inv_rom[8'h66]=8'hd3; aes_sbox_inv_rom[8'h67]=8'h0a;
    aes_sbox_inv_rom[8'h68]=8'hf7; aes_sbox_inv_rom[8'h69]=8'he4; aes_sbox_inv_rom[8'h6a]=8'h58; aes_sbox_inv_rom[8'h6b]=8'h05;
    aes_sbox_inv_rom[8'h6c]=8'hb8; aes_sbox_inv_rom[8'h6d]=8'hb3; aes_sbox_inv_rom[8'h6e]=8'h45; aes_sbox_inv_rom[8'h6f]=8'h06;
    aes_sbox_inv_rom[8'h70]=8'hd0; aes_sbox_inv_rom[8'h71]=8'h2c; aes_sbox_inv_rom[8'h72]=8'h1e; aes_sbox_inv_rom[8'h73]=8'h8f;
    aes_sbox_inv_rom[8'h74]=8'hca; aes_sbox_inv_rom[8'h75]=8'h3f; aes_sbox_inv_rom[8'h76]=8'h0f; aes_sbox_inv_rom[8'h77]=8'h02;
    aes_sbox_inv_rom[8'h78]=8'hc1; aes_sbox_inv_rom[8'h79]=8'haf; aes_sbox_inv_rom[8'h7a]=8'hbd; aes_sbox_inv_rom[8'h7b]=8'h03;
    aes_sbox_inv_rom[8'h7c]=8'h01; aes_sbox_inv_rom[8'h7d]=8'h13; aes_sbox_inv_rom[8'h7e]=8'h8a; aes_sbox_inv_rom[8'h7f]=8'h6b;
    aes_sbox_inv_rom[8'h80]=8'h3a; aes_sbox_inv_rom[8'h81]=8'h91; aes_sbox_inv_rom[8'h82]=8'h11; aes_sbox_inv_rom[8'h83]=8'h41;
    aes_sbox_inv_rom[8'h84]=8'h4f; aes_sbox_inv_rom[8'h85]=8'h67; aes_sbox_inv_rom[8'h86]=8'hdc; aes_sbox_inv_rom[8'h87]=8'hea;
    aes_sbox_inv_rom[8'h88]=8'h97; aes_sbox_inv_rom[8'h89]=8'hf2; aes_sbox_inv_rom[8'h8a]=8'hcf; aes_sbox_inv_rom[8'h8b]=8'hce;
    aes_sbox_inv_rom[8'h8c]=8'hf0; aes_sbox_inv_rom[8'h8d]=8'hb4; aes_sbox_inv_rom[8'h8e]=8'he6; aes_sbox_inv_rom[8'h8f]=8'h73;
    aes_sbox_inv_rom[8'h90]=8'h96; aes_sbox_inv_rom[8'h91]=8'hac; aes_sbox_inv_rom[8'h92]=8'h74; aes_sbox_inv_rom[8'h93]=8'h22;
    aes_sbox_inv_rom[8'h94]=8'he7; aes_sbox_inv_rom[8'h95]=8'had; aes_sbox_inv_rom[8'h96]=8'h35; aes_sbox_inv_rom[8'h97]=8'h85;
    aes_sbox_inv_rom[8'h98]=8'he2; aes_sbox_inv_rom[8'h99]=8'hf9; aes_sbox_inv_rom[8'h9a]=8'h37; aes_sbox_inv_rom[8'h9b]=8'he8;
    aes_sbox_inv_rom[8'h9c]=8'h1c; aes_sbox_inv_rom[8'h9d]=8'h75; aes_sbox_inv_rom[8'h9e]=8'hdf; aes_sbox_inv_rom[8'h9f]=8'h6e;
    aes_sbox_inv_rom[8'ha0]=8'h47; aes_sbox_inv_rom[8'ha1]=8'hf1; aes_sbox_inv_rom[8'ha2]=8'h1a; aes_sbox_inv_rom[8'ha3]=8'h71;
    aes_sbox_inv_rom[8'ha4]=8'h1d; aes_sbox_inv_rom[8'ha5]=8'h29; aes_sbox_inv_rom[8'ha6]=8'hc5; aes_sbox_inv_rom[8'ha7]=8'h89;
    aes_sbox_inv_rom[8'ha8]=8'h6f; aes_sbox_inv_rom[8'ha9]=8'hb7; aes_sbox_inv_rom[8'haa]=8'h62; aes_sbox_inv_rom[8'hab]=8'h0e;
    aes_sbox_inv_rom[8'hac]=8'haa; aes_sbox_inv_rom[8'had]=8'h18; aes_sbox_inv_rom[8'hae]=8'hbe; aes_sbox_inv_rom[8'haf]=8'h1b;
    aes_sbox_inv_rom[8'hb0]=8'hfc; aes_sbox_inv_rom[8'hb1]=8'h56; aes_sbox_inv_rom[8'hb2]=8'h3e; aes_sbox_inv_rom[8'hb3]=8'h4b;
    aes_sbox_inv_rom[8'hb4]=8'hc6; aes_sbox_inv_rom[8'hb5]=8'hd2; aes_sbox_inv_rom[8'hb6]=8'h79; aes_sbox_inv_rom[8'hb7]=8'h20;
    aes_sbox_inv_rom[8'hb8]=8'h9a; aes_sbox_inv_rom[8'hb9]=8'hdb; aes_sbox_inv_rom[8'hba]=8'hc0; aes_sbox_inv_rom[8'hbb]=8'hfe;
    aes_sbox_inv_rom[8'hbc]=8'h78; aes_sbox_inv_rom[8'hbd]=8'hcd; aes_sbox_inv_rom[8'hbe]=8'h5a; aes_sbox_inv_rom[8'hbf]=8'hf4;
    aes_sbox_inv_rom[8'hc0]=8'h1f; aes_sbox_inv_rom[8'hc1]=8'hdd; aes_sbox_inv_rom[8'hc2]=8'ha8; aes_sbox_inv_rom[8'hc3]=8'h33;
    aes_sbox_inv_rom[8'hc4]=8'h88; aes_sbox_inv_rom[8'hc5]=8'h07; aes_sbox_inv_rom[8'hc6]=8'hc7; aes_sbox_inv_rom[8'hc7]=8'h31;
    aes_sbox_inv_rom[8'hc8]=8'hb1; aes_sbox_inv_rom[8'hc9]=8'h12; aes_sbox_inv_rom[8'hca]=8'h10; aes_sbox_inv_rom[8'hcb]=8'h59;
    aes_sbox_inv_rom[8'hcc]=8'h27; aes_sbox_inv_rom[8'hcd]=8'h80; aes_sbox_inv_rom[8'hce]=8'hec; aes_sbox_inv_rom[8'hcf]=8'h5f;
    aes_sbox_inv_rom[8'hd0]=8'h60; aes_sbox_inv_rom[8'hd1]=8'h51; aes_sbox_inv_rom[8'hd2]=8'h7f; aes_sbox_inv_rom[8'hd3]=8'ha9;
    aes_sbox_inv_rom[8'hd4]=8'h19; aes_sbox_inv_rom[8'hd5]=8'hb5; aes_sbox_inv_rom[8'hd6]=8'h4a; aes_sbox_inv_rom[8'hd7]=8'h0d;
    aes_sbox_inv_rom[8'hd8]=8'h2d; aes_sbox_inv_rom[8'hd9]=8'he5; aes_sbox_inv_rom[8'hda]=8'h7a; aes_sbox_inv_rom[8'hdb]=8'h9f;
    aes_sbox_inv_rom[8'hdc]=8'h93; aes_sbox_inv_rom[8'hdd]=8'hc9; aes_sbox_inv_rom[8'hde]=8'h9c; aes_sbox_inv_rom[8'hdf]=8'hef;
    aes_sbox_inv_rom[8'he0]=8'ha0; aes_sbox_inv_rom[8'he1]=8'he0; aes_sbox_inv_rom[8'he2]=8'h3b; aes_sbox_inv_rom[8'he3]=8'h4d;
    aes_sbox_inv_rom[8'he4]=8'hae; aes_sbox_inv_rom[8'he5]=8'h2a; aes_sbox_inv_rom[8'he6]=8'hf5; aes_sbox_inv_rom[8'he7]=8'hb0;
    aes_sbox_inv_rom[8'he8]=8'hc8; aes_sbox_inv_rom[8'he9]=8'heb; aes_sbox_inv_rom[8'hea]=8'hbb; aes_sbox_inv_rom[8'heb]=8'h3c;
    aes_sbox_inv_rom[8'hec]=8'h83; aes_sbox_inv_rom[8'hed]=8'h53; aes_sbox_inv_rom[8'hee]=8'h99; aes_sbox_inv_rom[8'hef]=8'h61;
    aes_sbox_inv_rom[8'hf0]=8'h17; aes_sbox_inv_rom[8'hf1]=8'h2b; aes_sbox_inv_rom[8'hf2]=8'h04; aes_sbox_inv_rom[8'hf3]=8'h7e;
    aes_sbox_inv_rom[8'hf4]=8'hba; aes_sbox_inv_rom[8'hf5]=8'h77; aes_sbox_inv_rom[8'hf6]=8'hd6; aes_sbox_inv_rom[8'hf7]=8'h26;
    aes_sbox_inv_rom[8'hf8]=8'he1; aes_sbox_inv_rom[8'hf9]=8'h69; aes_sbox_inv_rom[8'hfa]=8'h14; aes_sbox_inv_rom[8'hfb]=8'h63;
    aes_sbox_inv_rom[8'hfc]=8'h55; aes_sbox_inv_rom[8'hfd]=8'h21; aes_sbox_inv_rom[8'hfe]=8'h0c; aes_sbox_inv_rom[8'hff]=8'h7d;
end

function [31:0] aes_subword_fwd;
    input [31:0] x;
    aes_subword_fwd = {aes_sbox_fwd_rom[x[31:24]], aes_sbox_fwd_rom[x[23:16]],
                        aes_sbox_fwd_rom[x[15:8]],  aes_sbox_fwd_rom[x[7:0]]};
endfunction
function [63:0] aes_apply_fwd_sbox_to_each_byte;
    input [63:0] x;
    aes_apply_fwd_sbox_to_each_byte = {aes_sbox_fwd_rom[x[63:56]], aes_sbox_fwd_rom[x[55:48]],
                                        aes_sbox_fwd_rom[x[47:40]], aes_sbox_fwd_rom[x[39:32]],
                                        aes_sbox_fwd_rom[x[31:24]], aes_sbox_fwd_rom[x[23:16]],
                                        aes_sbox_fwd_rom[x[15:8]],  aes_sbox_fwd_rom[x[7:0]]};
endfunction
function [63:0] aes_apply_inv_sbox_to_each_byte;
    input [63:0] x;
    aes_apply_inv_sbox_to_each_byte = {aes_sbox_inv_rom[x[63:56]], aes_sbox_inv_rom[x[55:48]],
                                        aes_sbox_inv_rom[x[47:40]], aes_sbox_inv_rom[x[39:32]],
                                        aes_sbox_inv_rom[x[31:24]], aes_sbox_inv_rom[x[23:16]],
                                        aes_sbox_inv_rom[x[15:8]],  aes_sbox_inv_rom[x[7:0]]};
endfunction

// RV64 half-state ShiftRows -- byte permutation hand-derived from the
// reference model's getbyte-indexed formula (see the design doc's own
// derivation). rs2/rs1 are the HIGH/LOW 64-bit halves of the real 128-bit
// AES state; each call produces ONE 64-bit half of the new state (software
// issues the instruction twice, with rs1/rs2 swapped, to get both halves).
function [63:0] aes_rv64_shiftrows_fwd;
    input [63:0] rs2, rs1;
    aes_rv64_shiftrows_fwd = {rs1[31:24], rs2[55:48], rs2[15:8], rs1[39:32],
                               rs2[63:56], rs2[23:16], rs1[47:40], rs1[7:0]};
endfunction
function [63:0] aes_rv64_shiftrows_inv;
    input [63:0] rs2, rs1;
    aes_rv64_shiftrows_inv = {rs2[31:24], rs2[55:48], rs1[15:8], rs1[39:32],
                               rs1[63:56], rs2[23:16], rs2[47:40], rs1[7:0]};
endfunction

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
        // Pillar K random-test finding (Gen7-K7): the old `w32 = A[31:0] <<
        // B[4:0]` truncated the shift to 32 bits BEFORE zero-extending,
        // silently discarding every bit shifted past bit31 -- real spec
        // semantics zero-extend A[31:0] to XLEN FIRST, then shift left by
        // the full 6-bit shamt (0-63) within that width. A real,
        // pre-existing bug since docs/adr/0060 (Pillar B) added this op;
        // never triggered by any prior random seed until Pillar K's own
        // random_gen.py additions happened to produce shamt>=32 with a
        // nonzero high bit in play. Also widened B's slice 4:0->
        // SHAMT_WIDTH-1:0 (5->6 bits) to match slli.uw's real 6-bit shamt
        // (riscv_defs.vh's own FUNCT6_ZBA_SLLIUW comment already documented
        // the field is 6 bits; this ALU.v arm just never used the full width).
        ALUOut = ({{(XLEN-32){1'b0}}, A[31:0]} << B[SHAMT_WIDTH-1:0]);

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

    // ---- Zbkx (docs/adr/0059 Pillar K) ---- nibble/byte crossbar lookup
    // into A, indexed by each nibble/byte of B. Out-of-range index -> 0
    // (explicit guard, since Verilog's `>>` on a fixed-width value does NOT
    // auto-zero past the top the way Sail's arbitrary-precision shift does
    // in the ratified spec).
    `ALUCTL_XPERM4:
        begin
            ALUOut = 0;
            for (i = 0; i < XLEN/4; i = i + 1) begin
                xperm_idx4 = B[i*4 +: 4];
                if (xperm_idx4 < XLEN/4)
                    ALUOut[i*4 +: 4] = A[xperm_idx4*4 +: 4];
            end
        end
    `ALUCTL_XPERM8:
        begin
            ALUOut = 0;
            for (i = 0; i < XLEN/8; i = i + 1) begin
                xperm_idx8 = B[i*8 +: 8];
                if (xperm_idx8 < XLEN/8)
                    ALUOut[i*8 +: 8] = A[xperm_idx8*8 +: 8];
            end
        end

    // ---- Zkne+Zknd (docs/adr/0059 Pillar K) AES ----
    // rnum for aes64ks1i arrives via B[3:0] (ImmGen's existing shamt-shaped
    // zero-extend path already produces this -- OPCODE_I funct3=001 lands
    // in ImmGen.v's `inst[19+SHAMT_BITS:20]` arm unmodified, verified by
    // direct code read; no ImmGen.v change was needed).
    `ALUCTL_AES64KS1I:
        begin
            aes_tmp1 = A[63:32];
            aes_rc   = aes_decode_rcon(B[3:0]);
            aes_tmp2 = (B[3:0] == 4'hA) ? aes_tmp1 : {aes_tmp1[7:0], aes_tmp1[31:8]};  // ror32(tmp1,8)
            aes_tmp3 = aes_subword_fwd(aes_tmp2);
            ALUOut = {aes_tmp3 ^ aes_rc, aes_tmp3 ^ aes_rc};
        end
    `ALUCTL_AES64KS2:
        begin
            aes_w0 = A[63:32] ^ B[31:0];
            aes_w1 = A[63:32] ^ B[31:0] ^ B[63:32];
            ALUOut = {aes_w1, aes_w0};
        end
    `ALUCTL_AES64ESM:
        begin
            aes_sr = aes_rv64_shiftrows_fwd(B, A);
            aes_sb = aes_apply_fwd_sbox_to_each_byte(aes_sr);
            ALUOut = {aes_mixcolumn_fwd(aes_sb[63:32]), aes_mixcolumn_fwd(aes_sb[31:0])};
        end
    `ALUCTL_AES64ES:
        begin
            aes_sr = aes_rv64_shiftrows_fwd(B, A);
            ALUOut = aes_apply_fwd_sbox_to_each_byte(aes_sr);
        end
    `ALUCTL_AES64DSM:
        begin
            aes_sr = aes_rv64_shiftrows_inv(B, A);
            aes_sb = aes_apply_inv_sbox_to_each_byte(aes_sr);
            ALUOut = {aes_mixcolumn_inv(aes_sb[63:32]), aes_mixcolumn_inv(aes_sb[31:0])};
        end
    `ALUCTL_AES64DS:
        begin
            aes_sr = aes_rv64_shiftrows_inv(B, A);
            ALUOut = aes_apply_inv_sbox_to_each_byte(aes_sr);
        end
    `ALUCTL_AES64IM:
        ALUOut = {aes_mixcolumn_inv(A[63:32]), aes_mixcolumn_inv(A[31:0])};

endcase
            zero = branch_zero;
end

    // ALU has two operands, executes a different operation based on ALUCtl.
    // `zero` (really "branch condition true") feeds the fetch-stage redirect mux.

endmodule

`default_nettype wire
