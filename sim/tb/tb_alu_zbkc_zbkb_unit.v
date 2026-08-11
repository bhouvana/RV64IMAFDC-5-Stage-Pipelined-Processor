`include "ALU.v"

// Pillar K, Task 3. Direct ALU.v instantiation, XLEN=64 -- values chosen to
// be hand-checkable, matching tb_bext_b10.v's own "cheap cases hand-
// verified, expensive ones cross-checked against iss.py" split.
module tb_alu_zbkc_zbkb_unit;
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

    initial begin
        // clmul(0x3, 0x5): 3=0b11, 5=0b101 -> XOR of (3<<0) and (3<<2) = 0b011 ^ 0b1100 = 0b1111 = 0xF
        ALUCtl = `ALUCTL_CLMUL; A = 64'h3; B = 64'h5;
        #1 check(64'hF, "clmul(3,5) = (3<<0)^(3<<2) = 3^12 = 15");

        // clmulh(0x3, 0x5): no term reaches bit>=64 at this small scale -> 0
        ALUCtl = `ALUCTL_CLMULH; A = 64'h3; B = 64'h5;
        #1 check(64'h0, "clmulh(3,5) = 0 (no carry-out at this small scale)");

        // clmulh with a real carry: A=2 (bit1), B has only bit63 set -> term is
        // A<<63 = 2<<63 = bit64 set (truncates to 0 in clmul's own low half) and
        // clmulh contributes (A>>(64-63))=(2>>1)=1 at i=63.
        ALUCtl = `ALUCTL_CLMULH; A = 64'h2; B = 64'h8000000000000000;
        #1 check(64'h1, "clmulh(2, 1<<63) = 1 (real carry captured in the high half)");

        // pack(0x1122334455667788, 0xAABBCCDDEEFF0011): low 32 of rs1=0x55667788,
        // low 32 of rs2=0xEEFF0011 -> rd = {0xEEFF0011, 0x55667788}
        ALUCtl = `ALUCTL_PACK; wordOp = 0;
        A = 64'h1122334455667788; B = 64'hAABBCCDDEEFF0011;
        #1 check(64'hEEFF001155667788, "pack: low32(rs2)@low32(rs1)");

        // packw: low 16 of each -> sign-extended 32-bit result. low16(A)=0x7788,
        // low16(B)=0x0011 -> w32=0x00117788 (bit31=0, so zero-extends same as sign-extends here)
        ALUCtl = `ALUCTL_PACK; wordOp = 1;
        #1 check(64'h0000000000117788, "packw: low16(rs2)@low16(rs1), sign-extended");

        // packh(0x..88, 0x..11): low byte of A=0x88, low byte of B=0x11 -> {0x11,0x88}, zero-ext
        ALUCtl = `ALUCTL_PACKH; A = 64'h1122334455667788; B = 64'hAABBCCDDEEFF0011;
        #1 check(64'h0000000000001188, "packh: byte(rs2)@byte(rs1), zero-extended");

        // brev8(0x01): reverse bits within the single low byte -> 0b00000001 -> 0b10000000 = 0x80
        ALUCtl = `ALUCTL_BREV8; A = 64'h0000000000000001;
        #1 check(64'h0000000000000080, "brev8(0x01) = 0x80 (bit-reverse within byte 0)");

        // brev8 on two bytes: 0x0102 -> byte0=0x02(0b00000010->0b01000000=0x40),
        // byte1=0x01(0b00000001->0b10000000=0x80) -> 0x8040
        ALUCtl = `ALUCTL_BREV8; A = 64'h0000000000000102;
        #1 check(64'h0000000000008040, "brev8(0x0102) = 0x8040 (per-byte reverse, byte order unchanged)");

        if (fails == 0)
            $display("PASS  alu_zbkc_zbkb_unit (%0d checks)", checks);
        else
            $display("FAIL  alu_zbkc_zbkb_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
