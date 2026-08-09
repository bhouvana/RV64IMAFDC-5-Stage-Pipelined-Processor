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

// docs/adr/00NN-mmu-sv32.md (Phase F5). Happy-path integration test -- see
// sim/programs/mmu_translate_f5.s's own header for the full story: a real
// 2-level Sv32 walk on fetch, then D-side store/load through a separate
// mapping, all while running as translated U-mode code. MEM_SIZE_BYTES is
// overridden (a real Sv32 page table needs more room than the 128-byte
// default -- mirrors docs/adr/0020 D10's own "scale memory up" precedent).
// A background always-block taps m_Ptw.done directly to count real walks
// -- exactly 2 expected (one I-side, one D-side); anything more would mean
// the TLB isn't actually being reused across repeated fetches/accesses.
module tb_mmu_translate_f5;
    reg clk = 0;
    reg start = 0;
    integer walk_count = 0;

    PIPELINED #(.INIT_FILE("sim/programs/mmu_translate_f5.mem"), .MEM_SIZE_BYTES(16384))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (start && dut.gen_mmu_ptw_sv32.m_Ptw.done)
            walk_count = walk_count + 1;
    end

    initial begin
        start = 0;
        #10 start = 1;
        #500;

        check_reg(10, 32'd111, "x10 = 111: fetch translation landed at u_code (VA 0x5048 -> PA 72)");
        check_reg(11, 32'd777, "x11 = 777: the value stored through the D-side translated address");
        check_reg(12, 32'd777, "x12 = 777: loaded back through the SAME D-side translation (round trip)");
        check_val(walk_count, 32'd2, "exactly 2 real Ptw.v walks occurred (1 I-side + 1 D-side) -- every repeated fetch/access after the first hit the TLB, no re-walk");

        report("mmu_translate_f5");
        $finish;
    end
endmodule
