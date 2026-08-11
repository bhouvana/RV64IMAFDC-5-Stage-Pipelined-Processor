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

// Generation 7, Pillar V, Phase 3 (Gen7-V, docs/adr/0064). Real vle32.v/
// vse32.v round-trip through OOOCore.v's real dispatch/rename/RS_VLSU/
// VLSU.v/CDB/ROB-retire path, sharing the same DataMemoryBRAM.v port the
// scalar LSQ already uses (real 3-way arbitration, not a separate
// memory). VLSU.v's own per-element/masking/tail-agnostic semantics are
// already proven standalone in tb_vlsu_unit.v, not re-tested here --
// this test proves the WIRING.
module tb_ooocore_vector_ls_v3;
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_vector_ls_v3.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Generous fixed wait -- 6 real instructions, several genuinely
        // multi-cycle (VALU.v ~16 cycles for the vadd.vi; VLSU.v ~16*3
        // cycles each for the vse32/vle32, one 3-cycle load or 1-cycle
        // store per element) -- 1500 cycles is a real, generous margin.
        for (i = 0; i < 1500; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd5, 64'h0000000000000010, "vsetvli x5,x10,e32,m1: vl=16");
        check_vreg_elem(5'd1, 4'd0, 32'h00000005, "vadd.vi v1,v0,5: v1 elem0=5");
        check_vreg_elem(5'd2, 4'd0, 32'h00000005, "vle32.v v2,(x11) elem0: round-trip=5");
        check_vreg_elem(5'd2, 4'd15, 32'h00000005, "vle32.v v2,(x11) elem15: round-trip=5 (full 16-element store+load)");

        $display("=== %0d/%0d checks passed ===", checks - fails, checks);
        if (fails == 0) $display("PASS  ooocore_vector_ls_v3 (%0d checks)", checks);
        else $display("FAIL  ooocore_vector_ls_v3 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
