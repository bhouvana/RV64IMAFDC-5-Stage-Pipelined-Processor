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

// docs/adr/0020-soc-integration.md (Phase D7, updated for D8): mie/mip's
// CSR-only plumbing -- masking (only MTIE/MEIE survive a write to mie),
// csrrw-replaces-vs-csrrs-ORs semantics against a real bit-position pair
// spread across the 32-bit register (not adjacent low bits, unlike
// mscratch's own tb_csr_ops.v coverage), and (updated for Phase F1) mip's
// mixed read-only-hardware/software-writable behavior: MTIP/MEIP stay
// hardware-driven and read-only exactly as through Phase E, but SSIP/STIP/
// SEIP are now real, software-writable storage (see the check below). No
// live interrupt *redirect* exists yet (D9) -- but as of D8,
// mip.MTIP is real, live-wired hardware state from Timer.v, which is
// pending from reset onward here (this program never touches MTIMECMP,
// and Timer.v resets with mtime=0/mtimecmp=0, so 0>=0 immediately) --
// see the mip checks below for the exact expected pattern.
module tb_mie_mip_csr;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/mie_mip_csr.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #300;

        // docs/adr/00NN-mmu-sv32.md (Phase F1): 0x7f (bits 0-6) now
        // includes real bits that didn't exist through Phase E -- SSIE@1/
        // STIE@5 (Phase F), plus MSIE@3 (docs/adr/0034, Phase R) -- so this
        // write no longer masks to entirely 0. MTIE@7/SEIE@9/MEIE@11 (the
        // bits 0x7f doesn't reach) still don't survive, confirming the
        // mask boundary is exactly right, not simply wider than before.
        check_reg(2, 32'h00000000, "csrrw x2,mie,0x7f: x2 = old mie (0)");
        check_reg(3, 32'h0000002A, "mie reads back 0x2a -- SSIE@1/MSIE@3/STIE@5 survived, nothing above bit6 did");

        check_reg(4, 32'h0000002A, "csrrw x4,mie,0x80: x4 = old mie (0x2a from the previous csrrw)");
        check_reg(5, 32'h00000080, "mie reads back 0x80 -- csrrw REPLACED (0x22 is gone), MTIE alone survived");

        check_reg(6, 32'h00000080, "csrrw x6,mie,0x800: x6 = old mie (0x80)");
        check_reg(7, 32'h00000800, "mie reads back 0x800 -- csrrw REPLACED, MTIE dropped");

        check_reg(8, 32'h00000800, "csrrs x8,mie,0x80: x8 = old mie (0x800)");
        check_reg(9, 32'h00000880, "mie reads back 0x880 -- csrrs ORed, MTIE and MEIE both set");

        // docs/adr/0020-soc-integration.md (Phase D8): mip.MTIP now
        // reflects Timer.v's real, live `pending` output -- Timer.v resets
        // with mtime=0/mtimecmp=0, so pending (mtime >= mtimecmp) is true
        // from the very first cycle onward (this program never touches
        // MTIMECMP), matching tb_timer_unit.v's own "reset: pending true
        // immediately" finding. mip.MEIP (UART) stays 0 -- nothing in this
        // program touches the UART. 0x80 = MTIP alone.
        check_reg(10, 32'h00000080, "mip reads 0x80 (MTIP live-pending from Timer.v since reset) before any write attempt");
        check_reg(11, 32'h00000080, "csrrw x11,mip,0x7ff: x11 = old mip (0x80)");
        // docs/adr/00NN-mmu-sv32.md (Phase F1): MTIP/MEIP (bits 7/11) stay
        // hardware-driven, read-only exactly as before -- but SSIP/STIP/
        // SEIP (bits 1/5/9) are now genuine, software-writable storage
        // (mip_sw in CSR.v), per the real spec's own convention that these
        // three specific mip bits are software-settable even though
        // MTIP/MEIP are not. 0x7ff has bits 0-10 all set, so bits 1/5/9
        // survive into mip_sw (0x222); MTIP (0x80, still live-pending)
        // ORs in on top -- 0x222 | 0x80 = 0x2a2. This is a real, deliberate
        // behavior change from before Phase F, not a regression: mip was
        // never meant to be entirely read-only, only its two
        // hardware-sourced bits are.
        check_reg(12, 32'h000002a2, "mip reads 0x2a2 -- SSIP/STIP/SEIP (Phase F, software-writable) took 0x7ff's bits 1/5/9, live MTIP (0x80) unaffected");

        report("mie_mip_csr");
        $finish;
    end
endmodule
