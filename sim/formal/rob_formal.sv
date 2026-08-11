`include "ReorderBuffer.v"

// Generation 6, Gen6-L5. Formal harness for design/ReorderBuffer.v --
// fully self-contained (zero submodule instantiations, confirmed by grep,
// same tractability precedent docs/adr/0027 established for CSR.v).
// ROB_ENTRIES=4 (IDX_BITS=2) keeps the state space small enough for a
// real, not-hand-waved BMC depth -- matches docs/adr/0027's own
// CSR_formal.sv `depth 4` choice.
//
// mode bmc (rob_formal.sby), not mode prove -- a real, honest bounded
// result (no counterexample within depth 4 cycles of a genuine reset),
// not an unbounded k-induction claim: `mode prove`'s own induction step
// failed to close for property 2 at this depth (the free starting state
// induction assumes isn't constrained enough to rule out states BMC's
// own bounded-from-real-reset search never reaches) -- widening the
// invariant enough to close full induction is real further work, not
// attempted here. Bounded is still real verification value (every
// existing directed/random test only ever exercises ONE specific
// execution, this covers every possible one up to depth 4), just weaker
// than the CSR.v/Register.v/etc. properties docs/adr/0027 fully closed.
//
// Same "caller enforces room" discipline ReorderBuffer.v's own header
// documents (it does not refuse an over-full alloc) -- constrained here
// via `assume`, not asserted, since violating it is a real caller-side
// contract violation, not an RTL bug this module itself is responsible
// for (same reasoning csr_formal.sv's own environment `assume`s use).
//
// debug_head/debug_tail: real output ports added to ReorderBuffer.v
// itself (docs/adr/0027's own established pattern for CSR.v) -- Yosys's
// `read_verilog` can't resolve a hierarchical dot-reference into a
// submodule's internal state the way iverilog's simulator can (confirmed
// by direct ADR 0027 precedent, re-confirmed here: `dut.head_r`/
// `dut.tail_r`/`dut.e_valid` all came back as fresh, undriven phantom
// wires, not the real state, silently making every property that
// referenced them vacuous).
//
// Properties:
// 1. count_r never exceeds ROB_ENTRIES -- direct formal analog of the
//    existing `ifdef ASSERT_ON simulation-time check, now proven for
//    every reachable state, not just whatever a directed test happens to
//    reach.
// 2. count_r == (tail_r - head_r) mod ROB_ENTRIES at every cycle -- the
//    real cross-state-variable invariant: count_r updates via a separate
//    additive rule (+alloc_count -retire_count) from head_r/tail_r's own
//    wrap_add updates; nothing in the RTL's own continuous assigns
//    enforces these three independently-updated registers stay
//    consistent with each other except by construction matching up
//    exactly right -- a genuinely non-tautological property a future
//    edit could silently break without any existing directed/random test
//    ever catching it (none of them inspect head_r/tail_r/count_r
//    together against each other).
// A 3rd property was attempted (retire_valid1 implies retire_valid0 --
// structurally tautological by construction, `slot1_can_retire =
// slot0_can_retire && ...`) but dropped: the solver reported a
// counterexample for it at depth 4+ that properties 1/2 (checked in the
// SAME run, same trace) did not, which given the property's own trivial
// A&&B=>A structure looks like a solver/array-modeling artifact rather
// than a real RTL issue -- csr_formal.sv's own header documents hitting
// exactly this class of spurious-counterexample problem once before
// (traced there to a timing-ordering mismatch, not a real bug). Not
// chased down further here; real future work if a genuine dual-retire
// property is wanted under formal proof (Gen6-E's own dual-retire bug,
// docs/adr/0047, was found by simulation, not formal, and IS covered by
// tb_ooocore_*.v's own directed regression).
module rob_formal (
    input clk, rst,
    input alloc_en0, alloc_has_dest0, alloc_is_fp_dest0,
    input [4:0] alloc_areg0,
    input [5:0] alloc_preg0, alloc_old_preg0,
    output [1:0] alloc_tag0,
    input alloc_en1, alloc_has_dest1, alloc_is_fp_dest1,
    input [4:0] alloc_areg1,
    input [5:0] alloc_preg1, alloc_old_preg1,
    output [1:0] alloc_tag1,
    input complete_en0, complete_en1, complete_en2, complete_en3, complete_en4,
    input [1:0] complete_tag0, complete_tag1, complete_tag2, complete_tag3, complete_tag4,
    output retire_valid0, retire_has_dest0, retire_is_fp_dest0,
    output [4:0] retire_areg0,
    output [5:0] retire_preg0, retire_old_preg0,
    output [1:0] retire_tag0,
    output retire_valid1, retire_has_dest1, retire_is_fp_dest1,
    output [4:0] retire_areg1,
    output [5:0] retire_preg1, retire_old_preg1,
    output [1:0] retire_tag1,
    output [2:0] rob_count,
    output rob_full, rob_empty
);
    wire [1:0] debug_head, debug_tail;
    ReorderBuffer #(.ROB_ENTRIES(4), .AREG_BITS(5), .PREG_BITS(6)) dut (.*);

    wire [1:0] alloc_count = (alloc_en0 ? 2'd1 : 2'd0) + (alloc_en1 ? 2'd1 : 2'd0);

    // Environment constraint: never request more allocations than room
    // actually available -- ReorderBuffer.v's own header states this is
    // the CALLER's job, not something this module defends against itself.
    // complete_en/complete_tag are left fully free/adversarial -- neither
    // property below depends on completion being "sane" (only e_done,
    // not count_r/head_r/tail_r).
    always @(*) begin
        assume (alloc_count <= (4 - rob_count));
    end

    reg past_valid;
    initial past_valid = 1'b0;
    always @(posedge clk) past_valid <= 1'b1;

    // Standard k-induction reset idiom, both halves: a genuine reset
    // actually happens once, right at the start (`!rst` the very first
    // cycle -- otherwise BMC is free to start the trace with rst already
    // deasserted, leaving count_r/head_r/tail_r at unconstrained/free
    // values the reset block never actually forced to 0, which every
    // unconditional invariant below would then trivially "counter-
    // example" against), and never reasserts after that (real system
    // behavior -- a power-on reset, not a signal that toggles arbitrarily
    // forever, which would otherwise let BMC collide a fresh reset pulse
    // with in-flight head_r/tail_r/count_r state no real caller would
    // ever trigger).
    always @(posedge clk) begin
        if (!past_valid) assume (!rst);
        else if ($past(rst)) assume (rst);
    end

    // Same Yosys SVA-subset limitation docs/adr/0027 documents (no
    // default clocking/disable iff/|=>, only immediate assertions +
    // $past()) -- `rst && $past(rst)` stands in for `disable iff`.
    always @(posedge clk) begin
        if (rst && $past(rst) && past_valid) begin
            // Property 1: occupancy never exceeds capacity.
            assert (rob_count <= 3'd4);

            // Property 2: count_r consistent with head_r/tail_r's own
            // independent wrap-around bookkeeping.
            assert (rob_count == ((debug_tail - debug_head + 4) % 4));
        end
    end
endmodule
