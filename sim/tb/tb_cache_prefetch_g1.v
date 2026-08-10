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

// docs/adr/0046-hardware-prefetchers-phase-g.md (Generation 4, Phase G).
// End-to-end directed regression: PREFETCH_MODE wired live through the real
// pipeline, not just Prefetcher.v's own standalone unit test (mirrors
// tb_cache_mshr_e1.v's own role for MSHR_ENTRIES). TWO fully independent
// DUTs run the IDENTICAL program -- dut1 at PREFETCH_MODE(0) (today's exact
// behavior, the regression baseline) and dut2 at PREFETCH_MODE(1)
// (PF_NEXT_LINE) -- both must reach the SAME correct final architectural
// state, matching sim/programs/cache_prefetch_g1.s's own design. Both DUTs
// need MSHR_ENTRIES(2) -- D$ prefetching is a documented no-op at
// MSHR_ENTRIES==1 (see DCache.v's own PREFETCH_MODE header comment).
//
// Real, measured finding worth recording here (not fought against): a whole-
// program CYCLE-COUNT race between these two DUTs does NOT show a clean
// prefetch win, matching the honest "near-zero/negative on this project's
// own tiny synthetic kernels" result every prior Gen4 cache-family phase
// found (most notably L2's own real negative delta). The reason is
// specific to this scenario: D$ prefetching requires MSHR_ENTRIES>1, but
// MSHR_ENTRIES>1 ALSO lets a plain, dependency-free cold miss retire
// non-blockingly on its own (Phase E) at near-zero pipeline cost -- so
// converting that SAME miss into a hit via prefetching does not clearly
// win a whole-program race (an ordinary hit still pays its own 1-cycle
// S_HIT_RD latch stage, which a non-blocking miss skips entirely). This is
// real, not a bug -- confirmed by direct hierarchical tracing of
// DCache.v's own state/access_hit/access_miss signals during development.
// So instead of asserting a fragile whole-program cycle race, this test
// proves the MECHANISM directly: dut2's own DCache.v must resolve the
// SECOND load as a genuine access_hit (not access_miss) -- the real,
// intended effect of the opportunistic prefetch -- while dut1's identical
// load is a genuine access_miss, mirroring tb_cache_l2_f1.v's own
// "prove the mechanism, not just the benchmark number" precedent.
module tb_cache_prefetch_g1;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/cache_prefetch_g1.mem"), .CACHE_MODE(1),
                .MSHR_ENTRIES(2), .PREFETCH_MODE(0),
                .DCACHE_WAYS(2), .DCACHE_SIZE_BYTES(32), .DCACHE_LINE_BYTES(8))
        dut1(.clk(clk), .start(start), .uart_rx(1'b1));

    PIPELINED #(.INIT_FILE("sim/programs/cache_prefetch_g1.mem"), .CACHE_MODE(1),
                .MSHR_ENTRIES(2), .PREFETCH_MODE(1),
                .DCACHE_WAYS(2), .DCACHE_SIZE_BYTES(32), .DCACHE_LINE_BYTES(8))
        dut2(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    integer total_checks = 0;
    integer total_fails  = 0;

    task check_reg1;
        input [4:0] regnum;
        input [63:0] expected;
        input [511:0] label;
        reg [63:0] actual;
        begin
            actual = dut1.m_Register.regs[regnum];
            total_checks = total_checks + 1;
            if (actual !== expected) begin
                total_fails = total_fails + 1;
                $display("  FAIL  dut1(PREFETCH_MODE=0) %0s: x%0d = 0x%016h, expected 0x%016h", label, regnum, actual, expected);
            end else $display("  pass  dut1(PREFETCH_MODE=0) %0s: x%0d = 0x%016h", label, regnum, actual);
        end
    endtask

    task check_reg2;
        input [4:0] regnum;
        input [63:0] expected;
        input [511:0] label;
        reg [63:0] actual;
        begin
            actual = dut2.m_Register.regs[regnum];
            total_checks = total_checks + 1;
            if (actual !== expected) begin
                total_fails = total_fails + 1;
                $display("  FAIL  dut2(PREFETCH_MODE=1) %0s: x%0d = 0x%016h, expected 0x%016h", label, regnum, actual, expected);
            end else $display("  pass  dut2(PREFETCH_MODE=1) %0s: x%0d = 0x%016h", label, regnum, actual);
        end
    endtask

    // Same halt-loop-detection idiom tb_cache_mshr_e1.v's own cycle-count
    // measurement uses: the first cycle the unconditional jal x0,halt
    // redirect resolves to its own instruction's PC is completion.
    integer cycles1, cycles2;
    reg done1 = 0, done2 = 0;

    always @(posedge clk) begin
        if (start && !done1) begin
            cycles1 = cycles1 + 1;
            if (dut1.unconditional_redirect && (dut1.redirect_target == dut1.pc_o_regde))
                done1 = 1;
        end
        if (start && !done2) begin
            cycles2 = cycles2 + 1;
            if (dut2.unconditional_redirect && (dut2.redirect_target == dut2.pc_o_regde))
                done2 = 1;
        end
    end

    // Mechanism-level proof (see the module header comment for why a
    // whole-program cycle race isn't the right check here): did the SECOND
    // load (line1, addr 8) genuinely resolve as a miss in dut1 and a real
    // cache HIT in dut2? access_hit/access_miss are one-cycle pulses
    // (docs/adr/0025's own exactly-once-per-real-access discipline) --
    // latched here since the sequential check block below runs long after
    // they've already come and gone.
    reg dut1_addr8_miss_seen = 1'b0;
    reg dut2_addr8_hit_seen  = 1'b0;
    reg dut2_addr8_miss_seen = 1'b0;
    always @(posedge clk) begin
        if (dut1.gen_dcache_writeback.m_DCache.access_miss && dut1.gen_dcache_writeback.m_DCache.req_addr == 32'd8)
            dut1_addr8_miss_seen <= 1'b1;
        if (dut2.gen_dcache_writeback.m_DCache.access_hit && dut2.gen_dcache_writeback.m_DCache.req_addr == 32'd8)
            dut2_addr8_hit_seen <= 1'b1;
        if (dut2.gen_dcache_writeback.m_DCache.access_miss && dut2.gen_dcache_writeback.m_DCache.req_addr == 32'd8)
            dut2_addr8_miss_seen <= 1'b1;
    end

    initial begin
        cycles1 = 0;
        cycles2 = 0;
        start = 0;
        #10 start = 1;
        #2000;

        if (!done1) $display("  FAIL  dut1(PREFETCH_MODE=0) never reached its halt loop within the time budget");
        if (!done2) $display("  FAIL  dut2(PREFETCH_MODE=1) never reached its halt loop within the time budget");

        // Both DUTs must reach the SAME correct architectural state --
        // prefetching changes WHEN a line becomes resident, never WHAT
        // value a load returns.
        check_reg1(5,  32'd0,   "x5 = 0 (line0, backing RAM default)");
        check_reg1(7,  32'd0,   "x7 = 0 (line1, backing RAM default)");
        check_reg1(9,  32'd777, "x9 = 777 (reached the end correctly)");
        check_reg1(10, 32'd10,  "x10 = 10 (last filler addi)");

        check_reg2(5,  32'd0,   "x5 = 0 (line0, backing RAM default)");
        check_reg2(7,  32'd0,   "x7 = 0 (line1, backing RAM default)");
        check_reg2(9,  32'd777, "x9 = 777 (reached the end correctly)");
        check_reg2(10, 32'd10,  "x10 = 10 (last filler addi)");

        // The real, intended mechanism: dut1's second load (line1) is a
        // genuine miss; dut2's identical load is a genuine hit, thanks to
        // the opportunistic background prefetch that ran during the filler
        // window. See the module header comment for why a whole-program
        // cycle race is NOT asserted as a hard pass/fail here.
        total_checks = total_checks + 1;
        if (!dut1_addr8_miss_seen) begin
            total_fails = total_fails + 1;
            $display("  FAIL  dut1(PREFETCH_MODE=0): line1 (addr 8) was never a genuine access_miss -- test precondition broken");
        end else $display("  pass  dut1(PREFETCH_MODE=0): line1 (addr 8) correctly missed (no prefetch)");

        total_checks = total_checks + 1;
        if (!dut2_addr8_hit_seen || dut2_addr8_miss_seen) begin
            total_fails = total_fails + 1;
            $display("  FAIL  dut2(PREFETCH_MODE=1): line1 (addr 8) did not resolve as a genuine hit (hit_seen=%b miss_seen=%b) -- prefetch did not do its job", dut2_addr8_hit_seen, dut2_addr8_miss_seen);
        end else $display("  pass  dut2(PREFETCH_MODE=1): line1 (addr 8) correctly HIT thanks to the opportunistic prefetch");

        // Informational only, not a pass/fail gate: real cycle count for
        // both. Matches every prior Gen4 cache-family phase's own honest
        // reporting discipline (a raw whole-program number here can go
        // either way for a small, dependency-free access pattern like this
        // one -- MSHR_ENTRIES>1's own non-blocking-miss retirement already
        // costs the pipeline close to nothing, so converting a miss to a
        // hit doesn't automatically win a whole-program race; the real,
        // load-bearing proof is the mechanism check above).
        $display("  info  dut1(PREFETCH_MODE=0): %0d total cycles", cycles1);
        $display("  info  dut2(PREFETCH_MODE=1): %0d total cycles", cycles2);

        $display("cache_prefetch_g1: %0d/%0d checks passed", total_checks - total_fails, total_checks);
        if (total_fails == 0) $display("PASS  cache_prefetch_g1");
        else $display("FAIL  cache_prefetch_g1 (%0d/%0d checks failed)", total_fails, total_checks);
        $finish;
    end
endmodule
