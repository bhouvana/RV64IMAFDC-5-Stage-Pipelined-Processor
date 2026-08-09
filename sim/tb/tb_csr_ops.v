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

module tb_csr_ops;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/csr_ops.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #300;

        check_reg(2, 32'd0,   "csrrw x2,mscratch,x1: x2 = old mscratch (0)");
        check_reg(3, 32'd5,   "csrrs x3,mscratch,x0: x3 = old mscratch (5), src=0 so no change");
        check_reg(5, 32'd5,   "csrrs x5,mscratch,x4: x5 = old mscratch (5)");
        check_reg(7, 32'd7,   "csrrc x7,mscratch,x6: x7 = old mscratch (7)");
        check_reg(8, 32'd6,   "csrrwi x8,mscratch,10: x8 = old mscratch (6)");
        check_reg(9, 32'd10,  "csrrsi x9,mscratch,5: x9 = old mscratch (10)");
        check_reg(10, 32'd15, "csrrci x10,mscratch,2: x10 = old mscratch (15)");
        check_val(dut.m_CSR.mscratch, 32'd13, "final mscratch = 15 & ~2 = 13");

        report("csr_ops");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
