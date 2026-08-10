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

// docs/adr/0026-performance-profiler.md (Phase K1). Confirms events 15/16
// (stall_itlb_pulse/stall_dtlb_pulse) each land on their own dedicated
// counter under a real Sv32 translation -- mirrors docs/adr/00NN-mmu-
// sv32.md Phase F5's own proven happy-path scenario; this test's own job
// is confirming the new per-cause wiring, not re-proving itlb_miss/
// dtlb_miss's own detection logic (already proven by F5/F7/F8).
module tb_perf_stallcause_mmu_k1;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/perf_stallcause_mmu_k1.mem"), .MEM_SIZE_BYTES(16384))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #700;

        check_val(dut.m_CSR.mhpmevent[0], 32'd15, "mhpmevent3 reprogrammed to event 15 (stall_itlb)");
        check_val(dut.m_CSR.mhpmevent[1], 32'd16, "mhpmevent4 reprogrammed to event 16 (stall_dtlb)");
        check_reg(10, 32'd111, "x10 = 111: fetch translation landed at u_code");
        check_reg(11, 32'd777, "x11 = 777: the value stored through the D-side translated address");
        check_reg(12, 32'd777, "x12 = 777: loaded back through the SAME D-side translation (round trip)");

        total_checks = total_checks + 1;
        if (dut.m_CSR.mhpmcounter_lo[0] == 0) begin
            total_fails = total_fails + 1;
            $display("  FAIL  stall_itlb counted 0 cycles, expected > 0 (a real I-side walk occurred)");
        end else $display("  pass  stall_itlb counted %0d cycles (> 0): a real per-cause count, not a no-op",
            dut.m_CSR.mhpmcounter_lo[0]);

        total_checks = total_checks + 1;
        if (dut.m_CSR.mhpmcounter_lo[1] == 0) begin
            total_fails = total_fails + 1;
            $display("  FAIL  stall_dtlb counted 0 cycles, expected > 0 (a real D-side walk occurred)");
        end else $display("  pass  stall_dtlb counted %0d cycles (> 0): a real per-cause count, not a no-op",
            dut.m_CSR.mhpmcounter_lo[1]);

        report("perf_stallcause_mmu_k1");
        $finish;
    end
endmodule
