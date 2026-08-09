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

// docs/adr/0041-cache-replacement-policy-phase-b.md. End-to-end directed
// regression: REPLACEMENT_POLICY=2 (POLICY_LRU) wired live through the
// real pipeline, not just DCache.v's own standalone unit test (mirrors
// tb_icache_live_g3.v's own role for CACHE_MODE=1 generally). PIPELINED
// instantiated with CACHE_MODE=1, REPLACEMENT_POLICY=2, and a deliberately
// small D$ override (4-way/64B/8B lines -> 2 sets -- see
// sim/programs/cache_lru_b1.s's own header) so real repeated conflict
// eviction is forced, not just cold misses.
module tb_cache_lru_b1;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/cache_lru_b1.mem"), .CACHE_MODE(1),
                .REPLACEMENT_POLICY(2),
                .DCACHE_WAYS(4), .DCACHE_SIZE_BYTES(64), .DCACHE_LINE_BYTES(8))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    // Sticky tap: confirm real, repeated D$ misses actually happened (not
    // just that the final architectural state came out correct by
    // coincidence, e.g. because the cache silently never engaged) --
    // mirrors tb_icache_live_g3.v's own icache_miss tap exactly, D-side.
    reg seen_dcache_miss = 0;
    integer miss_count = 0;
    always @(posedge clk) begin
        if (dut.dcache_access_miss) begin
            seen_dcache_miss <= 1;
            miss_count <= miss_count + 1;
        end
    end

    initial begin
        start = 0;
        #10 start = 1;
        #2000;

        check_reg(6,  32'd100, "x6 = 100: A re-touch hit, correct data");
        check_reg(7,  32'd200, "x7 = 200: B re-touch hit, correct data");
        check_reg(8,  32'd400, "x8 = 400: D still hits after E's eviction, correct data");
        check_reg(9,  32'd100, "x9 = 100: A still hits -- round-robin's blind choice (evict A) would have broken this");
        check_reg(10, 32'd300, "x10 = 300: C's content correct even after its own real eviction (write-back never loses data)");
        check_reg(11, 32'd999, "x11 = 999: marker reached, correct control flow throughout");

        total_checks = total_checks + 1;
        if (seen_dcache_miss !== 1'b1) begin
            total_fails = total_fails + 1;
            $display("  FAIL  dcache_access_miss never fired -- test didn't exercise real eviction/refill as intended");
        end else $display("  pass  dcache_access_miss fired (%0d times) -- real eviction/refill exercised", miss_count);

        // Floor, not an exact count (mirrors tb_icache_live_g3.v's own
        // "miss_count<5 FAIL" style): the worked example needs at least 5
        // real misses (A/B/C/D's own 4 fills + E's own 5th) regardless of
        // any extra real-pipeline stall/retry timing this directed program
        // might incur beyond the standalone DCache.v unit test's own count.
        total_checks = total_checks + 1;
        if (miss_count < 5) begin
            total_fails = total_fails + 1;
            $display("  FAIL  only %0d dcache_access_miss events -- too few for real repeated eviction", miss_count);
        end else $display("  pass  %0d dcache_access_miss events -- consistent with real repeated eviction, not just cold misses", miss_count);

        report("cache_lru_b1");
        $finish;
    end
endmodule
