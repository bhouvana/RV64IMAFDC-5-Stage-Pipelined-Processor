`include "ALU.v"

// Pillar K, Task 6. Two tiers: (1) direct single-instruction checks using
// known S-box entries and simple values -- easy to hand-verify, checks the
// SHIFTROWS/MIXCOLUMN wiring around the S-box; (2) a full AES-128
// single-block encrypt using the world's most widely-published AES test
// vector (FIPS-197 Appendix C.1), proving the whole key-schedule + round
// pipeline end-to-end. The exact register-half convention (which state/key
// half is "rs1" vs "rs2" in each call) was determined empirically -- built
// a standalone Python model using the identical S-box/rcon/mixcolumn/
// shiftrows functions this file's DUT uses, brute-forced the layout
// against the real KAT, confirmed a match, then transcribed that exact,
// now-verified convention here (not guessed/hand-derived blind).
module tb_alu_zkne_zknd_unit;
    reg [6:0] ALUCtl = 0;
    reg [63:0] A = 0, B = 0;
    reg wordOp = 0;
    wire [63:0] ALUOut;
    wire zero, branch_zero;

    ALU #(.XLEN(64)) dut(.ALUCtl(ALUCtl), .A(A), .B(B), .wordOp(wordOp),
                          .ALUOut(ALUOut), .zero(zero), .branch_zero(branch_zero));

    integer checks = 0;
    integer fails = 0;
    task check;
        input [63:0] expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (ALUOut !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: got %h, expected %h", label, ALUOut, expected);
            end else $display("pass  %0s: %h", label, ALUOut);
        end
    endtask

    // ---- Tier 2 scratch: full AES-128 encrypt driving the same DUT ----
    integer r;
    reg [63:0] rk_lo, rk_hi;
    reg [63:0] st_lo, st_hi;
    reg [63:0] t, new_lo, new_hi, new_rk_lo, new_rk_hi;

    task aes_call;  // one ALU call: set ALUCtl/A/B, capture ALUOut into out_
        input [6:0] ctl_;
        input [63:0] a_, b_;
        output [63:0] out_;
        begin
            ALUCtl = ctl_; A = a_; B = b_;
            #1 out_ = ALUOut;
        end
    endtask

    initial begin
        // ---- Tier 1 ----
        // All-zero state: shiftrows(0)=0, sbox(0x00)=0x63 (this file's own
        // aes_sbox_fwd_rom[0]=0x63) -> every output byte 0x63.
        ALUCtl = `ALUCTL_AES64ES; A = 64'h0; B = 64'h0;
        #1 check(64'h6363636363636363, "aes64es(0,0): shiftrows(0)=0, sbox(0x00) per byte = 0x63");

        // aes64ks2 word-xor combine, no S-box: A=rs1=0x1111111122222222 (rs1[63:32]=0x11111111),
        // B=rs2=0x3333333344444444. w0=0x11111111^0x44444444=0x55555555; w1=w0^0x33333333=0x66666666
        ALUCtl = `ALUCTL_AES64KS2; A = 64'h1111111122222222; B = 64'h3333333344444444;
        #1 check(64'h6666666655555555, "aes64ks2: w1@w0 word-xor combine");

        // aes64ks1i, rnum=0xA: no rotate, rc=0 (aes_decode_rcon(0xA)=0). tmp1=A[63:32]=0 ->
        // subword(0)=0x63636363, xor 0 = 0x63636363, replicated.
        ALUCtl = `ALUCTL_AES64KS1I; A = 64'h0000000000000000; B = {60'b0, 4'hA};
        #1 check(64'h6363636363636363, "aes64ks1i(rnum=0xA, tmp1=0): no rotate, rc=0, subword(0)=0x63 x4");

        // aes64im: mixcolumn_inv of two zero words is zero.
        ALUCtl = `ALUCTL_AES64IM; A = 64'h0000000000000000;
        #1 check(64'h0000000000000000, "aes64im(0) = 0");

        // ---- Tier 2: full AES-128 encrypt, FIPS-197 Appendix C.1 vector ----
        // Plaintext=00112233445566778899aabbccddeeff, Key=000102030405060708090a0b0c0d0e0f,
        // expected Ciphertext=69c4e0d86a7b0430d8cdb78070b4c55a.
        //
        // Register-half convention (empirically verified against the real KAT via a
        // standalone Python model using these exact same functions before writing
        // this test -- see the design doc / ADR): plaintext/key column c (4 bytes,
        // little-endian within the 32-bit word) packs as st_lo={col1,col0},
        // st_hi={col3,col2} (col_(2k+1) in the HIGH 32 bits, col_2k in the LOW 32
        // bits of each half) -- same shape for the key's 4 words (w1,w0 in rk_lo;
        // w3,w2 in rk_hi).
        st_lo = 64'h7766554433221100;  // PT columns 0,1: {0x77665544, 0x33221100}
        st_hi = 64'hffeeddccbbaa9988;  // PT columns 2,3: {0xffeeddcc, 0xbbaa9988}
        rk_lo = 64'h0706050403020100;  // key words w1,w0: {0x07060504, 0x03020100}
        rk_hi = 64'h0f0e0d0c0b0a0908;  // key words w3,w2: {0x0f0e0d0c, 0x0b0a0908}

        // Initial AddRoundKey (round-0 key = the raw key itself).
        st_lo = st_lo ^ rk_lo;
        st_hi = st_hi ^ rk_hi;

        for (r = 1; r <= 10; r = r + 1) begin
            // Key schedule: aes64ks1i(rs1=rk_hi, rnum=r-1) -> RotWord+SubWord+Rcon(r) of
            // rk_hi's own top word (w3 of the previous round key), replicated both halves.
            aes_call(`ALUCTL_AES64KS1I, rk_hi, {60'b0, r[3:0]-4'h1}, t);
            // aes64ks2(rs1=t, rs2=rk_lo) -> new_rk_lo = {w1_new, w0_new} where
            // w0_new = t[63:32]^rk_lo[31:0], w1_new = w0_new^rk_lo[63:32].
            aes_call(`ALUCTL_AES64KS2, t, rk_lo, new_rk_lo);
            // aes64ks2(rs1=new_rk_lo, rs2=rk_hi) -> new_rk_hi, chaining off new_rk_lo's
            // own top half exactly like a real dependent instruction sequence would.
            aes_call(`ALUCTL_AES64KS2, new_rk_lo, rk_hi, new_rk_hi);
            rk_lo = new_rk_lo;
            rk_hi = new_rk_hi;

            // Cipher round: ShiftRows+SubBytes(+MixColumns except the final round).
            // Each call's own rs1 is the half being PRODUCED, rs2 is the other half --
            // aes64esm(rs1=st_lo,rs2=st_hi) yields the new low half, and the swapped
            // call yields the new high half.
            if (r < 10) begin
                aes_call(`ALUCTL_AES64ESM, st_lo, st_hi, new_lo);
                aes_call(`ALUCTL_AES64ESM, st_hi, st_lo, new_hi);
            end else begin
                aes_call(`ALUCTL_AES64ES, st_lo, st_hi, new_lo);
                aes_call(`ALUCTL_AES64ES, st_hi, st_lo, new_hi);
            end
            st_lo = new_lo ^ rk_lo;
            st_hi = new_hi ^ rk_hi;
        end

        // Ciphertext byte i = getbyte(st_lo,i) for i=0..7, getbyte(st_hi,i) for i=0..7 --
        // the SAME LSB-first-within-a-half convention used to load PT/KEY above (byte0
        // of each column sits at bits[7:0]). A plain {st_hi,st_lo} 128-bit concatenation
        // read as one big-endian hex number puts byte0 at the TOP, not the bottom -- so
        // the expected literal below is the real ciphertext 69c4e0d8...b4c55a with its
        // OWN byte order reversed to match that same getbyte convention, not a different
        // value. (Confirmed against a standalone Python model using these exact S-box/
        // rcon/mixcolumn/shiftrows functions before this test was written -- see the
        // design doc.)
        checks = checks + 1;
        if ({st_hi, st_lo} !== 128'h5ac5b47080b7cdd830047b6ad8e0c469) begin
            fails = fails + 1;
            $display("FAIL  AES-128 FIPS-197 C.1 KAT: got st_hi=%h st_lo=%h", st_hi, st_lo);
        end else
            $display("pass  AES-128 FIPS-197 C.1 KAT: ciphertext bytes (getbyte(lo,0..7),getbyte(hi,0..7)) = 69 c4 e0 d8 6a 7b 04 30 d8 cd b7 80 70 b4 c5 5a");

        if (fails == 0)
            $display("PASS  alu_zkne_zknd_unit (%0d checks)", checks);
        else
            $display("FAIL  alu_zkne_zknd_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
