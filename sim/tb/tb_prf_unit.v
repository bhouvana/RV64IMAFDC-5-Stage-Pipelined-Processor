`include "PhysicalRegisterFile.v"

// Generation 6, Gen6-A. Standalone unit test for PhysicalRegisterFile.v,
// fully independent of FreeList.v/RegisterAliasTable.v/OOOCore.v --
// drives alloc/write/read ports directly with hand-picked physical
// register numbers.
module tb_prf_unit;
    reg clk = 0;
    always #5 clk = ~clk;

    integer fails = 0;
    integer checks = 0;

    task check_val;
        input [63:0] actual, expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: %0d, expected %0d", label, actual, expected);
            end else begin
                $display("pass  %0s: %0d", label, actual);
            end
        end
    endtask

    task check_bit;
        input actual, expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: %b, expected %b", label, actual, expected);
            end else begin
                $display("pass  %0s: %b", label, actual);
            end
        end
    endtask

    reg        rst = 0;
    reg  [5:0] raddr0 = 0, raddr1 = 0, raddr2 = 0, raddr3 = 0, raddr4 = 0, raddr5 = 0, raddr6 = 0, raddr7 = 0;
    wire [63:0] rdata0, rdata1, rdata2, rdata3, rdata4, rdata5, rdata6, rdata7;
    wire       rvalid0, rvalid1, rvalid2, rvalid3, rvalid4, rvalid5, rvalid6, rvalid7;
    reg        wen0 = 0, wen1 = 0, wen2 = 0;
    reg  [5:0] waddr0 = 0, waddr1 = 0, waddr2 = 0;
    reg [63:0] wdata0 = 0, wdata1 = 0, wdata2 = 0;
    reg        alloc_en0 = 0, alloc_en1 = 0;
    reg  [5:0] alloc_preg0 = 0, alloc_preg1 = 0;

    PhysicalRegisterFile #(.XLEN(64), .NUM_PREGS(64), .NUM_AREGS(32)) dut(
        .clk(clk), .rst(rst),
        .raddr0(raddr0), .raddr1(raddr1), .raddr2(raddr2), .raddr3(raddr3), .raddr4(raddr4), .raddr5(raddr5), .raddr6(raddr6), .raddr7(raddr7),
        .rdata0(rdata0), .rdata1(rdata1), .rdata2(rdata2), .rdata3(rdata3), .rdata4(rdata4), .rdata5(rdata5), .rdata6(rdata6), .rdata7(rdata7),
        .rvalid0(rvalid0), .rvalid1(rvalid1), .rvalid2(rvalid2), .rvalid3(rvalid3), .rvalid4(rvalid4), .rvalid5(rvalid5), .rvalid6(rvalid6), .rvalid7(rvalid7),
        .wen0(wen0), .waddr0(waddr0), .wdata0(wdata0),
        .wen1(wen1), .waddr1(waddr1), .wdata1(wdata1),
        .wen2(wen2), .waddr2(waddr2), .wdata2(wdata2),
        .alloc_en0(alloc_en0), .alloc_preg0(alloc_preg0),
        .alloc_en1(alloc_en1), .alloc_preg1(alloc_preg1)
    );

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // -- Case 1: reset state -- identity-mapped pregs (0..31) hold 0
        // and are valid; preg2 (== areg x2/sp) holds SP_INIT; unallocated
        // pregs (32+) are NOT valid --
        raddr0 = 5; raddr1 = 2; raddr2 = 40; #1;
        check_val(rdata0, 64'd0, "case1: preg5 == 0 at reset");
        check_bit(rvalid0, 1'b1, "case1: preg5 valid at reset (identity mapping)");
        check_val(rdata1, 64'd128, "case1: preg2 == SP_INIT at reset");
        check_bit(rvalid2, 1'b0, "case1: preg40 NOT valid at reset (never allocated yet)");

        // -- Case 2: preg0 (x0) always reads 0/valid, unconditionally --
        raddr0 = 0; #1;
        check_val(rdata0, 64'd0, "case2: preg0 always reads 0");
        check_bit(rvalid0, 1'b1, "case2: preg0 always valid");

        // -- Case 3: rename allocation clears valid on a fresh preg --
        @(negedge clk);
        alloc_en0 = 1; alloc_preg0 = 6'd40;
        #1;
        @(posedge clk); #1;
        alloc_en0 = 0;
        raddr0 = 40; #1;
        check_bit(rvalid0, 1'b0, "case3: preg40 not valid right after allocation");

        // -- Case 4: a CDB write sets both data and valid --
        @(negedge clk);
        wen0 = 1; waddr0 = 6'd40; wdata0 = 64'hDEAD_BEEF_0000_1234;
        #1;
        @(posedge clk); #1;
        wen0 = 0;
        raddr0 = 40; #1;
        check_val(rdata0, 64'hDEAD_BEEF_0000_1234, "case4: preg40 holds the CDB write's data");
        check_bit(rvalid0, 1'b1, "case4: preg40 valid after the CDB write");

        // -- Case 5: write-first bypass -- a read landing the SAME cycle
        // a write targets that preg sees the fresh value/valid
        // immediately, combinationally --
        @(negedge clk);
        wen0 = 1; waddr0 = 6'd41; wdata0 = 64'hCAFE;
        raddr0 = 41;
        #1;
        check_val(rdata0, 64'hCAFE, "case5: same-cycle write-first bypass on data");
        check_bit(rvalid0, 1'b1, "case5: same-cycle write-first bypass on valid");
        @(posedge clk); #1;
        wen0 = 0;

        // -- Case 6: two independent CDB writes, different pregs, same
        // cycle -- both land --
        @(negedge clk);
        wen0 = 1; waddr0 = 6'd42; wdata0 = 64'd111;
        wen1 = 1; waddr1 = 6'd43; wdata1 = 64'd222;
        #1;
        @(posedge clk); #1;
        wen0 = 0; wen1 = 0;
        raddr0 = 42; raddr1 = 43; #1;
        check_val(rdata0, 64'd111, "case6: preg42 gets its own write");
        check_val(rdata1, 64'd222, "case6: preg43 gets its own write, independently");

        if (fails == 0) $display("PASS  prf_unit (%0d checks)", checks);
        else $display("FAIL  prf_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
