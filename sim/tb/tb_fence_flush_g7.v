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

// docs/adr/0023-caches.md (Phase G6/G7). Direct, live-pipeline proof of
// this phase's core promise: a store under CACHE_MODE=1 (write-back D$)
// stays dirty in the cache -- invisible to a direct read of the backing
// DataMemoryBRAM array, the same way check_mem_word/every dump template
// reads it -- until fence genuinely flushes it. Checked at two points:
// shortly after the store (before fence executes: backing RAM must NOT yet
// show the value, proving this is really write-back, not write-through),
// and after the program halts (backing RAM MUST show it by then, proving
// the flush actually happened). Built as G6's own live-wiring confidence
// check; doubles as G7's permanent regression (its own plan explicitly
// calls for keeping exactly this test forever).
module tb_fence_flush_g7;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/fence_flush_g7.mem"), .CACHE_MODE(1))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;

        // Shortly after the store (addr40 at PC=4) but well before fence
        // (PC=8) could plausibly have completed a flush -- the dirty value
        // must NOT be visible in the backing array yet.
        #60;
        total_checks = total_checks + 1;
        if (dut.m_DataMemory.m_ram.data_memory[40] === 8'h55) begin
            total_fails = total_fails + 1;
            $display("  FAIL  addr40 already in backing RAM before fence -- not genuinely write-back");
        end else $display("  pass  addr40 NOT yet in backing RAM before fence (genuinely write-back, dirty in D$)");

        // A full flush at the real 4-way/4KB/16B default sizing scans all
        // 256 lines even to skip the clean ones (~1 cycle/line) -- a real,
        // expected cost of this sizing (confirmed via a debug trace: ~277
        // cycles), not a hang. Budgeted generously above that.
        #3500;   // let the program run to completion (fence + halt loop)

        check_reg(10, 32'd999, "x10 = 999: fence itself didn't hang or trap");
        check_mem_word(40, 32'h00000055, "addr40 in backing RAM after fence: the flush actually happened");

        report("fence_flush_g7");
        $finish;
    end
endmodule
