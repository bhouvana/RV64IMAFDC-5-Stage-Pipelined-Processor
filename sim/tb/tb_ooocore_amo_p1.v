`include "OOOCore.v"
`include "VALU.v"
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

// Generation 6, Gen6-P1. OOOCore.v's own general AMO-RMW + SC end-to-end
// test, on top of Gen6-J's LR-only atomics: SC.D (always succeeds,
// single-hart) followed by AMOADD.D (2-phase read-modify-write) against
// the SAME address, for sim/programs/ooocore_amo_p1.s. Proves the NEW
// disp_op_type0 dispatch path (OP_SC / OP_AMO_RMW) this phase added to
// LoadStoreQueue.v is actually wired correctly through OOOCore.v's own
// decode (is_amo_sc/is_amo_rmw, lsq_op_type0, is_mem_op) -- not just the
// standalone LSQ unit test (sim/tb/tb_lsq_unit.v) that already covers
// the module in isolation.
module tb_ooocore_amo_p1;
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_amo_p1.mem"),
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
        check_areg(5'd2, 64'd1000, "x2 = 1000 (AMOADD's own rs2, overwritten after the SC)");
        check_areg(5'd5, 64'd0, "x5 = sc.d's own rd = 0 -- always succeeds, single-hart (ADR 0038)");
        check_areg(5'd6, 64'd555, "x6 = amoadd.d's own rd = OLD mem value (555), not the new sum");
        check_areg(5'd7, 64'd1555, "x7 = ld(x1) = 1555 -- amoadd's own write really landed in memory");

        if (fails == 0) $display("PASS  ooocore_amo_p1 (%0d checks)", checks);
        else $display("FAIL  ooocore_amo_p1 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
