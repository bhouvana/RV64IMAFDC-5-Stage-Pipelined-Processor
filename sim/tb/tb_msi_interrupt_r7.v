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

// docs/adr/0034-uart-clint-register-compat-phase-r.md (Phase R). Directed
// test for the interrupt redirect path itself, machine-software source:
// sim/programs/msi_interrupt_r7.s arms CLINT.msip/mie.MSIE/mstatus.MIE,
// then runs a 10-iteration loop (addresses [32,68]) that an MSI interrupt
// fires somewhere in the middle of. Mirrors tb_timer_interrupt.v's own
// checks exactly, just against MCAUSE_INT_MACHINE_SOFTWARE(3) instead of
// the timer cause -- confirms the new msi_pending term riscvpipeline.v's
// interrupt_taken/interrupt_cause mux added (docs/adr/0034) is real, not
// just decoded-without-effect.
module tb_msi_interrupt_r7;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/msi_interrupt_r7.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #2000;

        check_reg(10, 32'd10,        "x10 = 10: every loop iteration ran exactly once despite the interrupt");
        check_reg(11, 32'd777,       "x11 = 777: the MSI interrupt handler ran");
        check_val(dut.m_CSR.mcause, 32'h80000003,
                   "mcause = 0x80000003: interrupt bit set (bit31) + MCAUSE_INT_MACHINE_SOFTWARE(3)");
        check_val(dut.m_CSR.mstatus, 32'h88,
                   "mstatus after mret: MIE(bit3)=1 restored from MPIE, MPIE(bit7)=1 set by mret");

        // mepc must land inside the loop's own address range [32,68] and be
        // word-aligned -- not a raw equality check (which exact iteration
        // gets interrupted isn't pinned down, deliberately, mirroring
        // timer_interrupt.s's own reasoning), but bounded and well-formed.
        total_checks = total_checks + 1;
        if (dut.m_CSR.mepc < 32'd32 || dut.m_CSR.mepc > 32'd68 || dut.m_CSR.mepc[1:0] != 2'b00) begin
            total_fails = total_fails + 1;
            $display("  FAIL  mepc in-loop bounds check: mepc = 0x%08h, expected in [32,68], word-aligned",
                      dut.m_CSR.mepc);
        end else begin
            $display("  pass  mepc in-loop bounds check: mepc = 0x%08h", dut.m_CSR.mepc);
        end

        // docs/adr/0025-hpc-performance-csrs.md (Phase J6). mhpmcounter10
        // (array index 7) defaults to event 8 (interrupts taken) with zero
        // configuration -- source-agnostic (riscvpipeline.v's own
        // .interrupt_pulse(interrupt_taken) wiring counts any of MEI/MSI/
        // MTI equally), so this MSI-sourced test should show exactly the
        // same single count timer_interrupt.s's own equivalent check does.
        check_val(dut.m_CSR.mhpmcounter_lo[7], 32'd1, "mhpmcounter10 (interrupts, default event): 1");

        report("msi_interrupt_r7");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
