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

module tb_illegal_instr;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/illegal_instr.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #300;

        check_reg(9, 32'd0,   "x9 never written: both addi's after the trap were redirected away");
        check_reg(10, 32'd77, "x10=77: the handler at mtvec ran");
        check_val(dut.m_CSR.mepc, 32'd8,   "mepc = the trapping instruction's own address");
        check_val(dut.m_CSR.mcause, 32'd2, "mcause = 2 (illegal instruction)");
        check_val(dut.m_CSR.mtvec, 32'd20, "mtvec unchanged from setup");

        report("illegal_instr");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
