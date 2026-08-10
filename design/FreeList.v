`default_nettype none

// Generation 6 (out-of-order core), Gen6-A rename-stage skeleton
// (C:\Users\poorn\.claude\plans\gen6-ooo-core.md). Physical-register free
// list: a circular FIFO of physical register numbers not currently mapped
// to any architectural register. Rename pops up to 2 entries/cycle (one
// per dispatch slot needing a fresh destination physical register);
// retire pushes up to 2 entries/cycle (the OLD physical register an
// instruction's rd mapping is replacing, reclaimed once that instruction
// retires and nothing can ever need the old value again). Mirrors
// DCache.v's own MSHR array head/tail/count FIFO idiom
// (docs/adr/0044-non-blocking-dcache-mshr-phase-e.md) generalized from
// pop-1/push-1 per cycle to pop-2/push-2, matching this generation's own
// confirmed dual-issue scope.
//
// NUM_PREGS physical registers total; the first NUM_AREGS of them are the
// initial 1:1 architectural mapping at reset (areg i -> preg i, matching
// RegisterAliasTable.v's own reset state) and are NOT in the free list
// initially -- only pregs [NUM_AREGS, NUM_PREGS) start free.
//
// Caller's own responsibility: never push more entries in a cycle than
// free_count - (this cycle's own pops) can absorb, and never free a preg
// that wasn't validly allocated earlier (a double-free would silently
// duplicate an entry in the queue). Unenforced in hardware, same
// discipline as DCache.v's own MSHR room-check being the caller's job,
// not this module's.
//
// Gen6-L (docs/adr/0048's own "real bugs/findings"): alloc_en0/alloc_en1
// are a pure QUERY, deliberately independent of whether dispatch actually
// happens this cycle -- a caller's own dispatch_stall combinational
// formula needs to know "would there be room" BEFORE it can decide
// do_dispatch itself, and gating alloc_en on that same decision would
// create a real combinational cycle (do_dispatch -> alloc_ok0 ->
// dispatch_stall -> do_dispatch). commit_en0/commit_en1 are the SEPARATE
// signal that actually pops the queue -- a caller must only assert these
// once do_dispatch (the real, confirmed decision) is known, or every
// cycle dispatch stalls for an unrelated reason (ROB/RS/LSQ full, a
// same-bundle class mismatch) while alloc_ok0/1 said yes permanently
// orphans one entry: it's already been popped from the queue by the
// QUERY alone, but no RAT/ROB write ever adopts it, so it's gone forever.
// This was a real, confirmed, previously-shipped deadlock (found by
// design/OOOCore.v's own sustained-loop constrained-random/benchmark
// testing, docs/adr/0048) -- commit_en0/commit_en1 are the fix: alloc_en0/
// alloc_en1/alloc_ok0/alloc_ok1's own query semantics are UNCHANGED by
// this fix (every existing caller's dispatch_stall wiring needs zero
// edits), only the actual pop moves to the new, separately-gated ports.
module FreeList #(
    parameter NUM_PREGS = 64,
    parameter NUM_AREGS = 32,
    parameter CAPACITY  = NUM_PREGS - NUM_AREGS,
    parameter PREG_BITS = $clog2(NUM_PREGS),
    parameter CAP_BITS  = $clog2(CAPACITY)
)(
    input  wire                 clk,
    input  wire                 rst,

    // Rename/dispatch AVAILABILITY QUERY, up to 2/cycle -- combinational,
    // independent of whether dispatch actually happens this cycle (see
    // this module's own header). alloc_preg1/alloc_ok1 account for
    // slot0's own hypothetical grant the same cycle (a single bundle
    // can't get the same preg twice for both slots).
    input  wire                 alloc_en0,
    input  wire                 alloc_en1,
    output wire [PREG_BITS-1:0] alloc_preg0,
    output wire [PREG_BITS-1:0] alloc_preg1,
    output wire                 alloc_ok0,
    output wire                 alloc_ok1,

    // Rename/dispatch COMMIT, up to 2/cycle -- the real, confirmed "this
    // slot is actually dispatching THIS cycle" pulse (a caller's own
    // do_dispatch/do_dispatch_slot1, not just needs_dest). Only THIS
    // actually pops the queue; see this module's own header for why the
    // query above must stay unconditional on it. A caller must never
    // assert commit_en0/1 without alloc_ok0/1 having been true the SAME
    // cycle (ASSERT_ON below checks this) -- by construction, any correct
    // caller's own do_dispatch already required this.
    input  wire                 commit_en0,
    input  wire                 commit_en1,

    // Retire reclaim push, up to 2/cycle.
    input  wire                 free_en0,
    input  wire [PREG_BITS-1:0] free_preg0,
    input  wire                 free_en1,
    input  wire [PREG_BITS-1:0] free_preg1,

    output wire [CAP_BITS:0]    free_count   // 0..CAPACITY, for an upstream
                                              // "can I dispatch 2 this cycle" check
);

reg [PREG_BITS-1:0] queue [0:CAPACITY-1];
reg [CAP_BITS:0]    count_r;         // 0..CAPACITY, occupancy
reg [CAP_BITS-1:0]  head_r, tail_r;  // FIFO pop/push order

assign free_count = count_r;

// wrap_add(base, amount): base+amount mod CAPACITY, amount in {0,1,2}.
function [CAP_BITS-1:0] wrap_add;
    input [CAP_BITS-1:0] base;
    input [1:0]          amount;
    reg   [CAP_BITS+1:0] sum;
    begin
        sum = base + amount;
        wrap_add = (sum >= CAPACITY) ? (sum - CAPACITY) : sum[CAP_BITS-1:0];
    end
endfunction

assign alloc_ok0 = alloc_en0 && (count_r >= 2'd1);
assign alloc_ok1 = alloc_en1 && (count_r >= (alloc_ok0 ? 2'd2 : 2'd1));

assign alloc_preg0 = queue[head_r];
assign alloc_preg1 = queue[wrap_add(head_r, alloc_ok0 ? 2'd1 : 2'd0)];

// Gen6-L fix (docs/adr/0048): the actual pop is gated on commit_en0/1
// (the caller's own CONFIRMED dispatch decision), not alloc_ok0/1 (the
// unconditional query) -- see this module's own header for why. A
// correct caller's own commit_en0/1 can only ever fire when alloc_ok0/1
// were already true this same cycle (its do_dispatch/do_dispatch_slot1
// itself required that), so no additional count_r re-check is needed
// here for the pop count itself -- ASSERT_ON below still checks the
// contract explicitly, defense-in-depth against a future caller bug.
wire [1:0] pop_count  = (commit_en0 ? 2'd1 : 2'd0) + (commit_en1 ? 2'd1 : 2'd0);
wire [1:0] push_count = (free_en0  ? 2'd1 : 2'd0) + (free_en1  ? 2'd1 : 2'd0);

integer reset_i;
always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < CAPACITY; reset_i = reset_i + 1)
            queue[reset_i] <= NUM_AREGS + reset_i;
        count_r <= CAPACITY[CAP_BITS:0];
        head_r  <= {CAP_BITS{1'b0}};
        tail_r  <= {CAP_BITS{1'b0}};
    end
    else begin
        if (commit_en0)
            head_r <= wrap_add(head_r, pop_count);
        if (free_en0)
            queue[tail_r] <= free_preg0;
        if (free_en1)
            queue[wrap_add(tail_r, free_en0 ? 2'd1 : 2'd0)] <= free_preg1;
        if (push_count != 2'd0)
            tail_r <= wrap_add(tail_r, push_count);
        count_r <= count_r - pop_count + push_count;
    end
end

`ifdef ASSERT_ON
always @(posedge clk) begin
    if (rst && (count_r > CAPACITY[CAP_BITS:0]))
        begin $display("ASSERTION FAILED @t=%0t: FreeList count_r=%0d exceeds CAPACITY=%0d", $time, count_r, CAPACITY); $finish; end
    // Gen6-L fix (docs/adr/0048): commit_en0/1 without alloc_ok0/1 having
    // been true the same cycle is a real caller contract violation (see
    // this module's own header) -- would silently pop a queue that
    // doesn't have room, corrupting head_r/count_r. Catches it loudly
    // instead.
    if (rst && commit_en0 && !alloc_ok0)
        begin $display("ASSERTION FAILED @t=%0t: FreeList commit_en0 without alloc_ok0", $time); $finish; end
    if (rst && commit_en1 && !alloc_ok1)
        begin $display("ASSERTION FAILED @t=%0t: FreeList commit_en1 without alloc_ok1", $time); $finish; end
end
`endif

endmodule

`default_nettype wire
