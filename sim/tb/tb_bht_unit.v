`include "Bht.v"

// docs/adr/0021-branch-prediction.md (Phase E2). Standalone unit test for
// Bht.v, independent of the pipeline. Covers: reset state (cold predicts
// not-taken), the full 2-bit saturating-counter transition table in both
// directions (confirming saturation at both boundaries and exactly which
// transition flips `predict_taken`), and index aliasing between two
// different PCs mapping to the same entry (confirming it's simply shared
// state, not a crash or an out-of-bounds access) alongside confirming two
// PCs at genuinely different indices stay fully independent.
module tb_bht_unit;
    reg clk = 0;
    reg rst = 0;
    reg [31:0] query_pc = 0;
    wire predict_taken;
    reg [31:0] train_pc = 0;
    wire train_predict_taken;
    reg update_valid = 0;
    reg [31:0] update_pc = 0;
    reg update_taken = 0;

    integer fails = 0;
    integer checks = 0;

    // NUM_ENTRIES=4 (INDEX_WIDTH=2, index = pc[3:2]) -- small enough that
    // aliasing PCs can be picked by hand and reasoned about directly,
    // mirroring this project's own preference for small, controlled test
    // values (e.g. Timer.v's tb_timer_unit.v uses small mtimecmp values).
    Bht #(.XLEN(32), .NUM_ENTRIES(4)) dut(
        .clk(clk), .rst(rst),
        .query_pc(query_pc), .predict_taken(predict_taken),
        .train_pc(train_pc), .train_predict_taken(train_predict_taken),
        .update_valid(update_valid), .update_pc(update_pc), .update_taken(update_taken)
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
        input taken;
        begin
            @(posedge clk);
            update_valid <= 1; update_pc <= pc; update_taken <= taken;
            @(posedge clk);
            update_valid <= 0;
        end
    endtask

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Reset: every entry cold, predicts not-taken.
        query_pc = 32'd0;
        #1 check_bit(predict_taken, 1'b0, "reset: pc=0 predicts not-taken (cold, strongly-not-taken)");
        query_pc = 32'd4;
        #1 check_bit(predict_taken, 1'b0, "reset: pc=4 (different index) also predicts not-taken");

        // Full saturating-counter walk, taken direction: 00 -> 01 -> 10 -> 11 -> 11.
        // predict_taken must flip to 1 exactly at the 00->01->10 transition
        // (the second "taken" training step), not the first.
        train(32'd0, 1'b1);  // 00 -> 01
        query_pc = 32'd0;
        #1 check_bit(predict_taken, 1'b0, "pc=0 after 1 taken (00->01, weakly-not-taken): still predicts not-taken");
        train(32'd0, 1'b1);  // 01 -> 10
        #1 check_bit(predict_taken, 1'b1, "pc=0 after 2 taken (01->10, weakly-taken): now predicts taken");
        train(32'd0, 1'b1);  // 10 -> 11
        #1 check_bit(predict_taken, 1'b1, "pc=0 after 3 taken (10->11, strongly-taken): still predicts taken");
        train(32'd0, 1'b1);  // 11 -> 11 (saturate)
        #1 check_bit(predict_taken, 1'b1, "pc=0 after 4 taken (11->11, saturated): still predicts taken");

        // Full saturating-counter walk, not-taken direction, from strongly-
        // taken back down: 11 -> 10 -> 01 -> 00 -> 00.
        train(32'd0, 1'b0);  // 11 -> 10
        #1 check_bit(predict_taken, 1'b1, "pc=0 after 1 not-taken (11->10, weakly-taken): still predicts taken");
        train(32'd0, 1'b0);  // 10 -> 01
        #1 check_bit(predict_taken, 1'b0, "pc=0 after 2 not-taken (10->01, weakly-not-taken): now predicts not-taken");
        train(32'd0, 1'b0);  // 01 -> 00
        #1 check_bit(predict_taken, 1'b0, "pc=0 after 3 not-taken (01->00, strongly-not-taken): still predicts not-taken");
        train(32'd0, 1'b0);  // 00 -> 00 (saturate)
        #1 check_bit(predict_taken, 1'b0, "pc=0 after 4 not-taken (00->00, saturated): still predicts not-taken");

        // Independent entries: train pc=4 (index 1) strongly-taken; pc=0
        // (index 0, currently strongly-not-taken from the walk above) must
        // be completely unaffected.
        train(32'd4, 1'b1);
        train(32'd4, 1'b1);
        query_pc = 32'd4;
        #1 check_bit(predict_taken, 1'b1, "pc=4 (index 1) trained taken: predicts taken");
        query_pc = 32'd0;
        #1 check_bit(predict_taken, 1'b0, "pc=0 (index 0) unaffected by pc=4's training: still predicts not-taken");

        // Aliasing: pc=0 and pc=16 both map to index 0 (16>>2 & 3 == 0).
        // Training pc=16 must move the SAME shared counter pc=0 reads --
        // not corrupt anything, not crash, just shared state by
        // construction (the untagged design this table deliberately uses).
        train(32'd16, 1'b1);
        train(32'd16, 1'b1);  // 00 -> 01 -> 10: shared counter now predicts taken
        query_pc = 32'd0;
        #1 check_bit(predict_taken, 1'b1, "pc=0 reflects pc=16's training (shared index 0, untagged aliasing)");
        query_pc = 32'd16;
        #1 check_bit(predict_taken, 1'b1, "pc=16 itself also predicts taken (same shared entry)");

        // Second read port: train_pc must read the exact same array as
        // query_pc, independently -- query pc=0 (currently trained taken
        // from the walk above) while train_pc probes pc=4 (trained taken
        // earlier) and pc=8 (never trained, cold) simultaneously.
        query_pc = 32'd0;
        train_pc = 32'd4;
        #1 check_bit(predict_taken, 1'b1, "second port: query_pc=0 still reads its own trained value");
        #0 check_bit(train_predict_taken, 1'b1, "second port: train_pc=4 independently reads pc=4's trained value");
        train_pc = 32'd8;
        #1 check_bit(train_predict_taken, 1'b0, "second port: train_pc=8 (cold, never trained) predicts not-taken");

        if (fails == 0)
            $display("PASS  bht_unit (%0d checks)", checks);
        else
            $display("FAIL  bht_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
