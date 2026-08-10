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

// docs/adr/0026-performance-profiler.md (Phase K). Template for
// sim/tools/profiler.py, combining two already-proven techniques rather
// than inventing a third: sim/tb/bench_template.v's own generic "program
// finished" detection (an unconditional redirect whose target equals its
// own PC -- every test program's mandatory `jal x0, self` halt loop, docs/
// adr/0011), and sim/tb/dump_regs_template.v's own full 32-register dump.
// The profiled kernel's own epilogue (assembled by profiler.py, not this
// template) reads mcycle/minstret/mhpmcounter3-11 into a fixed register
// convention via real `csrrs` instructions BEFORE the halt loop -- this
// template only needs to dump whatever's in the register file once the
// halt loop is reached, the same way every other register-comparison test
// in this repo already works. __INIT_FILE__/__OUT_FILE__/__MAX_TIME__/
// __MEM_SIZE__/__HAZARD_STRATEGY__/__PIPELINE_PROFILE__/__BRANCH_PREDICTOR__/
// __CACHE_MODE__/__MEM_LATENCY_I__/__MEM_LATENCY_D__ substituted per run,
// same idiom as bench_template.v/dump_regs_template.v.
module profiler_run;
    reg clk = 0;
    reg start = 0;
    integer fd;
    integer cycle_count;
    integer i;
    reg done;

    PIPELINED #(.INIT_FILE("__INIT_FILE__"), .MEM_SIZE_BYTES(__MEM_SIZE__), .HAZARD_STRATEGY(__HAZARD_STRATEGY__),
                .PIPELINE_PROFILE(__PIPELINE_PROFILE__), .BRANCH_PREDICTOR(__BRANCH_PREDICTOR__),
                .CACHE_MODE(__CACHE_MODE__), .MEM_LATENCY_I(__MEM_LATENCY_I__), .MEM_LATENCY_D(__MEM_LATENCY_D__),
                .XLEN(__XLEN__))
                dut(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    initial begin
        start = 0;
        cycle_count = 0;
        done = 0;
        #10 start = 1;
    end

    always @(posedge clk) begin
        if (start && !done) begin
            cycle_count = cycle_count + 1;
            if (dut.unconditional_redirect && (dut.redirect_target == dut.pc_o_regde)) begin
                done = 1;
                fd = $fopen("__OUT_FILE__", "w");
                $fdisplay(fd, "%0d", cycle_count);
                for (i = 0; i < 32; i = i + 1)
                    $fdisplay(fd, "%0d", dut.m_Register.regs[i]);
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
