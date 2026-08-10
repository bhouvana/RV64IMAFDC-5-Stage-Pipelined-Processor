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

module tb_muldiv;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/muldiv.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        // 6 real (non-shortcut) divisions in this program at ~33 cycles each
        // (docs/adr/0009-multicycle-divider.md) plus the surrounding setup
        // instructions -- division is no longer single-cycle, so this needs
        // far more margin than the other directed tests.
        #5000;

        check_reg(3,  32'd42,        "mul x3,x1,x2 = 6*7");
        check_reg(5,  32'd1,         "mul(-1,-1) low32");
        check_reg(6,  32'd0,         "mulh(-1,-1) signed upper");
        check_reg(7,  32'hFFFFFFFE,  "mulhu(-1,-1) unsigned upper");
        check_reg(8,  32'hFFFFFFFF,  "mulhsu(-1,-1) upper");
        check_reg(11, 32'd3,         "div(17,5)");
        check_reg(12, 32'd2,         "rem(17,5)");
        check_reg(13, 32'd3,         "divu(17,5)");
        check_reg(14, 32'd2,         "remu(17,5)");
        check_reg(17, 32'hFFFFFFFD,  "div(-7,2) truncates toward zero -> -3");
        check_reg(18, 32'hFFFFFFFF,  "rem(-7,2) -> -1");
        check_reg(21, 32'hFFFFFFFF,  "div by zero -> -1");
        check_reg(22, 32'd5,         "rem by zero -> dividend");
        check_reg(23, 32'hFFFFFFFF,  "divu by zero -> -1");
        check_reg(24, 32'd5,         "remu by zero -> dividend");
        check_reg(27, 32'h80000000,  "div signed overflow (INT_MIN/-1) -> INT_MIN");
        check_reg(28, 32'd0,         "rem signed overflow -> 0");

        report("muldiv");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
