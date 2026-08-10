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
`include "MemoryLatencyModel.v"

// docs/adr/0025-hpc-performance-csrs.md (Phase J3, the isolated highest-
// risk step: the new `valid` bit threaded reg1(id_bubble_r)->reg2->reg3,
// wired to minstret via `instret_pulse = valid_regem && !mem_stall`).
// sim/programs/perf_instret_j3.s is 10 independent, hazard-free
// straight-line addi instructions (distinct dest regs, no loads/stores/
// branches) followed by the mandatory fence+halt spin-loop -- chosen
// specifically so retirement cadence is exactly 1/cycle once the pipeline
// fills, with no redirect/stall cadence to reason about (unlike the
// mandatory halt loop's own jal, which pays a real static-predictor
// misprediction penalty every iteration -- see tb_perf_mcycle_j2.v's own
// comment for that separate, more involved derivation).
//
// Hand-derivation (confirmed against a cycle-by-cycle debug trace before
// committing to this exact checkpoint, not just paper-derived): clk
// toggles every 5ns from 0, so posedges land at t=5,15,25,...; `start`
// goes high at t=10, so t=5 still sees reset and t=15 is the first real
// cycle (raw cycle 2 in $time terms, cycle 1 being the reset-held edge at
// t=5). Instruction i (1-indexed) retires -- `instret_pulse` fires --
// exactly at raw cycle (i+4) once the pipeline fills, with zero hazards
// in this straight-line program: instruction 10 retires at raw cycle 14
// (t=135), instruction 11 (the mandatory `fence`) at raw cycle 15
// (t=145). `minstret_lo` reads 10 for the entire open interval
// (t=135, t=145) -- checking at t=140 (comfortably mid-interval, never at
// a posedge time itself, avoiding the same read/update race a posedge-
// exact checkpoint would risk) gets exactly 10, unambiguously before
// instruction 11 has had any chance to retire.
module tb_perf_instret_j3;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/perf_instret_j3.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #130;

        check_val(dut.m_CSR.minstret_lo, 32'd10, "minstret_lo: exactly 10 straight-line instructions retired");
        check_val(dut.m_CSR.minstret_hi, 32'd0, "minstret_hi: no spurious carry");

        report("perf_instret_j3");
        $finish;
    end
endmodule
