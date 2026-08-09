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
`include "ICache.v"
`include "DCache.v"
`include "VictimCache.v"

// docs/adr/0042-victim-cache-phase-c.md. End-to-end directed regression:
// VICTIM_ENTRIES wired live through the real pipeline, not just DCache.v's
// own standalone unit test (mirrors tb_cache_lru_b1.v's own role for
// REPLACEMENT_POLICY). PIPELINED instantiated with CACHE_MODE=1,
// VICTIM_ENTRIES=4, and a deliberately small D$ override (2-way/32B/8B
// lines -> 2 sets -- see sim/programs/cache_victim_c1.s's own header) so a
// real eviction-then-recovery is forced, not just cold misses.
module tb_cache_victim_c1;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/cache_victim_c1.mem"), .CACHE_MODE(1),
                .VICTIM_ENTRIES(4),
                .DCACHE_WAYS(2), .DCACHE_SIZE_BYTES(32), .DCACHE_LINE_BYTES(8))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    // Sticky tap: confirm the victim buffer's own same-cycle promote path
    // (vc_do_swap, DCache.v's own internal wire) genuinely fired, not just
    // that the final architectural state happens to be correct -- mirrors
    // tb_cache_lru_b1.v's own dcache_access_miss tap exactly.
    reg seen_victim_promote = 0;
    integer promote_count = 0;
    always @(posedge clk) begin
        if (dut.gen_dcache_writeback.m_DCache.vc_do_swap) begin
            seen_victim_promote <= 1;
            promote_count <= promote_count + 1;
        end
    end

    initial begin
        start = 0;
        #10 start = 1;
        #2000;

        check_reg(4,  32'd100, "x4 = 100: A's promoted content correct after real eviction+recovery");
        check_reg(5,  32'd999, "x5 = 999: marker reached, correct control flow throughout");

        total_checks = total_checks + 1;
        if (seen_victim_promote !== 1'b1) begin
            total_fails = total_fails + 1;
            $display("  FAIL  victim-buffer promote (vc_do_swap) never fired -- test didn't exercise real recovery as intended");
        end else $display("  pass  victim-buffer promote fired (%0d time(s)) -- real eviction+recovery exercised", promote_count);

        total_checks = total_checks + 1;
        if (promote_count < 1) begin
            total_fails = total_fails + 1;
            $display("  FAIL  0 victim-buffer promotes -- expected at least 1 (A's own re-load)");
        end else $display("  pass  %0d victim-buffer promote(s) -- consistent with A's real eviction+recovery", promote_count);

        report("cache_victim_c1");
        $finish;
    end
endmodule
