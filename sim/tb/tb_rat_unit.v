`include "RegisterAliasTable.v"

// Generation 6, Gen6-A. Standalone unit test for RegisterAliasTable.v,
// fully independent of FreeList.v/PhysicalRegisterFile.v/OOOCore.v --
// drives rename/retire/restore ports directly with hand-picked physical
// register numbers (doesn't need a real FreeList grant to exercise the
// table logic itself).
module tb_rat_unit;
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

    reg        rst = 0;
    reg  [4:0] raddr0 = 0, raddr1 = 0, raddr2 = 0, raddr3 = 0;
    wire [5:0] rpreg0, rpreg1, rpreg2, rpreg3;
    reg        wen0 = 0, wen1 = 0;
    reg  [4:0] waddr0 = 0, waddr1 = 0;
    reg  [5:0] wpreg0 = 0, wpreg1 = 0;
    wire [5:0] old_preg0, old_preg1;
    reg        cwen0 = 0, cwen1 = 0;
    reg  [4:0] cwaddr0 = 0, cwaddr1 = 0;
    reg  [5:0] cwpreg0 = 0, cwpreg1 = 0;
    reg        restore_en = 0;

    RegisterAliasTable #(.NUM_AREGS(32), .NUM_PREGS(64)) dut(
        .clk(clk), .rst(rst),
        .raddr0(raddr0), .raddr1(raddr1), .raddr2(raddr2), .raddr3(raddr3),
        .rpreg0(rpreg0), .rpreg1(rpreg1), .rpreg2(rpreg2), .rpreg3(rpreg3),
        .wen0(wen0), .waddr0(waddr0), .wpreg0(wpreg0), .old_preg0(old_preg0),
        .wen1(wen1), .waddr1(waddr1), .wpreg1(wpreg1), .old_preg1(old_preg1),
        .cwen0(cwen0), .cwaddr0(cwaddr0), .cwpreg0(cwpreg0),
        .cwen1(cwen1), .cwaddr1(cwaddr1), .cwpreg1(cwpreg1),
        .restore_en(restore_en)
    );

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // -- Case 1: reset identity mapping, areg i -> preg i --
        raddr0 = 5; raddr1 = 6; #1;
        check_val(rpreg0, 6'd5, "case1: identity mapping areg5 -> preg5 at reset");
        check_val(rpreg1, 6'd6, "case1: identity mapping areg6 -> preg6 at reset");

        // -- Case 2: x0 always reads preg0, even if (hypothetically)
        // something tried to remap it --
        raddr0 = 0; #1;
        check_val(rpreg0, 6'd0, "case2: areg x0 always maps to preg0");

        // -- Case 3: single rename write -- old_preg0 reflects the
        // PRE-write mapping combinationally, new mapping visible next
        // cycle --
        @(negedge clk);
        wen0 = 1; waddr0 = 5'd5; wpreg0 = 6'd40;
        #1;
        check_val(old_preg0, 6'd5, "case3: old_preg0 == 5, the pre-write identity mapping");
        @(posedge clk); #1;
        wen0 = 0;
        raddr0 = 5; #1;
        check_val(rpreg0, 6'd40, "case3: areg5 now maps to preg40 after the rename write");

        // -- Case 4: two slots, different aregs, same cycle -- both land
        // independently --
        @(negedge clk);
        wen0 = 1; waddr0 = 5'd6; wpreg0 = 6'd41;
        wen1 = 1; waddr1 = 5'd7; wpreg1 = 6'd42;
        #1;
        @(posedge clk); #1;
        wen0 = 0; wen1 = 0;
        raddr0 = 6; raddr1 = 7; #1;
        check_val(rpreg0, 6'd41, "case4: areg6 -> preg41");
        check_val(rpreg1, 6'd42, "case4: areg7 -> preg42");

        // -- Case 5: two slots, SAME areg, same cycle (WAW within one
        // dispatch bundle) -- old_preg1 must see slot0's own fresh write
        // as its "old" value (not the pre-cycle table), and slot1 (the
        // program-order-later instruction) wins the final mapping --
        @(negedge clk);
        wen0 = 1; waddr0 = 5'd8; wpreg0 = 6'd50;
        wen1 = 1; waddr1 = 5'd8; wpreg1 = 6'd51;
        #1;
        check_val(old_preg1, 6'd50, "case5: old_preg1 bypasses slot0's own same-cycle write");
        @(posedge clk); #1;
        wen0 = 0; wen1 = 0;
        raddr0 = 8; #1;
        check_val(rpreg0, 6'd51, "case5: slot1 (later) wins the final areg8 mapping");

        // -- Case 6: retire commit updates the ARCHITECTURAL table only
        // -- speculative table stays independently whatever it already
        // was --
        @(negedge clk);
        cwen0 = 1; cwaddr0 = 5'd5; cwpreg0 = 6'd40;   // commit areg5->preg40 (matches case3's spec state)
        #1;
        @(posedge clk); #1;
        cwen0 = 0;

        // Now diverge the speculative table for areg5 from what was just
        // committed, simulating a later, not-yet-retired rename.
        @(negedge clk);
        wen0 = 1; waddr0 = 5'd5; wpreg0 = 6'd59;
        #1;
        @(posedge clk); #1;
        wen0 = 0;
        raddr0 = 5; #1;
        check_val(rpreg0, 6'd59, "case6: speculative table diverged from the committed value");

        // -- Case 7: restore_en bulk-copies the ARCHITECTURAL table back
        // over the speculative one, discarding the divergent rename --
        @(negedge clk);
        restore_en = 1;
        #1;
        @(posedge clk); #1;
        restore_en = 0;
        raddr0 = 5; #1;
        check_val(rpreg0, 6'd40, "case7: restore reverts areg5 to its committed (retired) mapping");

        // -- Case 8: restore_en takes priority over a same-cycle rename
        // write (squash wins) --
        @(negedge clk);
        restore_en = 1;
        wen0 = 1; waddr0 = 5'd5; wpreg0 = 6'd61;
        #1;
        @(posedge clk); #1;
        restore_en = 0; wen0 = 0;
        raddr0 = 5; #1;
        check_val(rpreg0, 6'd40, "case8: restore wins over a same-cycle rename write");

        if (fails == 0) $display("PASS  rat_unit (%0d checks)", checks);
        else $display("FAIL  rat_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
