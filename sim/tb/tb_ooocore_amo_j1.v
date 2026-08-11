`include "OOOCore.v"
`include "VALU.v"
`include "VLSU.v"
`include "InstructionMemory.v"
`include "Control.v"
`include "ALUCtrl.v"
`include "ImmGen.v"
`include "ALU.v"
`include "FALU.v"
`include "FDivider.v"
`include "FSqrt.v"
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

// Generation 6, Gen6-J. OOOCore.v's first atomics end-to-end test: LR.D
// routed through the exact same LoadStoreQueue.v dispatch path an
// ordinary load already uses (is_amo_lr OR'd into is_mem_op), for
// sim/programs/ooocore_amo_j1.s.
module tb_ooocore_amo_j1;
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_amo_j1.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        for (i = 0; i < 300; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd1, 64'd100, "x1 = 100 (base)");
        check_areg(5'd2, 64'd555, "x2 = 555");
        check_areg(5'd3, 64'd555, "x3 = lr.d(x1) = 555, matches the store");
        check_areg(5'd4, 64'd555, "x4 = x3+x0 = 555 -- an ordinary ALU op consuming LR's own result");

        if (fails == 0) $display("PASS  ooocore_amo_j1 (%0d checks)", checks);
        else $display("FAIL  ooocore_amo_j1 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
