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

// docs/adr/00NN-mmu-sv32.md (Phase F1). Directed test for CSR.v's new
// privilege-mode/Sv32 storage -- see sim/programs/mmu_csr_f1.s's own header
// for the full story. Pure storage as of F1: no trap/mret/redirect
// interaction yet (that's F3), just read/write/masking correctness for
// every new register.
module tb_mmu_csr_f1;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/mmu_csr_f1.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #500;

        // mstatus: writing all-1s sets every real bit -- MIE@3/MPIE@7
        // (docs/adr/0011) plus SIE@1/SPIE@5/SPP@8/MPP@12:11 (Phase F).
        check_reg(2, 32'h00000000, "csrrw x2,mstatus,-1: x2 = old mstatus (0)");
        check_reg(3, 32'h000019AA, "mstatus readback: MIE/MPIE/SIE/SPIE/SPP/MPP all set (0x19aa)");

        // sstatus: a write through it must ONLY affect SIE/SPIE/SPP.
        check_reg(4, 32'h00000122, "csrrw x4,sstatus,0: x4 = old sstatus view (SIE/SPIE/SPP, 0x122)");
        check_reg(5, 32'h00001888, "mstatus readback: MIE/MPIE/MPP untouched (0x1888), SIE/SPIE/SPP cleared");
        check_reg(6, 32'h00000000, "sstatus readback: 0 (the clear took)");

        // mie: writing all-1s sets every real bit -- MTIE@7/MEIE@11
        // (docs/adr/0020), MSIE@3 (docs/adr/0034, Phase R), plus
        // SSIE@1/STIE@5/SEIE@9 (Phase F).
        check_reg(7, 32'h00000000, "csrrw x7,mie,-1: x7 = old mie (0)");
        check_reg(8, 32'h00000AAA, "mie readback: MSIE/MTIE/MEIE/SSIE/STIE/SEIE all set (0xaaa)");

        // sie: same restricted-view relationship as sstatus/mstatus (MSIE
        // is machine-only, no S-level view, so it's untouched by the sie
        // write below, same as MTIE/MEIE).
        check_reg(9, 32'h00000222, "csrrw x9,sie,0: x9 = old sie view (SSIE/STIE/SEIE, 0x222)");
        check_reg(10, 32'h00000888, "mie readback: MSIE/MTIE/MEIE untouched (0x888), SSIE/STIE/SEIE cleared");
        check_reg(11, 32'h00000000, "sie readback: 0 (the clear took)");

        // sip/mip: SSIP/STIP/SEIP are genuinely shared, software-writable
        // storage; MTIP/MEIP stay hardware-only and outside sip's view.
        // MTIP itself reads 0 here (not the usual reset-pending 0x80) --
        // this program's own setup deliberately disabled the timer first
        // (see mmu_csr_f1.s's own header) to avoid a real interrupt firing
        // partway through this test once MIE/MTIE got set above.
        check_reg(12, 32'h00000000, "csrrw x12,sip,-1: x12 = old sip view (0, reset default)");
        check_reg(13, 32'h00000222, "mip readback: SSIP/STIP/SEIP (0x222), MTIP now 0 (timer deliberately disabled)");
        check_reg(14, 32'h00000222, "sip readback: SSIP/STIP/SEIP only (0x222), MTIP not in this view regardless");

        // Plain, unmasked round-trip storage -- representative sample
        // (stvec/sepc/satp); sscratch/scause/stval/mtval share the exact
        // same code shape in CSR.v, not independently re-tested here (see
        // mmu_csr_f1.s's own header for why -- the 32-instruction ceiling).
        check_reg(15, 32'h00000000, "csrrw x15,stvec,-1: x15 = old stvec (0)");
        check_reg(16, 32'hFFFFFFFF, "stvec readback: unmasked, all bits survive");
        check_reg(17, 32'h00000000, "csrrw x17,sepc,-1: x17 = old sepc (0)");
        check_reg(18, 32'hFFFFFFFF, "sepc readback: unmasked, all bits survive");
        check_reg(19, 32'h00000000, "csrrw x19,satp,-1: x19 = old satp (0)");
        check_reg(20, 32'hFFFFFFFF, "satp readback: unmasked, all bits survive");

        // mideleg/medeleg: only this core's own real cause bits survive.
        check_reg(21, 32'h00000AAA, "mideleg readback: SSIE/STIE/MSIE/MTIE/SEIE/MEIE bits only (0xaaa)");
        check_reg(22, 32'h0000BB0C, "medeleg readback: illegal/breakpoint/ecall-U/S/M/page-fault bits only (0xbb0c)");

        report("mmu_csr_f1");
        $finish;
    end
endmodule
