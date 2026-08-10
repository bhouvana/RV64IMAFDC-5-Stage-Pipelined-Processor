`include "Scoreboard.v"

// docs/adr/0044-non-blocking-dcache-mshr-phase-e.md (Generation 4, Phase E).
// Standalone unit test for Scoreboard.v, fully independent of DCache.v/
// riscvpipeline.v -- drives alloc_valid/alloc_reg/complete_valid/
// complete_reg/check_reg directly.
module tb_scoreboard_unit;
    reg clk = 0;
    always #5 clk = ~clk;

    integer fails = 0;
    integer checks = 0;

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
    reg        alloc_valid = 0;
    reg  [4:0] alloc_reg = 0;
    reg        complete_valid = 0;
    reg  [4:0] complete_reg = 0;
    reg  [4:0] check_reg = 0;
    wire       reg_pending;

    Scoreboard #(.REG_BITS(5)) dut(
        .clk(clk), .rst(rst),
        .alloc_valid(alloc_valid), .alloc_reg(alloc_reg),
        .complete_valid(complete_valid), .complete_reg(complete_reg),
        .check_reg(check_reg), .reg_pending(reg_pending)
    );

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // -- Case 1: allocate reg5 -- pending next cycle, an unrelated
        // register stays clear --
        @(negedge clk);
        alloc_valid = 1; alloc_reg = 5'd5;
        @(posedge clk); #1;
        alloc_valid = 0;
        check_reg = 5'd5;
        #1;
        check_bit(reg_pending, 1'b1, "case1: reg5 pending the cycle after alloc");
        check_reg = 5'd6;
        #1;
        check_bit(reg_pending, 1'b0, "case1: unrelated reg6 stays clear");

        // -- Case 2: complete reg5 -- pending clears next cycle --
        @(negedge clk);
        complete_valid = 1; complete_reg = 5'd5;
        @(posedge clk); #1;
        complete_valid = 0;
        check_reg = 5'd5;
        #1;
        check_bit(reg_pending, 1'b0, "case2: reg5 no longer pending after complete");

        // -- Case 3: x0 (reg0) never marks pending, even if "allocated" --
        @(negedge clk);
        alloc_valid = 1; alloc_reg = 5'd0;
        @(posedge clk); #1;
        alloc_valid = 0;
        check_reg = 5'd0;
        #1;
        check_bit(reg_pending, 1'b0, "case3: x0 never marks pending");

        // -- Case 4: two independent allocations, completing one doesn't
        // clear the other --
        @(negedge clk);
        alloc_valid = 1; alloc_reg = 5'd5;
        @(posedge clk); #1;
        alloc_valid = 1; alloc_reg = 5'd9;
        @(posedge clk); #1;
        alloc_valid = 0;
        check_reg = 5'd5; #1; check_bit(reg_pending, 1'b1, "case4: reg5 pending");
        check_reg = 5'd9; #1; check_bit(reg_pending, 1'b1, "case4: reg9 ALSO pending, independently");

        @(negedge clk);
        complete_valid = 1; complete_reg = 5'd9;
        @(posedge clk); #1;
        complete_valid = 0;
        check_reg = 5'd9; #1; check_bit(reg_pending, 1'b0, "case4: reg9 cleared by its own completion");
        check_reg = 5'd5; #1; check_bit(reg_pending, 1'b1, "case4: reg5 UNAFFECTED by reg9's own completion");

        // drain reg5 before the next case
        @(negedge clk);
        complete_valid = 1; complete_reg = 5'd5;
        @(posedge clk); #1;
        complete_valid = 0;

        // -- Case 5: alloc and complete on the SAME register the SAME
        // cycle (the caller's own WAW-stall invariant should make this
        // unreachable in practice -- this pins down the module's own
        // defined behavior if that invariant is ever violated) -- alloc
        // wins, stays pending --
        @(negedge clk);
        alloc_valid = 1; alloc_reg = 5'd12;
        @(posedge clk); #1;
        alloc_valid = 0;
        @(negedge clk);
        alloc_valid = 1; alloc_reg = 5'd12;
        complete_valid = 1; complete_reg = 5'd12;
        @(posedge clk); #1;
        alloc_valid = 0; complete_valid = 0;
        check_reg = 5'd12; #1;
        check_bit(reg_pending, 1'b1, "case5: same-cycle alloc+complete on the same reg -- alloc wins, defined behavior");

        // -- Case 6: reset clears every pending bit --
        @(negedge clk); rst <= 0;
        @(posedge clk); rst <= 1;
        @(posedge clk); #1;
        check_reg = 5'd12; #1;
        check_bit(reg_pending, 1'b0, "case6: reset clears a previously-pending register");

        if (fails == 0) $display("PASS  scoreboard_unit (%0d checks)", checks);
        else $display("FAIL  scoreboard_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
