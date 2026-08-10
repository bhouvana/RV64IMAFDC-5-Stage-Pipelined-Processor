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
`include "Gshare.v"
`include "Chooser.v"
`include "ICache.v"
`include "DCache.v"
`include "VictimCache.v"
`include "MemoryLatencyModel.v"

// Template for sim/tools/random_gen.py's cross-check driver -- __INIT_FILE__,
// __MAX_TIME__, __HAZARD_STRATEGY__ (docs/adr/0016-swappable-hazard-
// strategy.md; 0 or 1, see riscvpipeline.v's HAZARD_STRATEGY parameter), and
// __PIPELINE_PROFILE__ (docs/adr/0018-variable-pipeline-depth.md; 0 or 1,
// see riscvpipeline.v's PIPELINE_PROFILE parameter), and __BRANCH_PREDICTOR__
// (docs/adr/0021-branch-prediction.md; 0 or 1, see riscvpipeline.v's
// BRANCH_PREDICTOR parameter), and __CACHE_MODE__ (docs/adr/0023-caches.md;
// 0 or 1, see riscvpipeline.v's CACHE_MODE parameter), and __MEM_LATENCY_I__/
// __MEM_LATENCY_D__ (docs/adr/0024-variable-latency-memory.md; extra
// wait-state cycles, 0 by default), and __XLEN__ (Generation 2, docs/adr/
// 0028-rv64-migration-phase-m.md; 32 or 64), __REPLACEMENT_POLICY__
// (docs/adr/0041-cache-replacement-policy-phase-b.md; 0/1/2, only
// meaningful under CACHE_MODE=1), and __VICTIM_ENTRIES__ (docs/adr/0042-
// victim-cache-phase-c.md; 0=disabled, only meaningful under CACHE_MODE=1)
// are substituted per
// run. Dumps final
// architectural state as one decimal value per line, for comparison against
// sim/tools/iss.py's own final state on the same program -- the ISS itself
// doesn't model pipeline microarchitecture (or branch-prediction timing) at
// all, so it's equally valid as a reference regardless of which hazard
// strategy, pipeline profile, or branch predictor the RTL used. Not part of sim/run_tests.sh's
// tb_*.v glob (different shape -- generated per-run, not a fixed named
// test). Layout: 32 integer regs, 128 data memory bytes, 32 float regs
// (docs/adr/0019-f-extension.md Phase C9), fflags, frm -- in that order,
// matching sim/tools/run_random_tests.py's own unpacking.
module dump_regs;
    reg clk = 0;
    reg start = 0;
    integer i;
    integer fd;

    PIPELINED #(.INIT_FILE("__INIT_FILE__"), .HAZARD_STRATEGY(__HAZARD_STRATEGY__),
                .PIPELINE_PROFILE(__PIPELINE_PROFILE__), .BRANCH_PREDICTOR(__BRANCH_PREDICTOR__),
                .CACHE_MODE(__CACHE_MODE__), .REPLACEMENT_POLICY(__REPLACEMENT_POLICY__),
                .VICTIM_ENTRIES(__VICTIM_ENTRIES__), .MSHR_ENTRIES(__MSHR_ENTRIES__),
                .BURST_ENABLE(__BURST_ENABLE__), .MEM_LATENCY_D_BURST(__MEM_LATENCY_D_BURST__),
                .MEM_LATENCY_I(__MEM_LATENCY_I__), .MEM_LATENCY_D(__MEM_LATENCY_D__),
                .XLEN(__XLEN__))
                dut(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #__MAX_TIME__;
        fd = $fopen("__OUT_FILE__", "w");
        for (i = 0; i < 32; i = i + 1)
            $fdisplay(fd, "%0d", dut.m_Register.regs[i]);
        for (i = 0; i < 128; i = i + 1)
            $fdisplay(fd, "%0d", dut.m_DataMemory.m_ram.data_memory[i]);
        for (i = 0; i < 32; i = i + 1)
            $fdisplay(fd, "%0d", dut.m_FRegister.regs[i]);
        $fdisplay(fd, "%0d", dut.m_CSR.fflags);
        $fdisplay(fd, "%0d", dut.m_CSR.frm);
        $fclose(fd);
        $finish;
    end
endmodule
