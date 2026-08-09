`include "riscvpipeline.v"
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

// docs/adr/0023-caches.md (Phase G3). Directed regression for I$ wired
// live: PIPELINED instantiated with CACHE_MODE=1 and a deliberately small
// I$ override (2-way/32B/8B lines -- see sim/programs/loop_cache_g3.s's
// own header for why) so a real, tight taken-branch loop forces repeated
// line eviction/refill, not just cold misses. Confirms icache_miss/
// branch_taken/redirect compose correctly under real repeated churn --
// the phase plan's own explicitly-called-out risk (an in-flight fill for
// an address the branch is about to abandon; the very next fetch after
// the redirect correctly detecting and stalling on its own fresh miss).
// Final register values would be identical under CACHE_MODE=0 -- a cache
// only changes timing, never architectural results.
module tb_icache_live_g3;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/loop_cache_g3.mem"), .CACHE_MODE(1),
                .ICACHE_WAYS(2), .ICACHE_SIZE_BYTES(32), .ICACHE_LINE_BYTES(8))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    // Sticky taps: confirm the scenario this test exists to exercise
    // actually happened (real misses AND real taken redirects), not just
    // that the final architectural state came out correct by coincidence
    // (e.g. because the cache silently never engaged).
    reg seen_icache_miss = 0;
    reg seen_taken_redirect = 0;
    integer miss_count = 0;
    always @(posedge clk) begin
        if (dut.icache_miss) begin
            seen_icache_miss <= 1;
            miss_count <= miss_count + 1;
        end
        if (dut.branch_taken) seen_taken_redirect <= 1;
    end

    initial begin
        start = 0;
        #10 start = 1;
        #2000;

        check_reg(5, 32'd5, "x5 = 5: loop counter reached N");
        check_reg(6, 32'd5, "x6 = 5: N unchanged");
        check_reg(7, 32'd8, "x7 = 8: last iteration's body computed correctly despite real eviction/refill churn");
        check_reg(10, 32'd999, "x10 = 999: loop-finished marker reached (correct control flow throughout)");

        total_checks = total_checks + 1;
        if (seen_icache_miss !== 1'b1) begin
            total_fails = total_fails + 1;
            $display("  FAIL  icache_miss never fired -- test didn't exercise real eviction/refill as intended");
        end else $display("  pass  icache_miss fired (%0d times) -- real eviction/refill exercised", miss_count);

        total_checks = total_checks + 1;
        if (seen_taken_redirect !== 1'b1) begin
            total_fails = total_fails + 1;
            $display("  FAIL  branch_taken never fired -- loop's back-edge redirect didn't happen");
        end else $display("  pass  branch_taken fired -- loop back-edge redirects exercised alongside real misses");

        // A cache-capacity sanity floor: the loop body (40 bytes) exceeds
        // this cache's total capacity (32 bytes/4 lines), so a correct
        // implementation MUST miss more than once per iteration on
        // average across 5 iterations -- a suspiciously low count would
        // mean eviction isn't really being forced (e.g. a cache that's
        // silently bigger than configured, or a hit check that's stuck at
        // 1 and never really misses again after the first fill).
        total_checks = total_checks + 1;
        if (miss_count < 5) begin
            total_fails = total_fails + 1;
            $display("  FAIL  only %0d icache_miss events -- too few for real repeated eviction across 5 iterations", miss_count);
        end else $display("  pass  %0d icache_miss events -- consistent with real repeated eviction, not just cold misses", miss_count);

        report("icache_live_g3");
        $finish;
    end
endmodule
