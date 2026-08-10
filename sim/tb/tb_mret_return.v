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

module tb_mret_return;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/mret_return.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #400;

        check_reg(9, 32'd222,  "x9=222: execution resumed after ecall via mret, both post-return addi's ran");
        check_reg(11, 32'd55,  "x11=55: the trap handler ran");
        check_val(dut.m_CSR.mepc, 32'd16,    "mepc = 16: handler advanced it past the ecall before mret");
        check_val(dut.m_CSR.mcause, 32'd11,  "mcause = 11 (ECALL_FROM_M), still latched after mret");
        check_val(dut.m_CSR.mtvec, 32'd28,   "mtvec unchanged from setup");
        check_val(dut.m_CSR.mstatus, 32'h88, "mstatus: MIE(bit3)=1 restored from MPIE, MPIE(bit7)=1 set by mret");

        report("mret_return");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
