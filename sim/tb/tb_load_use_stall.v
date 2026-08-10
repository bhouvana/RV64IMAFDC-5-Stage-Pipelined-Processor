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
`include "reg2.v"
`include "reg3.v"
`include "reg4.v"
`include "Hazard.v"
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

module tb_load_use_stall;
    `include "check_tasks.vh"
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/load_use_stall.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #800;

        check_reg(7, 32'd77,  "lw x7 <- mem[32] == 77");
        check_reg(8, 32'd154, "load-use stall: x8=x7+x7=154 (would be 0 if stall were broken)");
        // docs/adr/0025-hpc-performance-csrs.md (Phase J6). mhpmcounter9
        // (array index 6) defaults to event 7 (pc_stall, counted every
        // cycle it's 1 -- duration, not discrete occurrences). Safe to
        // check at this program's own existing checkpoint despite the
        // long halt-loop spin afterward: pc_stall has no branch-redirect
        // component (a mispredicted jal squashes via reg1/reg2 flush, not
        // by freezing PC), so the spin loop itself contributes zero
        // further stall cycles once steady-state -- this count is
        // therefore stable, not growing with simulation time. 3 total:
        // the one Hazard.v-detected load-use stall this program exists to
        // exercise, plus one mem_stall cycle each for the `sw` and the
        // `lw` (every load/store's own registered-read latency under
        // CACHE_NONE, docs/adr/0013 -- confirmed against a debug run, not
        // just paper-derived, since this is the first test to ever count
        // stall cycles as a discrete number).
        check_val(dut.m_CSR.mhpmcounter_lo[6], 32'd3, "mhpmcounter9 (stall cycles, default event): 3");

        report("load_use_stall");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
