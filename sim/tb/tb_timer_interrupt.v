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

// docs/adr/0020-soc-integration.md (Phase D9). Directed test for the
// interrupt redirect path itself, timer source: sim/programs/timer_interrupt.s
// arms MTIMECMP/mie.MTIE/mstatus.MIE, then runs an 18-iteration loop
// (addresses [32,100], Phase R shifted -4 from the CLINT register-layout
// change -- see the .s file's own header) that a timer interrupt fires somewhere in the middle
// of. Checks: the interrupt is actually taken (handler ran, mcause carries
// the interrupt bit + the timer cause code), mepc is the "would have
// executed next" instruction (squashed, not the trapping one -- this test's
// whole point, the real semantic difference from the exception path already
// covered by tb_mret_return.v), mret needs no software +4 adjustment to
// resume correctly, and the loop's own final count is exactly right
// regardless of exactly which iteration got interrupted (no instruction
// skipped or re-executed twice).
module tb_timer_interrupt;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/timer_interrupt.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #2000;

        check_reg(10, 32'd18,        "x10 = 18: every loop iteration ran exactly once despite the interrupt");
        check_reg(11, 32'd999,       "x11 = 999: the timer interrupt handler ran");
        check_val(dut.m_CSR.mcause, 32'h80000007,
                   "mcause = 0x80000007: interrupt bit set (bit31) + MCAUSE_INT_MACHINE_TIMER(7)");
        check_val(dut.m_CSR.mstatus, 32'h88,
                   "mstatus after mret: MIE(bit3)=1 restored from MPIE, MPIE(bit7)=1 set by mret");

        // mepc must land inside the loop's own address range [32,100] and be
        // word-aligned -- not a raw equality check (which exact iteration
        // gets interrupted isn't pinned down, deliberately, see the .s
        // file's header comment), but bounded and well-formed.
        total_checks = total_checks + 1;
        if (dut.m_CSR.mepc < 32'd32 || dut.m_CSR.mepc > 32'd100 || dut.m_CSR.mepc[1:0] != 2'b00) begin
            total_fails = total_fails + 1;
            $display("  FAIL  mepc in-loop bounds check: mepc = 0x%08h, expected in [32,100], word-aligned",
                      dut.m_CSR.mepc);
        end else begin
            $display("  pass  mepc in-loop bounds check: mepc = 0x%08h", dut.m_CSR.mepc);
        end

        // docs/adr/0025-hpc-performance-csrs.md (Phase J6). mhpmcounter10
        // (array index 7) defaults to event 8 (interrupts taken) with zero
        // configuration -- exactly one real timer interrupt in this
        // program (mtimecmp is reprogrammed huge before mret specifically
        // to prevent a second one, per this file's own header comment).
        check_val(dut.m_CSR.mhpmcounter_lo[7], 32'd1, "mhpmcounter10 (interrupts, default event): 1");

        report("timer_interrupt");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
