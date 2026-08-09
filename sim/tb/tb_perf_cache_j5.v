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

// docs/adr/0025-hpc-performance-csrs.md (Phase J5). CACHE_MODE=1 at
// default sizing (generous enough that nothing in this small, straight-
// line program evicts). sim/programs/perf_cache_j5.s touches exactly two
// distinct D$ lines (addr 0, addr 64) each store-miss-then-two-load-hits,
// and its own instructions span exactly two I$ lines before the mandatory
// fence/halt (a third I$ line, cold-missed once).
//
// mhpmcounter3-6 default (reset) to events 1-4 -- wrong for this test
// (those are branches/mispredicts, always 0 here, no branches at all) --
// so this test instead directly reads mhpmevent5/6/7/8's own index-2/3/4/5
// slots (mhpmcounter_lo[2..5], i.e. mhpmcounter5-8) since J5 wires events
// 3-6 (icache hit/miss, dcache hit/miss) into indices 2-5 of the array
// (mhpmcounter3 is array index 0). See riscv_defs.vh's own event-index
// comment: index 1=branches,2=mispredicts,3=icache hit,4=icache miss,
// 5=dcache hit,6=dcache miss -- mhpmcounterN's own array slot is N-3, and
// its DEFAULT event selection is N-2 (mhpmcounter3's default is event 1,
// mhpmcounter5's default is event 3, etc.) -- so mhpmcounter5(array
// index 2)'s reset default (event 3, icache hit) and mhpmcounter6(index
// 3)'s reset default (event 4, icache miss) are exactly the ones this
// test needs already, with zero configuration; likewise mhpmcounter7/8
// (indices 4/5) default to events 5/6 (dcache hit/miss).
//
// Hand-derivation (confirmed against a cycle-by-cycle debug trace before
// committing to these exact values, not just paper-derived -- a real bug
// was found this way: DCache.v's own read-hit double-counted itself once
// on returning to S_IDLE with a still-stale req_read, fixed in DCache.v's
// own access_hit definition, see its header comment): at this test's
// checkpoint (t=310, comfortably after the program's own 8 real fetches +
// 5 real D$ accesses complete and before the mandatory halt loop's own
// jal has repeated enough to add further I$ activity), icache hits=6/
// misses=3 (8 total fetches: cold miss on each of 3 distinct 16B/4-
// instruction lines, 6 hits on the remaining same-line fetches) and
// dcache hits=3/misses=2 (5 total accesses: 2 cold misses -- one per
// distinct line -- 3 hits on the repeat/same-line accesses).
module tb_perf_cache_j5;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/perf_cache_j5.mem"), .CACHE_MODE(1))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        // docs/adr/0043-memory-controller-phase-d.md (Generation 4, Phase
        // D). Widened from #300 -- a real, pre-existing RamWishboneAdapter.v
        // ack bug (fixed this phase) made every multi-word D$ fill complete
        // artificially fast (reusing one real round-trip's own latency
        // across every remaining word instead of paying it per word); this
        // program's own two full D$ line fills now correctly take more
        // real cycles, so the old fixed budget cut off before the last
        // instruction's own effects were fully counted (icache_miss/
        // dcache_hit both landed one short). Generous margin, not tuned.
        #600;

        check_val(dut.m_CSR.mhpmcounter_lo[2], 32'd6, "mhpmcounter5 (icache hit, default event): 6");
        check_val(dut.m_CSR.mhpmcounter_lo[3], 32'd3, "mhpmcounter6 (icache miss, default event): 3");
        check_val(dut.m_CSR.mhpmcounter_lo[4], 32'd3, "mhpmcounter7 (dcache hit, default event): 3");
        check_val(dut.m_CSR.mhpmcounter_lo[5], 32'd2, "mhpmcounter8 (dcache miss, default event): 2");

        report("perf_cache_j5");
        $finish;
    end
endmodule
