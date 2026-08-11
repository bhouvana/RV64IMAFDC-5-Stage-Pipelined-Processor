`include "riscvpipeline.v"
`include "Scoreboard.v"
`include "MemoryController.v"
`include "CompressedExpander.v"
`include "PC.v"
`include "Adder.v"
`include "ALU.v"
`include "ALUCtrl.v"
`include "Control.v"
`include "DataMemoryBRAM.v"
`include "ImmGen.v"
`include "InstructionMemory.v"
`include "Mux2to1.v"
`include "Mux4to1.v"
`include "MuxN.v"
`include "FRegister.v"
`include "FALU.v"
`include "FDivider.v"
`include "FSqrt.v"
`include "FMADDUnit.v"
`include "Register.v"
`include "ShiftLeftOne.v"
`include "reg1.v"
`include "reg2.v"
`include "reg3.v"
`include "reg4.v"
`include "Hazard.v"
`include "Forward.v"
`include "FForward.v"
`include "Divider.v"
`include "CSR.v"
`include "WbDecoder.v"
`include "RamWishboneAdapter.v"
`include "Uart.v"
`include "Timer.v"
`include "Tlb.v"
`include "Ptw.v"
`include "Tlb39.v"
`include "Ptw39.v"

// Generation 7, Pillar B (Gen7-B10, docs/adr/0060). Directed B-extension
// (Zba+Zbb+Zbs) coverage through the scalar in-order core, XLEN=64. Expected
// values cross-checked against sim/tools/iss.py's own B-ext handlers, not
// hand-multiplied alone -- see sim/programs/bext_b10.s's own header.
module tb_bext_b10;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/bext_b10.mem"), .XLEN(64))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #800;

        check_reg(10, 64'h0000000000000004, "andn x10,x1,x2 = 5 & ~3 = 4");
        check_reg(11, 64'hFFFFFFFFFFFFFFFD, "orn x11,x1,x2 = 5 | ~3");
        check_reg(12, 64'hFFFFFFFFFFFFFFF9, "xnor x12,x1,x2 = ~(5^3)");
        check_reg(13, 64'h0000000000000003, "min x13,x1,x2 = min(5,3) = 3");
        check_reg(14, 64'h0000000000000005, "max x14,x1,x2 = max(5,3) = 5");
        check_reg(15, 64'h0000000000000003, "minu x15,x1,x2 = minu(5,3) = 3");
        check_reg(18, 64'h0000000000000005, "maxu x18,x1,x2 = maxu(5,3) = 5");
        check_reg(19, 64'h0000000000000028, "rol x19,x1,x2 = rotl(5,3) = 40");
        check_reg(20, 64'hA000000000000000, "ror x20,x1,x2 = rotr(5,3)");
        check_reg(21, 64'h000000000000000D, "sh1add x21,x1,x2 = (5<<1)+3 = 13");
        check_reg(22, 64'h0000000000000017, "sh2add x22,x1,x2 = (5<<2)+3 = 23");
        check_reg(23, 64'h000000000000002B, "sh3add x23,x1,x2 = (5<<3)+3 = 43");
        check_reg(24, 64'h0000000000000007, "bclr x24,x16,x2 = 15 & ~(1<<3) = 7");
        check_reg(25, 64'h0000000000000001, "bext x25,x16,x2 = (15>>3)&1 = 1");
        check_reg(26, 64'h0000000000000007, "binv x26,x16,x2 = 15 ^ (1<<3) = 7");
        check_reg(27, 64'h0000000000000023, "bset x27,x2,x1 = 3 | (1<<5) = 35");
        check_reg(29, 64'h0000000000000001, "bexti x29,x16,3 = (15>>3)&1 = 1");
        check_reg(3,  64'h4000000000000001, "rori x3,x1,2 = rotr(5,2)");
        check_reg(4,  64'h000000000000003D, "clz x4,x1 = clz(5) = 61");
        check_reg(5,  64'h0000000000000000, "ctz x5,x1 = ctz(5) = 0");
        check_reg(6,  64'h0000000000000002, "cpop x6,x1 = popcount(5) = 2");
        check_reg(7,  64'h000000000000000F, "sext.b x7,x16 = sign-extend byte(15) = 15");
        check_reg(8,  64'h000000000000000F, "sext.h x8,x16 = sign-extend halfword(15) = 15");
        check_reg(9,  64'h00000000000000FF, "orc.b x9,x1 = orc.b(5): lowest byte nonzero -> 0xFF");
        check_reg(28, 64'h00EFF0F0FFFFFFFF, "rev8 x28,x17 = byte-reverse(0xFFFFFFFFF0F0EF00)");

        report("bext_b10");
        $finish;
    end
endmodule
