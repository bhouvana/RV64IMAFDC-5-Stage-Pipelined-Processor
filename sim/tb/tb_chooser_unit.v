`include "Chooser.v"

// docs/adr/0040-gshare-tournament-branch-predictor.md (Generation 4, Phase
// A). Standalone unit test for Chooser.v, independent of Bht.v/Gshare.v/
// the pipeline -- a_correct/b_correct are driven directly as plain regs,
// exactly as if some other pair of direction predictors had already
// resolved them.
module tb_chooser_unit;
    reg clk = 0;
    reg rst = 0;
    reg [31:0] query_pc = 0;
    wire prefer_b;
    reg update_valid = 0;
    reg [31:0] update_pc = 0;
    reg a_correct = 0;
    reg b_correct = 0;

    integer fails = 0;
    integer checks = 0;

    Chooser #(.XLEN(32), .NUM_ENTRIES(4)) dut(
        .clk(clk), .rst(rst),
        .query_pc(query_pc), .prefer_b(prefer_b),
        .update_valid(update_valid), .update_pc(update_pc),
        .a_correct(a_correct), .b_correct(b_correct)
    );

    always #5 clk = ~clk;

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

    task train;
        input [31:0] pc;
        input a_ok;
        input b_ok;
        begin
            @(posedge clk);
            update_valid <= 1; update_pc <= pc; a_correct <= a_ok; b_correct <= b_ok;
            @(posedge clk);
            update_valid <= 0;
        end
    endtask

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Reset: cold, strongly-prefer-A.
        query_pc = 32'd0;
        #1 check_bit(prefer_b, 1'b0, "reset: pc=0 prefers A (cold, strongly-prefer-A)");

        // Agreement (both right): no update at all, even though it "looks
        // productive" -- the real tournament rule is disagreement-only
        // training.
        train(32'd0, 1'b1, 1'b1);
        query_pc = 32'd0;
        #1 check_bit(prefer_b, 1'b0, "both correct (agreement): no training, still prefers A");
        train(32'd0, 1'b0, 1'b0);
        #1 check_bit(prefer_b, 1'b0, "both wrong (agreement): no training, still prefers A");

        // Disagreement, B right: nudge toward B, full walk to saturation.
        train(32'd0, 1'b0, 1'b1);  // 00 -> 01
        #1 check_bit(prefer_b, 1'b0, "1 disagreement favoring B (00->01, weakly-A): still prefers A");
        train(32'd0, 1'b0, 1'b1);  // 01 -> 10
        #1 check_bit(prefer_b, 1'b1, "2 disagreements favoring B (01->10, weakly-B): now prefers B");
        train(32'd0, 1'b0, 1'b1);  // 10 -> 11
        #1 check_bit(prefer_b, 1'b1, "3 disagreements favoring B (10->11, strongly-B): still prefers B");
        train(32'd0, 1'b0, 1'b1);  // 11 -> 11 saturate
        #1 check_bit(prefer_b, 1'b1, "4 disagreements favoring B (11->11, saturated): still prefers B");

        // Disagreement, A right: walk back down.
        train(32'd0, 1'b1, 1'b0);  // 11 -> 10
        #1 check_bit(prefer_b, 1'b1, "1 disagreement favoring A (11->10, weakly-B): still prefers B");
        train(32'd0, 1'b1, 1'b0);  // 10 -> 01
        #1 check_bit(prefer_b, 1'b0, "2 disagreements favoring A (10->01, weakly-A): now prefers A");

        // Independent entry (pc=4, index 1) unaffected by pc=0's training.
        train(32'd4, 1'b0, 1'b1);
        train(32'd4, 1'b0, 1'b1);
        query_pc = 32'd4;
        #1 check_bit(prefer_b, 1'b1, "pc=4 (index 1) trained toward B independently: prefers B");
        query_pc = 32'd0;
        #1 check_bit(prefer_b, 1'b0, "pc=0 (index 0) unaffected by pc=4's training: still prefers A");

        if (fails == 0)
            $display("PASS  chooser_unit (%0d checks)", checks);
        else
            $display("FAIL  chooser_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
