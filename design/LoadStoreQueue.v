`default_nettype none

// Generation 6 (out-of-order core), Gen6-E
// (C:\Users\poorn\.claude\plans\gen6-ooo-core.md). Load/store queue: a
// FIFO of in-flight memory ops, dispatched in program order (mirrors
// ReorderBuffer.v's own FIFO shape), but processing ONLY the head entry
// against memory at a time -- a deliberate, documented scope cut for
// this bring-up phase (see below), not the genuine out-of-order
// load/store execution a full LSQ eventually provides.
//
// `# ponytail`-tagged scope cuts, both real and both flagged rather than
// silently dropped:
//   - STRICT IN-ORDER memory access: the head entry is the only one ever
//     issued to memory: a load can't execute past an older, not-yet-
//     addressed store, and there is no address-based store-to-load
//     forwarding. This trivially preserves memory program order (same
//     guarantee the ORIGINAL in-order pipeline always had) while still
//     letting every OTHER (non-memory) instruction execute/complete out
//     of order around it via the ROB -- Gen6-D's own already-proven OoO
//     ALU path is completely unaffected. Real out-of-order load
//     execution/forwarding (the actual point of a full LSQ) is future
//     work.
//   - Talks to DataMemoryBRAM.v directly, NOT DCache.v/its MSHR array --
//     single-outstanding-at-a-time access needs none of DCache's own
//     multi-way/non-blocking/L2/victim machinery. A real, load-bearing
//     research finding from this phase's own design pass: DCache.v's
//     existing `req_dest_reg`/`mshr_complete_reg` tag scheme does NOT
//     need to change for OoO at all -- it already tags completions by a
//     plain numeric ID, and since RegisterAliasTable.v/FreeList.v
//     already guarantee every dynamic instruction gets a UNIQUE physical
//     register, using dest_preg (not an architectural register number)
//     AS that same ID works unmodified. This phase doesn't reach
//     DCache.v at all (DataMemoryBRAM.v needs no such tag, being
//     single-outstanding by construction), but the finding matters for
//     whichever future phase upgrades this LSQ to real non-blocking
//     DCache/MSHR access.
//
// Effective-address computation is a plain internal adder (base + imm),
// not a shared instance of ALU.v/ReservationStation.v's own INT-ALU
// class -- address calc is a single `+`, real duplication of one
// operation, deliberately kept separate from Gen6-D's already-verified
// ALU/RS path (avoids touching working code for a trivial reuse).
module LoadStoreQueue #(
    parameter XLEN         = 64,
    parameter LSQ_ENTRIES  = 8,
    parameter PREG_BITS    = 6,
    parameter ROB_IDX_BITS = 4,
    parameter LSQ_IDX_BITS = $clog2(LSQ_ENTRIES),
    parameter CNT_BITS     = $clog2(LSQ_ENTRIES+1)
)(
    input  wire                    clk,
    input  wire                    rst,

    // Dispatch, up to 2/cycle (matches every other Gen6-* module's own
    // dual-issue-capable shape; only slot0 driven until Gen6-K widens
    // the whole core).
    input  wire                    disp_en0,
    input  wire                    disp_is_store0,
    input  wire [PREG_BITS-1:0]    disp_base_preg0,
    input  wire                    disp_base_ready0,
    input  wire [XLEN-1:0]         disp_imm0,
    input  wire [2:0]              disp_funct3_0,
    input  wire [PREG_BITS-1:0]    disp_store_data_preg0,
    input  wire                    disp_store_data_ready0,
    input  wire [PREG_BITS-1:0]    disp_dest_preg0,     // loads only
    input  wire [ROB_IDX_BITS-1:0] disp_rob_tag0,

    input  wire                    disp_en1,
    input  wire                    disp_is_store1,
    input  wire [PREG_BITS-1:0]    disp_base_preg1,
    input  wire                    disp_base_ready1,
    input  wire [XLEN-1:0]         disp_imm1,
    input  wire [2:0]              disp_funct3_1,
    input  wire [PREG_BITS-1:0]    disp_store_data_preg1,
    input  wire                    disp_store_data_ready1,
    input  wire [PREG_BITS-1:0]    disp_dest_preg1,
    input  wire [ROB_IDX_BITS-1:0] disp_rob_tag1,

    // CDB snoop -- wakes a not-yet-ready base/store-data operand, same
    // shape as ReservationStation.v's own wakeup.
    input  wire                    cdb_valid0,
    input  wire [PREG_BITS-1:0]    cdb_preg0,
    input  wire                    cdb_valid1,
    input  wire [PREG_BITS-1:0]    cdb_preg1,
    input  wire                    cdb_valid2,
    input  wire [PREG_BITS-1:0]    cdb_preg2,

    // Caller-side PRF read, mirrors ReservationStation.v's own decoupled-
    // from-PRF discipline: this module exposes which pregs the HEAD
    // entry needs, the caller wires those to real PRF read ports and
    // feeds the values back.
    output wire [PREG_BITS-1:0]    head_base_preg,
    output wire [PREG_BITS-1:0]    head_store_data_preg,
    input  wire [XLEN-1:0]         mem_base_value,
    input  wire [XLEN-1:0]         mem_store_data_value,

    // Memory port -- DataMemoryBRAM.v directly.
    output wire                    mem_memRead,
    output wire                    mem_memWrite,
    output wire [XLEN-1:0]         mem_address,
    output wire [XLEN-1:0]         mem_writeData,
    output wire [2:0]              mem_funct3,
    input  wire [XLEN-1:0]         mem_readData,

    // Completion -- mirrors ReservationStation.v's own issue_*/CDB shape.
    // complete_valid pulses the cycle AFTER a load's memRead (readData
    // now registered-valid) or the cycle a store's memWrite lands
    // (DataMemoryBRAM.v commits stores same-cycle, so a store completes
    // one cycle after issue too, for a uniform single "pending" latency
    // either way -- see the always block below).
    output wire                    complete_valid,
    output wire                    complete_is_load,
    output wire [PREG_BITS-1:0]    complete_dest_preg,
    output wire [XLEN-1:0]         complete_data,
    output wire [ROB_IDX_BITS-1:0] complete_rob_tag,

    output wire [CNT_BITS-1:0]     lsq_count,
    output wire                    lsq_full
);

reg                    e_valid          [0:LSQ_ENTRIES-1];
reg                    e_is_store       [0:LSQ_ENTRIES-1];
reg [PREG_BITS-1:0]    e_base_preg      [0:LSQ_ENTRIES-1];
reg                    e_base_ready     [0:LSQ_ENTRIES-1];
reg [XLEN-1:0]         e_imm            [0:LSQ_ENTRIES-1];
reg [2:0]              e_funct3         [0:LSQ_ENTRIES-1];
reg [PREG_BITS-1:0]    e_store_data_preg [0:LSQ_ENTRIES-1];
reg                    e_store_data_ready [0:LSQ_ENTRIES-1];
reg [PREG_BITS-1:0]    e_dest_preg      [0:LSQ_ENTRIES-1];
reg [ROB_IDX_BITS-1:0] e_rob_tag        [0:LSQ_ENTRIES-1];

reg [CNT_BITS-1:0]     count_r;
reg [LSQ_IDX_BITS-1:0] head_r, tail_r;
reg                    mem_pending_r;   // 1 = a memRead/memWrite was
                                          // issued last cycle; this cycle
                                          // completes it.

function [LSQ_IDX_BITS-1:0] wrap_add;
    input [LSQ_IDX_BITS-1:0] base;
    input [1:0]              amount;
    reg   [LSQ_IDX_BITS+1:0] sum;
    begin
        sum = base + amount;
        wrap_add = (sum >= LSQ_ENTRIES) ? (sum - LSQ_ENTRIES) : sum[LSQ_IDX_BITS-1:0];
    end
endfunction

assign lsq_count = count_r;
assign lsq_full  = (count_r >= LSQ_ENTRIES[CNT_BITS-1:0]);

wire [LSQ_IDX_BITS-1:0] tail1_idx = wrap_add(tail_r, 2'd1);
wire [1:0] disp_count = (disp_en0 ? 2'd1 : 2'd0) + (disp_en1 ? 2'd1 : 2'd0);

wire lsq_empty    = (count_r == {CNT_BITS{1'b0}});
wire head_present = !lsq_empty && e_valid[head_r];

assign head_base_preg       = e_base_preg[head_r];
assign head_store_data_preg = e_store_data_preg[head_r];

wire head_ready = head_present && !mem_pending_r
                 && e_base_ready[head_r]
                 && (!e_is_store[head_r] || e_store_data_ready[head_r]);

wire [XLEN-1:0] head_addr = mem_base_value + e_imm[head_r];

assign mem_memRead   = head_ready && !e_is_store[head_r];
assign mem_memWrite  = head_ready && e_is_store[head_r];
assign mem_address   = head_addr;
assign mem_writeData = mem_store_data_value;
assign mem_funct3    = e_funct3[head_r];

assign complete_valid      = mem_pending_r;
assign complete_is_load    = !e_is_store[head_r];
assign complete_dest_preg  = e_dest_preg[head_r];
assign complete_data       = mem_readData;
assign complete_rob_tag    = e_rob_tag[head_r];

integer reset_i;
always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < LSQ_ENTRIES; reset_i = reset_i + 1)
            e_valid[reset_i] <= 1'b0;
        count_r       <= {CNT_BITS{1'b0}};
        head_r        <= {LSQ_IDX_BITS{1'b0}};
        tail_r        <= {LSQ_IDX_BITS{1'b0}};
        mem_pending_r <= 1'b0;
    end
    else begin
        // Wakeup: any entry's not-yet-ready base/store-data operand
        // matching a live CDB broadcast becomes ready next cycle -- same
        // shape as ReservationStation.v's own wakeup, applied to every
        // entry (not just the head) so operands can become ready while
        // still queued behind an older entry.
        for (reset_i = 0; reset_i < LSQ_ENTRIES; reset_i = reset_i + 1) begin
            if (e_valid[reset_i] && !e_base_ready[reset_i]
                && ((cdb_valid0 && cdb_preg0 == e_base_preg[reset_i]) || (cdb_valid1 && cdb_preg1 == e_base_preg[reset_i]) || (cdb_valid2 && cdb_preg2 == e_base_preg[reset_i])))
                e_base_ready[reset_i] <= 1'b1;
            if (e_valid[reset_i] && e_is_store[reset_i] && !e_store_data_ready[reset_i]
                && ((cdb_valid0 && cdb_preg0 == e_store_data_preg[reset_i]) || (cdb_valid1 && cdb_preg1 == e_store_data_preg[reset_i]) || (cdb_valid2 && cdb_preg2 == e_store_data_preg[reset_i])))
                e_store_data_ready[reset_i] <= 1'b1;
        end

        // Memory issue/complete, head entry only. complete_valid (==
        // mem_pending_r, declared above) is this cycle's own retire
        // signal -- reused directly in the single count_r update at the
        // end of this block instead of a second, separately-maintained
        // copy of the same condition.
        if (head_ready)
            mem_pending_r <= 1'b1;
        else if (mem_pending_r) begin
            mem_pending_r   <= 1'b0;
            e_valid[head_r] <= 1'b0;
            head_r          <= wrap_add(head_r, 2'd1);
        end

        // Dispatch: append at the tail.
        if (disp_en0) begin
            e_valid[tail_r]             <= 1'b1;
            e_is_store[tail_r]          <= disp_is_store0;
            e_base_preg[tail_r]         <= disp_base_preg0;
            e_base_ready[tail_r]        <= disp_base_ready0;
            e_imm[tail_r]               <= disp_imm0;
            e_funct3[tail_r]            <= disp_funct3_0;
            e_store_data_preg[tail_r]   <= disp_store_data_preg0;
            e_store_data_ready[tail_r]  <= disp_store_data_ready0;
            e_dest_preg[tail_r]         <= disp_dest_preg0;
            e_rob_tag[tail_r]           <= disp_rob_tag0;
        end
        if (disp_en1) begin
            e_valid[tail1_idx]             <= 1'b1;
            e_is_store[tail1_idx]          <= disp_is_store1;
            e_base_preg[tail1_idx]         <= disp_base_preg1;
            e_base_ready[tail1_idx]        <= disp_base_ready1;
            e_imm[tail1_idx]               <= disp_imm1;
            e_funct3[tail1_idx]            <= disp_funct3_1;
            e_store_data_preg[tail1_idx]   <= disp_store_data_preg1;
            e_store_data_ready[tail1_idx]  <= disp_store_data_ready1;
            e_dest_preg[tail1_idx]         <= disp_dest_preg1;
            e_rob_tag[tail1_idx]           <= disp_rob_tag1;
        end
        if (disp_count != 2'd0)
            tail_r <= wrap_add(tail_r, disp_count);

        // Single, unified occupancy update -- complete_valid (==
        // mem_pending_r) is this cycle's own retire, disp_count is this
        // cycle's own dispatch; both can happen the same cycle (a
        // completing head and a fresh tail append never touch the same
        // entry, so there's no ordering hazard between them).
        count_r <= count_r - (complete_valid ? 2'd1 : 2'd0) + disp_count;
    end
end

`ifdef ASSERT_ON
always @(posedge clk) begin
    if (rst && (count_r > LSQ_ENTRIES[CNT_BITS-1:0]))
        begin $display("ASSERTION FAILED @t=%0t: LoadStoreQueue count_r=%0d exceeds LSQ_ENTRIES=%0d", $time, count_r, LSQ_ENTRIES); $finish; end
end
`endif

endmodule

`default_nettype wire
