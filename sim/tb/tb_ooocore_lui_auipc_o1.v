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

// Generation 6, Gen6-O (docs/adr/0051). OOOCore.v's own first lui/auipc
// test -- proves the new use_forced_a0/forced_a_value0 payload mechanism
// (docs/adr/0051's own Design section) end to end: lui's rd = 0+imm,
// auipc's rd = this instruction's own captured PC + imm, both via the
// SAME RS_ALU/ALU.v pipeline every other ALU op already uses, just with
// operand A forced instead of PRF-read.
module tb_ooocore_lui_auipc_o1;
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_lui_auipc_o1.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        for (i = 0; i < 200; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd1, 64'h1000, "x1 = lui x1,0x1 = 0x1000");
        check_areg(5'd2, 64'h1004, "x2 = auipc x2,0x1 at pc=4 = 0x1004");
        check_areg(5'd3, 64'h1000, "x3 = addi x3,x1,0 -- proves RS wakeup saw lui's own real completion");

        if (fails == 0) $display("PASS  ooocore_lui_auipc_o1 (%0d checks)", checks);
        else $display("FAIL  ooocore_lui_auipc_o1 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
