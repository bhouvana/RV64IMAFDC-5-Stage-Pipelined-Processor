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

// Generation 6, Gen6-K. Dual-issue widening's own directed test --
// sim/programs/ooocore_dual_k1.s (see that file's own header for the
// hand-traced bundle-by-bundle pairing). Same "generous fixed wait, then
// diff committed architectural state" convention as tb_ooocore_alu_d1.v,
// plus one extra check that dual-issue actually fired during the run
// (sampling dut.do_dispatch_slot1 directly) -- without that, a bug that
// silently always fell back to single-issue would still pass every
// architectural-state check below and hide the one thing this phase
// actually set out to test.
module tb_ooocore_dual_k1;
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_dual_k1.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst));

    integer dual_issue_count;
    always @(posedge clk) begin
        if (~rst)
            dual_issue_count <= 0;
        else if (dut.do_dispatch_slot1)
            dual_issue_count <= dual_issue_count + 1;
    end

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        for (i = 0; i < 200; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd1, 64'd5,   "x1 = 5");
        check_areg(5'd2, 64'd3,   "x2 = 3");
        check_areg(5'd3, 64'd8,   "x3 = x1+x2 = 8");
        check_areg(5'd4, 64'd3,   "x4 = x3-x1 = 3 (same-bundle RAW bypass)");
        check_areg(5'd5, 64'd6,   "x5 = x1^x2 = 6");
        check_areg(5'd6, 64'd7,   "x6 = x1|x2 = 7");
        check_areg(5'd7, 64'd222, "x7 = 222 (same-bundle WAW, slot1 wins)");

        checks = checks + 1;
        if (dual_issue_count == 0) begin
            fails = fails + 1;
            $display("FAIL  dual-issue never fired (do_dispatch_slot1 stayed 0 the whole run)");
        end else begin
            $display("pass  dual-issue fired %0d times", dual_issue_count);
        end

        if (fails == 0) $display("PASS  ooocore_dual_k1 (%0d checks)", checks);
        else $display("FAIL  ooocore_dual_k1 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
