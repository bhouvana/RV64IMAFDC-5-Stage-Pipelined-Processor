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
`include "L2Cache.v"
`include "InstructionMemoryWishboneAdapter.v"
`include "MemoryLatencyModel.v"

// docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). End-to-end
// directed regression: L2 wired live through the real pipeline (mirrors
// tb_cache_mshr_e1.v's own role for MSHR_ENTRIES). FOUR fully independent
// DUTs run the IDENTICAL program (sim/programs/cache_l2_f1.s):
//
//  - correct_on / correct_off: D$ sized so it never evicts addr0 on its own
//    capacity -- ONLY L2's own eviction (correct_on) forces the inclusion
//    probe's dirty-pullback path; correct_off (L2 disabled) is the
//    architectural baseline, addr0 resolved purely as a D$ hit.
//  - timing_on / timing_off: D$ sized small enough that IT evicts addr0 on
//    its own capacity (an ordinary, pre-existing DCache.v writeback, not
//    L2-specific) -- timing_on's L2 has spare room and absorbs it (a real
//    L2 HIT on the reload); timing_off has no L2 at all, forcing a full,
//    slow round trip to backing RAM (MEM_LATENCY_D(5) applied to all four).
//
// All four must reach the IDENTICAL correct final architectural state
// (x9=999, the dirty value survives regardless of mechanism); timing_on
// must finish in FEWER cycles than timing_off (the real, measurable win).
module tb_cache_l2_f1;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/cache_l2_f1.mem"), .CACHE_MODE(1),
                .DCACHE_WAYS(2), .DCACHE_SIZE_BYTES(64), .DCACHE_LINE_BYTES(16),
                .L2_SIZE_BYTES(32), .L2_WAYS(2), .MEM_LATENCY_D(5))
        dut_correct_on(.clk(clk), .start(start), .uart_rx(1'b1));

    PIPELINED #(.INIT_FILE("sim/programs/cache_l2_f1.mem"), .CACHE_MODE(1),
                .DCACHE_WAYS(2), .DCACHE_SIZE_BYTES(64), .DCACHE_LINE_BYTES(16),
                .L2_SIZE_BYTES(0), .MEM_LATENCY_D(5))
        dut_correct_off(.clk(clk), .start(start), .uart_rx(1'b1));

    PIPELINED #(.INIT_FILE("sim/programs/cache_l2_f1.mem"), .CACHE_MODE(1),
                .DCACHE_WAYS(2), .DCACHE_SIZE_BYTES(32), .DCACHE_LINE_BYTES(16),
                .L2_SIZE_BYTES(64), .L2_WAYS(4), .MEM_LATENCY_D(5))
        dut_timing_on(.clk(clk), .start(start), .uart_rx(1'b1));

    PIPELINED #(.INIT_FILE("sim/programs/cache_l2_f1.mem"), .CACHE_MODE(1),
                .DCACHE_WAYS(2), .DCACHE_SIZE_BYTES(32), .DCACHE_LINE_BYTES(16),
                .L2_SIZE_BYTES(0), .MEM_LATENCY_D(5))
        dut_timing_off(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    integer total_checks = 0;
    integer total_fails  = 0;

    task check_reg;
        input [4:0] regnum;
        input [63:0] expected;
        input [63:0] actual;
        input [511:0] label;
        begin
            total_checks = total_checks + 1;
            if (actual !== expected) begin
                total_fails = total_fails + 1;
                $display("  FAIL  %0s: x%0d = 0x%016h, expected 0x%016h", label, regnum, actual, expected);
            end else $display("  pass  %0s: x%0d = 0x%016h", label, regnum, actual);
        end
    endtask

    integer cyc_co, cyc_cf, cyc_to, cyc_tf;
    reg done_co = 0, done_cf = 0, done_to = 0, done_tf = 0;

    always @(posedge clk) begin
        if (start && !done_co) begin
            cyc_co = cyc_co + 1;
            if (dut_correct_on.unconditional_redirect && (dut_correct_on.redirect_target == dut_correct_on.pc_o_regde)) done_co = 1;
        end
        if (start && !done_cf) begin
            cyc_cf = cyc_cf + 1;
            if (dut_correct_off.unconditional_redirect && (dut_correct_off.redirect_target == dut_correct_off.pc_o_regde)) done_cf = 1;
        end
        if (start && !done_to) begin
            cyc_to = cyc_to + 1;
            if (dut_timing_on.unconditional_redirect && (dut_timing_on.redirect_target == dut_timing_on.pc_o_regde)) done_to = 1;
        end
        if (start && !done_tf) begin
            cyc_tf = cyc_tf + 1;
            if (dut_timing_off.unconditional_redirect && (dut_timing_off.redirect_target == dut_timing_off.pc_o_regde)) done_tf = 1;
        end
    end

    initial begin
        cyc_co = 0; cyc_cf = 0; cyc_to = 0; cyc_tf = 0;
        start = 0;
        #10 start = 1;
        #3000;

        if (!done_co) $display("  FAIL  dut_correct_on never reached its halt loop within the time budget");
        if (!done_cf) $display("  FAIL  dut_correct_off never reached its halt loop within the time budget");
        if (!done_to) $display("  FAIL  dut_timing_on never reached its halt loop within the time budget");
        if (!done_tf) $display("  FAIL  dut_timing_off never reached its halt loop within the time budget");

        check_reg(5, 32'd0,   dut_correct_on.m_Register.regs[5],  "correct_on x5 (addr0 cold)");
        check_reg(6, 32'd0,   dut_correct_on.m_Register.regs[6],  "correct_on x6 (addr16 cold)");
        check_reg(8, 32'd0,   dut_correct_on.m_Register.regs[8],  "correct_on x8 (addr64 cold)");
        check_reg(9, 32'd999, dut_correct_on.m_Register.regs[9],  "correct_on x9 (dirty pullback survives L2 eviction+probe)");
        check_reg(10, 32'd111, dut_correct_on.m_Register.regs[10], "correct_on x10 (reached the end)");

        check_reg(9, 32'd999, dut_correct_off.m_Register.regs[9], "correct_off x9 (baseline, L2 disabled, plain D$ hit)");
        check_reg(10, 32'd111, dut_correct_off.m_Register.regs[10], "correct_off x10 (reached the end)");

        check_reg(9, 32'd999, dut_timing_on.m_Register.regs[9],  "timing_on x9 (dirty survives D$ eviction + L2 hit)");
        check_reg(10, 32'd111, dut_timing_on.m_Register.regs[10], "timing_on x10 (reached the end)");

        check_reg(9, 32'd999, dut_timing_off.m_Register.regs[9], "timing_off x9 (dirty survives D\$ eviction, full RAM round trip)");
        check_reg(10, 32'd111, dut_timing_off.m_Register.regs[10], "timing_off x10 (reached the end)");

        // docs/adr/0045-l2-cache-phase-f.md. A real, necessary gap found by
        // running the constrained-random harness AFTER this test's own
        // register-only checks above all already passed: fence's own flush
        // never reached L2 at all in the original design -- a dirty write
        // merged into L2 (e.g. via this exact program's own D$ eviction/
        // flush-writeback) had no further trigger ever pushing it down to
        // backing RAM, so it stayed silently stuck in L2 forever, invisible
        // to anything reading backing memory directly. This test's own
        // x9 register checks above never caught it (x9 is loaded straight
        // through the cache hierarchy, never touching backing RAM
        // directly) -- checking backing RAM itself, post-fence, is the
        // real, necessary proof and stays here permanently to guard against
        // this exact regression class.
        total_checks = total_checks + 1;
        if (dut_correct_on.m_DataMemory.m_ram.data_memory[0] !== 8'hE7) begin
            total_fails = total_fails + 1;
            $display("  FAIL  correct_on backing RAM addr0 byte0 = 0x%02h, expected 0xe7 (999's own low byte, fence must flush L2 too)",
                dut_correct_on.m_DataMemory.m_ram.data_memory[0]);
        end else $display("  pass  correct_on backing RAM addr0 byte0 = 0xe7 (fence flushed L2 all the way to backing RAM)");

        total_checks = total_checks + 1;
        if (dut_timing_on.m_DataMemory.m_ram.data_memory[0] !== 8'hE7) begin
            total_fails = total_fails + 1;
            $display("  FAIL  timing_on backing RAM addr0 byte0 = 0x%02h, expected 0xe7",
                dut_timing_on.m_DataMemory.m_ram.data_memory[0]);
        end else $display("  pass  timing_on backing RAM addr0 byte0 = 0xe7 (fence flushed L2 all the way to backing RAM)");

        // The real, measurable win: L2 absorbing what D$ evicted (timing_on)
        // must finish in FEWER cycles than no L2 at all (timing_off) -- the
        // reload of addr0 is a real L2 hit instead of a full, slow round
        // trip to backing RAM (MEM_LATENCY_D(5)).
        total_checks = total_checks + 1;
        if (!(cyc_to < cyc_tf)) begin
            total_fails = total_fails + 1;
            $display("  FAIL  L2 hit (timing_on, %0d cycles) is not faster than no L2 (timing_off, %0d cycles)", cyc_to, cyc_tf);
        end else $display("  pass  L2 hit (timing_on, %0d cycles) genuinely faster than no L2 (timing_off, %0d cycles)", cyc_to, cyc_tf);

        $display("cache_l2_f1: %0d/%0d checks passed", total_checks - total_fails, total_checks);
        if (total_fails == 0) $display("PASS  cache_l2_f1");
        else $display("FAIL  cache_l2_f1 (%0d/%0d checks failed)", total_fails, total_checks);
        $finish;
    end
endmodule
