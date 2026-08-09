`include "riscvpipeline.v"
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

// Generation 2 (Phase M8, docs/adr/0028-rv64-migration-phase-m.md). See
// sim/programs/rv64_wordops_m8.s's own header for the full story: every new
// RV64-only instruction exercised end to end through the real assembled
// pipeline at XLEN=64. x9 vs x11 (sllw vs plain sll on identical operands)
// is the key check -- they must differ, proving wordOp_regde really
// changes the ALU's behavior rather than merely decoding without effect.
module tb_rv64_wordops_m8;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/rv64_wordops_m8.mem"), .XLEN(64))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        // Four divide-family instructions (divw/divuw/remw/remuw), each
        // costing a full XLEN=64-cycle Divider.v iteration regardless of
        // operand magnitude (docs/adr/0009) -- 4*64=256 cycles just for
        // those, plus ~21 ordinary single-cycle instructions and pipeline
        // fill/drain. #400 (40 cycles) was nowhere near enough, silently
        // caught mid-divide the first time this ran (found by tracing
        // div_busy directly, not by guessing).
        #3000;

        check_reg(3,  64'hFFFFFFFFFFFFFFFF, "addiw: low32(-2)+1 = -1, sign-extended");
        check_reg(4,  64'hFFFFFFFFFFFFFFE0, "slliw: low32(-2)<<4 = 0xFFFFFFE0, sign-extended");
        check_reg(5,  64'h000000000FFFFFFF, "srliw: low32(-2)>>4 logical = 0x0FFFFFFF, zero-extended (bit31=0)");
        check_reg(6,  64'hFFFFFFFFFFFFFFFF, "sraiw: low32(-2)>>>4 arithmetic = -1, sign-extended");
        check_reg(7,  64'hFFFFFFFFFFFFFFFF, "addw: low32(-2)+low32(1) = -1, sign-extended");
        check_reg(8,  64'h0000000000000002, "subw: 0-low32(-2) = 2, zero-extended");
        check_reg(9,  64'hFFFFFFFF80000000, "sllw: low32(1)<<31 = 0x80000000, sign-extended (negative)");
        check_reg(11, 64'h0000000080000000, "plain sll (not w): 1<<31 = 0x80000000 at full 64-bit width, positive -- MUST differ from x9");
        check_reg(12, 64'h0000000000000001, "srlw: low32(-2)>>31 logical = 1, zero-extended");
        check_reg(13, 64'hFFFFFFFFFFFFFFFF, "sraw: low32(-2)>>>31 arithmetic = -1, sign-extended");
        check_reg(14, 64'hFFFFFFFFFFFFFFFE, "mulw: low32(-2)*low32(1) = -2, sign-extended");
        check_reg(15, 64'h0000000000000000, "divw: signed -2/3 (round toward zero) = 0");
        check_reg(16, 64'h0000000055555554, "divuw: unsigned 0xFFFFFFFE/3 = 1431655764 (0x55555554)");
        check_reg(17, 64'hFFFFFFFFFFFFFFFE, "remw: signed -2 rem 3 = -2, sign-extended");
        check_reg(18, 64'h0000000000000002, "remuw: unsigned 0xFFFFFFFE rem 3 = 2");
        check_reg(27, 64'hFFFFFFFFFFFFFFFE, "ld: reads back the full 64-bit stored value (-2)");
        check_reg(28, 64'h00000000FFFFFFFE, "lwu: reads back only the low 32 bits, zero-extended -- differs from x27");

        report("rv64_wordops_m8");
        $finish;
    end
endmodule
