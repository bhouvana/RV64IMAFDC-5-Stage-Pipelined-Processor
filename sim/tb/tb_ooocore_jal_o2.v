`include "OOOCore.v"
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

// Generation 6, Gen6-O (docs/adr/0051). OOOCore.v's own first jal test --
// proves the new decode-time-resolvable PC redirect (docs/adr/0051's own
// Design section): jal's target is known unconditionally at decode (no
// BTB/prediction needed, unlike a conditional branch), so this is a
// real redirect, not a speculative one -- if it worked, the two
// instructions between jal and its target never execute/retire at all.
module tb_ooocore_jal_o2;
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_jal_o2.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        for (i = 0; i < 200; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd1, 64'd11, "x1 = 11 -- untouched by the SKIPPED addi x1,x0,99 instructions");
        check_areg(5'd5, 64'd8,  "x5 = jal's own link value (pc+4 = 4+4 = 8)");
        check_areg(5'd2, 64'd12, "x2 = x1+1 = 12 -- proves fetch/dispatch really landed at target:, not fell through");

        if (fails == 0) $display("PASS  ooocore_jal_o2 (%0d checks)", checks);
        else $display("FAIL  ooocore_jal_o2 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
