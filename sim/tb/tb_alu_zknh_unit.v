`include "ALU.v"

// Pillar K, Task 4. sigma/sum functions are pure fixed-rotate XORs -- easiest
// to hand-verify with A=0 (every term is 0, trivial) and A=all-ones (every
// rotate of all-ones is still all-ones, so sig0/sig1's XOR-of-3-rotates
// collapses predictably: sum0/sum1 XOR three all-ones 32-bit rotates =
// all-ones (odd number of terms XORed) for the sum* ops; sig0/sig1 XOR two
// rotates (still all-ones) with a *shift* (not rotate) of all-ones, which is
// NOT all-ones -- hand-computable per case below.
module tb_alu_zknh_unit;
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
        // A=0 -> every sigma/sum is 0 for every op (rotate/shift of 0 is always 0).
        A = 64'h0;
        ALUCtl = `ALUCTL_SHA256SUM0; #1 check(64'h0, "sha256sum0(0)=0");
        ALUCtl = `ALUCTL_SHA256SUM1; #1 check(64'h0, "sha256sum1(0)=0");
        ALUCtl = `ALUCTL_SHA256SIG0; #1 check(64'h0, "sha256sig0(0)=0");
        ALUCtl = `ALUCTL_SHA256SIG1; #1 check(64'h0, "sha256sig1(0)=0");
        ALUCtl = `ALUCTL_SHA512SUM0; #1 check(64'h0, "sha512sum0(0)=0");
        ALUCtl = `ALUCTL_SHA512SUM1; #1 check(64'h0, "sha512sum1(0)=0");
        ALUCtl = `ALUCTL_SHA512SIG0; #1 check(64'h0, "sha512sig0(0)=0");
        ALUCtl = `ALUCTL_SHA512SIG1; #1 check(64'h0, "sha512sig1(0)=0");

        // A=all-ones (32-bit view). sum0/sum1: XOR of 3 rotates of 0xFFFFFFFF, each still
        // 0xFFFFFFFF -- XOR of 3 identical all-ones values = all-ones (odd count).
        A = 64'hFFFFFFFF;
        ALUCtl = `ALUCTL_SHA256SUM0; #1 check(64'hFFFFFFFFFFFFFFFF, "sha256sum0(-1) = -1 (odd XOR of all-ones rotates), sign-extended");
        ALUCtl = `ALUCTL_SHA256SUM1; #1 check(64'hFFFFFFFFFFFFFFFF, "sha256sum1(-1) = -1");

        // sig0(-1) = rotr7(-1) ^ rotr18(-1) ^ (-1>>3, LOGICAL shift, top 3 bits become 0)
        // = 0xFFFFFFFF ^ 0xFFFFFFFF ^ 0x1FFFFFFF = 0x1FFFFFFF (first two cancel to 0)
        ALUCtl = `ALUCTL_SHA256SIG0; #1 check(64'h000000001FFFFFFF, "sha256sig0(-1) = 0x1FFFFFFF (two rotates cancel, logical shift remains)");
        // sig1(-1) = rotr17(-1) ^ rotr19(-1) ^ (-1>>10) = 0 ^ 0x003FFFFF = 0x003FFFFF
        ALUCtl = `ALUCTL_SHA256SIG1; #1 check(64'h00000000003FFFFF, "sha256sig1(-1) = 0x3FFFFF");

        A = 64'hFFFFFFFFFFFFFFFF;
        ALUCtl = `ALUCTL_SHA512SUM0; #1 check(64'hFFFFFFFFFFFFFFFF, "sha512sum0(-1) = -1 (odd XOR of all-ones rotates)");
        ALUCtl = `ALUCTL_SHA512SUM1; #1 check(64'hFFFFFFFFFFFFFFFF, "sha512sum1(-1) = -1");
        // sig0(-1) = rotr1(-1) ^ rotr8(-1) ^ (-1>>7) = 0 ^ (64'hFFFFFFFFFFFFFFFF>>7)
        ALUCtl = `ALUCTL_SHA512SIG0; #1 check(64'h01FFFFFFFFFFFFFF, "sha512sig0(-1) = -1>>7 (rotates cancel)");
        ALUCtl = `ALUCTL_SHA512SIG1; #1 check(64'h03FFFFFFFFFFFFFF, "sha512sig1(-1) = -1>>6 (rotates cancel)");

        if (fails == 0)
            $display("PASS  alu_zknh_unit (%0d checks)", checks);
        else
            $display("FAIL  alu_zknh_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
