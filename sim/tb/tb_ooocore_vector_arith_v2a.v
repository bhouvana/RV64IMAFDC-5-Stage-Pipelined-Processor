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

// Generation 7, Pillar V, Phase 2a (Gen7-V, docs/adr/0062). Real vector
// arithmetic (LMUL=1) end-to-end through OOOCore.v's real dispatch/
// rename/RS_VALU/VALU.v/CDB/ROB-retire path. Proves the WIRING (dual-
// issue exclusion, cross-file .vx read, chained .vv dependency through
// the vector rename stack, the new additive ROB is_vec_dest bit, the new
// 6th completion port) -- VALU.v's own per-element/masking/tail-agnostic
// semantics are already proven standalone in tb_valu_unit.v, not
// re-tested here.
module tb_ooocore_vector_arith_v2a;
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

    // Only the low 32 bits (element0, SEW32) are checked -- every element
    // holds the same broadcast value in this test (vadd.vi/vand.vx's own
    // scalar/immediate operand applies identically to every active
    // element), so element0 alone is a sufficient, real proof.
    task check_vreg;
        input [4:0] areg;
        input [31:0] expected;
        input [1023:0] label;
        reg [5:0] preg;
        reg [31:0] actual;
        begin
            preg = dut.m_RAT_Vec.arch_map[areg];
            actual = dut.m_PRF_Vec.regs[preg][31:0];
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s (v%0d via vpreg%0d): %h, expected %h", label, areg, preg, actual, expected);
            end else begin
                $display("pass  %0s (v%0d via vpreg%0d): %h", label, areg, preg, actual);
            end
        end
    endtask

    reg rst = 0;

    OOOCore #(
        .XLEN(64), .NUM_AREGS(32), .NUM_PREGS(64),
        .ROB_ENTRIES(16), .RS_ALU_ENTRIES(8),
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_vector_arith_v2a.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Generous fixed wait -- 8 real instructions, several genuinely
        // multi-cycle (VALU.v takes ~16 cycles/instruction at SEW32,
        // LMUL1, 16 elements) -- 600 cycles is a real, generous margin,
        // not a tight one.
        for (i = 0; i < 600; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd5, 64'h0000000000000010, "vsetvli x5,x10,e32,m1: vl=min(100,16)=16");
        check_vreg(5'd1, 32'h00000005, "vadd.vi v1,v0,5: v1=0+5=5");
        check_vreg(5'd2, 32'h00000003, "vadd.vi v2,v0,3: v2=0+3=3");
        check_vreg(5'd3, 32'h00000008, "vadd.vv v3,v1,v2: v3=5+3=8");
        check_vreg(5'd4, 32'h00000005, "vand.vx v4,v1,x11: v4=5&15=5");
        check_vreg(5'd6, 32'hFFFFFFFF, "vadd.vi v6,v0,-1: v6=-1");
        check_vreg(5'd7, 32'hFFFFFFFF, "vmin.vv v7,v6,v2: v7=min(-1,3)=-1 (signed)");

        $display("=== %0d/%0d checks passed ===", checks - fails, checks);
        if (fails == 0) $display("PASS  ooocore_vector_arith_v2a (%0d checks)", checks);
        else $display("FAIL  ooocore_vector_arith_v2a (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
