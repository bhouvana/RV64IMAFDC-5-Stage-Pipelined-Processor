`include "OOOCore.v"
`include "InstructionMemory.v"
`include "Control.v"
`include "ALUCtrl.v"
`include "ImmGen.v"
`include "ALU.v"
`include "FALU.v"
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

// Generation 6, Gen6-E. OOOCore.v's first load/store end-to-end test:
// fetch -> decode -> rename -> dispatch -> LSQ -> DataMemoryBRAM.v ->
// CDB -> ROB retire, for sim/programs/ooocore_lsq_e1.s (store/load
// round trip, twice, plus an ordinary ALU op consuming a loaded value).
// Same fixed-cycle-count + committed-architectural-state-diff style as
// tb_ooocore_alu_d1.v.
module tb_ooocore_lsq_e1;
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
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_lsq_e1.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Generous fixed wait -- memory ops have real latency (issue +
        // complete, ~2 cycles each, strictly in order) on top of the
        // ordinary ALU dispatch-to-retire latency; 300 cycles for 12
        // instructions is ample margin.
        for (i = 0; i < 300; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd1, 64'd100,               "x1 = 100 (base)");
        check_areg(5'd2, 64'd42,                 "x2 = 42");
        check_areg(5'd3, 64'd42,                 "x3 = ld from mem[100] = 42, matches the store");
        check_areg(5'd4, 64'd7,                  "x4 = 7");
        check_areg(5'd5, 64'd7,                  "x5 = lw from mem[108] = 7, matches the second store");
        check_areg(5'd6, 64'd49,                 "x6 = x3+x5 = 49 -- an ordinary ALU op consuming two loaded values");

        if (fails == 0) $display("PASS  ooocore_lsq_e1 (%0d checks)", checks);
        else $display("FAIL  ooocore_lsq_e1 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
