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

// Ad hoc cycle-by-cycle trace tool, not a directed test (excluded from
// sim/run_tests.sh's tb_*.v glob on purpose). Point INIT_FILE and the
// $display arguments at whatever you're debugging; this is meant to be
// edited per-investigation, not run as-is. A precursor to the proper
// instruction-trace tooling in docs/ROADMAP.md Phase 8.
module trace_debug;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/store_load.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #150 $finish;
    end

    always @(posedge clk) begin
        if (start)
            $display("t=%0d | IF:pc=%0d inst=%h | ID:regWrite=%b ALUSrc=%b memRead=%b memWrite=%b | EX:memRead_regde=%b memWrite_regde=%b ALUOut=%0d rd1f=%0d rd2f=%0d immval=%0d | MEM:addr=%0d memWrite_regem=%b memRead_regem=%b wdata=%0d rdata=%0d | mem[16..19]=%b %b %b %b",
                $time, dut.pc_o, dut.inst_regfd, dut.regWrite, dut.ALUSrc, dut.memRead, dut.memWrite,
                dut.memRead_regde, dut.memWrite_regde, dut.ALUOut, dut.readData1_final, dut.readData2_final, dut.imm_reg_val,
                dut.ALUOut_regem, dut.memWrite_regem, dut.memRead_regem, dut.readData2_regem, dut.readData,
                dut.m_DataMemory.m_ram.data_memory[16], dut.m_DataMemory.m_ram.data_memory[17], dut.m_DataMemory.m_ram.data_memory[18], dut.m_DataMemory.m_ram.data_memory[19]);
    end
endmodule
