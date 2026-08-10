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
`include "ICache.v"
`include "DCache.v"
`include "VictimCache.v"

// docs/adr/0026-performance-profiler.md (Phase K1). Confirms event 17
// (stall_icache_pulse) lands on its own dedicated counter under
// CACHE_MODE=1 -- reuses docs/adr/0025 Phase J5's own proven access
// pattern; this test's own job is confirming the new per-cause wiring,
// not re-proving icache_miss's own detection logic (already proven by J5).
module tb_perf_stallcause_cache_k1;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/perf_stallcause_cache_k1.mem"), .CACHE_MODE(1))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #300;

        check_val(dut.m_CSR.mhpmevent[0], 32'd17, "mhpmevent3 reprogrammed to event 17 (stall_icache)");

        total_checks = total_checks + 1;
        if (dut.m_CSR.mhpmcounter_lo[0] == 0) begin
            total_fails = total_fails + 1;
            $display("  FAIL  stall_icache counted 0 cycles, expected > 0 (real I$ misses occurred)");
        end else $display("  pass  stall_icache counted %0d cycles (> 0): a real per-cause count, not a no-op",
            dut.m_CSR.mhpmcounter_lo[0]);

        report("perf_stallcause_cache_k1");
        $finish;
    end
endmodule
