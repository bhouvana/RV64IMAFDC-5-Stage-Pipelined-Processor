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

// Generation 6, Gen6-P2d (docs/adr/0053). OOOCore.v's own D-side Sv39
// translation test: a real D-side page fault (LOAD_PAGE_FAULT, an
// unmapped VPN2), correctly redirected to mtvec, AND -- the real point
// of this test, not just the fault itself -- proof the LSQ is NOT left
// permanently deadlocked afterward (force_retire_ext's own reason to
// exist): a second mret drops back into the SAME still-live translated
// region and an ordinary store+load round-trips correctly right after.
// For sim/programs/ooocore_mmu_p2d.s.
module tb_ooocore_mmu_p2d;
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

    task check_val;
        input [63:0] actual;
        input [63:0] expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: %h, expected %h", label, actual, expected);
            end else begin
                $display("pass  %0s: %h", label, actual);
            end
        end
    endtask

    reg rst = 0;

    OOOCore #(
        .XLEN(64), .NUM_AREGS(32), .NUM_PREGS(64),
        .ROB_ENTRIES(16), .RS_ALU_ENTRIES(8),
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_mmu_p2d.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        for (i = 0; i < 600; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd10, 64'd111, "x10 = 111 -- translated fetch landed at u_code");
        check_areg(5'd22, 64'd222, "x22 = 222 -- the D-side fault correctly redirected to the handler");
        check_val(dut.m_CSR.mcause, 64'd13, "mcause == 13 (MCAUSE_LOAD_PAGE_FAULT)");
        check_areg(5'd24, 64'h1F, "x24 = 0x1F -- recovery's own translated load round-trip succeeded (proves the LSQ did NOT deadlock after the fault)");
        check_val(dut.m_DMem.data_memory[200] | (dut.m_DMem.data_memory[201] << 8) | (dut.m_DMem.data_memory[202] << 16) | (dut.m_DMem.data_memory[203] << 24),
                   32'h0000_001F, "recovery's own translated store really landed in physical memory at 200");

        if (fails == 0) $display("PASS  ooocore_mmu_p2d (%0d checks)", checks);
        else $display("FAIL  ooocore_mmu_p2d (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
