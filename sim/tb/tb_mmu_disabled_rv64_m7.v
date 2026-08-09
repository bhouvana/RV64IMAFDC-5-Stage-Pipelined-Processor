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

// Generation 2 (Phase M7, docs/adr/0028-rv64-migration-phase-m.md). See
// sim/programs/mmu_disabled_rv64_m7.s's own header for the full story --
// updated by docs/adr/00NN-sv39-mmu-phase-p.md (Phase P3): translate_enable
// is genuinely live at XLEN=64 now (the old hard XLEN==32 gate is gone),
// but this test's own satp pattern (MODE=1 at Sv32's old bit-31 position)
// still correctly decodes as satp_mode_w=0 (Bare) under Sv39's real
// bit[63:60] MODE field, so execution still proceeds untranslated here --
// now confirming the *decode* is correct (a non-Sv39-shaped pattern reads
// Bare) rather than an XLEN gate. Drops to U-mode via mret and confirms no
// page fault, no real Ptw walk, still lands in real U-mode -- ruling out
// "it only looks disabled because we stayed in M-mode", since M-mode
// already bypasses translation unconditionally regardless.
module tb_mmu_disabled_rv64_m7;
    reg clk = 0;
    reg start = 0;
    integer walk_count = 0;

    PIPELINED #(.INIT_FILE("sim/programs/mmu_disabled_rv64_m7.mem"), .XLEN(64))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (start && dut.gen_mmu_ptw_sv39.m_Ptw.done)
            walk_count = walk_count + 1;
    end

    initial begin
        start = 0;
        #10 start = 1;
        #500;

        check_reg(10, 32'd111, "x10 = 111: fetch landed at u_code untranslated (satp decodes Bare)");
        check_reg(11, 32'd777, "x11 = 777: value stored to the untranslated (== physical) address");
        check_reg(12, 32'd777, "x12 = 777: loaded back from the same untranslated address (round trip)");
        check_val(walk_count, 32'd0, "zero real Ptw.v walks -- satp_mode_w correctly reads 0 (Bare) for this non-Sv39-shaped pattern");
        check_val({30'b0, dut.m_CSR.priv_mode}, 32'd0, "priv_mode == PRIV_U: mret really dropped privilege, ruling out \"still M-mode, would bypass anyway\"");

        report("mmu_disabled_rv64_m7");
        $finish;
    end
endmodule
