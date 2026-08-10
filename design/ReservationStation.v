`default_nettype none

// Generation 6 (out-of-order core), Gen6-C
// (C:\Users\poorn\.claude\plans\gen6-ooo-core.md). One reservation-
// station implementation, instantiated once per functional-unit class
// (INT-ALU, MUL/DIV, FP, AGU/LSU) -- mirrors VictimCache.v/L2Cache.v/
// Prefetcher.v's own "one implementation, multiple instances" precedent.
// Each instance feeds exactly ONE execution port (the single existing
// ALU.v/Divider.v/FALU.v/etc. instance for that class, per Gen1-5's own
// actual hardware -- not a speculative multi-port design nobody asked
// for).
//
// Deliberately decoupled from PhysicalRegisterFile.v: this module never
// reads/writes the PRF itself. Dispatch-time operand readiness
// (disp_src*_ready) is the CALLER's own PRF.rvalid query result; issued
// operand VALUES are the caller's own PRF read the cycle it accepts
// issue_valid (by the time an entry is ready, PRF.rvalid for that preg
// is true by construction, so a same-cycle PRF read at issue is always
// live data, never a stale/garbage race). Same decoupled-module
// discipline as every other Gen6-* module so far (and Scoreboard.v/
// DCache.v's own established precedent, docs/adr/0044).
//
// Wakeup (CDB snoop): each entry's src1/src2 physical-register tags are
// compared against up to 2 CDB broadcasts/cycle; a same-cycle dispatch
// also sees this (a same-cycle producer/consumer through the RS, not
// just through PhysicalRegisterFile.v's own write-first bypass).
//
// `# ponytail`-tagged deliberate simplifications, both with a known,
// documented ceiling and upgrade path (same style as VictimCache.v's own
// FIFO-only comment, Prefetcher.v's own single-global-entry predictor):
//   - Select is lowest-index-first among ready entries, NOT true
//     age/oldest-first tracking. Correctness is unaffected (the ROB
//     enforces retire order regardless of RS issue order) -- only
//     scheduling throughput could suffer under contention. Upgrade path:
//     add a real age counter per entry if profiling ever shows this
//     mattering.
//   - Wakeup-to-issue takes one full cycle: an entry only becomes
//     selectable to issue the cycle AFTER its last operand's CDB
//     broadcast lands (registered ready bits), not the same cycle.
//     Upgrade path: OR the live cdb_valid/preg match into the select
//     condition the same way dispatch's own same-cycle bypass already
//     works, if this 1-cycle bubble ever shows up as a real bottleneck.
module ReservationStation #(
    parameter RS_ENTRIES    = 8,
    parameter PREG_BITS     = 6,
    parameter ROB_IDX_BITS  = 5,
    parameter PAYLOAD_BITS  = 8,    // caller-defined opcode/control payload
    parameter ENTRY_BITS    = $clog2(RS_ENTRIES),
    parameter CNT_BITS      = $clog2(RS_ENTRIES+1)
)(
    input  wire                     clk,
    input  wire                     rst,

    // Dispatch, up to 2/cycle. Caller must check rs_full itself first,
    // same caller-enforces-room discipline as every other Gen6-* module.
    input  wire                     disp_en0,
    input  wire [PREG_BITS-1:0]     disp_src1_preg0,
    input  wire                     disp_src1_ready0,
    input  wire [PREG_BITS-1:0]     disp_src2_preg0,
    input  wire                     disp_src2_ready0,
    input  wire [PREG_BITS-1:0]     disp_dest_preg0,
    input  wire [ROB_IDX_BITS-1:0]  disp_rob_tag0,
    input  wire [PAYLOAD_BITS-1:0]  disp_payload0,

    input  wire                     disp_en1,
    input  wire [PREG_BITS-1:0]     disp_src1_preg1,
    input  wire                     disp_src1_ready1,
    input  wire [PREG_BITS-1:0]     disp_src2_preg1,
    input  wire                     disp_src2_ready1,
    input  wire [PREG_BITS-1:0]     disp_dest_preg1,
    input  wire [ROB_IDX_BITS-1:0]  disp_rob_tag1,
    input  wire [PAYLOAD_BITS-1:0]  disp_payload1,

    // CDB snoop, 3 broadcasts/cycle (Gen6-F, up from 2 -- a 3rd,
    // independent completion source, Divider.v's own multi-cycle DIV/REM
    // result, joined ReorderBuffer.v/PhysicalRegisterFile.v's own matching
    // 3rd ports the same phase).
    input  wire                     cdb_valid0,
    input  wire [PREG_BITS-1:0]     cdb_preg0,
    input  wire                     cdb_valid1,
    input  wire [PREG_BITS-1:0]     cdb_preg1,
    input  wire                     cdb_valid2,
    input  wire [PREG_BITS-1:0]     cdb_preg2,

    // Issue (select), one entry/cycle.
    output wire                     issue_valid,
    output wire [PREG_BITS-1:0]     issue_src1_preg,
    output wire [PREG_BITS-1:0]     issue_src2_preg,
    output wire [PREG_BITS-1:0]     issue_dest_preg,
    output wire [ROB_IDX_BITS-1:0]  issue_rob_tag,
    output wire [PAYLOAD_BITS-1:0]  issue_payload,
    input  wire                     issue_ack,   // caller pulses when it
                                                  // genuinely consumes the
                                                  // selected entry this
                                                  // cycle -- mirrors
                                                  // Divider.v/FDivider.v's
                                                  // own caller-controlled
                                                  // start handshake

    output wire [CNT_BITS-1:0]      rs_count,
    output wire                     rs_full
);

reg                    valid      [0:RS_ENTRIES-1];
reg [PREG_BITS-1:0]    src1_preg  [0:RS_ENTRIES-1];
reg                    src1_ready [0:RS_ENTRIES-1];
reg [PREG_BITS-1:0]    src2_preg  [0:RS_ENTRIES-1];
reg                    src2_ready [0:RS_ENTRIES-1];
reg [PREG_BITS-1:0]    dest_preg  [0:RS_ENTRIES-1];
reg [ROB_IDX_BITS-1:0] rob_tag    [0:RS_ENTRIES-1];
reg [PAYLOAD_BITS-1:0] payload    [0:RS_ENTRIES-1];

// -- Free-slot allocation: lowest-index invalid entry. A `generate`/
// `assign` first-match accumulator chain, NOT a procedural always@*
// for-loop over these unpacked arrays -- DCache.v's own hit_data_acc/
// hit_lineidx_acc (docs/adr/0042's own header comment on that pattern)
// already found the reason: Icarus (-g2005, this project's own
// toolchain) emits an "always @* sensitive to all N words" warning for
// the loop form, so every such array-wide priority-encode in this
// project uses the accumulator-chain form instead. --
wire                 alloc0_acc_found [0:RS_ENTRIES];
wire [ENTRY_BITS-1:0] alloc0_acc_idx  [0:RS_ENTRIES];
assign alloc0_acc_found[0] = 1'b0;
assign alloc0_acc_idx[0]   = {ENTRY_BITS{1'b0}};

wire                 alloc1_acc_found [0:RS_ENTRIES];
wire [ENTRY_BITS-1:0] alloc1_acc_idx  [0:RS_ENTRIES];
assign alloc1_acc_found[0] = 1'b0;
assign alloc1_acc_idx[0]   = {ENTRY_BITS{1'b0}};

genvar ga;
generate
    for (ga = 0; ga < RS_ENTRIES; ga = ga + 1) begin : gen_alloc_scan
        wire cand0 = ~valid[ga];
        assign alloc0_acc_found[ga+1] = alloc0_acc_found[ga] | cand0;
        assign alloc0_acc_idx[ga+1]   = alloc0_acc_found[ga] ? alloc0_acc_idx[ga]
                                       : (cand0 ? ga[ENTRY_BITS-1:0] : alloc0_acc_idx[ga]);

        // slot1's own candidate excludes whichever index slot0 is about
        // to claim this cycle (alloc0_found/alloc0_idx, the FINAL
        // accumulator outputs below, referenced here since generate
        // elaboration allows forward reference to a later-declared wire).
        wire cand1 = ~valid[ga] && !(disp_en0 && alloc0_found && (ga[ENTRY_BITS-1:0] == alloc0_idx));
        assign alloc1_acc_found[ga+1] = alloc1_acc_found[ga] | cand1;
        assign alloc1_acc_idx[ga+1]   = alloc1_acc_found[ga] ? alloc1_acc_idx[ga]
                                       : (cand1 ? ga[ENTRY_BITS-1:0] : alloc1_acc_idx[ga]);
    end
endgenerate

wire alloc0_found = alloc0_acc_found[RS_ENTRIES];
wire [ENTRY_BITS-1:0] alloc0_idx = alloc0_acc_idx[RS_ENTRIES];
wire alloc1_found = alloc1_acc_found[RS_ENTRIES];
wire [ENTRY_BITS-1:0] alloc1_idx = alloc1_acc_idx[RS_ENTRIES];

wire disp0_ok = disp_en0 && alloc0_found;
wire disp1_ok = disp_en1 && alloc1_found;

// Same-cycle CDB bypass at dispatch time -- mirrors
// PhysicalRegisterFile.v's own write-first bypass reasoning: a producer
// broadcasting the exact cycle a dependent instruction dispatches must
// be visible immediately, not one cycle late.
wire disp0_s1_ready = disp_src1_ready0 || (cdb_valid0 && cdb_preg0 == disp_src1_preg0) || (cdb_valid1 && cdb_preg1 == disp_src1_preg0) || (cdb_valid2 && cdb_preg2 == disp_src1_preg0);
wire disp0_s2_ready = disp_src2_ready0 || (cdb_valid0 && cdb_preg0 == disp_src2_preg0) || (cdb_valid1 && cdb_preg1 == disp_src2_preg0) || (cdb_valid2 && cdb_preg2 == disp_src2_preg0);
wire disp1_s1_ready = disp_src1_ready1 || (cdb_valid0 && cdb_preg0 == disp_src1_preg1) || (cdb_valid1 && cdb_preg1 == disp_src1_preg1) || (cdb_valid2 && cdb_preg2 == disp_src1_preg1);
wire disp1_s2_ready = disp_src2_ready1 || (cdb_valid0 && cdb_preg0 == disp_src2_preg1) || (cdb_valid1 && cdb_preg1 == disp_src2_preg1) || (cdb_valid2 && cdb_preg2 == disp_src2_preg1);

// -- Issue (select): lowest-index entry with both operands ready --
// same accumulator-chain style as the alloc scan above.
wire                 issue_acc_found [0:RS_ENTRIES];
wire [ENTRY_BITS-1:0] issue_acc_idx  [0:RS_ENTRIES];
assign issue_acc_found[0] = 1'b0;
assign issue_acc_idx[0]   = {ENTRY_BITS{1'b0}};

genvar gs;
generate
    for (gs = 0; gs < RS_ENTRIES; gs = gs + 1) begin : gen_issue_scan
        wire cand_ready = valid[gs] && src1_ready[gs] && src2_ready[gs];
        assign issue_acc_found[gs+1] = issue_acc_found[gs] | cand_ready;
        assign issue_acc_idx[gs+1]   = issue_acc_found[gs] ? issue_acc_idx[gs]
                                      : (cand_ready ? gs[ENTRY_BITS-1:0] : issue_acc_idx[gs]);
    end
endgenerate

wire [ENTRY_BITS-1:0] issue_idx = issue_acc_idx[RS_ENTRIES];

assign issue_valid     = issue_acc_found[RS_ENTRIES];
assign issue_src1_preg = src1_preg[issue_idx];
assign issue_src2_preg = src2_preg[issue_idx];
assign issue_dest_preg = dest_preg[issue_idx];
assign issue_rob_tag   = rob_tag[issue_idx];
assign issue_payload   = payload[issue_idx];

// Population count -- same accumulator-chain style, an adder this time
// rather than a first-match search.
wire [CNT_BITS-1:0] count_acc [0:RS_ENTRIES];
assign count_acc[0] = {CNT_BITS{1'b0}};
genvar gc;
generate
    for (gc = 0; gc < RS_ENTRIES; gc = gc + 1) begin : gen_popcount
        assign count_acc[gc+1] = count_acc[gc] + (valid[gc] ? 1'b1 : 1'b0);
    end
endgenerate

assign rs_count = count_acc[RS_ENTRIES];
assign rs_full  = (count_acc[RS_ENTRIES] >= RS_ENTRIES[CNT_BITS-1:0]);

integer reset_i;
always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < RS_ENTRIES; reset_i = reset_i + 1)
            valid[reset_i] <= 1'b0;
    end
    else begin
        // Wakeup: any valid, not-yet-ready entry whose src preg matches
        // a live CDB broadcast becomes ready next cycle.
        for (reset_i = 0; reset_i < RS_ENTRIES; reset_i = reset_i + 1) begin
            if (valid[reset_i] && !src1_ready[reset_i]
                && ((cdb_valid0 && cdb_preg0 == src1_preg[reset_i]) || (cdb_valid1 && cdb_preg1 == src1_preg[reset_i]) || (cdb_valid2 && cdb_preg2 == src1_preg[reset_i])))
                src1_ready[reset_i] <= 1'b1;
            if (valid[reset_i] && !src2_ready[reset_i]
                && ((cdb_valid0 && cdb_preg0 == src2_preg[reset_i]) || (cdb_valid1 && cdb_preg1 == src2_preg[reset_i]) || (cdb_valid2 && cdb_preg2 == src2_preg[reset_i])))
                src2_ready[reset_i] <= 1'b1;
        end

        // Issue: clear the selected entry once the caller actually
        // consumes it.
        if (issue_valid && issue_ack)
            valid[issue_idx] <= 1'b0;

        // Dispatch: write a fresh entry into each free slot found by
        // this cycle's combinational scan. That scan reads `valid[]`'s
        // CURRENT (pre-this-edge) contents, so a slot freed by the
        // issue-clear above only becomes allocatable the cycle AFTER --
        // a real, deliberate one-cycle conservatism (rs_full reflects
        // that exact same pre-clear count, so the caller's own room
        // check never disagrees with what dispatch can actually use
        // this cycle -- no collision is possible, just a bubble a
        // same-cycle free+reuse could have avoided).
        if (disp0_ok) begin
            valid[alloc0_idx]      <= 1'b1;
            src1_preg[alloc0_idx]  <= disp_src1_preg0;
            src1_ready[alloc0_idx] <= disp0_s1_ready;
            src2_preg[alloc0_idx]  <= disp_src2_preg0;
            src2_ready[alloc0_idx] <= disp0_s2_ready;
            dest_preg[alloc0_idx]  <= disp_dest_preg0;
            rob_tag[alloc0_idx]    <= disp_rob_tag0;
            payload[alloc0_idx]    <= disp_payload0;
        end
        if (disp1_ok) begin
            valid[alloc1_idx]      <= 1'b1;
            src1_preg[alloc1_idx]  <= disp_src1_preg1;
            src1_ready[alloc1_idx] <= disp1_s1_ready;
            src2_preg[alloc1_idx]  <= disp_src2_preg1;
            src2_ready[alloc1_idx] <= disp1_s2_ready;
            dest_preg[alloc1_idx]  <= disp_dest_preg1;
            rob_tag[alloc1_idx]    <= disp_rob_tag1;
            payload[alloc1_idx]    <= disp_payload1;
        end
    end
end

`ifdef ASSERT_ON
always @(posedge clk) begin
    if (rst && (count_acc[RS_ENTRIES] > RS_ENTRIES[CNT_BITS-1:0]))
        begin $display("ASSERTION FAILED @t=%0t: ReservationStation count_acc[RS_ENTRIES]=%0d exceeds RS_ENTRIES=%0d", $time, count_acc[RS_ENTRIES], RS_ENTRIES); $finish; end
end
`endif

endmodule

`default_nettype wire
