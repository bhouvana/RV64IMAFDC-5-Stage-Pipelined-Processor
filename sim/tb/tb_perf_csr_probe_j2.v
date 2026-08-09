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
`include "MemoryLatencyModel.v"

// docs/adr/0025-hpc-performance-csrs.md (Phase J2). Read/write/masking
// correctness for mcountinhibit/minstret/minstreth/mhpmcounter3/
// mhpmcounter3h/mhpmevent3/mhpmcounter11/mhpmevent11 -- pure storage as
// of J2, no live event-pulse consumers yet (J3-J6 wire those). See
// sim/programs/perf_csr_probe_j2.s's own header for why this test never
// checks mcycle's absolute value (its own mcountinhibit round-trip
// briefly sets bit0/CY).
module tb_perf_csr_probe_j2;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/perf_csr_probe_j2.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #500;

        check_reg(2, 32'h00000000, "csrrw x2,mcountinhibit,-1: x2 = old mcountinhibit (0)");
        check_reg(3, 32'h00000FFD, "mcountinhibit readback: masked to bits 0,2-11 (0xffd)");

        // docs/adr/0025-hpc-performance-csrs.md (Phase J3): minstret_lo is
        // now genuinely live (instret_pulse), so its "old" value here is a
        // real, moving retirement count, not a fixed 0 -- not worth
        // asserting precisely in this masking/round-trip-focused test
        // (tb_perf_instret_j3.v already covers retirement-counting
        // precision on its own dedicated program). Only the write/readback
        // itself, which stays fully deterministic regardless, is checked.
        check_reg(6, 32'hFFFFFFFF, "minstret_lo readback: unmasked, the write took");
        check_reg(7, 32'h00000000, "csrrw x7,minstreth,-1: x7 = old minstret_hi (0)");
        check_reg(8, 32'hFFFFFFFF, "minstret_hi readback: unmasked, the write took");

        check_reg(9, 32'h00000000, "csrrw x9,mhpmcounter3,-1: x9 = old value (0)");
        check_reg(10, 32'hFFFFFFFF, "mhpmcounter3 readback: unmasked");
        check_reg(11, 32'h00000000, "csrrw x11,mhpmcounter3h,-1: x11 = old value (0)");
        check_reg(12, 32'hFFFFFFFF, "mhpmcounter3h readback: unmasked");

        check_reg(13, 32'h00000001, "mhpmevent3 reset default: event index 1");
        // docs/adr/0026-performance-profiler.md (Phase K1): mhpmevent widened
        // 4->5 bits real (10 new stall-cause event codes, 10-18, no longer
        // fit 4 bits) -- was 0xF (only low 4 bits real).
        check_reg(15, 32'h0000001F, "mhpmevent3 readback: only low 5 bits real (0x1f)");

        check_reg(16, 32'h00000009, "mhpmevent11 reset default: event index 9 (top of the range)");
        check_reg(17, 32'h00000000, "csrrw x17,mhpmcounter11,-1: x17 = old value (0)");
        check_reg(18, 32'hFFFFFFFF, "mhpmcounter11 readback: unmasked (range-decode boundary correct)");
        check_reg(19, 32'h00000000, "csrrw x19,mhpmcounter11h,-1: x19 = old value (0)");
        check_reg(20, 32'hFFFFFFFF, "mhpmcounter11h readback: unmasked");

        report("perf_csr_probe_j2");
        $finish;
    end
endmodule
