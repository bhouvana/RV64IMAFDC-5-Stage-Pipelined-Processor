`default_nettype none
`include "riscv_defs.vh"

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
    //
    // Gen6-P1 (docs/adr/0052): disp_is_store0 (1-bit) replaced by
    // disp_op_type0 (2-bit: OP_LOAD/OP_STORE/OP_SC/OP_AMO_RMW, see the
    // localparams below) -- a real, load-bearing interface change, not
    // a cosmetic rename. SC/AMO-RMW both need a real destination
    // register on what used to be a pure "is this a store" boolean, and
    // AMO-RMW specifically needs a genuine 2-phase read-then-write
    // sequence (see amo_need_write_r's own section below) neither a
    // plain load nor a plain store ever needed. disp_amo_op0 (funct5,
    // riscv_defs.vh's own AMO_F5_* encoding reused directly rather than
    // inventing a new one) selects which RMW operation for OP_AMO_RMW
    // entries -- ignored for the other 3 op types.
    input  wire                    disp_en0,
    input  wire [1:0]              disp_op_type0,
    input  wire [4:0]              disp_amo_op0,
    input  wire [PREG_BITS-1:0]    disp_base_preg0,
    input  wire                    disp_base_ready0,
    input  wire [XLEN-1:0]         disp_imm0,
    input  wire [2:0]              disp_funct3_0,
    input  wire [PREG_BITS-1:0]    disp_store_data_preg0,
    input  wire                    disp_store_data_ready0,
    input  wire [PREG_BITS-1:0]    disp_dest_preg0,     // loads/sc/amo_rmw
    input  wire [ROB_IDX_BITS-1:0] disp_rob_tag0,
    // Gen6-P2 (docs/adr/0053): the dispatching instruction's own PC --
    // needed ONLY so a D-side page fault (discovered well after dispatch,
    // once this entry finally reaches the head) can still supply the
    // real faulting PC to CSR.v's own trap_pc (mepc), the exact same
    // value trap_inflight_pc_r already latches for a dispatch-time-known
    // trap. Nothing else in this module ever reads it.
    input  wire [XLEN-1:0]         disp_pc0,

    input  wire                    disp_en1,
    input  wire [1:0]              disp_op_type1,
    input  wire [4:0]              disp_amo_op1,
    input  wire [PREG_BITS-1:0]    disp_base_preg1,
    input  wire                    disp_base_ready1,
    input  wire [XLEN-1:0]         disp_imm1,
    input  wire [2:0]              disp_funct3_1,
    input  wire [PREG_BITS-1:0]    disp_store_data_preg1,
    input  wire                    disp_store_data_ready1,
    input  wire [PREG_BITS-1:0]    disp_dest_preg1,
    input  wire [ROB_IDX_BITS-1:0] disp_rob_tag1,
    input  wire [XLEN-1:0]         disp_pc1,   // Gen6-P2: see disp_pc0's own comment; slot1 never actually dispatches into this queue (OOOCore.v ties it off), kept for symmetry

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

    // Gen6-P2 (docs/adr/0053): external freeze, held by the caller for as
    // long as the head's own virtual address hasn't finished translating
    // (an ITLB/DTLB miss mid-walk, or simply the shared physical-memory
    // port being on loan to Ptw39 for an UNRELATED walk -- OOOCore.v's own
    // MMU section owns the exact condition; this module just needs to not
    // issue a real access while it's held, same "stall-and-wait" shape
    // trap_inflight_valid_r/jr_inflight_valid_r already use elsewhere in
    // OOOCore.v). Purely additive: tied 0 by every pre-existing caller/
    // testbench, bit-exact with this module's own pre-Gen6-P2 behavior.
    input  wire                    mem_stall_ext,

    // Gen6-P2: a one-cycle pulse from the caller -- "silently retire the
    // head NOW, without ever touching memory." A genuine DTLB page fault
    // means mem_stall_ext will hold this entry frozen FOREVER (ls_hit can
    // never become true for a translation that's already known to fault),
    // so nothing about this module's own normal head_ready/mem_pending_r
    // path could ever retire it -- left unhandled, the LSQ would stay
    // permanently "occupied" by one phantom entry even after the fault's
    // own trap has redirected execution entirely away from it, eventually
    // deadlocking (lsq_full) once real, unrelated LATER instructions fill
    // the remaining entries. The caller's own MMU section is what
    // actually detects the fault and reports it to the ROB/trap machinery
    // (a SEPARATE, already-latched mechanism -- see OOOCore.v's own
    // dside_fault_pulse) -- this pulse is purely this module's own
    // internal bookkeeping cleanup, decoupled from complete_valid on
    // purpose (nothing external needs to react to it a second time).
    input  wire                    force_retire_ext,

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

    // Gen6-P2 (docs/adr/0053): the head's own PRE-STALL readiness --
    // "would this cycle issue a real access, if mem_stall_ext weren't
    // held" -- plus its rob_tag/PC, unconditionally valid whenever
    // head_present (not gated by mem_pending_r the way complete_* is).
    // The caller's own MMU section needs all four to run a DTLB query
    // and, on a fault, inject a synthetic ROB completion + trap using
    // this exact entry's own identity, since a permanently-stalled head
    // never asserts complete_valid on its own.
    output wire                    head_want_access,
    output wire                    head_want_write,
    output wire [ROB_IDX_BITS-1:0] head_rob_tag,
    output wire [XLEN-1:0]         head_pc,

    output wire [CNT_BITS-1:0]     lsq_count,
    output wire                    lsq_full
);

// Gen6-P1 (docs/adr/0052): the 4 real op types this queue now handles.
// OP_LOAD/OP_STORE are exactly what they always were; OP_SC and
// OP_AMO_RMW are new.
localparam OP_LOAD    = 2'd0;
localparam OP_STORE   = 2'd1;
localparam OP_SC      = 2'd2;
localparam OP_AMO_RMW = 2'd3;

reg                    e_valid          [0:LSQ_ENTRIES-1];
reg  [1:0]             e_op_type        [0:LSQ_ENTRIES-1];
reg  [4:0]             e_amo_op         [0:LSQ_ENTRIES-1];
reg [PREG_BITS-1:0]    e_base_preg      [0:LSQ_ENTRIES-1];
reg                    e_base_ready     [0:LSQ_ENTRIES-1];
reg [XLEN-1:0]         e_imm            [0:LSQ_ENTRIES-1];
reg [2:0]              e_funct3         [0:LSQ_ENTRIES-1];
reg [PREG_BITS-1:0]    e_store_data_preg [0:LSQ_ENTRIES-1];
reg                    e_store_data_ready [0:LSQ_ENTRIES-1];
reg [PREG_BITS-1:0]    e_dest_preg      [0:LSQ_ENTRIES-1];
reg [ROB_IDX_BITS-1:0] e_rob_tag        [0:LSQ_ENTRIES-1];
reg [XLEN-1:0]         e_pc             [0:LSQ_ENTRIES-1];   // Gen6-P2: see disp_pc0's own comment

reg [CNT_BITS-1:0]     count_r;
reg [LSQ_IDX_BITS-1:0] head_r, tail_r;
reg                    mem_pending_r;   // 1 = a memRead/memWrite was
                                          // issued last cycle; this cycle
                                          // completes it.
// Gen6-P1: OP_AMO_RMW's own real 2-phase sequencing -- read the old
// value first (phase 1, amo_need_write_r==0), capture it, compute
// new = old OP rs2, then issue the write (phase 2, amo_need_write_r==1)
// before finally completing (rd = the captured OLD value, per spec).
// Global, not per-entry, same "only the head is ever in flight" scope
// this whole module already established for mem_pending_r itself.
reg                    amo_need_write_r;
reg [XLEN-1:0]         amo_old_value_r;

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

// Gen6-P1: op-type classification of the head entry -- head_needs_data
// is true for STORE/SC/AMO_RMW (all three consume the store-data/rs2
// operand: a real store writes it directly, SC writes it directly too
// (just with a real destination alongside), AMO_RMW uses it as the RMW
// operand); head_wants_read/head_wants_write pick which memory
// direction THIS cycle needs, accounting for AMO_RMW's own 2-phase
// sequence via amo_need_write_r.
wire head_is_load  = (e_op_type[head_r] == OP_LOAD);
wire head_is_store = (e_op_type[head_r] == OP_STORE);
wire head_is_sc    = (e_op_type[head_r] == OP_SC);
wire head_is_amo   = (e_op_type[head_r] == OP_AMO_RMW);

wire head_needs_data  = head_is_store || head_is_sc || head_is_amo;
wire head_wants_read  = head_is_load || (head_is_amo && !amo_need_write_r);
wire head_wants_write = head_is_store || head_is_sc || (head_is_amo && amo_need_write_r);

// Gen6-P2: head_want_access is head_ready's own pre-stall condition,
// exposed so the caller's MMU section can run a DTLB query and inject a
// synthetic completion/trap on a fault -- a permanently-stalled entry
// (mem_stall_ext held forever once a real DTLB fault is latched) never
// asserts complete_valid on its own, so the caller needs its own signal
// to know "the head WOULD be issuing right now."
assign head_want_access = head_present && !mem_pending_r
                 && e_base_ready[head_r]
                 && (!head_needs_data || e_store_data_ready[head_r]);
assign head_want_write  = head_wants_write;
assign head_rob_tag     = e_rob_tag[head_r];
assign head_pc          = e_pc[head_r];

wire head_ready = head_want_access && !mem_stall_ext;

wire [XLEN-1:0] head_addr = mem_base_value + e_imm[head_r];

// Gen6-P1: the real read-modify-write computation for OP_AMO_RMW's own
// phase-2 write -- amo_old_value_r was captured when phase 1's own read
// completed (see the always block below); mem_store_data_value is rs2's
// own value, read through the SAME PRF port a plain store's own data
// already uses (head_store_data_preg stays constant across both phases,
// since head_r itself doesn't advance until the entry is FULLY done).
// funct5 encoding reused directly from riscv_defs.vh's own AMO_F5_*
// (docs/adr/0038's own established values) -- no new encoding invented.
// Continuous assign with a ternary chain, NOT a procedural always+case
// reading e_amo_op[head_r] -- Icarus's own "@* is sensitive to all N
// words in array" warning for a variable-indexed array read inside a
// procedural block (the same PhysicalRegisterFile.v/Mailbox.v finding
// this whole project already established); a plain assign avoids it.
wire signed [XLEN-1:0] amo_old_signed = amo_old_value_r;
wire signed [XLEN-1:0] amo_rs2_signed = mem_store_data_value;
wire [4:0] head_amo_op = e_amo_op[head_r];
wire [XLEN-1:0] amo_new_value =
    (head_amo_op == `AMO_F5_ADD)  ? (amo_old_value_r + mem_store_data_value) :
    (head_amo_op == `AMO_F5_SWAP) ? mem_store_data_value :
    (head_amo_op == `AMO_F5_XOR)  ? (amo_old_value_r ^ mem_store_data_value) :
    (head_amo_op == `AMO_F5_OR)   ? (amo_old_value_r | mem_store_data_value) :
    (head_amo_op == `AMO_F5_AND)  ? (amo_old_value_r & mem_store_data_value) :
    (head_amo_op == `AMO_F5_MIN)  ? ((amo_old_signed < amo_rs2_signed) ? amo_old_value_r : mem_store_data_value) :
    (head_amo_op == `AMO_F5_MAX)  ? ((amo_old_signed > amo_rs2_signed) ? amo_old_value_r : mem_store_data_value) :
    (head_amo_op == `AMO_F5_MINU) ? ((amo_old_value_r < mem_store_data_value) ? amo_old_value_r : mem_store_data_value) :
    (head_amo_op == `AMO_F5_MAXU) ? ((amo_old_value_r > mem_store_data_value) ? amo_old_value_r : mem_store_data_value) :
    mem_store_data_value;   // unreached for a valid encoding

assign mem_memRead   = head_ready && head_wants_read;
assign mem_memWrite  = head_ready && head_wants_write;
assign mem_address   = head_addr;
// SC writes rs2's own raw value directly (a real store, just with a
// destination too); AMO_RMW's own phase-2 write uses the computed RMW
// result instead.
assign mem_writeData = (head_is_amo && amo_need_write_r) ? amo_new_value : mem_store_data_value;
assign mem_funct3    = e_funct3[head_r];

// Gen6-P1: complete_valid excludes AMO_RMW's own phase-1-just-finished
// moment (mem_pending_r dropping after the READ, not yet after the
// WRITE) -- see the always block below for where phase 1 -> phase 2
// actually transitions instead of retiring.
wire amo_phase1_just_finished = mem_pending_r && head_is_amo && !amo_need_write_r;
assign complete_valid      = mem_pending_r && !amo_phase1_just_finished;
// Gen6-P1: generalized from the original `!e_is_store[head_r]` --
// still exactly "does this completion carry a real destination value",
// just now true for LOAD/SC/AMO_RMW and false only for a plain STORE
// (the same 3-vs-1 split needs_dest itself already makes at dispatch
// time). A real bug caught before writing any test for it: an earlier
// version of this line was `head_is_load || head_is_amo`, silently
// missing SC -- SC's own real destination write (rd=0) would never
// have reached the PRF/ROB at all, since PRF's/RS_ALU's own CDB-write/
// snoop wiring both gate on this flag, the same "orphaned preg, never
// completes" deadlock shape docs/adr/0049 already found and fixed once
// for FreeList.v.
assign complete_is_load    = !head_is_store;
assign complete_dest_preg  = e_dest_preg[head_r];
// SC always succeeds (single-hart, no real contention possible -- same
// spec-legal simplification docs/adr/0038's own LR/SC header already
// established for LR) -- rd = 0 unconditionally. AMO_RMW's own rd is
// the OLD value (captured before the write, per spec); a plain load's
// rd is whatever memory returned this cycle.
assign complete_data       = head_is_sc ? {XLEN{1'b0}} : (head_is_amo ? amo_old_value_r : mem_readData);
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
        amo_need_write_r <= 1'b0;
    end
    else begin
        // Wakeup: any entry's not-yet-ready base/store-data operand
        // matching a live CDB broadcast becomes ready next cycle -- same
        // shape as ReservationStation.v's own wakeup, applied to every
        // entry (not just the head) so operands can become ready while
        // still queued behind an older entry. Gen6-P1: STORE/SC/AMO_RMW
        // all need the store-data/rs2 operand (e_op_type != OP_LOAD),
        // not just STORE.
        for (reset_i = 0; reset_i < LSQ_ENTRIES; reset_i = reset_i + 1) begin
            if (e_valid[reset_i] && !e_base_ready[reset_i]
                && ((cdb_valid0 && cdb_preg0 == e_base_preg[reset_i]) || (cdb_valid1 && cdb_preg1 == e_base_preg[reset_i]) || (cdb_valid2 && cdb_preg2 == e_base_preg[reset_i])))
                e_base_ready[reset_i] <= 1'b1;
            if (e_valid[reset_i] && (e_op_type[reset_i] != OP_LOAD) && !e_store_data_ready[reset_i]
                && ((cdb_valid0 && cdb_preg0 == e_store_data_preg[reset_i]) || (cdb_valid1 && cdb_preg1 == e_store_data_preg[reset_i]) || (cdb_valid2 && cdb_preg2 == e_store_data_preg[reset_i])))
                e_store_data_ready[reset_i] <= 1'b1;
        end

        // Memory issue/complete, head entry only. complete_valid (==
        // mem_pending_r && !amo_phase1_just_finished, declared above) is
        // this cycle's own retire signal -- reused directly in the
        // single count_r update at the end of this block instead of a
        // second, separately-maintained copy of the same condition.
        // Gen6-P1: OP_AMO_RMW's own phase 1 (read) completing does NOT
        // retire the entry -- it captures the old value and flips into
        // phase 2 (write) instead, re-triggering head_ready/mem_pending_r
        // for the SAME entry.
        // Gen6-P2: force_retire_ext takes priority over the ordinary
        // head_ready/mem_pending_r path -- mutually exclusive by
        // construction anyway (the caller only ever pulses this while
        // mem_stall_ext has been holding head_ready false, so
        // mem_pending_r is guaranteed 0 here), but checked first for
        // clarity. Silently retires -- no memory touched, no
        // complete_valid pulse (the caller already informed the ROB via
        // its own separate synthetic-completion mechanism).
        if (force_retire_ext) begin
            e_valid[head_r]   <= 1'b0;
            head_r            <= wrap_add(head_r, 2'd1);
            amo_need_write_r  <= 1'b0;
        end
        else if (head_ready)
            mem_pending_r <= 1'b1;
        else if (mem_pending_r) begin
            mem_pending_r <= 1'b0;
            if (head_is_amo && !amo_need_write_r) begin
                amo_old_value_r  <= mem_readData;
                amo_need_write_r <= 1'b1;
                // e_valid[head_r]/head_r deliberately untouched -- this
                // entry isn't done yet, phase 2 (the write) still needs
                // to happen before it can retire.
            end
            else begin
                e_valid[head_r]   <= 1'b0;
                head_r            <= wrap_add(head_r, 2'd1);
                amo_need_write_r  <= 1'b0;   // reset for whichever entry
                                               // is head next (harmless
                                               // no-op if that entry
                                               // isn't itself an AMO_RMW)
            end
        end

        // Dispatch: append at the tail.
        if (disp_en0) begin
            e_valid[tail_r]             <= 1'b1;
            e_op_type[tail_r]           <= disp_op_type0;
            e_amo_op[tail_r]            <= disp_amo_op0;
            e_base_preg[tail_r]         <= disp_base_preg0;
            e_base_ready[tail_r]        <= disp_base_ready0;
            e_imm[tail_r]               <= disp_imm0;
            e_funct3[tail_r]            <= disp_funct3_0;
            e_store_data_preg[tail_r]   <= disp_store_data_preg0;
            e_store_data_ready[tail_r]  <= disp_store_data_ready0;
            e_dest_preg[tail_r]         <= disp_dest_preg0;
            e_rob_tag[tail_r]           <= disp_rob_tag0;
            e_pc[tail_r]                <= disp_pc0;
        end
        if (disp_en1) begin
            e_valid[tail1_idx]             <= 1'b1;
            e_op_type[tail1_idx]           <= disp_op_type1;
            e_amo_op[tail1_idx]            <= disp_amo_op1;
            e_base_preg[tail1_idx]         <= disp_base_preg1;
            e_base_ready[tail1_idx]        <= disp_base_ready1;
            e_imm[tail1_idx]               <= disp_imm1;
            e_funct3[tail1_idx]            <= disp_funct3_1;
            e_store_data_preg[tail1_idx]   <= disp_store_data_preg1;
            e_store_data_ready[tail1_idx]  <= disp_store_data_ready1;
            e_dest_preg[tail1_idx]         <= disp_dest_preg1;
            e_rob_tag[tail1_idx]           <= disp_rob_tag1;
            e_pc[tail1_idx]                <= disp_pc1;
        end
        if (disp_count != 2'd0)
            tail_r <= wrap_add(tail_r, disp_count);

        // Single, unified occupancy update -- complete_valid (==
        // mem_pending_r) OR force_retire_ext (Gen6-P2's own silent
        // retire, mutually exclusive with complete_valid by construction)
        // is this cycle's own retire, disp_count is this cycle's own
        // dispatch; both can happen the same cycle (a completing head and
        // a fresh tail append never touch the same entry, so there's no
        // ordering hazard between them).
        count_r <= count_r - ((complete_valid || force_retire_ext) ? 2'd1 : 2'd0) + disp_count;
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
