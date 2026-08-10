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
`include "Prefetcher.v"
`include "DCache.v"
`include "L2Cache.v"
`include "InstructionMemoryWishboneAdapter.v"
`include "VictimCache.v"
`include "MemoryLatencyModel.v"

// docs/adr/0024-variable-latency-memory.md (Phase I3). Live-pipeline proof
// that MEM_LATENCY_I produces real multi-cycle I-side stalls (not a
// silent no-op) under CACHE_NONE, AND that a taken jal mid-stream still
// correctly redirects fetch (doesn't get swallowed by imem_wait -- the
// stall-vs-redirect priority bug this project has hit three times before,
// docs/adr/0016/0022/0023, fixed proactively this time).
module tb_mem_latency_i3;
    reg clk = 0;
    reg start = 0;

    localparam MEM_LATENCY_I = 3;

    PIPELINED #(.INIT_FILE("sim/programs/mem_latency_i3.mem"), .MEM_LATENCY_I(MEM_LATENCY_I))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    integer stall_run, max_stall_run;
    initial begin
        stall_run = 0;
        max_stall_run = 0;
    end
    always @(posedge clk) begin
        if (start && dut.imem_wait) begin
            stall_run = stall_run + 1;
            if (stall_run > max_stall_run) max_stall_run = stall_run;
        end else begin
            stall_run = 0;
        end
    end

    initial begin
        start = 0;
        #10 start = 1;

        #600;

        check_reg(1, 32'd1, "x1 = 1: first instruction survives real I-side latency");
        check_reg(2, 32'd2, "x2 = 2: second instruction survives real I-side latency");
        check_reg(3, 32'd0, "x3 = 0: the jal's target correctly SKIPPED these, not swallowed by imem_wait");
        check_reg(4, 32'd4, "x4 = 4: fetch resumed correctly at the jal's real target");
        check_reg(5, 32'd5, "x5 = 5: execution continued correctly after the redirect");

        total_checks = total_checks + 1;
        if (max_stall_run < MEM_LATENCY_I) begin
            total_fails = total_fails + 1;
            $display("  FAIL  longest imem_wait run was only %0d cycles, expected >= %0d (MEM_LATENCY_I): latency looks like a no-op",
                max_stall_run, MEM_LATENCY_I);
        end else $display("  pass  longest imem_wait run was %0d cycles (>= MEM_LATENCY_I=%0d): a real multi-cycle wait occurred",
            max_stall_run, MEM_LATENCY_I);

        report("mem_latency_i3");
        $finish;
    end
endmodule
