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
`include "Prefetcher.v"
`include "DCache.v"
`include "L2Cache.v"
`include "InstructionMemoryWishboneAdapter.v"
`include "VictimCache.v"
`include "MemoryLatencyModel.v"

// docs/adr/0043-memory-controller-phase-d.md (Generation 4, Phase D). End-to-
// end proof of the real, measurable win this phase delivers: the SAME
// program, same nonzero MEM_LATENCY_D, run through two PIPELINED instances
// -- one BURST_ENABLE(0) (every word of the 4-word default line pays the
// full latency), one BURST_ENABLE(1) with a cheaper MEM_LATENCY_D_BURST
// (only the first word of the burst pays full latency, the other 3 pay the
// cheap continuation cost). Asserts the burst-enabled run completes in
// strictly fewer real cycles -- unlike the victim cache's own honest
// zero-delta, this is a genuine, always-applicable win (amortizing fixed
// per-access latency, not dependent on any specific eviction/thrash
// pattern).
module tb_memctrl_burst_d1;
    reg clk = 0;
    reg start = 0;

    localparam MEM_LATENCY_D_CLASSIC = 10;
    localparam MEM_LATENCY_D_BURST_VAL = 1;

    PIPELINED #(.INIT_FILE("sim/programs/memctrl_burst_d1.mem"), .CACHE_MODE(1),
                .MEM_LATENCY_D(MEM_LATENCY_D_CLASSIC), .BURST_ENABLE(0))
        dut_classic(.clk(clk), .start(start), .uart_rx(1'b1));

    PIPELINED #(.INIT_FILE("sim/programs/memctrl_burst_d1.mem"), .CACHE_MODE(1),
                .MEM_LATENCY_D(MEM_LATENCY_D_CLASSIC), .BURST_ENABLE(1),
                .MEM_LATENCY_D_BURST(MEM_LATENCY_D_BURST_VAL))
        dut_burst(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    // Same halt-detection technique bench_template.v's own cycle-count
    // measurement already uses: the first cycle EX resolves the program's
    // own `jal x0, self` spin loop.
    integer cycles_classic = 0, cycles_burst = 0;
    reg done_classic = 0, done_burst = 0;
    always @(posedge clk) begin
        if (start && !done_classic) begin
            cycles_classic = cycles_classic + 1;
            if (dut_classic.unconditional_redirect && (dut_classic.redirect_target == dut_classic.pc_o_regde))
                done_classic = 1;
        end
        if (start && !done_burst) begin
            cycles_burst = cycles_burst + 1;
            if (dut_burst.unconditional_redirect && (dut_burst.redirect_target == dut_burst.pc_o_regde))
                done_burst = 1;
        end
    end

    integer fails = 0;
    integer checks = 0;
    task check;
        input cond;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (!cond) begin
                fails = fails + 1;
                $display("FAIL  %0s", label);
            end else begin
                $display("pass  %0s", label);
            end
        end
    endtask

    initial begin
        start = 0;
        #10 start = 1;
        #5000;

        check(done_classic, "classic (BURST_ENABLE=0) run completed within the time budget");
        check(done_burst, "burst (BURST_ENABLE=1) run completed within the time budget");
        $display("  classic cycles=%0d, burst cycles=%0d", cycles_classic, cycles_burst);
        check(cycles_burst < cycles_classic,
              "burst-enabled run completes in strictly fewer real cycles -- the real measured win");

        if (fails == 0)
            $display("PASS  memctrl_burst_d1 (%0d checks)", checks);
        else
            $display("FAIL  memctrl_burst_d1 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
