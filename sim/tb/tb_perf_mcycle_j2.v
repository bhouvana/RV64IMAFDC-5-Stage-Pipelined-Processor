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
`include "MemoryLatencyModel.v"

// docs/adr/0025-hpc-performance-csrs.md (Phase J2). mcycle is already
// live in this step (unconditional +1/cycle unless mcountinhibit[0] --
// no interlock needed, unlike minstret). This test asserts its exact
// wall-clock value at a known simulation time, hand-derived from this
// testbench's own clock/reset timing (rst==start directly,
// riscvpipeline.v's `.rst(start)` connections): clk toggles every 5ns
// from an initial value of 0, so posedges land at t=5,15,25,...; `start`
// goes high at t=10, so t=5's edge still sees reset asserted and t=15's
// edge is the first real (not-reset) cycle, incrementing mcycle_lo from 0
// to 1. By the checkpoint at t=10+500=510, posedges at
// t=15,25,...,505 have fired -- (505-15)/10+1 = 50 of them -- so
// mcycle_lo must read exactly 50 (0x32) and mcycle_hi must still be 0 (no
// spurious carry). sim/programs/perf_mcycle_j2.s is deliberately just the
// mandatory halt spin-loop (nothing else) so no CSR write anywhere in
// this test could perturb that count.
//
// docs/adr/0025-hpc-performance-csrs.md (Phase J3). minstret is now wired
// live too (instret_pulse = valid_regem && !mem_stall) -- confirmed
// against a cycle-by-cycle debug trace: `fence` retires at raw cycle 5,
// the halt loop's `jal` first retires at raw cycle 6, then each
// subsequent loop iteration's `jal` costs a real 3-cycle redirect penalty
// (this core's static predictor always guesses "not taken," and an
// unconditional backward jal is architecturally always taken -- so every
// iteration after the first genuinely mispredicts), retiring at raw cycle
// 6+3*(k-1) for iteration k. By raw cycle 51 (t=505, the last edge whose
// effect is visible by this test's own t=510 checkpoint -- the same
// edge/window mcycle_lo's own 50-cycle count above already relies on),
// iterations k=1..16 have all retired (6+3*15=51) -- 1 fence + 16 jal
// retirements = 17 (0x11) total.
module tb_perf_mcycle_j2;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/perf_mcycle_j2.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #500;

        check_val(dut.m_CSR.mcycle_lo, 32'd50, "mcycle_lo: exactly 50 cycles since reset");
        check_val(dut.m_CSR.mcycle_hi, 32'd0, "mcycle_hi: no spurious carry");
        check_val(dut.m_CSR.minstret_lo, 32'd17, "minstret_lo: 1 fence + 16 jal retirements (see header derivation)");
        check_val(dut.m_CSR.minstret_hi, 32'd0, "minstret_hi: stays 0");

        report("perf_mcycle_j2");
        $finish;
    end
endmodule
