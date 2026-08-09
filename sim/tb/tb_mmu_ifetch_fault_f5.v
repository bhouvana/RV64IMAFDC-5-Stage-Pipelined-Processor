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

// docs/adr/00NN-mmu-sv32.md (Phase F5). Instruction page fault -- see
// sim/programs/mmu_ifetch_fault_f5.s's own header: satp enabled with a
// deliberately empty page table, so a translated fetch attempt faults at
// the level-1 PDE itself (no level-0 walk needed). Confirms cause
// classification (mcause=12) and mtval (the faulting VA).
module tb_mmu_ifetch_fault_f5;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/mmu_ifetch_fault_f5.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #300;

        check_reg(11, 32'd12, "x11 = mcause in m_handler: 12 (MCAUSE_INSTRUCTION_PAGE_FAULT)");
        check_reg(13, 32'h00005000, "x13 = mtval in m_handler: 0x5000 (the faulting virtual address)");

        report("mmu_ifetch_fault_f5");
        $finish;
    end
endmodule
