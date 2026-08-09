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

// docs/adr/0026-performance-profiler.md (Phase K1). Confirms the 5 new
// per-cause stall events reachable under default params (stall_hazard/
// stall_div/stall_mem/stall_fp/stall_float_lu, events 10-14) each land on
// their own dedicated counter (mhpmcounter3-7) and stay nonzero -- these
// are the same raw wires whose OR already forms pc_stall/event 7 (proven
// correct there since docs/adr/0025); this test's own job is confirming
// the NEW per-cause wiring (hpm_event_pulse[10..14]), not re-proving each
// wire's own detection logic. sim/programs/perf_stallcause_k1.s's own
// header documents which instruction produces which event.
module tb_perf_stallcause_k1;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/perf_stallcause_k1.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #1700;

        check_val(dut.m_CSR.mhpmevent[0], 32'd10, "mhpmevent3 reprogrammed to event 10 (stall_hazard)");
        check_val(dut.m_CSR.mhpmevent[1], 32'd11, "mhpmevent4 reprogrammed to event 11 (stall_div)");
        check_val(dut.m_CSR.mhpmevent[2], 32'd12, "mhpmevent5 reprogrammed to event 12 (stall_mem)");
        check_val(dut.m_CSR.mhpmevent[3], 32'd13, "mhpmevent6 reprogrammed to event 13 (stall_fp)");
        check_val(dut.m_CSR.mhpmevent[4], 32'd14, "mhpmevent7 reprogrammed to event 14 (stall_float_lu)");

        // Confirmed against a debug trace before committing to these exact
        // values (not paper-derived) -- FDivider.v's own 51-cycle iterative
        // shape (QW=24+27, see its header) meant the first attempt at this
        // window was too short to let fp_stall/float_lu ever resolve, which
        // looked like "these two events never fire" until traced cycle-by-
        // cycle. stall_hazard=2 (not the naively-expected 1): a second,
        // real pulse of the *existing* `stall` wire (Hazard.v's own output,
        // already part of pc_stall's proven-correct aggregate since
        // docs/adr/0025) occurs somewhere after the load-use pair this
        // program deliberately set up -- pre-existing `stall` behavior, not
        // something Phase K's new wiring introduces (this test only adds a
        // new counter observing the same already-proven wire).
        check_val(dut.m_CSR.mhpmcounter_lo[0], 32'd2,  "stall_hazard (event 10): 2");
        check_val(dut.m_CSR.mhpmcounter_lo[1], 32'd33, "stall_div (event 11): 33 (Divider.v's own real iteration count for 20/3)");
        check_val(dut.m_CSR.mhpmcounter_lo[2], 32'd9,  "stall_mem (event 12): 9 (4 loads/stores incl. fsw/flw)");
        check_val(dut.m_CSR.mhpmcounter_lo[3], 32'd52, "stall_fp (event 13): 52 (FDivider.v's own 51-cycle iteration count, +1)");
        check_val(dut.m_CSR.mhpmcounter_lo[4], 32'd1,  "stall_float_lu (event 14): 1 (the flw-then-fadd.s pair)");

        report("perf_stallcause_k1");
        $finish;
    end
endmodule
