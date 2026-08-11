`include "ALU.v"

// Pillar K, Task 5.
module tb_alu_zbkx_unit;
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
        // A = 16 nibbles, value at nibble i is i (A = 0xFEDCBA9876543210).
        ALUCtl = `ALUCTL_XPERM4;
        A = 64'hFEDCBA9876543210;
        B = 64'h0000000000000000;  // every nibble of B selects nibble 0 of A -> every result nibble = A's nibble0 = 0
        #1 check(64'h0000000000000000, "xperm4 all-select-nibble0 -> every output nibble = A[3:0] = 0");
        B = 64'h1111111111111111;  // every nibble selects nibble1 of A = 1
        #1 check(64'h1111111111111111, "xperm4 all-select-nibble1 -> every output nibble = A[7:4] = 1");
        B = 64'hFEDCBA9876543210;  // identity permutation
        #1 check(64'hFEDCBA9876543210, "xperm4 identity permutation");

        // xperm8: A = 8 bytes, byte i = i (A = 0x0706050403020100). B picks byte0 -> 0x00 everywhere;
        // out-of-range byte index (>=8, e.g. 0xFF) -> 0.
        ALUCtl = `ALUCTL_XPERM8;
        A = 64'h0706050403020100;
        B = 64'h0000000000000000;
        #1 check(64'h0000000000000000, "xperm8 all-select-byte0 -> every output byte = A[7:0] = 0x00");
        B = 64'hFFFFFFFFFFFFFFFF;  // every byte index = 0xFF, out of range (>=8) -> 0
        #1 check(64'h0000000000000000, "xperm8 out-of-range index (0xFF >= 8) -> 0");
        B = 64'h0706050403020100;  // identity permutation
        #1 check(64'h0706050403020100, "xperm8 identity permutation");

        if (fails == 0)
            $display("PASS  alu_zbkx_unit (%0d checks)", checks);
        else
            $display("FAIL  alu_zbkx_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
