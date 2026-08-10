`default_nettype none

// Generation 6 (out-of-order core), Gen6-B
// (C:\Users\poorn\.claude\plans\gen6-ooo-core.md). Reorder buffer: a
// circular FIFO of in-flight instructions, allocated in program order at
// dispatch, completed out of order (whenever the RS/execute/CDB side
// finishes each one, tag-addressed by this entry's own ROB index), and
// retired strictly in program order from the head -- the actual defining
// property under test here: an entry marked done can NEVER retire ahead
// of an earlier, not-yet-done entry, even though completion itself can
// race arbitrarily.
//
// This phase (Gen6-B) is a genuine skeleton: alloc/complete/retire only,
// no exception/branch/store fields yet -- those are added in Gen6-G
// (speculation/squash) and Gen6-I (precise exceptions) once there's a
// real consumer for them, matching this project's own established
// "parameter declaration first, no premature fields" discipline
// (docs/adr/0044's own MSHR array grew fields only as each later phase
// needed them, never speculatively up front).
//
// Deliberately does NOT touch RegisterAliasTable.v/FreeList.v/
// PhysicalRegisterFile.v itself -- retire outputs are plain combinational
// signals the caller wires to those modules' own commit/free/write ports,
// same decoupled-module discipline as Scoreboard.v/DCache.v (docs/adr/0044)
// keeping the scoreboard ignorant of DCache's own internals.
//
// FIFO head/tail/count mechanics mirror DCache.v's own MSHR array
// (docs/adr/0044) and FreeList.v's own pop-2/push-2 generalization of it.
module ReorderBuffer #(
    parameter ROB_ENTRIES = 32,
    parameter AREG_BITS   = 5,
    parameter PREG_BITS   = 6,
    parameter IDX_BITS    = $clog2(ROB_ENTRIES),
    parameter CNT_BITS    = $clog2(ROB_ENTRIES+1)
)(
    input  wire                  clk,
    input  wire                  rst,

    // Dispatch/allocate, up to 2/cycle. Caller must check rob_count
    // against ROB_ENTRIES itself first (same "caller enforces room"
    // discipline FreeList.v/DCache.v's own MSHR room-check already
    // established) -- this module does not refuse an over-full alloc.
    // alloc_tag* is this entry's own ROB index, combinational the same
    // cycle -- the tag a later RS/LSQ dispatch stashes to know which ROB
    // entry to mark done on completion.
    input  wire                  alloc_en0,
    input  wire                  alloc_has_dest0,
    input  wire                  alloc_is_fp_dest0,   // Gen6-H -- see below
    input  wire [AREG_BITS-1:0]  alloc_areg0,
    input  wire [PREG_BITS-1:0]  alloc_preg0,
    input  wire [PREG_BITS-1:0]  alloc_old_preg0,
    output wire [IDX_BITS-1:0]   alloc_tag0,

    input  wire                  alloc_en1,
    input  wire                  alloc_has_dest1,
    input  wire                  alloc_is_fp_dest1,
    input  wire [AREG_BITS-1:0]  alloc_areg1,
    input  wire [PREG_BITS-1:0]  alloc_preg1,
    input  wire [PREG_BITS-1:0]  alloc_old_preg1,
    output wire [IDX_BITS-1:0]   alloc_tag1,

    // Completion (CDB), up to 3/cycle, tag-addressed -- marks an
    // in-flight entry done. Order-independent: any valid tag, any cycle,
    // any number of cycles after its own alloc. 3 ports (Gen6-F, up from
    // 2 in Gen6-D/E) -- one per genuinely independent completion source
    // this core now has (RS_ALU's instant single-cycle broadcast, LSQ's
    // own multi-cycle memory completion, Divider.v's own multi-cycle
    // completion) -- each must own a real, never-silently-dropped port:
    // OR-ing two sources onto one port risks losing one whenever both
    // complete the same cycle, the exact bug class Gen6-E's own ROB
    // dual-retire finding already hit once for retire, not completion.
    input  wire                  complete_en0,
    input  wire [IDX_BITS-1:0]   complete_tag0,
    input  wire                  complete_en1,
    input  wire [IDX_BITS-1:0]   complete_tag1,
    input  wire                  complete_en2,
    input  wire [IDX_BITS-1:0]   complete_tag2,
    input  wire                  complete_en3,   // Gen6-H: RS_FALU's own
                                                   // instant broadcast
    input  wire [IDX_BITS-1:0]   complete_tag3,

    // Retire, up to 2/cycle, STRICTLY in program order from the head.
    // slot1 can only ALSO retire the same cycle slot0 does -- a
    // not-done head blocks everything behind it, entry-by-entry, not
    // just slot-by-slot.
    output wire                  retire_valid0,
    output wire                  retire_has_dest0,
    output wire                  retire_is_fp_dest0,
    output wire [AREG_BITS-1:0]  retire_areg0,
    output wire [PREG_BITS-1:0]  retire_preg0,
    output wire [PREG_BITS-1:0]  retire_old_preg0,

    output wire                  retire_valid1,
    output wire                  retire_has_dest1,
    output wire                  retire_is_fp_dest1,
    output wire [AREG_BITS-1:0]  retire_areg1,
    output wire [PREG_BITS-1:0]  retire_preg1,
    output wire [PREG_BITS-1:0]  retire_old_preg1,

    output wire [CNT_BITS-1:0]   rob_count,
    output wire                  rob_full,
    output wire                  rob_empty
);

reg                 e_valid      [0:ROB_ENTRIES-1];
reg                 e_done       [0:ROB_ENTRIES-1];
reg                 e_has_dest   [0:ROB_ENTRIES-1];
// Gen6-H: an entry's dest is EITHER an integer OR a float register, never
// both (RV32F's own encoding never writes both files from one
// instruction) -- one bit disambiguates which RAT/FreeList/PRF the
// caller routes e_areg/e_preg/e_old_preg to at retire, reusing those
// same fields rather than adding a second, mostly-redundant set.
reg                 e_is_fp_dest [0:ROB_ENTRIES-1];
reg [AREG_BITS-1:0] e_areg       [0:ROB_ENTRIES-1];
reg [PREG_BITS-1:0] e_preg       [0:ROB_ENTRIES-1];
reg [PREG_BITS-1:0] e_old_preg   [0:ROB_ENTRIES-1];

reg [CNT_BITS-1:0]  count_r;
reg [IDX_BITS-1:0]  head_r, tail_r;

assign rob_count = count_r;
assign rob_full  = (count_r >= ROB_ENTRIES[CNT_BITS-1:0]);
assign rob_empty = (count_r == {CNT_BITS{1'b0}});

function [IDX_BITS-1:0] wrap_add;
    input [IDX_BITS-1:0] base;
    input [1:0]          amount;
    reg   [IDX_BITS+1:0] sum;
    begin
        sum = base + amount;
        wrap_add = (sum >= ROB_ENTRIES) ? (sum - ROB_ENTRIES) : sum[IDX_BITS-1:0];
    end
endfunction

assign alloc_tag0 = tail_r;
assign alloc_tag1 = wrap_add(tail_r, alloc_en0 ? 2'd1 : 2'd0);

// Retire eligibility -- entry-by-entry in-order gating, referenced
// directly in the assigns below (not hidden inside a called function --
// PhysicalRegisterFile.v's own Gen6-A finding: an Icarus continuous
// assign only tracks its EXPLICIT operands, so every signal a retire
// decision depends on must appear directly in the assign expression
// itself, not behind a function call).
wire [IDX_BITS-1:0] head1_idx = wrap_add(head_r, 2'd1);
wire slot0_can_retire = !rob_empty && e_valid[head_r] && e_done[head_r];
wire slot1_can_retire = slot0_can_retire && (count_r >= 2'd2)
                         && e_valid[head1_idx] && e_done[head1_idx];

assign retire_valid0      = slot0_can_retire;
assign retire_has_dest0   = e_has_dest[head_r];
assign retire_is_fp_dest0 = e_is_fp_dest[head_r];
assign retire_areg0       = e_areg[head_r];
assign retire_preg0       = e_preg[head_r];
assign retire_old_preg0   = e_old_preg[head_r];

assign retire_valid1      = slot1_can_retire;
assign retire_has_dest1   = e_has_dest[head1_idx];
assign retire_is_fp_dest1 = e_is_fp_dest[head1_idx];
assign retire_areg1       = e_areg[head1_idx];
assign retire_preg1       = e_preg[head1_idx];
assign retire_old_preg1   = e_old_preg[head1_idx];

wire [1:0] retire_count = (slot0_can_retire ? 2'd1 : 2'd0) + (slot1_can_retire ? 2'd1 : 2'd0);
wire [1:0] alloc_count  = (alloc_en0 ? 2'd1 : 2'd0) + (alloc_en1 ? 2'd1 : 2'd0);

integer reset_i;
always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < ROB_ENTRIES; reset_i = reset_i + 1) begin
            e_valid[reset_i] <= 1'b0;
            e_done[reset_i]  <= 1'b0;
        end
        count_r <= {CNT_BITS{1'b0}};
        head_r  <= {IDX_BITS{1'b0}};
        tail_r  <= {IDX_BITS{1'b0}};
    end
    else begin
        // Allocate: write the tail entry/entries (freshly retired or
        // never-used slots -- either way, safe to overwrite; a slot only
        // ever holds meaningful data between its own alloc and its own
        // retire).
        if (alloc_en0) begin
            e_valid[tail_r]      <= 1'b1;
            e_done[tail_r]       <= 1'b0;
            e_has_dest[tail_r]   <= alloc_has_dest0;
            e_is_fp_dest[tail_r] <= alloc_is_fp_dest0;
            e_areg[tail_r]       <= alloc_areg0;
            e_preg[tail_r]       <= alloc_preg0;
            e_old_preg[tail_r]   <= alloc_old_preg0;
        end
        if (alloc_en1) begin
            e_valid[alloc_tag1]      <= 1'b1;
            e_done[alloc_tag1]       <= 1'b0;
            e_has_dest[alloc_tag1]   <= alloc_has_dest1;
            e_is_fp_dest[alloc_tag1] <= alloc_is_fp_dest1;
            e_areg[alloc_tag1]       <= alloc_areg1;
            e_preg[alloc_tag1]       <= alloc_preg1;
            e_old_preg[alloc_tag1]   <= alloc_old_preg1;
        end
        if (alloc_count != 2'd0)
            tail_r <= wrap_add(tail_r, alloc_count);

        // Complete: tag-addressed, independent of alloc/retire this same
        // cycle (a freshly-allocated entry cannot complete the same
        // cycle in any real pipeline -- execution takes at least one
        // more cycle -- so no same-cycle alloc/complete collision on the
        // same tag is expected; ASSERT_ON below would need a real
        // exec-latency model to check this meaningfully, deferred to
        // whichever later phase adds execution).
        if (complete_en0)
            e_done[complete_tag0] <= 1'b1;
        if (complete_en1)
            e_done[complete_tag1] <= 1'b1;
        if (complete_en2)
            e_done[complete_tag2] <= 1'b1;
        if (complete_en3)
            e_done[complete_tag3] <= 1'b1;

        // Retire: free the entries just vacated. A retiring entry's own
        // e_valid clear isn't strictly needed for correctness (head_r
        // moving past it means it'll never be read again until reused by
        // a future alloc, which always sets e_valid itself) but clearing
        // it defensively matches Register.v's own "assert loudly, don't
        // trust an invariant silently" discipline if a future bug ever
        // reads a stale head.
        if (slot0_can_retire)
            e_valid[head_r] <= 1'b0;
        if (slot1_can_retire)
            e_valid[head1_idx] <= 1'b0;
        if (retire_count != 2'd0)
            head_r <= wrap_add(head_r, retire_count);

        count_r <= count_r + alloc_count - retire_count;
    end
end

`ifdef ASSERT_ON
always @(posedge clk) begin
    if (rst && (count_r > ROB_ENTRIES[CNT_BITS-1:0]))
        begin $display("ASSERTION FAILED @t=%0t: ReorderBuffer count_r=%0d exceeds ROB_ENTRIES=%0d", $time, count_r, ROB_ENTRIES); $finish; end
end
`endif

endmodule

`default_nettype wire
