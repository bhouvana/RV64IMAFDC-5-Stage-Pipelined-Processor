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

// Generation 6, Gen6-P4 (docs/adr/0055). OOOCore.v's own first fdiv.s/
// fsqrt.s test -- RS_FDIV + the real, multi-cycle FDivider.v/FSqrt.v.
// For sim/programs/ooocore_fdiv_p4.s.
module tb_ooocore_fdiv_p4;
    reg clk = 0;
    always #5 clk = ~clk;

    integer fails = 0;
    integer checks = 0;

    task check_freg;
        input [4:0] areg;
        input [31:0] expected;
        input [1023:0] label;
        reg [5:0] preg;
        reg [31:0] actual;
        begin
            preg = dut.m_RAT_Float.arch_map[areg];
            actual = dut.m_PRF_Float.regs[preg];
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s (f%0d via fpreg%0d): %h, expected %h", label, areg, preg, actual, expected);
            end else begin
                $display("pass  %0s (f%0d via fpreg%0d): %h", label, areg, preg, actual);
            end
        end
    endtask

    reg rst = 0;

    OOOCore #(
        .XLEN(64), .NUM_AREGS(32), .NUM_PREGS(64),
        .ROB_ENTRIES(16), .RS_ALU_ENTRIES(8),
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_fdiv_p4.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (
        .clk(clk), .rst(rst), .mailbox_readData(64'b0),
        .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0)
    );

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // FDivider.v/FSqrt.v are both real, multi-cycle iterative units --
        // a generous budget, sized well above either's own worst-case
        // iteration count.
        for (i = 0; i < 800; i = i + 1)
            @(posedge clk);
        #1;

        check_freg(5'd1, 32'h40C00000, "f1 = 6.0f (via FMV.W.X)");
        check_freg(5'd2, 32'h40000000, "f2 = 2.0f (via FMV.W.X)");
        check_freg(5'd3, 32'h40400000, "f3 = f1/f2 = 3.0f (FDIV.S, real multi-cycle FDivider.v)");
        check_freg(5'd4, 32'h3FB504F3, "f4 = sqrt(f2) = sqrt(2.0f) (FSQRT.S, real multi-cycle FSqrt.v)");

        if (fails == 0) $display("PASS  ooocore_fdiv_p4 (%0d checks)", checks);
        else $display("FAIL  ooocore_fdiv_p4 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
