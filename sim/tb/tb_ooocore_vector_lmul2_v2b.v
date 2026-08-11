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

// Generation 7, Pillar V, Phase 2b (Gen7-V, docs/adr/0063). Real LMUL=2
// crack-into-microops proof through OOOCore.v's real dispatch path --
// ONE macro vadd.vi instruction must produce TWO real, independently-
// renamed physical vector registers (v2 AND v3), with per-crack-op
// local vl correctly clamped (proving the crack sequencer's own
// per-register element-range math, not just "it ran twice").
module tb_ooocore_vector_lmul2_v2b;
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
        input [3:0] elem;        // SEW32 element index within this physical register
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_vector_lmul2_v2b.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        for (i = 0; i < 700; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd5, 64'h0000000000000014, "vsetvli x5,x10,e32,m2: vl=20 (unclamped, <VLMAX=32)");
        // crack0 (v2): local_vl=16, elements 0 and 15 both active (real proof of a full 16-element run).
        check_vreg_elem(5'd2, 4'd0,  32'h00000007, "v2 elem0 (crack0, always active) = 0+7=7");
        check_vreg_elem(5'd2, 4'd15, 32'h00000007, "v2 elem15 (crack0, last of local_vl=16) = 7");
        // crack1 (v3): local_vl=20-16=4 -- elements 0-3 active, element4+ tail-agnostic ZERO
        // (the real proof this crack-op got its OWN clamped vl, not the macro instruction's raw 20).
        check_vreg_elem(5'd3, 4'd0, 32'h00000007, "v3 elem0 (crack1, active, local_vl=4) = 0+7=7");
        check_vreg_elem(5'd3, 4'd3, 32'h00000007, "v3 elem3 (crack1, last active elem of local_vl=4) = 7");
        check_vreg_elem(5'd3, 4'd4, 32'h00000000, "v3 elem4 (crack1, PAST local_vl=4, tail-agnostic zero)");
        check_vreg_elem(5'd3, 4'd15, 32'h00000000, "v3 elem15 (crack1, well past local_vl=4, zero)");

        $display("=== %0d/%0d checks passed ===", checks - fails, checks);
        if (fails == 0) $display("PASS  ooocore_vector_lmul2_v2b (%0d checks)", checks);
        else $display("FAIL  ooocore_vector_lmul2_v2b (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
