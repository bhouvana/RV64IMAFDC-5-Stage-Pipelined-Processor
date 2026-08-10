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

// Generation 6, Gen6-D. OOOCore.v's first end-to-end test: fetch -> decode
// -> rename -> dispatch -> RS -> ALU execute -> CDB -> ROB retire, all the
// way through to committed architectural state, for
// sim/programs/ooocore_alu_d1.s (straight-line integer ALU coverage, no
// branches/mem/mul-div/fp -- Gen6-D's own explicit scope). Runs a fixed,
// generous cycle count then reads back committed state via
// RegisterAliasTable.v's own ARCHITECTURAL table (arch_map[areg] -> the
// committed physical register) and PhysicalRegisterFile.v's own storage
// -- the same "final-state diffing, not per-cycle" philosophy this
// project's whole verification approach already uses (confirmed still
// valid for OoO by this session's own Gen6 research), just via direct
// hierarchical reference instead of iss.py (Gen6-L's own job is building
// that real comparison harness -- this is Gen6-D's own narrower, hand-
// computed-expected-values directed test).
module tb_ooocore_alu_d1;
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
        // 128 matches asm.py's own default --size -- sim/run_tests.sh's
        // own assembly loop (no --xlen/--size flags) regenerates every
        // sim/programs/*.mem from its *.s source with plain defaults
        // every run, so this must match that default, not an arbitrary
        // larger value (found by running the full suite: a mismatched
        // IMEM_SIZE_BYTES produces a harmless but real $readmemb
        // "not enough words" runtime warning otherwise).
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_alu_d1.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Generous fixed wait -- 20 real instructions, single-issue,
        // ~3-4 cycle dispatch-to-retire latency but pipelined/overlapped
        // -- 200 cycles is 10x+ margin.
        for (i = 0; i < 200; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd1,  64'd5,                  "x1 = 5");
        check_areg(5'd2,  64'd3,                  "x2 = 3");
        check_areg(5'd3,  64'd8,                  "x3 = x1+x2 = 8");
        check_areg(5'd4,  64'd2,                  "x4 = x1-x2 = 2");
        check_areg(5'd5,  64'd1,                  "x5 = x1&x2 = 1");
        check_areg(5'd6,  64'd7,                  "x6 = x1|x2 = 7");
        check_areg(5'd7,  64'd6,                  "x7 = x1^x2 = 6");
        check_areg(5'd8,  64'd40,                 "x8 = x1<<x2 = 40");
        check_areg(5'd9,  64'd5,                  "x9 = x8>>x2 = 5");
        check_areg(5'd10, 64'd1,                  "x10 = (x2<x1) = 1");
        check_areg(5'd11, 64'd0,                  "x11 = (x1<x2 unsigned) = 0");
        check_areg(5'd12, 64'hFFFFFFFF_FFFFFFFF,  "x12 = -1 sign-extended (XLEN=64)");
        check_areg(5'd13, 64'h0FFFFFFF_FFFFFFFF,  "x13 = x12>>4 logical");
        check_areg(5'd14, 64'hFFFFFFFF_FFFFFFFF,  "x14 = x12>>>4 arithmetic (stays all-1s)");
        check_areg(5'd15, 64'd20,                 "x15 = x1<<2 = 20");
        check_areg(5'd16, 64'd64,                 "x16 = ctz(0) = 64");

        if (fails == 0) $display("PASS  ooocore_alu_d1 (%0d checks)", checks);
        else $display("FAIL  ooocore_alu_d1 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
