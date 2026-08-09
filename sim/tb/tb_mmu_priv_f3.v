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
`include "reg1a.v"
`include "reg2.v"
`include "reg3.v"
`include "reg4.v"
`include "Hazard.v"
`include "HazardNoForward.v"
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
`include "Bht.v"
`include "Btb.v"

// docs/adr/00NN-mmu-sv32.md (Phase F3). End-to-end privilege-aware trap
// integration test -- see sim/programs/mmu_priv_f3.s's own header for the
// full story: M sets up delegation, drops to U via mret, a U-mode ecall is
// correctly delegated to S, and an illegal mret attempted from S correctly
// traps back to M as an ordinary (undelegated) illegal-instruction
// exception. This is the real, integrated behavior F1-F3 together exist
// to deliver -- M-mode-only behavior (every pre-Phase-F test) stays
// bit-exact since mideleg/medeleg default to 0 and nothing else in this
// program's own path ever executes below M except deliberately.
module tb_mmu_priv_f3;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/mmu_priv_f3.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #400;

        check_reg(20, 32'd8, "x20 = scause in s_handler: 8 (MCAUSE_ECALL_FROM_U) -- ecall-from-U correctly delegated to S");
        check_reg(21, 32'd2, "x21 = mcause in m_handler2: 2 (MCAUSE_ILLEGAL_INSTRUCTION) -- mret-from-S correctly trapped, undelegated");
        check_reg(22, 32'h00000800, "x22 = mstatus in m_handler2: MPP=S (0x800 at bits[12:11]) -- previous privilege (S) correctly recorded");

        report("mmu_priv_f3");
        $finish;
    end
endmodule
