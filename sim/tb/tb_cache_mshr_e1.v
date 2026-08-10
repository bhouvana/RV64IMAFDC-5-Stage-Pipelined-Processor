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
`include "L2Cache.v"
`include "InstructionMemoryWishboneAdapter.v"
`include "VictimCache.v"

// docs/adr/0044-non-blocking-dcache-mshr-phase-e.md. End-to-end directed
// regression: MSHR_ENTRIES wired live through the real pipeline, not just
// DCache.v's own standalone unit test (mirrors tb_cache_victim_c1.v's own
// role for VICTIM_ENTRIES). TWO fully independent DUTs run the IDENTICAL
// program -- dut1 at MSHR_ENTRIES(1) (today's exact blocking behavior,
// the regression baseline) and dut2 at MSHR_ENTRIES(2) (real non-blocking)
// -- both must reach the SAME correct final architectural state, and dut2
// must reach it in FEWER cycles (the real, measurable win this phase
// exists for), matching sim/programs/cache_mshr_e1.s's own design.
module tb_cache_mshr_e1;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/cache_mshr_e1.mem"), .CACHE_MODE(1),
                .MSHR_ENTRIES(1),
                .DCACHE_WAYS(2), .DCACHE_SIZE_BYTES(32), .DCACHE_LINE_BYTES(8))
        dut1(.clk(clk), .start(start), .uart_rx(1'b1));

    PIPELINED #(.INIT_FILE("sim/programs/cache_mshr_e1.mem"), .CACHE_MODE(1),
                .MSHR_ENTRIES(2),
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
                $display("  FAIL  dut1(MSHR=1) %0s: x%0d = 0x%016h, expected 0x%016h", label, regnum, actual, expected);
            end else $display("  pass  dut1(MSHR=1) %0s: x%0d = 0x%016h", label, regnum, actual);
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
                $display("  FAIL  dut2(MSHR=2) %0s: x%0d = 0x%016h, expected 0x%016h", label, regnum, actual, expected);
            end else $display("  pass  dut2(MSHR=2) %0s: x%0d = 0x%016h", label, regnum, actual);
        end
    endtask

    // Same halt-loop-detection idiom bench_template.v's own cycle-count
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

    initial begin
        cycles1 = 0;
        cycles2 = 0;
        start = 0;
        #10 start = 1;
        #2000;

        if (!done1) $display("  FAIL  dut1(MSHR=1) never reached its halt loop within the time budget");
        if (!done2) $display("  FAIL  dut2(MSHR=2) never reached its halt loop within the time budget");

        // Both DUTs must reach the SAME correct architectural state --
        // non-blocking completion changes WHEN a register gets written,
        // never WHAT value lands there.
        check_reg1(5, 32'd0,   "x5 = 0 (addr0, backing RAM default)");
        check_reg1(6, 32'd42,  "x6 = 42 (independent ALU op)");
        check_reg1(7, 32'd0,   "x7 = 0 (addr8, backing RAM default)");
        check_reg1(8, 32'd1,   "x8 = x5+1 (RAW on x5, correct post-fill value)");
        check_reg1(9, 32'd777, "x9 = 777 (reached the end correctly)");

        check_reg2(5, 32'd0,   "x5 = 0 (addr0, backing RAM default)");
        check_reg2(6, 32'd42,  "x6 = 42 (independent ALU op)");
        check_reg2(7, 32'd0,   "x7 = 0 (addr8, backing RAM default)");
        check_reg2(8, 32'd1,   "x8 = x5+1 (RAW on x5, correct post-fill value)");
        check_reg2(9, 32'd777, "x9 = 777 (reached the end correctly)");

        // The real, measurable win: non-blocking (dut2) must finish in
        // FEWER cycles than blocking (dut1) -- x6's independent ALU op
        // executes while addr0's own miss is still draining, instead of
        // waiting behind it.
        total_checks = total_checks + 1;
        if (!(cycles2 < cycles1)) begin
            total_fails = total_fails + 1;
            $display("  FAIL  non-blocking (dut2, %0d cycles) is not faster than blocking (dut1, %0d cycles)", cycles2, cycles1);
        end else $display("  pass  non-blocking (dut2, %0d cycles) genuinely faster than blocking (dut1, %0d cycles)", cycles2, cycles1);

        $display("cache_mshr_e1: %0d/%0d checks passed", total_checks - total_fails, total_checks);
        if (total_fails == 0) $display("PASS  cache_mshr_e1");
        else $display("FAIL  cache_mshr_e1 (%0d/%0d checks failed)", total_fails, total_checks);
        $finish;
    end
endmodule
