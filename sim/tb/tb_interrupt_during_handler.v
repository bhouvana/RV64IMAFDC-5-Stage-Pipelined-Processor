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

// docs/adr/0020-soc-integration.md (Phase D9). Directed test:
// sim/programs/interrupt_during_handler.s takes an ecall trap, then --
// still inside that handler, with mstatus.MIE=0 -- re-arms the timer so it
// becomes genuinely pending and enabled. This testbench event-waits for
// that re-arm (a 0->1 transition on Timer.v's own `pending`, sampled via
// hierarchical reference the same way D8's throwaway debug testbench did)
// and, at exactly that moment, confirms no interrupt has been taken yet
// (mcause/mstatus unchanged from the ecall's own trap entry). Only after
// letting the handler's real mret run does the deferred timer interrupt
// finally get taken, proving mstatus.MIE=0 correctly blocked it without
// losing it (a pending, enabled, level source that would otherwise refire
// forever if truly dropped).
module tb_interrupt_during_handler;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/interrupt_during_handler.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;

        // Mid-run sample: wait for the mainline's own early defusal to take
        // effect (pending drops to 0), then for the handler's later re-arm
        // to take effect (pending rises back to 1) -- an edge, not a level,
        // since Timer.v resets with `pending` already true (mtime=0>=
        // mtimecmp=0) and a plain level-wait would return immediately at
        // t=0, long before the handler even runs.
        wait (dut.m_Timer.pending == 1'b0);
        wait (dut.m_Timer.pending == 1'b1);
        @(posedge clk);  // let this cycle's state settle before sampling

        total_checks = total_checks + 1;
        if (dut.m_CSR.mcause !== 32'd11 || dut.m_CSR.mstatus[3] !== 1'b0) begin
            total_fails = total_fails + 1;
            $display("  FAIL  mid-handler: interrupt taken despite mstatus.MIE=0 -- mcause=0x%08h, mstatus.MIE=%b (expected mcause=11, MIE=0)",
                      dut.m_CSR.mcause, dut.m_CSR.mstatus[3]);
        end else begin
            $display("  pass  mid-handler: mip.MTIP pending+enabled but mstatus.MIE=0 correctly still blocks it -- mcause=%0d, MIE=%b",
                      dut.m_CSR.mcause, dut.m_CSR.mstatus[3]);
        end

        #1000;

        check_reg(11, 32'd111, "x11 = 111: the handler ran (at least once, via the ecall)");
        check_reg(15, 32'd42,  "x15 = 42: mainline resumed after the ecall handler's own real mret");
        check_val(dut.m_CSR.mcause, 32'h80000007,
                   "mcause = 0x80000007: the deferred timer interrupt was eventually taken, once mret restored MIE=1");

        report("interrupt_during_handler");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
