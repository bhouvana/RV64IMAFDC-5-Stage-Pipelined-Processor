`include "Register.v"

// docs/adr/0044-non-blocking-dcache-mshr-phase-e.md (Generation 4, Phase E).
// Standalone unit test for Register.v's own second write port (we2/waddr2/
// wdata2), independent of riscvpipeline.v. The existing write-first-bypass
// behavior (docs/adr/0002) is pre-existing/unmodified and not re-tested
// here beyond confirming the new port didn't disturb it.
module tb_register_unit;
    reg clk = 0;
    always #5 clk = ~clk;

    integer fails = 0;
    integer checks = 0;

    task check_word;
        input [31:0] actual, expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: 0x%08h, expected 0x%08h", label, actual, expected);
            end else begin
                $display("pass  %0s: 0x%08h", label, actual);
            end
        end
    endtask

    reg        rst = 0;
    reg        regWrite = 0;
    reg [4:0]  readReg1 = 0, readReg2 = 0, writeReg = 0;
    reg [31:0] writeData = 0;
    reg        we2 = 0;
    reg [4:0]  waddr2 = 0;
    reg [31:0] wdata2 = 0;
    wire [31:0] readData1, readData2;

    Register #(.XLEN(32), .NUM_REGS(32), .SP_INIT(32'd128)) dut(
        .clk(clk), .rst(rst), .regWrite(regWrite),
        .readReg1(readReg1), .readReg2(readReg2),
        .writeReg(writeReg), .writeData(writeData),
        .we2(we2), .waddr2(waddr2), .wdata2(wdata2),
        .readData1(readData1), .readData2(readData2)
    );

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // -- Case 1: port2 writes x5, readable next cycle via the normal
        // read ports (regs[] committed) --
        @(negedge clk);
        we2 = 1; waddr2 = 5'd5; wdata2 = 32'hCAFEF00D;
        @(posedge clk); #1;
        we2 = 0;
        readReg1 = 5'd5;
        #1;
        check_word(readData1, 32'hCAFEF00D, "case1: port2 write to x5 committed, readable via port1");

        // -- Case 2: port1 (regWrite) and port2 write DIFFERENT registers
        // the SAME cycle, both land correctly --
        @(negedge clk);
        regWrite = 1; writeReg = 5'd9; writeData = 32'h11112222;
        we2 = 1; waddr2 = 5'd10; wdata2 = 32'h33334444;
        @(posedge clk); #1;
        regWrite = 0; we2 = 0;
        readReg1 = 5'd9; readReg2 = 5'd10;
        #1;
        check_word(readData1, 32'h11112222, "case2: port1's own write (x9) landed correctly");
        check_word(readData2, 32'h33334444, "case2: port2's own write (x10) landed correctly, same cycle");

        // -- Case 3: write-first bypass extended to port2 -- a read of the
        // SAME register port2 is writing THIS cycle sees the fresh value,
        // not the stale pre-write one --
        @(negedge clk);
        we2 = 1; waddr2 = 5'd15; wdata2 = 32'h55556666;
        readReg1 = 5'd15;
        #1;
        check_word(readData1, 32'h55556666, "case3: port2's own write-first bypass, same-cycle read sees fresh data");
        @(posedge clk); #1;
        we2 = 0;

        // -- Case 4: x0 stays hardwired to 0 even if port2 "writes" it --
        @(negedge clk);
        we2 = 1; waddr2 = 5'd0; wdata2 = 32'hDEADBEEF;
        @(posedge clk); #1;
        we2 = 0;
        readReg1 = 5'd0;
        #1;
        check_word(readData1, 32'h0, "case4: x0 stays hardwired to 0 even via port2");

        // -- Case 5: pre-existing port1 write-first bypass still works
        // unmodified (regression check for the edit) --
        @(negedge clk);
        regWrite = 1; writeReg = 5'd20; writeData = 32'h77778888;
        readReg2 = 5'd20;
        #1;
        check_word(readData2, 32'h77778888, "case5: port1's own pre-existing write-first bypass unaffected");
        @(posedge clk); #1;
        regWrite = 0;

        if (fails == 0) $display("PASS  register_unit (%0d checks)", checks);
        else $display("FAIL  register_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
