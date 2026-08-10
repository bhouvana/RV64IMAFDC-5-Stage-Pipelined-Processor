`include "OOOCore.v"
`include "InstructionMemory.v"
`include "Control.v"
`include "ALUCtrl.v"
`include "ImmGen.v"
`include "ALU.v"
`include "FALU.v"
`include "RegisterAliasTable.v"
`include "FreeList.v"
`include "PhysicalRegisterFile.v"
`include "ReorderBuffer.v"
`include "ReservationStation.v"
`include "LoadStoreQueue.v"
`include "DataMemoryBRAM.v"
`include "Divider.v"
`include "Bht.v"
`include "Btb.v"
`include "CSR.v"
`include "Tlb39.v"
`include "Ptw39.v"

// Generation 6, Gen6-P2b (docs/adr/0053). OOOCore.v's own first LIVE Sv39
// translation test: a real gigapage identity mapping, mret into the
// translated region, and a marker instruction proving the translated
// fetch actually landed at the right physical address -- not just that
// Tlb39.v/Ptw39.v elaborate cleanly (Gen6-P2a already proved that with
// zero behavior change; this proves the NEW behavior itself, for
// sim/programs/ooocore_mmu_p2b.s).
module tb_ooocore_mmu_p2b;
    reg clk = 0;
    always #5 clk = ~clk;

    integer fails = 0;
    integer checks = 0;

    task check_areg;
        input [4:0] areg;
        input [63:0] expected;
        input [1023:0] label;
        reg [5:0] preg;
        reg [63:0] actual;
        begin
            preg = dut.m_RAT.arch_map[areg];
            actual = dut.m_PRF.regs[preg];
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s (x%0d via preg%0d): %h, expected %h", label, areg, preg, actual, expected);
            end else begin
                $display("pass  %0s (x%0d via preg%0d): %h", label, areg, preg, actual);
            end
        end
    endtask

    reg rst = 0;

    OOOCore #(
        .XLEN(64), .NUM_AREGS(32), .NUM_PREGS(64),
        .ROB_ENTRIES(16), .RS_ALU_ENTRIES(8),
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_mmu_p2b.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        for (i = 0; i < 400; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd1, 64'h1B, "x1 = 0x1B (gigapage leaf PTE)");
        check_areg(5'd3, 64'h8000000000000000, "x3 = satp value (MODE=Sv39, PPN=0)");
        check_areg(5'd4, 64'd36, "x4 = 36 (VA written to mepc)");
        check_areg(5'd10, 64'd111, "x10 = 111 -- the marker instruction, only reachable via a REAL translated fetch landing at PA 36");

        if (fails == 0) $display("PASS  ooocore_mmu_p2b (%0d checks)", checks);
        else $display("FAIL  ooocore_mmu_p2b (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
