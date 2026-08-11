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

// Generation 7, Pillar V backlog closure (docs/adr/0066). Mask-writing
// compares (vmseq/vmsne/vmslt(u)/vmsle(u)/vmsgt(u), LMUL<=1) end-to-end
// through OOOCore.v's real dispatch/rename/RS_VALU/CDB/ROB-retire path.
module tb_ooocore_vector_cmp_v6;
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
            end else
                $display("pass  %0s (x%0d via preg%0d): %h", label, areg, preg, actual);
        end
    endtask

    task check_vreg_elem;
        input [4:0] areg;
        input [3:0] elem;
        input [31:0] expected;
        input [1023:0] label;
        reg [5:0] preg;
        reg [31:0] actual;
        begin
            preg = dut.m_RAT_Vec.arch_map[areg];
            actual = dut.m_PRF_Vec.regs[preg][elem*32 +: 32];
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s (v%0d elem%0d via vpreg%0d): %h, expected %h", label, areg, elem, preg, actual, expected);
            end else
                $display("pass  %0s (v%0d elem%0d via vpreg%0d): %h", label, areg, elem, preg, actual);
        end
    endtask

    reg rst = 0;

    OOOCore #(
        .XLEN(64), .NUM_AREGS(32), .NUM_PREGS(64),
        .ROB_ENTRIES(16), .RS_ALU_ENTRIES(8),
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_vector_cmp_v6.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        for (i = 0; i < 900; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd5, 64'h0000000000000010, "vsetvli x5,x10,e32,m1: vl=16");
        check_vreg_elem(5'd1, 4'd0, 32'h00000005, "vadd.vi v1,v0,5: v1 elem0=5");
        check_vreg_elem(5'd2, 4'd0, 32'h00000003, "vadd.vi v2,v0,3: v2 elem0=3");
        check_vreg_elem(5'd6, 4'd0, 32'h0000FFFF, "vmsltu.vv v6,v2,v1: 3<5 unsigned true for all 16 elems -> low 16 bits set");
        check_vreg_elem(5'd8, 4'd0, 32'h0000FFFF, "vmslt.vx v8,v1,x11(=10): 5<10 signed true for all 16 elems -> low 16 bits set");

        $display("=== %0d/%0d checks passed ===", checks - fails, checks);
        if (fails == 0) $display("PASS  ooocore_vector_cmp_v6 (%0d checks)", checks);
        else $display("FAIL  ooocore_vector_cmp_v6 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
