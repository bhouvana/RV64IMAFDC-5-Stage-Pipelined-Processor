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

// Generation 7, Pillar B (Gen7-B10, docs/adr/0060). B-extension end-to-end
// through OOOCore.v's real dispatch/rename/RS_ALU/CDB/ROB-retire path --
// same structural shape as sim/tb/tb_ooocore_alu_d1.v (Gen6-D), just with
// B-ext mnemonics instead of base-ISA ones. Every op here routes through
// the SAME RS_ALU/ALU.v path base ALU ops already use (zero new RS/ROB
// port), so this test is really proving the decode-side wiring (ALUCtrl.v's
// new rs2_c port, the widened ALUCtl bus) survives OOOCore.v's rename/
// dispatch/issue pipeline intact, not new execution-unit plumbing.
module tb_ooocore_bext_b10;
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_bext_b10.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Generous fixed wait -- 31 real instructions, same margin as
        // tb_ooocore_alu_d1.v's own 200-cycle wait for 20 instructions.
        for (i = 0; i < 300; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd10, 64'h0000000000000004, "andn x10,x1,x2 = 5 & ~3 = 4");
        check_areg(5'd11, 64'hFFFFFFFFFFFFFFFD, "orn x11,x1,x2 = 5 | ~3");
        check_areg(5'd12, 64'hFFFFFFFFFFFFFFF9, "xnor x12,x1,x2 = ~(5^3)");
        check_areg(5'd13, 64'h0000000000000003, "min x13,x1,x2 = min(5,3) = 3");
        check_areg(5'd14, 64'h0000000000000005, "max x14,x1,x2 = max(5,3) = 5");
        check_areg(5'd15, 64'h0000000000000003, "minu x15,x1,x2 = minu(5,3) = 3");
        check_areg(5'd18, 64'h0000000000000005, "maxu x18,x1,x2 = maxu(5,3) = 5");
        check_areg(5'd19, 64'h0000000000000028, "rol x19,x1,x2 = rotl(5,3) = 40");
        check_areg(5'd20, 64'hA000000000000000, "ror x20,x1,x2 = rotr(5,3)");
        check_areg(5'd21, 64'h000000000000000D, "sh1add x21,x1,x2 = (5<<1)+3 = 13");
        check_areg(5'd22, 64'h0000000000000017, "sh2add x22,x1,x2 = (5<<2)+3 = 23");
        check_areg(5'd23, 64'h000000000000002B, "sh3add x23,x1,x2 = (5<<3)+3 = 43");
        check_areg(5'd24, 64'h0000000000000007, "bclr x24,x16,x2 = 15 & ~(1<<3) = 7");
        check_areg(5'd25, 64'h0000000000000001, "bext x25,x16,x2 = (15>>3)&1 = 1");
        check_areg(5'd26, 64'h0000000000000007, "binv x26,x16,x2 = 15 ^ (1<<3) = 7");
        check_areg(5'd27, 64'h0000000000000023, "bset x27,x2,x1 = 3 | (1<<5) = 35");
        check_areg(5'd29, 64'h0000000000000001, "bexti x29,x16,3 = (15>>3)&1 = 1");
        check_areg(5'd3,  64'h4000000000000001, "rori x3,x1,2 = rotr(5,2)");
        check_areg(5'd4,  64'h000000000000003D, "clz x4,x1 = clz(5) = 61");
        check_areg(5'd5,  64'h0000000000000000, "ctz x5,x1 = ctz(5) = 0");
        check_areg(5'd6,  64'h0000000000000002, "cpop x6,x1 = popcount(5) = 2");
        check_areg(5'd7,  64'h000000000000000F, "sext.b x7,x16 = sign-extend byte(15) = 15");
        check_areg(5'd8,  64'h000000000000000F, "sext.h x8,x16 = sign-extend halfword(15) = 15");
        check_areg(5'd9,  64'h00000000000000FF, "orc.b x9,x1 = orc.b(5): lowest byte nonzero -> 0xFF");
        check_areg(5'd28, 64'h00EFF0F0FFFFFFFF, "rev8 x28,x17 = byte-reverse(0xFFFFFFFFF0F0EF00)");

        if (fails == 0) $display("PASS  ooocore_bext_b10 (%0d checks)", checks);
        else $display("FAIL  ooocore_bext_b10 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
