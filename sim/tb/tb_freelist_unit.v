`include "FreeList.v"

// Generation 6, Gen6-A (extended Gen6-L, docs/adr/0048). Standalone unit
// test for FreeList.v, fully independent of RegisterAliasTable.v/
// PhysicalRegisterFile.v/OOOCore.v -- drives alloc_en*/commit_en*/free_en*
// directly. NUM_PREGS=8/NUM_AREGS=6 -> a tiny CAPACITY=2 free list so
// exhaustion/refill/wraparound are all reachable in a handful of cycles,
// mirroring tb_scoreboard_unit.v's own small-parameter-for-coverage
// convention.
//
// Gen6-L (docs/adr/0048): alloc_en/alloc_ok are now a pure QUERY,
// independent of whether the caller's own dispatch actually happens --
// commit_en is the separate, real pop trigger. Every pre-existing case
// below now drives commit_en == alloc_en (the old, single-phase behavior:
// "query and immediately commit"), preserving their own original meaning
// bit-for-bit. Case 8 is new: proves the actual bug this fix closes --
// a query that succeeds but whose commit is WITHHELD (simulating a
// caller's dispatch_stall firing for an unrelated reason) must NOT
// consume the entry; it must still be there on a later query/commit.
module tb_freelist_unit;
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
    reg        alloc_en0 = 0, alloc_en1 = 0;
    reg        commit_en0 = 0, commit_en1 = 0;
    reg        free_en0 = 0, free_en1 = 0;
    reg  [2:0] free_preg0 = 0, free_preg1 = 0;
    wire [2:0] alloc_preg0, alloc_preg1;
    wire       alloc_ok0, alloc_ok1;
    wire [1:0] free_count;

    FreeList #(.NUM_PREGS(8), .NUM_AREGS(6)) dut(
        .clk(clk), .rst(rst),
        .alloc_en0(alloc_en0), .alloc_en1(alloc_en1),
        .alloc_preg0(alloc_preg0), .alloc_preg1(alloc_preg1),
        .alloc_ok0(alloc_ok0), .alloc_ok1(alloc_ok1),
        .commit_en0(commit_en0), .commit_en1(commit_en1),
        .free_en0(free_en0), .free_preg0(free_preg0),
        .free_en1(free_en1), .free_preg1(free_preg1),
        .free_count(free_count)
    );

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // -- Case 1: reset state -- both free pregs (6,7) available --
        #1;
        check_val(free_count, 2'd2, "case1: free_count == CAPACITY at reset");

        // -- Case 2: allocate one -- gets preg6 (the first free entry) --
        @(negedge clk);
        alloc_en0 = 1; alloc_en1 = 0;
        #1;
        check_val(alloc_ok0, 1'b1, "case2: alloc_ok0 asserted, a preg is free");
        check_val(alloc_preg0, 3'd6, "case2: alloc_preg0 == 6, first free entry");
        commit_en0 = 1;
        @(posedge clk); #1;
        alloc_en0 = 0; commit_en0 = 0;
        check_val(free_count, 2'd1, "case2: free_count drops to 1 after the pop");

        // -- Case 3: allocate two in one cycle -- only 1 left, slot0 gets
        // it, slot1 must report NOT ok --
        @(negedge clk);
        alloc_en0 = 1; alloc_en1 = 1;
        #1;
        check_val(alloc_ok0, 1'b1, "case3: alloc_ok0 -- last free entry");
        check_val(alloc_preg0, 3'd7, "case3: alloc_preg0 == 7, the remaining free entry");
        check_val(alloc_ok1, 1'b0, "case3: alloc_ok1 -- list now empty, slot1 gets nothing");
        commit_en0 = 1; commit_en1 = 0;   // alloc_ok1 was 0 -- committing it would violate ASSERT_ON
        @(posedge clk); #1;
        alloc_en0 = 0; alloc_en1 = 0; commit_en0 = 0;
        check_val(free_count, 2'd0, "case3: free_count == 0, list exhausted");

        // -- Case 4: exhausted list refuses any further allocation --
        @(negedge clk);
        alloc_en0 = 1;
        #1;
        check_val(alloc_ok0, 1'b0, "case4: alloc_ok0 refused, list empty");
        @(posedge clk); #1;
        alloc_en0 = 0;

        // -- Case 5: reclaim (free) two pregs in one cycle, refilling the
        // list -- FreeList itself doesn't care which pregs, just pushes
        // whatever the caller reclaims (a real caller only ever reclaims
        // pregs it previously got from case2/case3's own alloc grants:
        // preg6 and preg7). --
        @(negedge clk);
        free_en0 = 1; free_preg0 = 3'd6;
        free_en1 = 1; free_preg1 = 3'd7;
        #1;
        @(posedge clk); #1;
        free_en0 = 0; free_en1 = 0;
        check_val(free_count, 2'd2, "case5: free_count back to 2 after reclaiming both");

        // -- Case 6: reallocating now returns the reclaimed pregs, in
        // reclaim (FIFO) order --
        @(negedge clk);
        alloc_en0 = 1; alloc_en1 = 1;
        #1;
        check_val(alloc_ok0, 1'b1, "case6: alloc_ok0 after refill");
        check_val(alloc_preg0, 3'd6, "case6: alloc_preg0 == 6, FIFO order preserved");
        check_val(alloc_ok1, 1'b1, "case6: alloc_ok1 after refill");
        check_val(alloc_preg1, 3'd7, "case6: alloc_preg1 == 7, FIFO order preserved");
        commit_en0 = 1; commit_en1 = 1;
        @(posedge clk); #1;
        alloc_en0 = 0; alloc_en1 = 0; commit_en0 = 0; commit_en1 = 0;

        // -- Case 7: simultaneous alloc + free the same cycle, non-
        // overlapping pregs -- both proceed independently --
        @(negedge clk);
        free_en0 = 1; free_preg0 = 3'd6;
        alloc_en0 = 1;
        #1;
        // At this instant, the list is empty (case6 drained it), so the
        // fresh free() this cycle is what alloc_ok0 must be granted from
        // -- but a same-cycle push+pop only lands as a pop-visible entry
        // NEXT cycle (registered FIFO), so alloc_ok0 should be refused
        // here.
        check_val(alloc_ok0, 1'b0, "case7: same-cycle free is not visible to an alloc the same cycle (registered)");
        @(posedge clk); #1;
        free_en0 = 0; alloc_en0 = 0;
        check_val(free_count, 2'd1, "case7: free_count == 1 after the settled push");

        // -- Case 8 (Gen6-L, docs/adr/0048's own real bug): a query that
        // succeeds but whose commit is WITHHELD -- simulating a caller
        // whose dispatch_stall fires for an unrelated reason the same
        // cycle needs_dest/alloc_ok0 were both true -- must NOT consume
        // the entry. Before this fix, alloc_ok0 alone drove the pop, so
        // this exact scenario silently orphaned a physical register
        // every time it occurred; a real, confirmed deadlock in
        // design/OOOCore.v under sustained load (bench_sum_array.s under
        // bench_runner.py --compare-ooo).
        @(negedge clk);
        alloc_en0 = 1;
        #1;
        check_val(alloc_ok0, 1'b1, "case8: alloc_ok0 -- one entry free (case7's own settled push)");
        // commit_en0 deliberately left 0 -- query succeeds, commit withheld.
        @(posedge clk); #1;
        alloc_en0 = 0;
        check_val(free_count, 2'd1, "case8: free_count UNCHANGED -- query alone must never pop");

        // -- Case 9: the SAME entry the withheld query in case8 pointed at
        // is still there, and a real commit now (query + commit together)
        // correctly retrieves it -- no leak, no double-pop.
        @(negedge clk);
        alloc_en0 = 1;
        #1;
        check_val(alloc_ok0, 1'b1, "case9: alloc_ok0 -- the same entry case8 never actually took");
        check_val(alloc_preg0, 3'd6, "case9: alloc_preg0 == 6 -- case7's own reclaimed preg, untouched by case8's withheld commit");
        commit_en0 = 1;
        @(posedge clk); #1;
        alloc_en0 = 0; commit_en0 = 0;
        check_val(free_count, 2'd0, "case9: free_count == 0 -- exactly one real pop happened across case8+case9");

        if (fails == 0) $display("PASS  freelist_unit (%0d checks)", checks);
        else $display("FAIL  freelist_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
