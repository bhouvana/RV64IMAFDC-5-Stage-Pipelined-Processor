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

module tb_bltu_bgeu;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/bltu_bgeu.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #800;

        check_reg(3,  32'd1, "bltu not taken (0xFFFFFFFF unsigned is not < 1)");
        check_reg(4,  32'd1, "bgeu taken (0xFFFFFFFF unsigned is >= 1)");
        check_reg(7,  32'd1, "blt taken (-1 signed < 1) -- docs/adr/0004 regression");
        check_reg(8,  32'd1, "bge not taken (-1 signed is not >= 1) -- docs/adr/0004 regression");
        check_reg(9,  32'd1, "ble taken (-1 signed <= 1, custom op) -- docs/adr/0004 regression");
        check_reg(10, 32'd1, "bgt not taken (-1 signed is not > 1, custom op) -- docs/adr/0004 regression");

        report("bltu_bgeu");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
