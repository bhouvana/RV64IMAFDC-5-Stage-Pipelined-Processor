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

// Generation 7, Pillar V, Phase 1 (Gen7-V4, docs/adr/0061). Real vsetvli
// end-to-end through OOOCore.v's real dispatch/rename/RS_ALU/CDB/ROB-retire
// path -- same structural shape as tb_ooocore_bext_b10.v. vl = min(AVL,
// VLMAX) reuses the SAME RS_ALU/issue/CDB/PRF-write path base ALU ops
// already use (a new payload bit selects a min() override of alu_out at
// issue time instead of ALU.v's own result) -- proving the decode-side
// wiring (Control.v's new isVecCfg arm, the widened RS_ALU payload, the
// forced-operand-A rs1==x0 special case) survives OOOCore.v's rename/
// dispatch/issue pipeline intact, not new execution-unit plumbing.
module tb_ooocore_vsetvli_v1;
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_vsetvli_v1.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Generous fixed wait -- 5 real instructions, same margin
        // convention tb_ooocore_bext_b10.v's own 300-cycle wait uses.
        for (i = 0; i < 300; i = i + 1)
            @(posedge clk);
        #1;

        // vsetvli x5, x10(=100), e32, m4 -> VLMAX=512*4/32=64, AVL=100>64
        // -> clamped to VLMAX.
        check_areg(5'd5, 64'h0000000000000040, "vsetvli x5,x10,e32,m4: vl=min(100,64)=64 (clamped)");
        // vsetvli x7, x11(=10), e32, m4 -> AVL=10<64 -> unclamped.
        check_areg(5'd7, 64'h000000000000000A, "vsetvli x7,x11,e32,m4: vl=min(10,64)=10 (unclamped)");

        if (fails == 0) $display("PASS  ooocore_vsetvli_v1 (%0d checks)", checks);
        else $display("FAIL  ooocore_vsetvli_v1 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
