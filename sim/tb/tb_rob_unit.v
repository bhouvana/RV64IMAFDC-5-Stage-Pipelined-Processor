`include "ReorderBuffer.v"

// Generation 6, Gen6-B. Standalone unit test for ReorderBuffer.v, fully
// independent of RegisterAliasTable.v/FreeList.v/PhysicalRegisterFile.v/
// OOOCore.v -- drives alloc/complete/retire ports directly.
// ROB_ENTRIES=4 (tiny) so wraparound/full are reachable in a handful of
// cycles, same small-parameter-for-coverage convention as
// tb_freelist_unit.v.
module tb_rob_unit;
    reg clk = 0;
    always #5 clk = ~clk;

    integer fails = 0;
    integer checks = 0;

    task check_val;
        input [31:0] actual, expected;
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
    reg        alloc_en0 = 0, alloc_has_dest0 = 0;
    reg  [4:0] alloc_areg0 = 0;
    reg  [5:0] alloc_preg0 = 0, alloc_old_preg0 = 0;
    reg        alloc_en1 = 0, alloc_has_dest1 = 0;
    reg  [4:0] alloc_areg1 = 0;
    reg  [5:0] alloc_preg1 = 0, alloc_old_preg1 = 0;
    wire [1:0] alloc_tag0, alloc_tag1;

    reg        complete_en0 = 0, complete_en1 = 0, complete_en2 = 0, complete_en3 = 0;
    reg  [1:0] complete_tag0 = 0, complete_tag1 = 0, complete_tag2 = 0, complete_tag3 = 0;

    wire       retire_valid0, retire_has_dest0;
    wire [4:0] retire_areg0;
    wire [5:0] retire_preg0, retire_old_preg0;
    wire       retire_valid1, retire_has_dest1;
    wire [4:0] retire_areg1;
    wire [5:0] retire_preg1, retire_old_preg1;

    wire [2:0] rob_count;
    wire       rob_full, rob_empty;

    reg  [1:0] captured_tag;

    ReorderBuffer #(.ROB_ENTRIES(4)) dut(
        .clk(clk), .rst(rst),
        .alloc_en0(alloc_en0), .alloc_has_dest0(alloc_has_dest0), .alloc_is_fp_dest0(1'b0),
        .alloc_areg0(alloc_areg0), .alloc_preg0(alloc_preg0), .alloc_old_preg0(alloc_old_preg0),
        .alloc_tag0(alloc_tag0),
        .alloc_en1(alloc_en1), .alloc_has_dest1(alloc_has_dest1), .alloc_is_fp_dest1(1'b0),
        .alloc_areg1(alloc_areg1), .alloc_preg1(alloc_preg1), .alloc_old_preg1(alloc_old_preg1),
        .alloc_tag1(alloc_tag1),
        .complete_en0(complete_en0), .complete_tag0(complete_tag0),
        .complete_en1(complete_en1), .complete_tag1(complete_tag1),
        .complete_en2(complete_en2), .complete_tag2(complete_tag2),
        .complete_en3(complete_en3), .complete_tag3(complete_tag3),
        .retire_valid0(retire_valid0), .retire_has_dest0(retire_has_dest0), .retire_is_fp_dest0(), .retire_tag0(),
        .retire_areg0(retire_areg0), .retire_preg0(retire_preg0), .retire_old_preg0(retire_old_preg0),
        .retire_valid1(retire_valid1), .retire_has_dest1(retire_has_dest1), .retire_is_fp_dest1(), .retire_tag1(),
        .retire_areg1(retire_areg1), .retire_preg1(retire_preg1), .retire_old_preg1(retire_old_preg1),
        .rob_count(rob_count), .rob_full(rob_full), .rob_empty(rob_empty)
    );

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // -- Case 1: reset state --
        #1;
        check_bit(rob_empty, 1'b1, "case1: empty at reset");
        check_val(rob_count, 3'd0, "case1: count == 0 at reset");

        // -- Case 2: allocate 2 entries in one cycle -- tags 0 and 1 --
        @(negedge clk);
        alloc_en0 = 1; alloc_has_dest0 = 1; alloc_areg0 = 5'd5; alloc_preg0 = 6'd40; alloc_old_preg0 = 6'd5;
        alloc_en1 = 1; alloc_has_dest1 = 1; alloc_areg1 = 5'd6; alloc_preg1 = 6'd41; alloc_old_preg1 = 6'd6;
        #1;
        check_val(alloc_tag0, 2'd0, "case2: alloc_tag0 == 0");
        check_val(alloc_tag1, 2'd1, "case2: alloc_tag1 == 1");
        @(posedge clk); #1;
        alloc_en0 = 0; alloc_en1 = 0;
        check_val(rob_count, 3'd2, "case2: count == 2 after allocating both");

        // -- Case 3: neither entry done yet -- nothing retires --
        check_bit(retire_valid0, 1'b0, "case3: retire_valid0 refused, head not done");

        // -- Case 4: complete tag1 (the SECOND entry) FIRST, out of
        // order -- the head (tag0) is still not done, so NOTHING may
        // retire yet, even though tag1 itself is ready. This is the
        // core ROB property under test. --
        @(negedge clk);
        complete_en1 = 1; complete_tag1 = 2'd1;
        #1;
        @(posedge clk); #1;
        complete_en1 = 0;
        check_bit(retire_valid0, 1'b0, "case4: tag1 done but tag0 (head) isn't -- still nothing retires");
        check_bit(retire_valid1, 1'b0, "case4: slot1 also blocked -- in-order, not just head-blocks-itself");

        // -- Case 5: now complete tag0 too -- both retire the SAME
        // cycle, in the correct areg/preg/old_preg pairing per slot --
        @(negedge clk);
        complete_en0 = 1; complete_tag0 = 2'd0;
        #1;
        @(posedge clk); #1;
        complete_en0 = 0;
        check_bit(retire_valid0, 1'b1, "case5: slot0 retires");
        check_val(retire_areg0, 5'd5, "case5: slot0 retire areg == 5");
        check_val(retire_preg0, 6'd40, "case5: slot0 retire preg == 40");
        check_val(retire_old_preg0, 6'd5, "case5: slot0 retire old_preg == 5, reclaimable");
        check_bit(retire_valid1, 1'b1, "case5: slot1 ALSO retires the same cycle");
        check_val(retire_areg1, 5'd6, "case5: slot1 retire areg == 6");
        check_val(retire_preg1, 6'd41, "case5: slot1 retire preg == 41");

        @(posedge clk); #1;   // let the retire actually commit (head_r/count_r advance)
        check_bit(rob_empty, 1'b1, "case5: empty again after both retire");

        // -- Case 6: has_dest=0 entry (e.g. a store/branch) -- retire
        // signal correctly reports no destination, even though the
        // entry otherwise flows through identically. alloc_tag0 is a
        // LIVE combinational signal (== tail_r), so it must be captured
        // into a variable the same cycle it's granted -- reading it
        // again later would see tail_r's now-advanced value instead
        // (the exact same class of trap Gen6-A's PRF finding warns
        // about: never trust a live wire's value after the cycle that
        // produced the meaning you wanted from it). --
        @(negedge clk);
        alloc_en0 = 1; alloc_has_dest0 = 0; alloc_areg0 = 5'd0; alloc_preg0 = 6'd0; alloc_old_preg0 = 6'd0;
        #1;
        captured_tag = alloc_tag0;
        @(posedge clk); #1;
        alloc_en0 = 0;
        @(negedge clk);
        complete_en0 = 1; complete_tag0 = captured_tag;
        #1;
        @(posedge clk); #1;
        complete_en0 = 0;
        check_bit(retire_valid0, 1'b1, "case6: no-dest entry retires normally");
        check_bit(retire_has_dest0, 1'b0, "case6: retire_has_dest0 correctly 0");
        @(posedge clk); #1;

        // -- Case 7: full detection and wraparound -- ROB_ENTRIES=4,
        // starting empty (head_r==tail_r==3 after case6's own single
        // entry retired). 4 back-to-back single allocations land at
        // tags 3,0,1,2 -- tail_r genuinely wraps past the array
        // boundary, and the 4th alloc fills the ROB completely. --
        check_bit(rob_empty, 1'b1, "case7: empty again after case6's entry retired");

        @(negedge clk);
        alloc_en0 = 1; alloc_has_dest0 = 1; alloc_areg0 = 5'd1; alloc_preg0 = 6'd10; alloc_old_preg0 = 6'd1;
        #1;
        check_val(alloc_tag0, 2'd3, "case7: 1st alloc lands at tag3 (the last index before wrap)");
        @(posedge clk); #1; alloc_en0 = 0;

        @(negedge clk);
        alloc_en0 = 1; alloc_has_dest0 = 1; alloc_areg0 = 5'd2; alloc_preg0 = 6'd11; alloc_old_preg0 = 6'd2;
        #1;
        check_val(alloc_tag0, 2'd0, "case7: 2nd alloc wraps to tag0");
        @(posedge clk); #1; alloc_en0 = 0;

        @(negedge clk);
        alloc_en0 = 1; alloc_has_dest0 = 1; alloc_areg0 = 5'd3; alloc_preg0 = 6'd12; alloc_old_preg0 = 6'd3;
        #1;
        check_val(alloc_tag0, 2'd1, "case7: 3rd alloc lands at tag1");
        @(posedge clk); #1; alloc_en0 = 0;
        check_bit(rob_full, 1'b0, "case7: not yet full, 3/4 entries occupied");

        @(negedge clk);
        alloc_en0 = 1; alloc_has_dest0 = 1; alloc_areg0 = 5'd4; alloc_preg0 = 6'd13; alloc_old_preg0 = 6'd4;
        #1;
        check_val(alloc_tag0, 2'd2, "case7: 4th alloc lands at tag2, ROB now completely full");
        @(posedge clk); #1; alloc_en0 = 0;
        check_bit(rob_full, 1'b1, "case7: ROB full at 4/4 entries");

        if (fails == 0) $display("PASS  rob_unit (%0d checks)", checks);
        else $display("FAIL  rob_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
