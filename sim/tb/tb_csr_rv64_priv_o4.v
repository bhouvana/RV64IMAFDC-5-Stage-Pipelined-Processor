// Generation 3, Phase O (docs/adr/0031-sv39-privilege-csr-groundwork-phase-o.md).
// See sim/programs/csr_rv64_priv_o4.s's own header for the full story: the
// RV64/Sv39 CSR-side groundwork (mstatus.UXL/SXL fixed-2 read-mux override,
// satp's XLEN-conditional MODE/PPN decode) plus ordinary Bare-mode+U-mode
// untranslated execution once privilege genuinely drops via mret.
//
// docs/adr/00NN-sv39-mmu-phase-p.md (Phase P3) note: this test's satp
// program no longer restores a live-looking Sv39 pattern before the final
// section (see the .s file's own header) -- Phase O's "translate_enable
// stays force-disabled regardless" guarantee this test originally proved
// no longer holds once Phase P3 makes translate_enable genuinely live at
// XLEN=64. The walk_count/priv_mode checks below now confirm ordinary,
// unconditional Bare-mode behavior instead.
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

module tb_csr_rv64_priv_o4;
    reg clk = 0;
    reg start = 0;
    integer walk_count = 0;

    PIPELINED #(.INIT_FILE("sim/programs/csr_rv64_priv_o4.mem"), .XLEN(64))
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

        // mstatus: real low bits (MIE/MPIE/SIE/SPIE/SPP/MPP, all-1s write)
        // combined with the new fixed UXL(33:32)=2/SXL(35:34)=2 override.
        // Synchronize on x3 itself (rather than a fixed delay) since satp
        // -- checked next -- is deliberately overwritten several more
        // times later in this same program; satp_mode_w/satp_ppn_w must be
        // sampled while their defining write is still the *current* satp
        // value, not at some arbitrary later point.
        wait (dut.m_Register.regs[3] === 64'hA000019AA);
        check_reg(3, 64'hA000019AA, "x3 = mstatus readback: real low bits + fixed UXL/SXL=2");

        // satp storage is unmasked at full 64-bit width regardless of XLEN.
        // Sample satp_mode_w/satp_ppn_w the same cycle x7 becomes valid --
        // still well before the next satp-changing instruction.
        wait (dut.m_Register.regs[7] === 64'h8123400000000155);
        check_reg(7, 64'h8123400000000155, "x7 = satp readback: MODE=8/Sv39, ASID=0x1234, PPN=0x155, unmasked");
        check_val({63'b0, dut.satp_mode_w}, 32'd1, "satp_mode_w == 1: Sv39 MODE field (63:60==8) now decoded, not Sv32's old bit-31 read");
        check_val({10'b0, dut.satp_ppn_w}, 32'h155, "satp_ppn_w == 0x155: low 22 bits of the real 44-bit Sv39 PPN field");

        // Same field position, MODE=0 (Bare) -- decode tracks the actual
        // field, not a "satp is nonzero" heuristic. Sampled the same way.
        wait (dut.m_Register.regs[8] === 64'h0123400000000155);
        check_reg(8, 64'h0123400000000155, "x8 = satp readback: MODE forced to 0 (Bare), ASID/PPN unchanged");
        check_val({63'b0, dut.satp_mode_w}, 32'd0, "satp_mode_w == 0: MODE=0 (Bare) correctly decodes false");

        #300;

        // Phase P3: satp is genuinely Bare (MODE=0) here (see the .s file's
        // own header for why this program no longer restores a live-looking
        // Sv39 pattern first) and privilege has dropped to U -- fetch/
        // store/load below proceed untranslated and zero real Ptw walks
        // occur, ordinary unconditional Bare-mode behavior.
        check_reg(11, 32'd222, "x11 = 222: fetch landed at u_code untranslated (Bare mode)");
        check_reg(13, 32'd999, "x13 = 999: value stored to the untranslated (== physical) address");
        check_reg(14, 32'd999, "x14 = 999: loaded back from the same untranslated address (round trip)");
        check_val(walk_count, 32'd0, "zero real Ptw walks -- satp.MODE=Bare, translation genuinely inactive");
        check_val({30'b0, dut.m_CSR.priv_mode}, 32'd0, "priv_mode == PRIV_U: mret really dropped privilege, ruling out \"still M-mode, would bypass anyway\"");

        report("csr_rv64_priv_o4");
        $finish;
    end
endmodule
