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

// Generation 7, Pillar K (Gen7-K7, docs/adr/0059). K-extension end-to-end
// through OOOCore.v's real dispatch/rename/RS_ALU/CDB/ROB-retire path --
// same structural shape as tb_ooocore_bext_b10.v. Every op here routes
// through the SAME RS_ALU/ALU.v path base ALU ops already use (zero new
// RS/ROB port), so this test proves the decode-side wiring (ALUCtrl.v's
// new AES/SHA/Zbkc/Zbkb/Zbkx arms, the 7-bit ALUCtl bus) survives
// OOOCore.v's rename/dispatch/issue pipeline intact -- including the real
// ALUCtrl.v decode arms for the AES R-type ops (aes64ks2 here), a gap
// found while writing this test: Task 6 wired ALU.v's compute logic but
// never added their ALUCtrl.v decode arms, so they were reachable only by
// driving ALUCtl directly in the unit testbench, not from a real
// instruction word. Fixed alongside this test (see the commit).
module tb_ooocore_pillar_k_v7;
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/pillar_k_ooo.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // 7 real instructions -- same generous fixed-wait convention as
        // tb_ooocore_bext_b10.v's own 300-cycle wait for 31.
        for (i = 0; i < 300; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd10, 64'h000000000000000F, "clmul x10,x1,x2 = (5<<0)^(5<<1) = 5^10 = 15");
        check_areg(5'd11, 64'h0000000300000005, "pack x11,x1,x2 = {low32(x2),low32(x1)}");
        check_areg(5'd12, 64'h000000000A014000, "sha256sig0 x12,x1 = ror32(5,7)^ror32(5,18)^(5>>3)");
        check_areg(5'd13, 64'h5555555555555550, "xperm4 x13,x1,x2 (nibble crossbar)");
        check_areg(5'd14, 64'h0000000300000003, "aes64ks2 x14,x1,x2 = {w1,w0} = {3,3}");

        if (fails == 0) $display("PASS  ooocore_pillar_k_v7 (%0d checks)", checks);
        else $display("FAIL  ooocore_pillar_k_v7 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
