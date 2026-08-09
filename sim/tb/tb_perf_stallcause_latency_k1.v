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
`include "MemoryLatencyModel.v"

// docs/adr/0026-performance-profiler.md (Phase K1). Confirms event 18
// (stall_imem_wait_pulse) lands on its own dedicated counter under
// CACHE_NONE + MEM_LATENCY_I=3 -- same scenario docs/adr/0024's own I3
// already proved produces real multi-cycle imem_wait; this test's own job
// is confirming the new per-cause wiring, not re-proving imem_wait's own
// detection logic.
module tb_perf_stallcause_latency_k1;
    reg clk = 0;
    reg start = 0;

    localparam MEM_LATENCY_I = 3;

    PIPELINED #(.INIT_FILE("sim/programs/perf_stallcause_latency_k1.mem"), .MEM_LATENCY_I(MEM_LATENCY_I))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #600;

        check_val(dut.m_CSR.mhpmevent[0], 32'd18, "mhpmevent3 reprogrammed to event 18 (stall_imem_wait)");
        check_reg(4, 32'd4, "x4 = 4: execution survived real I-side latency + jal redirect");
        check_reg(5, 32'd5, "x5 = 5: execution continued correctly");

        total_checks = total_checks + 1;
        if (dut.m_CSR.mhpmcounter_lo[0] < 32'd3) begin
            total_fails = total_fails + 1;
            $display("  FAIL  stall_imem_wait counted only %0d cycles, expected >= %0d (MEM_LATENCY_I)",
                dut.m_CSR.mhpmcounter_lo[0], MEM_LATENCY_I);
        end else $display("  pass  stall_imem_wait counted %0d cycles (>= MEM_LATENCY_I=%0d): a real per-cause count, not a no-op",
            dut.m_CSR.mhpmcounter_lo[0], MEM_LATENCY_I);

        report("perf_stallcause_latency_k1");
        $finish;
    end
endmodule
