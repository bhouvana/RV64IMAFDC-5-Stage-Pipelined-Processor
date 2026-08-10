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

module tb_jalr;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/jalr_test.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #800;

        check_reg(1, 32'd8,  "jalr link value: x1 = PC(4)+4");
        check_reg(6, 32'd0,  "poisons squashed: x6 never written");
        check_reg(3, 32'd16, "EX/MEM forward of jalr result: x3=x1+x1=16");

        report("jalr");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
