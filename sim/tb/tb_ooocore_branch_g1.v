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

// Generation 6, Gen6-G. OOOCore.v's first branch-speculation end-to-end
// test: fetch->BHT/BTB-predict->decode->dispatch->RS_ALU/ALU-resolve->
// misprediction detect->PC redirect->recovery, for
// sim/programs/ooocore_branch_g1.s (one genuine misprediction, one
// correctly-predicted branch). Same fixed-cycle-count +
// committed-architectural-state-diff style as every other Gen6-* OOOCore
// end-to-end test -- the real proof here is that x3 stays 0 (the
// wrong-path instruction after the taken branch never commits) while x4/
// x7/x8 all show the CORRECT (non-speculative) architectural outcome.
module tb_ooocore_branch_g1;
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_branch_g1.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Generous fixed wait -- single-outstanding-branch stalls all
        // dispatch until each branch resolves (Gen6-G's own scope cut),
        // adding real latency beyond straight-line code, but this is
        // still a tiny (16-instruction) program.
        for (i = 0; i < 300; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd1, 64'd5,   "x1 = 5");
        check_areg(5'd2, 64'd5,   "x2 = 5");
        check_areg(5'd3, 64'd0,   "x3 = 0 -- the wrong-path instruction after the mispredicted-taken branch1 NEVER committed");
        check_areg(5'd4, 64'd222, "x4 = 222 -- reached via the branch's real (redirected) target");
        check_areg(5'd5, 64'd9,   "x5 = 9");
        check_areg(5'd6, 64'd3,   "x6 = 3");
        check_areg(5'd7, 64'd333, "x7 = 333 -- branch2's correctly-predicted not-taken fallthrough executed normally");
        check_areg(5'd8, 64'd444, "x8 = 444 -- reached either way, post-branch execution continues correctly");

        if (fails == 0) $display("PASS  ooocore_branch_g1 (%0d checks)", checks);
        else $display("FAIL  ooocore_branch_g1 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
