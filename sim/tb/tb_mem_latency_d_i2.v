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

// docs/adr/0024-variable-latency-memory.md (Phase I2). Live-pipeline proof
// that MEM_LATENCY_D actually produces real multi-cycle D-side stalls (not
// silently a no-op) AND that the data ends up correct despite them, under
// CACHE_MODE=0 (CACHE_NONE) specifically -- the mode whose mem_access_ready/
// mem_trigger this step changed from a hardcoded constant to genuinely
// tracking lsu_ack. Tracks the longest run of consecutive dut.mem_stall
// cycles seen; asserts it reaches at least MEM_LATENCY_D, proving the wait
// is real, not a silent pass-through.
module tb_mem_latency_d_i2;
    reg clk = 0;
    reg start = 0;

    localparam MEM_LATENCY_D = 3;

    PIPELINED #(.INIT_FILE("sim/programs/mem_latency_d_i2.mem"), .MEM_LATENCY_D(MEM_LATENCY_D))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    // A second instance, CACHE_MODE=1 -- confirms MEM_LATENCY_D also reaches
    // DCache.v's own fill/writeback engine transparently (zero DCache.v
    // changes were needed, since it's already fully m_ack-driven, per the
    // ADR's own Context finding). Independent checks/report via a second
    // check_tasks.vh scope needs its own total_checks/total_fails names --
    // hand-rolled here instead, same shape check_tasks.vh itself uses.
    PIPELINED #(.INIT_FILE("sim/programs/mem_latency_d_i2.mem"), .MEM_LATENCY_D(MEM_LATENCY_D), .CACHE_MODE(1))
        dut_cached(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    integer stall_run;
    integer max_stall_run;
    integer stall_run_c;
    integer max_stall_run_c;
    initial begin
        stall_run = 0;
        max_stall_run = 0;
        stall_run_c = 0;
        max_stall_run_c = 0;
    end
    always @(posedge clk) begin
        if (start && dut.mem_stall) begin
            stall_run = stall_run + 1;
            if (stall_run > max_stall_run) max_stall_run = stall_run;
        end else begin
            stall_run = 0;
        end

        if (start && dut_cached.mem_stall) begin
            stall_run_c = stall_run_c + 1;
            if (stall_run_c > max_stall_run_c) max_stall_run_c = stall_run_c;
        end else begin
            stall_run_c = 0;
        end
    end

    initial begin
        start = 0;
        #10 start = 1;

        // Budget generously: dut_cached's own fence flush scans all 256
        // lines regardless of dirty status (~277 cycles at MEM_LATENCY_D=0
        // per docs/adr/0023's own tb_fence_flush_g7.v precedent), plus this
        // step's own MEM_LATENCY_D adding real per-transaction delay to the
        // one dirty line's actual writeback.
        #4000;

        check_reg(7, 32'd123, "x7 = 123: readback after a delayed store correctly sees the just-written value");
        check_reg(9, 32'd456, "x9 = 456: a fresh delayed load at a different address is also correct");
        check_mem_word(40, 32'd123, "backing RAM addr40 == 123 (delayed write actually committed)");
        check_mem_word(44, 32'd456, "backing RAM addr44 == 456 (delayed write actually committed)");

        total_checks = total_checks + 1;
        if (max_stall_run < MEM_LATENCY_D) begin
            total_fails = total_fails + 1;
            $display("  FAIL  longest mem_stall run was only %0d cycles, expected >= %0d (MEM_LATENCY_D): latency looks like a no-op",
                max_stall_run, MEM_LATENCY_D);
        end else $display("  pass  longest mem_stall run was %0d cycles (>= MEM_LATENCY_D=%0d): a real multi-cycle wait occurred",
            max_stall_run, MEM_LATENCY_D);

        total_checks = total_checks + 1;
        if (dut_cached.m_Register.regs[7] !== 32'd123) begin
            total_fails = total_fails + 1;
            $display("  FAIL  CACHE_MODE=1: x7 = %0d, expected 123", dut_cached.m_Register.regs[7]);
        end else $display("  pass  CACHE_MODE=1: x7 = 123 (delayed D$ fill/writeback still correct)");

        total_checks = total_checks + 1;
        if (dut_cached.m_Register.regs[9] !== 32'd456) begin
            total_fails = total_fails + 1;
            $display("  FAIL  CACHE_MODE=1: x9 = %0d, expected 456", dut_cached.m_Register.regs[9]);
        end else $display("  pass  CACHE_MODE=1: x9 = 456 (delayed D$ fill/writeback still correct)");

        total_checks = total_checks + 1;
        if (dut_cached.m_DataMemory.m_ram.data_memory[40] !== 8'd123) begin
            total_fails = total_fails + 1;
            $display("  FAIL  CACHE_MODE=1: backing RAM addr40 = %0d after fence, expected 123",
                dut_cached.m_DataMemory.m_ram.data_memory[40]);
        end else $display("  pass  CACHE_MODE=1: backing RAM addr40 == 123 after fence (delayed flush landed)");

        total_checks = total_checks + 1;
        if (max_stall_run_c < MEM_LATENCY_D) begin
            total_fails = total_fails + 1;
            $display("  FAIL  CACHE_MODE=1: longest mem_stall run was only %0d cycles, expected >= %0d: latency isn't reaching DCache.v's fill engine",
                max_stall_run_c, MEM_LATENCY_D);
        end else $display("  pass  CACHE_MODE=1: longest mem_stall run was %0d cycles (>= MEM_LATENCY_D=%0d): DCache.v's fill/writeback engine inherited the delay transparently",
            max_stall_run_c, MEM_LATENCY_D);

        report("mem_latency_d_i2");
        $finish;
    end
endmodule
