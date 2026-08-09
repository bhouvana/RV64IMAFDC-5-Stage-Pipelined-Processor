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

// docs/adr/00NN-mmu-sv32.md (Phase F5). Closes a real gap this phase's own
// hand-trace found in F3's csr_priv_violation logic -- see
// sim/programs/mmu_csr_leak_f5.s's own header for the full story: a
// U-mode csrrs on an M-only CSR (mscratch) must trap AND must never let
// rd (x10) actually receive the CSR's real value. No MMU/satp involvement
// -- this is a pure privilege-check gap, independent of translation.
module tb_mmu_csr_leak_f5;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/mmu_csr_leak_f5.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #300;

        check_reg(10, 32'd0, "x10 = 0: the privilege-violating csrrs never actually wrote mscratch's real value (999) to rd");
        check_reg(11, 32'd2, "x11 = mcause in m_handler: 2 (MCAUSE_ILLEGAL_INSTRUCTION) -- the violation correctly trapped");

        report("mmu_csr_leak_f5");
        $finish;
    end
endmodule
