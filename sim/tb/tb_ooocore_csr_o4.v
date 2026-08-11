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

// Generation 6, Gen6-O (docs/adr/0051). OOOCore.v's own first csrrX test
// -- proves the new csr_inflight single-outstanding scope cut end to
// end across all 6 csrrw/csrrs/csrrc(+i) forms: each rd gets the OLD
// mscratch value (captured at dispatch), and mscratch itself is
// actually mutated per the real write/set/clear semantics (resolved
// only once the real operand -- rs1's PRF value or the immediate uimm
// -- is known).
module tb_ooocore_csr_o4;
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_csr_o4.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        for (i = 0; i < 200; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd2, 64'd0, "x2 = old mscratch at reset (0)");
        check_areg(5'd3, 64'd5, "x3 = mscratch after csrrw (5), csrrs x0 is a pure read");
        check_areg(5'd5, 64'd5, "x5 = mscratch BEFORE csrrs x4 (5)");
        check_areg(5'd6, 64'd7, "x6 = mscratch BEFORE csrrc x4 (5|3=7)");
        check_areg(5'd7, 64'd4, "x7 = mscratch BEFORE csrrwi 9 (7&~3=4)");
        check_areg(5'd8, 64'd9, "x8 = final mscratch (9, from csrrwi)");

        if (fails == 0) $display("PASS  ooocore_csr_o4 (%0d checks)", checks);
        else $display("FAIL  ooocore_csr_o4 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
