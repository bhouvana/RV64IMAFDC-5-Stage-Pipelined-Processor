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

// Generation 6, Gen6-F. OOOCore.v's first MUL/DIV end-to-end test.
// MUL/MULH/MULHSU/MULHU flow through the pre-existing RS_ALU/ALU.v path
// unchanged (confirmed here, not newly built); DIV/DIVU/REM/REMU exercise
// the real new RS_DIV + Divider.v multi-cycle completion path, including
// its own dedicated 3rd CDB/ROB-complete/PRF-write port. Same
// fixed-cycle-count + committed-architectural-state-diff style as every
// other Gen6-* OOOCore end-to-end test.
module tb_ooocore_muldiv_f1;
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_muldiv_f1.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Generous fixed wait -- DIV/REM are genuinely 64-cycle multi-cycle
        // ops (Divider.v iterates XLEN cycles), and this program has 4 of
        // them (2 shared serialized through the single Divider instance,
        // 2 more independent but still serialized behind it) -- 700
        // cycles gives ample margin over the real worst case (~4*64 plus
        // dispatch/retire overhead).
        for (i = 0; i < 700; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd1,  64'd6,                  "x1 = 6");
        check_areg(5'd2,  64'd7,                  "x2 = 7");
        check_areg(5'd3,  64'd42,                 "x3 = x1*x2 = 42 (MUL, existing ALU path)");
        check_areg(5'd4,  64'hFFFFFFFF_FFFFFFFF,  "x4 = -1 sign-extended");
        check_areg(5'd5,  64'd6,                  "x5 = mulhu(x4,x2) = 6 (MULHU, existing ALU path)");
        check_areg(5'd6,  64'd6,                  "x6 = x3/x2 = 6 (DIV, real Divider.v path)");
        check_areg(5'd7,  64'd0,                  "x7 = x3%x2 = 0 (REM)");
        check_areg(5'd8,  64'hFFFFFFFF_FFFFFFEC,  "x8 = -20 sign-extended");
        check_areg(5'd9,  64'hFFFFFFFF_FFFFFFFE,  "x9 = -20/7 = -2 (signed DIV, truncates toward 0)");
        check_areg(5'd10, 64'hFFFFFFFF_FFFFFFFA,  "x10 = -20%7 = -6 (signed REM)");
        check_areg(5'd11, 64'h24924924_9249248F,  "x11 = unsigned(-20)/7 (DIVU, real huge unsigned quotient)");

        if (fails == 0) $display("PASS  ooocore_muldiv_f1 (%0d checks)", checks);
        else $display("FAIL  ooocore_muldiv_f1 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
