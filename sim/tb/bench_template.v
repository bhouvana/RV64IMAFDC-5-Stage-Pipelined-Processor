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
`include "Gshare.v"
`include "Chooser.v"
`include "ICache.v"
`include "DCache.v"
`include "VictimCache.v"
`include "MemoryLatencyModel.v"

// Template for sim/tools/bench_runner.py (docs/ROADMAP.md Phase 10).
// __INIT_FILE__/__MAX_TIME__/__OUT_FILE__/__MEM_SIZE__/__HAZARD_STRATEGY__/
// __PIPELINE_PROFILE__/__BRANCH_PREDICTOR__/__CACHE_MODE__/__MEM_LATENCY_I__/
// __MEM_LATENCY_D__ substituted per run, same idiom dump_regs_template.v
// (docs/ROADMAP.md V-4) already established. __HAZARD_STRATEGY__ (docs/adr/
// 0016-swappable-hazard-strategy.md) is what makes this runner double as the
// "compare hazard strategies" tool docs/ROADMAP.md Phase 6 named as a
// research-platform goal; __PIPELINE_PROFILE__ (docs/adr/0018-variable-
// pipeline-depth.md, Phase A6) does the same for "compare pipeline depths";
// __BRANCH_PREDICTOR__ (docs/adr/0021-branch-prediction.md, Phase E5) does
// the same for "compare branch predictors"; __CACHE_MODE__ (docs/adr/0023-
// caches.md, Phase G8) does the same for "compare cache configurations";
// __MEM_LATENCY_I__/__MEM_LATENCY_D__ (docs/adr/0024-variable-latency-
// memory.md, Phase I6) does the same for "compare memory latencies";
// __REPLACEMENT_POLICY__ (docs/adr/0041-cache-replacement-policy-phase-b.md,
// Generation 4 Phase B) does the same for "compare replacement policies".
// __VICTIM_ENTRIES__ (docs/adr/0042-victim-cache-phase-c.md, Generation 4
// Phase C) does the same for "compare victim-cache sizes".
//
// Detects "program finished" generically, without needing to know any
// program's specific halt-label address: every benchmark (like every other
// test program in this repo, docs/adr/0011) ends in a deliberate
// `jal x0, self` spin loop, which resolves in EX as an unconditional
// redirect whose target equals its own instruction's PC. The *first* cycle
// that pattern appears is recorded as completion -- a few cycles before the
// pipeline fully drains of in-flight work, but that offset is constant
// across every benchmark, so relative comparisons between them are still
// fair (see sim/tools/bench_runner.py's docstring for the exact caveat).
module bench_run;
    reg clk = 0;
    reg start = 0;
    integer fd;
    integer cycle_count;
    reg done;

    PIPELINED #(.INIT_FILE("__INIT_FILE__"), .MEM_SIZE_BYTES(__MEM_SIZE__), .HAZARD_STRATEGY(__HAZARD_STRATEGY__), .PIPELINE_PROFILE(__PIPELINE_PROFILE__), .BRANCH_PREDICTOR(__BRANCH_PREDICTOR__), .CACHE_MODE(__CACHE_MODE__), .REPLACEMENT_POLICY(__REPLACEMENT_POLICY__), .VICTIM_ENTRIES(__VICTIM_ENTRIES__), .MEM_LATENCY_I(__MEM_LATENCY_I__), .MEM_LATENCY_D(__MEM_LATENCY_D__), .XLEN(__XLEN__)) dut(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    initial begin
        start = 0;
        cycle_count = 0;
        done = 0;
        icache_miss_count = 0;
        icache_access_count = 0;
        dcache_miss_count = 0;
        icache_miss_prev_r = 1'b0;
        pc_o_prev_r = 32'hFFFFFFFF;   // sentinel, never a real reset PC -- guarantees the first fetch counts
        mem_stall_run_r = 2'd0;
        #10 start = 1;
    end

    // docs/adr/0023-caches.md (Phase G8). Hit/miss counters, tapped purely
    // from the testbench side (no new RTL) via the same hierarchical-dot
    // pattern this file already uses for dut.unconditional_redirect --
    // matches --compare-cache's own need for "is this cache mode doing
    // anything real" evidence, not a claim of precise hardware performance
    // counters (docs/ROADMAP_VISION.md's own separate, real HPC-CSR item).
    // I$: icache_miss_count is a rising-edge count of dut.icache_miss
    // (always defined and tied 0 under CACHE_NONE, so naturally 0 there);
    // icache_access_count counts every cycle pc_o changes (a fresh fetch
    // address), a simple, honest proxy for "how many distinct fetches
    // happened" without needing a second RTL tap. D$: dcache_miss_count
    // distinguishes a genuine miss from a routine 1-cycle hit-read stall
    // by run-length -- mem_stall lasts exactly one cycle for a hit (state=
    // S_HIT_RD) but LINE_WORDS+ cycles for a real miss (S_WB/S_FILL); a
    // run reaching its SECOND consecutive cycle is what a plain 1-cycle
    // hit-read stall can never do, so that's the miss signal, counted once
    // per run (not once per cycle of the run).
    integer icache_miss_count;
    integer icache_access_count;
    integer dcache_miss_count;
    reg icache_miss_prev_r;
    reg [31:0] pc_o_prev_r;
    reg [1:0] mem_stall_run_r;
    always @(posedge clk) begin
        if (start) begin
            if (dut.icache_miss && !icache_miss_prev_r) icache_miss_count = icache_miss_count + 1;
            icache_miss_prev_r <= dut.icache_miss;
            if (dut.pc_o !== pc_o_prev_r) icache_access_count = icache_access_count + 1;
            pc_o_prev_r <= dut.pc_o;

            if (dut.mem_stall && (dut.memRead_regem || dut.memWrite_regem)) begin
                if (mem_stall_run_r == 2'd1) dcache_miss_count = dcache_miss_count + 1;
                if (mem_stall_run_r != 2'd2) mem_stall_run_r <= mem_stall_run_r + 1'b1;
            end
            else mem_stall_run_r <= 2'd0;
        end
    end

    always @(posedge clk) begin
        if (start && !done) begin
            cycle_count = cycle_count + 1;
            if (dut.unconditional_redirect && (dut.redirect_target == dut.pc_o_regde)) begin
                done = 1;
                fd = $fopen("__OUT_FILE__", "w");
                $fdisplay(fd, "%0d", cycle_count);
                $fdisplay(fd, "%0d", icache_miss_count);
                $fdisplay(fd, "%0d", icache_access_count);
                $fdisplay(fd, "%0d", dcache_miss_count);
                $fclose(fd);
                $finish;
            end
        end
    end

    initial begin
        #__MAX_TIME__;
        if (!done) begin
            $display("TIMEOUT: __INIT_FILE__ never reached its halt loop within __MAX_TIME__ time units");
            $finish;
        end
    end
endmodule
