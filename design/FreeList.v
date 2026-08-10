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
module FreeList #(
    parameter NUM_PREGS = 64,
    parameter NUM_AREGS = 32,
    parameter CAPACITY  = NUM_PREGS - NUM_AREGS,
    parameter PREG_BITS = $clog2(NUM_PREGS),
    parameter CAP_BITS  = $clog2(CAPACITY)
)(
    input  wire                 clk,
    input  wire                 rst,

    // Rename/dispatch pop request, up to 2/cycle. alloc_preg1/alloc_ok1
    // account for slot0's own grant the same cycle (a single instruction
    // can't get the same preg twice).
    input  wire                 alloc_en0,
    input  wire                 alloc_en1,
    output wire [PREG_BITS-1:0] alloc_preg0,
    output wire [PREG_BITS-1:0] alloc_preg1,
    output wire                 alloc_ok0,
    output wire                 alloc_ok1,

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

wire [1:0] pop_count  = (alloc_ok0 ? 2'd1 : 2'd0) + (alloc_ok1 ? 2'd1 : 2'd0);
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
        if (alloc_ok0)
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
end
`endif

endmodule

`default_nettype wire
