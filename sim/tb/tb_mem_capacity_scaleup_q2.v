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

// Phase Q (docs/adr/0033-memory-capacity-scale-up-phase-q.md). Standalone
// (not one of the generic run_random_tests.py templates -- this needs a
// non-default MEM_SIZE_BYTES), no MMU (satp stays at its Bare reset
// default, so translate_enable never engages -- MMU+large-memory
// interaction beyond the kept-as-is 20-bit PPN truncation's own arithmetic
// is a deliberately out-of-scope check this phase, see the ADR).
module tb_mem_capacity_scaleup_q2;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/mem_capacity_scaleup_q2.mem"),
                .MEM_SIZE_BYTES(67108864), .XLEN(64))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #600;

        check_reg(3, 64'h0000000000000064, "baseline lw near address 0: 100");
        check_reg(4, 64'hFFFFFFFFFFFFFCF7, "ld at MEM_SIZE_BYTES-8 (top of 64MB region): -777");
        check_mem_word(0, 32'h00000064, "baseline mem[0] low word: 100");
        check_mem_word(67108856, 32'hFFFFFCF7, "mem[MEM_SIZE_BYTES-8] low word: low32(-777)");

        report("mem_capacity_scaleup_q2");
        $finish;
    end
endmodule
