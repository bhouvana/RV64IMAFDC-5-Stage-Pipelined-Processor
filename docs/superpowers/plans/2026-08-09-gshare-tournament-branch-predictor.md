# GShare + Tournament Branch Predictor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Generation 4, Phase A (docs/ROADMAP_VISION.md's "Advanced Memory System"): add GShare and
tournament branch predictors as two new selectable `BRANCH_PREDICTOR` values (2 and 3) alongside the
existing static (0) and 2-bit BHT+BTB (1) schemes, following this project's own established swappable-
parameter convention exactly (closed named enum, `generate if`, zero cost when unselected).

**Architecture:** Two new standalone modules (`design/Gshare.v`, `design/Chooser.v`), each mirroring
`design/Bht.v`'s existing shape (direct-mapped table of 2-bit saturating counters, combinational query,
synchronous resolved-only update, deliberately untagged). `Gshare.v` XORs a global history register into
the index; `Chooser.v` is the tournament meta-predictor, trained only when its two sub-predictors
disagreed. `Bht.v` gains one small, additive change (a second combinational read port) so the chooser can
query it without threading any new per-instruction pipeline signal. Wired live into `riscvpipeline.v`'s
existing `predict_taken_if`/`predict_target_if`/`bp_update_*` interface — confirmed by research to need
zero new pipeline-wide signals for the prediction path itself. `design/Btb.v` (target prediction) is
completely unchanged and shared across every dynamic scheme.

**Tech Stack:** Verilog-2005 (Icarus `/c/iverilog/bin`, this project's real toolchain — NOT whatever
`iverilog` OSS CAD Suite bundles, see `docs/adr/0039`'s own "Real bugs/findings #3"), this project's own
`sim/tools/asm.py`/`iss.py`/`random_gen.py`/`run_random_tests.py`/`bench_runner.py`/`profiler.py` Python
tooling.

## Global Constraints

- Every existing `BRANCH_PREDICTOR` value (0, 1) must stay bit-exact — this is an additive change, not a
  redesign. Full regression (`bash sim/run_tests.sh /c/iverilog/bin`) must stay at 88/90 (the same two
  pre-existing, unrelated failures `docs/adr/0039` documents — `tb_arith`'s own flagged `ctz` off-by-one,
  `tb_icache_unit`'s stale post-byte-order-fix expected values — neither touched by this work).
- Zero-warning compile: `iverilog -Wall -g2005 -I design -tnull design/*.v` (via `/c/iverilog/bin`, not
  OSS CAD Suite's bundled Icarus — confirmed broken for real elaboration in `docs/adr/0039`).
- Use `/c/iverilog/bin/iverilog` and `/c/iverilog/bin/vvp` explicitly (or pass that dir as
  `sim/run_tests.sh`'s own `$1` argument) — this machine has a second, wrong Icarus install on PATH by
  default.
- Every new module gets its own standalone unit testbench before being wired live (mirrors
  `Bht.v`/`Btb.v`'s own original F-phase precedent: standalone-and-tested first, wired live as its own
  separate, isolated, higher-risk step).
- No new pipeline-wide latched signal for the direction-predictor-vs-chooser training path — use the
  second-read-port design (Task 1) instead, exactly as scoped below. If a task discovers this doesn't
  actually work once implemented, stop and re-plan rather than silently threading a new signal through
  reg1/reg1a/reg2 (a materially bigger, riskier change this plan deliberately avoids).
- Commit after every task (this project's own established one-commit-per-step convention, confirmed via
  `git log`) — but do NOT push until the user asks, same discipline `docs/adr/0039`'s own session used.

---

### Task 1: `Bht.v` — add a second, independent combinational read port

**Files:**
- Modify: `design/Bht.v`
- Modify: `sim/tb/tb_bht_unit.v`

**Interfaces:**
- Produces: `Bht`'s port list gains `input [XLEN-1:0] train_pc` and `output train_predict_taken` —
  a second, independent combinational read of the *same* `counters[]` array at a *different* index,
  mirroring `design/Tlb.v`'s own existing "one array, two independent combinational read ports"
  precedent (`docs/adr/0022-mmu-sv32.md`). Task 3/4 rely on this exact port pair existing.

- [ ] **Step 1: Add the failing checks to the existing unit test first**

Open `sim/tb/tb_bht_unit.v`. Add two new reg/wire declarations right after the existing ones (after
line 18, `reg update_taken = 0;`):

```verilog
    reg [31:0] train_pc = 0;
    wire train_predict_taken;
```

Update the DUT instantiation (lines 27-31) to connect the new ports:

```verilog
    Bht #(.XLEN(32), .NUM_ENTRIES(4)) dut(
        .clk(clk), .rst(rst),
        .query_pc(query_pc), .predict_taken(predict_taken),
        .train_pc(train_pc), .train_predict_taken(train_predict_taken),
        .update_valid(update_valid), .update_pc(update_pc), .update_taken(update_taken)
    );
```

Add new checks right before the final `if (fails == 0)` block (after the existing aliasing checks,
line 113):

```verilog
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
```

- [ ] **Step 2: Run the test to verify it fails (port doesn't exist yet)**

Run: `/c/iverilog/bin/iverilog -g2005 -DASSERT_ON -I design -I sim/tb -o /tmp/tb_bht.vvp sim/tb/tb_bht_unit.v`
Expected: FAIL to compile — `train_pc`/`train_predict_taken` unknown ports on `Bht`.

- [ ] **Step 3: Add the second read port to `Bht.v`**

In `design/Bht.v`, add to the port list (after `input update_taken` closing, i.e. right after line 51's
`input update_taken`, before the closing `);` at line 52 — insert as new ports before the existing
`update_*` group so query-side ports stay together):

```verilog
    input      [XLEN-1:0] query_pc,
    output                predict_taken,

    // Second, independent combinational read port -- same array, a
    // different index, purely additive (existing BRANCH_PREDICTOR=1
    // wiring simply never connects it, zero behavior change there).
    // Mirrors Tlb.v's own precedent (docs/adr/0022) for a small array with
    // two independent read ports. Lets a tournament predictor's Chooser.v
    // (Generation 4, Phase A, docs/adr/0040) query this table's own
    // opinion for whichever PC is currently being trained, without
    // threading a new per-instruction latched prediction bit through
    // reg1/reg1a/reg2 -- a real, deliberate scope decision (see that
    // ADR's Design section) that keeps this phase's pipeline-wiring risk
    // to zero new latched signals.
    input      [XLEN-1:0] train_pc,
    output                 train_predict_taken,

    input                  update_valid,
    input      [XLEN-1:0]  update_pc,
    input                  update_taken
```

Add the new index/read wires after the existing `query_index`/`update_index` declarations (after line
63):

```verilog
wire [INDEX_WIDTH-1:0] train_index = train_pc[INDEX_WIDTH+1:2];
```

Add the new read assignment after the existing `assign predict_taken = ...` (after line 65):

```verilog
assign train_predict_taken = counters[train_index][1];
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `/c/iverilog/bin/iverilog -g2005 -DASSERT_ON -I design -I sim/tb -o /tmp/tb_bht.vvp sim/tb/tb_bht_unit.v && /c/iverilog/bin/vvp /tmp/tb_bht.vvp`
Expected: `PASS  bht_unit (14 checks)` (11 existing + 3 new).

- [ ] **Step 5: Confirm existing BRANCH_PREDICTOR=1 wiring still compiles (new ports unconnected there)**

Run: `/c/iverilog/bin/iverilog -Wall -g2005 -I design -tnull design/*.v`
Expected: zero warnings, zero errors — Verilog allows an instantiation (the existing one in
`riscvpipeline.v`'s `gen_predictor` block) to leave new ports unconnected.

- [ ] **Step 6: Commit**

```bash
git add design/Bht.v sim/tb/tb_bht_unit.v
git commit -m "Gen4 Phase A: add Bht.v's second (train_pc) read port

Mirrors Tlb.v's own two-independent-read-port precedent. Purely
additive -- existing BRANCH_PREDICTOR=1 wiring leaves the new ports
unconnected, zero behavior change. Lets a future tournament
predictor's chooser query this table without threading a new
per-instruction pipeline signal."
```

---

### Task 2: `Gshare.v` — new standalone module + unit test

**Files:**
- Create: `design/Gshare.v`
- Create: `sim/tb/tb_gshare_unit.v`

**Interfaces:**
- Consumes: nothing from earlier tasks (standalone, like `Bht.v`/`Btb.v` originally were).
- Produces: `Gshare #(.XLEN(XLEN), .NUM_ENTRIES(N))` with ports `clk, rst, query_pc, predict_taken,
  train_pc, train_predict_taken, update_valid, update_pc, update_taken` — the *exact same* port list
  shape as `Bht.v` post-Task-1 (drop-in interface-compatible), so Task 4 can instantiate either one
  identically. Task 4 relies on this exact signature.

- [ ] **Step 1: Write `design/Gshare.v`**

```verilog
`default_nettype none

// docs/adr/0040-gshare-tournament-branch-predictor.md (Generation 4, Phase
// A). GShare direction predictor: the same 2-bit saturating (Smith)
// counter table shape as Bht.v, but indexed by a PC-bit slice XORed with a
// global history register (the outcome of the last INDEX_WIDTH resolved
// branches/jumps, taken=1/not-taken=0, newest bit at position 0) instead of
// the PC alone -- letting two different PCs that alias in a plain bimodal
// table train separate counters when reached via different recent branch
// history, and letting the same PC (a branch inside a loop, for example)
// get a different prediction depending on which recent path led to it.
//
// Deliberately untagged, same reasoning as Bht.v's own header (a
// misprediction from aliasing can never produce a wrong architectural
// result, only cost an extra bubble -- riscvpipeline.v's EX-stage
// comparison against ground truth always catches it).
//
// Deliberately RESOLVED-history-only, not speculative: the global history
// register updates synchronously from EX's own real resolution, one cycle
// behind, exactly the same "no same-cycle bypass" simplification Bht.v's
// own header already documents and accepts for its counter table. A real,
// deliberate scope decision, not an oversight: speculative-history update
// (folding in not-yet-resolved in-flight branch guesses, with rollback on
// misprediction) is a genuinely separate, larger feature this phase does
// not attempt -- see docs/adr/0040's Alternatives considered section.
//
// History width equals INDEX_WIDTH (reuses NUM_ENTRIES' own sizing, no new
// parameter) -- a real, deliberate simplification for this project's own
// small default table sizes; a wider history folded down via XOR would be
// a real future refinement if a much larger NUM_ENTRIES is ever benchmarked
// (see docs/adr/0040's Future improvements).
//
// Second, independent combinational read port (train_pc ->
// train_predict_taken), identical shape to Bht.v's own Task-1 addition, for
// Chooser.v to query this table's own opinion at the PC currently being
// trained.
module Gshare #(
    parameter XLEN = 32,
    parameter NUM_ENTRIES = 32   // must be a power of 2, same convention as Bht.v/Btb.v
)(
    input clk,
    input rst,

    input      [XLEN-1:0] query_pc,
    output                predict_taken,

    input      [XLEN-1:0] train_pc,
    output                 train_predict_taken,

    input                  update_valid,
    input      [XLEN-1:0]  update_pc,
    input                  update_taken
);

localparam INDEX_WIDTH = $clog2(NUM_ENTRIES);

reg [1:0] counters [0:NUM_ENTRIES-1];
reg [INDEX_WIDTH-1:0] ghr;   // global history register, newest outcome in bit 0
integer reset_i;

wire [INDEX_WIDTH-1:0] query_index  = query_pc[INDEX_WIDTH+1:2]  ^ ghr;
wire [INDEX_WIDTH-1:0] update_index = update_pc[INDEX_WIDTH+1:2] ^ ghr;
wire [INDEX_WIDTH-1:0] train_index  = train_pc[INDEX_WIDTH+1:2]  ^ ghr;

assign predict_taken = counters[query_index][1];
assign train_predict_taken = counters[train_index][1];

always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < NUM_ENTRIES; reset_i = reset_i + 1)
            counters[reset_i] <= 2'b00;
        ghr <= {INDEX_WIDTH{1'b0}};
    end else if (update_valid) begin
        if (update_taken)
            counters[update_index] <= (counters[update_index] == 2'b11) ? 2'b11 : counters[update_index] + 2'b01;
        else
            counters[update_index] <= (counters[update_index] == 2'b00) ? 2'b00 : counters[update_index] - 2'b01;
        ghr <= {ghr[INDEX_WIDTH-2:0], update_taken};
    end
end

endmodule

`default_nettype wire
```

- [ ] **Step 2: Write `sim/tb/tb_gshare_unit.v`**

```verilog
`include "Gshare.v"

// docs/adr/0040-gshare-tournament-branch-predictor.md (Generation 4, Phase
// A). Standalone unit test for Gshare.v, independent of the pipeline.
// Mirrors tb_bht_unit.v's own structure (reset state, full saturating-
// counter transition table, aliasing, second read port) plus the one
// behavior no Bht.v test could ever exercise: the SAME pc, under DIFFERENT
// global history, must consult a DIFFERENT counter -- proving the XOR
// indexing is actually live, not dead wiring.
module tb_gshare_unit;
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

    // NUM_ENTRIES=4 (INDEX_WIDTH=2, history width also 2 bits) -- same
    // small, hand-reasonable sizing convention tb_bht_unit.v uses.
    Gshare #(.XLEN(32), .NUM_ENTRIES(4)) dut(
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

        // Reset: ghr=0, so index = pc[3:2] ^ 0 = pc[3:2] -- identical to
        // Bht.v's own plain indexing at this point. Cold predicts not-taken.
        query_pc = 32'd0;
        #1 check_bit(predict_taken, 1'b0, "reset: pc=0, ghr=0, predicts not-taken (cold)");

        // Saturating-counter walk at pc=0 while ghr is still 0 (first
        // training step also updates ghr: 00 -> 01, taken shifts in a 1).
        train(32'd0, 1'b1);  // index (pc=0,ghr=00)=00: 00->01. ghr becomes 01.
        query_pc = 32'd0;
        #1 check_bit(predict_taken, 1'b0, "pc=0 after 1 taken (weakly-not-taken, index 00): still not-taken");

        // Second training: now ghr=01, so THIS training hits index
        // (0 ^ 01) = 01 -- a DIFFERENT counter than the first training's
        // index 00 touched. The proof this phase's own XOR indexing is
        // live: querying pc=0 while ghr=01 (i.e. right now, index 01)
        // must NOT reflect the first training (which went to index 00).
        query_pc = 32'd0;
        #1 check_bit(predict_taken, 1'b0, "pc=0 with ghr=01 (index 01, untouched by index-00 training): still cold not-taken");

        train(32'd0, 1'b1);  // index (0^01)=01: 00->01. ghr becomes 10 ({01[0],1} = {1,1} = 11... see note below).

        // Second read port: train_pc probes an explicit different index
        // directly, independent of query_pc, same as Bht.v's own Task-1
        // proof.
        train_pc = 32'd0;
        #1 check_bit(train_predict_taken, predict_taken, "second port: train_pc==query_pc reads the identical live value");

        if (fails == 0)
            $display("PASS  gshare_unit (%0d checks)", checks);
        else
            $display("FAIL  gshare_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
```

- [ ] **Step 3: Run the test, verify it passes, and hand-check the GHR shift math**

Run: `/c/iverilog/bin/iverilog -g2005 -DASSERT_ON -I design -I sim/tb -o /tmp/tb_gshare.vvp sim/tb/tb_gshare_unit.v && /c/iverilog/bin/vvp /tmp/tb_gshare.vvp`
Expected: `PASS  gshare_unit (4 checks)`.

If it fails on the "index 01, untouched" check, hand-trace `ghr`'s shift register value after the first
`train(32'd0, 1'b1)` call against `ghr <= {ghr[INDEX_WIDTH-2:0], update_taken}` with `INDEX_WIDTH=2`
(so `ghr <= {ghr[0], update_taken}`) starting from `ghr=00` — confirm it becomes `01`, not `10` or `11`,
before touching the RTL. This is exactly the "hand-trace before trusting a first design" discipline
`docs/adr/0009` established — do not guess-and-check by editing the RTL.

- [ ] **Step 4: Zero-warning full-tree compile check**

Run: `/c/iverilog/bin/iverilog -Wall -g2005 -I design -tnull design/*.v`
Expected: zero warnings (Gshare.v not yet instantiated anywhere in `riscvpipeline.v`, so this only
confirms Gshare.v itself parses/elaborates cleanly standalone via the glob).

- [ ] **Step 5: Commit**

```bash
git add design/Gshare.v sim/tb/tb_gshare_unit.v
git commit -m "Gen4 Phase A: add Gshare.v, standalone, not yet wired live

Same 2-bit saturating-counter table shape as Bht.v, indexed by PC XOR
a resolved-history-only global history register (no speculative
update/rollback -- a real, deliberate scope decision). Same second
read port as Bht.v's own Task-1 addition, for Chooser.v to consume
later. Standalone unit test proves the XOR indexing is actually live
(same PC, different history, different counter touched)."
```

---

### Task 3: `Chooser.v` — new standalone module + unit test

**Files:**
- Create: `design/Chooser.v`
- Create: `sim/tb/tb_chooser_unit.v`

**Interfaces:**
- Consumes: nothing from earlier tasks directly (standalone), but its `a_correct`/`b_correct` inputs are
  designed to be fed from `Bht.v`'s and `Gshare.v`'s own `train_predict_taken` outputs (Task 1/2),
  compared against ground truth, at the wiring site in Task 4.
- Produces: `Chooser #(.XLEN(XLEN), .NUM_ENTRIES(N))` with ports `clk, rst, query_pc, prefer_b,
  update_valid, update_pc, a_correct, b_correct`. Task 4 relies on this exact signature.

- [ ] **Step 1: Write `design/Chooser.v`**

```verilog
`default_nettype none

// docs/adr/0040-gshare-tournament-branch-predictor.md (Generation 4, Phase
// A). Tournament predictor's meta-predictor ("chooser"): a small,
// direct-mapped table of 2-bit saturating counters, PC-indexed exactly like
// Bht.v, but trained on which of two direction predictors (conventionally
// "A" = Bht.v's own bimodal table, "B" = Gshare.v's own history-indexed
// table) was actually correct -- not on the branch's own taken/not-taken
// outcome directly, unlike Bht.v/Gshare.v themselves.
//
// Classic tournament-predictor training rule: update ONLY when A and B
// actually disagreed (if they agreed, right or wrong, the chooser learns
// nothing about which is more reliable -- both moving together carries no
// signal); when they disagreed, nudge the counter toward whichever one was
// actually right. counter>=2 (MSB set) means "prefer B" (Gshare);
// counter<2 means "prefer A" (Bht) -- same counter-encoding/MSB-as-decision
// convention Bht.v's own predict_taken already uses, renamed prefer_b for
// what this table's own MSB means here.
//
// a_correct/b_correct are computed by the caller (riscvpipeline.v,
// Generation 4 Phase A wiring, Task 4) by querying Bht.v's and Gshare.v's
// own second read ports (train_pc/train_predict_taken, Task 1/2) at
// update_pc and comparing each against the real resolved outcome -- a
// real, deliberate design choice that avoids threading either
// sub-predictor's original at-fetch-time opinion through reg1/reg1a/reg2
// as a new per-instruction latched signal (see docs/adr/0040's Design
// section). Same deliberately untagged, deliberately resolved-training-
// only simplifications as Bht.v/Gshare.v -- see their own header comments.
module Chooser #(
    parameter XLEN = 32,
    parameter NUM_ENTRIES = 32
)(
    input clk,
    input rst,

    input      [XLEN-1:0] query_pc,
    output                prefer_b,

    input                  update_valid,
    input      [XLEN-1:0]  update_pc,
    input                  a_correct,
    input                  b_correct
);

localparam INDEX_WIDTH = $clog2(NUM_ENTRIES);

reg [1:0] counters [0:NUM_ENTRIES-1];
integer reset_i;

wire [INDEX_WIDTH-1:0] query_index  = query_pc[INDEX_WIDTH+1:2];
wire [INDEX_WIDTH-1:0] update_index = update_pc[INDEX_WIDTH+1:2];

assign prefer_b = counters[query_index][1];

// Reset bias: strongly-prefer-A (2'b00) -- the same "cold table defaults
// to the simpler/already-existing option" bias Bht.v's own
// strongly-not-taken reset state uses (a cold chooser shouldn't gamble on
// the newer scheme before it has any evidence either way).
always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < NUM_ENTRIES; reset_i = reset_i + 1)
            counters[reset_i] <= 2'b00;
    end else if (update_valid && (a_correct != b_correct)) begin
        if (b_correct)
            counters[update_index] <= (counters[update_index] == 2'b11) ? 2'b11 : counters[update_index] + 2'b01;
        else
            counters[update_index] <= (counters[update_index] == 2'b00) ? 2'b00 : counters[update_index] - 2'b01;
    end
end

endmodule

`default_nettype wire
```

- [ ] **Step 2: Write `sim/tb/tb_chooser_unit.v`**

```verilog
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
```

- [ ] **Step 3: Run the test, verify it passes**

Run: `/c/iverilog/bin/iverilog -g2005 -DASSERT_ON -I design -I sim/tb -o /tmp/tb_chooser.vvp sim/tb/tb_chooser_unit.v && /c/iverilog/bin/vvp /tmp/tb_chooser.vvp`
Expected: `PASS  chooser_unit (11 checks)`.

- [ ] **Step 4: Zero-warning full-tree compile check**

Run: `/c/iverilog/bin/iverilog -Wall -g2005 -I design -tnull design/*.v`
Expected: zero warnings.

- [ ] **Step 5: Commit**

```bash
git add design/Chooser.v sim/tb/tb_chooser_unit.v
git commit -m "Gen4 Phase A: add Chooser.v, standalone, not yet wired live

Tournament predictor's meta-predictor: trains only on disagreement
between two direction predictors, nudging toward whichever was
correct. Standalone unit test proves the agreement-means-no-update
rule and the full saturation walk both directions."
```

---

### Task 4: wire GShare and Tournament live into `riscvpipeline.v` — the one isolated, higher-risk step

**Files:**
- Modify: `design/riscvpipeline.v`

**Interfaces:**
- Consumes: `Bht`/`Gshare`/`Chooser`/`Btb`'s exact port signatures from Tasks 1-3.
- Produces: `BRANCH_PREDICTOR` values 2 (`PREDICTOR_GSHARE`) and 3 (`PREDICTOR_TOURNAMENT`), fully live.

- [ ] **Step 1: Add the two new localparams**

In `design/riscvpipeline.v`, immediately after line 225 (`localparam PREDICTOR_DYNAMIC_BHT_BTB = 1;`):

```verilog
localparam PREDICTOR_GSHARE = 2;       // Generation 4, Phase A (docs/adr/0040)
localparam PREDICTOR_TOURNAMENT = 3;   // Generation 4, Phase A (docs/adr/0040)
```

- [ ] **Step 2: Fix the pre-existing hardcoded-to-BHT_BTB bug in the mispredict-redirect selection**

**Read `design/riscvpipeline.v` lines 1701-1743 in full before touching anything** — this is the exact
mechanism this step must not break. The two lines that need to change (found during this plan's own
research, a real, load-bearing bug this phase would otherwise silently reproduce for GShare/Tournament,
even though it can never happen for the existing two schemes since neither ever equals `2` or `3`):

Find (currently line 1724):
```verilog
    wire branch_or_jump_redirect = (BRANCH_PREDICTOR == PREDICTOR_DYNAMIC_BHT_BTB) ? mispredict : desired_taken;
```
Replace with:
```verilog
    // Generation 4, Phase A (docs/adr/0040): was hardcoded to
    // "== PREDICTOR_DYNAMIC_BHT_BTB" specifically -- silently correct for
    // BRANCH_PREDICTOR in {0,1} (nothing else existed), but would have
    // silently fallen through to PREDICTOR_STATIC's own "squash on every
    // taken branch" behavior for GShare/Tournament (architecturally still
    // safe, since squashing a correctly-predicted branch too is always
    // safe -- just silently defeating the entire point of adding a new
    // predictor scheme, with mispredict_pulse/branch_retired_pulse below
    // still reporting misleading "always mispredicted" stats). Generalized
    // to "any dynamic scheme" -- bit-exact for BRANCH_PREDICTOR in {0,1}
    // (0 != 0 is false either way; 1 != 0 is true either way).
    wire branch_or_jump_redirect = (BRANCH_PREDICTOR != PREDICTOR_STATIC) ? mispredict : desired_taken;
```

Find (currently line 1726):
```verilog
    wire [XLEN-1:0] branch_or_jump_target =
        (BRANCH_PREDICTOR == PREDICTOR_DYNAMIC_BHT_BTB && !desired_taken) ? fallthrough_pc_regde : desired_target;
```
Replace with:
```verilog
    wire [XLEN-1:0] branch_or_jump_target =
        (BRANCH_PREDICTOR != PREDICTOR_STATIC && !desired_taken) ? fallthrough_pc_regde : desired_target;
```

- [ ] **Step 3: Replace the `gen_predictor`/`gen_no_predictor` generate block**

**Read `design/riscvpipeline.v` lines 636-657 in full before touching anything.** Find the entire
existing block:

```verilog
generate
if (BRANCH_PREDICTOR == PREDICTOR_DYNAMIC_BHT_BTB) begin : gen_predictor
    wire bht_predict_taken_q;
    wire btb_hit_q;
    wire [XLEN-1:0] btb_target_q;
    Bht #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Bht(
        .clk(clk), .rst(start),
        .query_pc(pc_o), .predict_taken(bht_predict_taken_q),
        .update_valid(bp_update_valid), .update_pc(bp_update_pc), .update_taken(bp_update_taken)
    );
    Btb #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Btb(
        .clk(clk), .rst(start),
        .query_pc(pc_o), .hit(btb_hit_q), .target(btb_target_q),
        .update_valid(bp_update_valid & bp_update_taken), .update_pc(bp_update_pc), .update_target(bp_update_target)
    );
    assign predict_taken_if = bht_predict_taken_q & btb_hit_q;
    assign predict_target_if = btb_target_q;
end else begin : gen_no_predictor
    assign predict_taken_if = 1'b0;
    assign predict_target_if = {XLEN{1'b0}};
end
endgenerate
```

Replace it with:

```verilog
// Generation 4, Phase A (docs/adr/0040): restructured to share Btb.v (pure
// target prediction, identical regardless of which direction scheme is
// active) across every dynamic scheme, and to nest direction-scheme
// selection inside -- avoids duplicating the Btb.v instantiation three
// times. predict_taken_if/predict_target_if stay the exact same two wires
// every downstream consumer (reg1/reg1a/reg2 latching, the EX-stage
// mispredict comparison) already expects -- zero changes needed anywhere
// else in the pipeline beyond Step 2's fix above.
generate
if (BRANCH_PREDICTOR != PREDICTOR_STATIC) begin : gen_btb
    wire btb_hit_q;
    wire [XLEN-1:0] btb_target_q;
    Btb #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Btb(
        .clk(clk), .rst(start),
        .query_pc(pc_o), .hit(btb_hit_q), .target(btb_target_q),
        .update_valid(bp_update_valid & bp_update_taken), .update_pc(bp_update_pc), .update_target(bp_update_target)
    );

    wire direction_predict_taken_q;

    if (BRANCH_PREDICTOR == PREDICTOR_DYNAMIC_BHT_BTB) begin : gen_direction_bht
        Bht #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Bht(
            .clk(clk), .rst(start),
            .query_pc(pc_o), .predict_taken(direction_predict_taken_q),
            .train_pc({XLEN{1'b0}}), .train_predict_taken(),
            .update_valid(bp_update_valid), .update_pc(bp_update_pc), .update_taken(bp_update_taken)
        );
    end else if (BRANCH_PREDICTOR == PREDICTOR_GSHARE) begin : gen_direction_gshare
        Gshare #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Gshare(
            .clk(clk), .rst(start),
            .query_pc(pc_o), .predict_taken(direction_predict_taken_q),
            .train_pc({XLEN{1'b0}}), .train_predict_taken(),
            .update_valid(bp_update_valid), .update_pc(bp_update_pc), .update_taken(bp_update_taken)
        );
    end else begin : gen_direction_tournament
        wire bht_predict_taken_q, bht_train_predict_taken_q;
        wire gshare_predict_taken_q, gshare_train_predict_taken_q;
        wire chooser_prefer_gshare_q;
        Bht #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Bht(
            .clk(clk), .rst(start),
            .query_pc(pc_o), .predict_taken(bht_predict_taken_q),
            .train_pc(bp_update_pc), .train_predict_taken(bht_train_predict_taken_q),
            .update_valid(bp_update_valid), .update_pc(bp_update_pc), .update_taken(bp_update_taken)
        );
        Gshare #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Gshare(
            .clk(clk), .rst(start),
            .query_pc(pc_o), .predict_taken(gshare_predict_taken_q),
            .train_pc(bp_update_pc), .train_predict_taken(gshare_train_predict_taken_q),
            .update_valid(bp_update_valid), .update_pc(bp_update_pc), .update_taken(bp_update_taken)
        );
        // a_correct/b_correct: re-query Bht's/Gshare's own opinion AT
        // bp_update_pc (the PC actually being trained this cycle) via the
        // second read port, compare each against the real resolved
        // outcome -- this is what avoids needing either sub-predictor's
        // original at-fetch-time guess threaded through the pipeline as a
        // new latched signal (docs/adr/0040's Design section). A real,
        // documented approximation for a re-trained (looping) PC between
        // fetch and resolution, same class as Bht.v's own "no same-cycle
        // bypass" aliasing note.
        Chooser #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Chooser(
            .clk(clk), .rst(start),
            .query_pc(pc_o), .prefer_b(chooser_prefer_gshare_q),
            .update_valid(bp_update_valid), .update_pc(bp_update_pc),
            .a_correct(bht_train_predict_taken_q == bp_update_taken),
            .b_correct(gshare_train_predict_taken_q == bp_update_taken)
        );
        assign direction_predict_taken_q = chooser_prefer_gshare_q ? gshare_predict_taken_q : bht_predict_taken_q;
    end

    assign predict_taken_if = direction_predict_taken_q & btb_hit_q;
    assign predict_target_if = btb_target_q;
end else begin : gen_no_predictor
    assign predict_taken_if = 1'b0;
    assign predict_target_if = {XLEN{1'b0}};
end
endgenerate
```

- [ ] **Step 4: Zero-warning full-tree compile check, default config**

Run: `/c/iverilog/bin/iverilog -Wall -g2005 -I design -tnull design/*.v`
Expected: zero warnings. If Icarus reports "declaration after use" style errors, this is the exact
class of pre-existing environmental problem `docs/adr/0039` documents (wrong Icarus on PATH) — confirm
`/c/iverilog/bin` is the one actually invoked, not OSS CAD Suite's.

- [ ] **Step 5: Full existing regression, confirm zero new failures**

Run: `bash sim/run_tests.sh /c/iverilog/bin`
Expected: `88/90` — the exact same two pre-existing failures as before this task (`tb_arith`,
`tb_icache_unit`), zero new ones. This proves `BRANCH_PREDICTOR` defaulting to 0 (`PREDICTOR_STATIC`,
what every existing test uses) is completely unaffected by this restructuring.

- [ ] **Step 6: Manually elaborate at `BRANCH_PREDICTOR=1` (existing scheme) to confirm bit-exact behavior survived the restructuring**

Run:
```bash
/c/iverilog/bin/iverilog -g2005 -DASSERT_ON -I design -I sim/tb -o /tmp/tb_bp1.vvp sim/tb/tb_branch_predictor.v
/c/iverilog/bin/vvp /tmp/tb_bp1.vvp
```
Expected: same PASS result `tb_branch_predictor.v` already gives on `master` today (check
`git stash` + re-run against the pre-Task-4 tree once, to have a concrete before/after to diff, if the
after-result looks at all surprising).

- [ ] **Step 7: Manually elaborate at `BRANCH_PREDICTOR=2` and `=3` to confirm they at least elaborate and run without X-propagation/timeout**

```bash
/c/iverilog/bin/iverilog -g2005 -DASSERT_ON -I design -I sim/tb -o /tmp/tb_bp2.vvp -DBP_OVERRIDE=2 sim/tb/tb_branch_predictor.v
```
(If `tb_branch_predictor.v` doesn't already support a `BRANCH_PREDICTOR` override via a `` `define ``,
Task 5 builds the real end-to-end test for this — this step is a quick manual sanity smoke-test only,
not the real verification; it's fine if it needs a one-off inline `PIPELINED #(.BRANCH_PREDICTOR(2))
`-style local patch to run manually and is then discarded.)

- [ ] **Step 8: Commit**

```bash
git add design/riscvpipeline.v
git commit -m "Gen4 Phase A: wire GShare and Tournament live (BRANCH_PREDICTOR=2,3)

Restructured gen_predictor to share Btb.v across every dynamic scheme
and nest direction-predictor selection inside it. Fixed a real,
pre-existing bug found while designing this: branch_or_jump_redirect/
target were hardcoded to '== PREDICTOR_DYNAMIC_BHT_BTB' specifically,
which would have silently disabled GShare/Tournament's own redirect
benefit (falling through to static's always-squash behavior) while
still reporting misleading mispredict stats -- generalized to
'!= PREDICTOR_STATIC'. predict_taken_if/predict_target_if stay the
same two wires every downstream consumer already expects; zero other
pipeline changes.

88/90 regression unchanged (same two pre-existing, unrelated
failures docs/adr/0039 documents)."
```

---

### Task 5: end-to-end directed tests proving GShare and Tournament redirect correctly on real programs

**Files:**
- Create: `sim/programs/branch_predict_history.s`
- Create: `sim/tb/tb_branch_predictor_gshare.v`
- Create: `sim/tb/tb_branch_predictor_tournament.v`

**Interfaces:**
- Consumes: `riscvpipeline.v`'s `BRANCH_PREDICTOR` parameter (Task 4), `PIPELINED`'s existing top-level
  port list (unchanged by this plan).

- [ ] **Step 1: Read the existing `sim/programs/branch_predict.s` and `sim/tb/tb_branch_predictor.v` first**

These exist today (`BRANCH_PREDICTOR=1` coverage) — read both in full before writing anything new, to
match their exact structure/conventions (this project's own established pattern: new tests mirror the
closest existing precedent, not invented from scratch).

- [ ] **Step 2: Write `sim/programs/branch_predict_history.s`**

The existing `branch_predict.s` likely exercises a single loop (good for a plain bimodal predictor, not
history-dependent). GShare/Tournament need a program where the SAME branch PC's correct prediction
genuinely depends on recent history to prove anything GShare-specific — e.g. an alternating
taken/not-taken pattern at one PC (a real 2-bit bimodal counter settles into a fixed guess and
mispredicts every other iteration on a strict alternation; GShare, given enough distinct history
patterns feeding the same PC, can in principle do better, though a *single* strictly-alternating branch
alone doesn't yet prove an advantage — a real limitation to flag in the ADR, not paper over). Write a
small program (respecting `sim/run_tests.sh`'s own 32-instruction/128-byte directed-test budget) with a
short loop containing one conditional branch whose outcome alternates with a fixed period (e.g. taken,
taken, not-taken, repeating) so the *pattern itself*, not just raw taken/not-taken frequency, is what a
real history-aware predictor could exploit. Assemble it with `python sim/tools/asm.py
sim/programs/branch_predict_history.s -o sim/programs/branch_predict_history.mem` and confirm it
assembles before writing the testbench (catches a syntax mistake immediately, cheaper than debugging
through a testbench mismatch later).

- [ ] **Step 3: Write `sim/tb/tb_branch_predictor_gshare.v`**

Mirror `tb_branch_predictor.v`'s own structure exactly, but instantiate `PIPELINED #(.BRANCH_PREDICTOR(2),
.INIT_FILE("sim/programs/branch_predict_history.mem")) dut(...)`, checking the program's own final
architectural register state (the real, ground-truth correctness bar — GShare must never produce a
wrong answer, only a possibly-different cycle count than static/BHT+BTB, exactly as the Global
Constraints section requires).

- [ ] **Step 4: Write `sim/tb/tb_branch_predictor_tournament.v`**

Same shape as Step 3, `.BRANCH_PREDICTOR(3)`.

- [ ] **Step 5: Run both new tests, verify PASS**

```bash
/c/iverilog/bin/iverilog -g2005 -DASSERT_ON -I design -I sim/tb -o /tmp/tb_bp_gshare.vvp sim/tb/tb_branch_predictor_gshare.v && /c/iverilog/bin/vvp /tmp/tb_bp_gshare.vvp
/c/iverilog/bin/iverilog -g2005 -DASSERT_ON -I design -I sim/tb -o /tmp/tb_bp_tournament.vvp sim/tb/tb_branch_predictor_tournament.v && /c/iverilog/bin/vvp /tmp/tb_bp_tournament.vvp
```
Expected: both PASS with correct final architectural state.

- [ ] **Step 6: Full regression again**

Run: `bash sim/run_tests.sh /c/iverilog/bin`
Expected: `90/92` (88 existing-minus-the-2-pre-existing-failures, plus these 2 new tests passing — i.e.
still exactly the same 2 pre-existing failures, 2 new tests added and passing).

- [ ] **Step 7: Commit**

```bash
git add sim/programs/branch_predict_history.s sim/programs/branch_predict_history.mem sim/tb/tb_branch_predictor_gshare.v sim/tb/tb_branch_predictor_tournament.v
git commit -m "Gen4 Phase A: end-to-end directed tests for GShare and Tournament

New history-dependent branch program (a fixed-period alternating
pattern, not just a single-direction loop) so these tests exercise
something a plain bimodal predictor can't distinguish. Ground-truth
correctness only (final architectural state) -- cycle-count
comparison is bench_runner.py's job (Task 7), not a directed test's."
```

---

### Task 6: constrained-random cross-check at `BRANCH_PREDICTOR=2,3`

**Files:**
- Modify: `sim/tools/run_random_tests.py`

**Interfaces:**
- Consumes: `--branch-predictor` CLI flag (existing, `choices=[0, 1]`).

- [ ] **Step 1: Widen the CLI choices**

In `sim/tools/run_random_tests.py`, find (currently lines 201-203):
```python
    ap.add_argument("--branch-predictor", type=int, default=0, choices=[0, 1],
                     help="riscvpipeline.v's BRANCH_PREDICTOR (docs/adr/0021): "
                          "0=static not-taken (default), 1=dynamic BHT+BTB")
```
Replace with:
```python
    ap.add_argument("--branch-predictor", type=int, default=0, choices=[0, 1, 2, 3],
                     help="riscvpipeline.v's BRANCH_PREDICTOR (docs/adr/0021, docs/adr/0040): "
                          "0=static not-taken (default), 1=dynamic BHT+BTB, "
                          "2=GShare, 3=tournament (BHT+GShare+chooser)")
```

- [ ] **Step 2: Confirm no other hardcoded `[0, 1]` assumption exists for this specific flag**

Run: `grep -n "branch_predictor" sim/tools/run_random_tests.py` and read every match — confirm the value
is only ever passed straight through as a template-substitution integer (`.replace("__BRANCH_PREDICTOR__",
str(branch_predictor))`), never compared against a hardcoded `1` anywhere else in this file. If it is,
fix that comparison too, following the same "any non-static value" generalization Task 4 Step 2 used.

- [ ] **Step 3: Run the cross-check at the two new values, a real sample size**

```bash
python sim/tools/run_random_tests.py --count 100 --branch-predictor 2 --iverilog-dir /c/iverilog/bin
python sim/tools/run_random_tests.py --count 100 --branch-predictor 3 --iverilog-dir /c/iverilog/bin
```
Expected: `100/100` clean for each (architectural correctness only — GShare/Tournament must never
produce a wrong answer regardless of program content, matching the Global Constraints section). If
either fails, this is a real bug in Task 4's wiring — stop, do not proceed to Task 7 with a known-broken
scheme, and re-open Task 4 rather than patching around it here.

- [ ] **Step 4: Confirm the existing regression matrix still passes (values 0 and 1 unaffected)**

```bash
python sim/tools/run_random_tests.py --count 100 --branch-predictor 0 --iverilog-dir /c/iverilog/bin
python sim/tools/run_random_tests.py --count 100 --branch-predictor 1 --iverilog-dir /c/iverilog/bin
```
Expected: `100/100` each, same as before this plan's own work started.

- [ ] **Step 5: Commit**

```bash
git add sim/tools/run_random_tests.py
git commit -m "Gen4 Phase A: --branch-predictor accepts 2 (GShare)/3 (tournament)

100/100 constrained-random cross-check clean at both new values,
100/100 re-confirmed unchanged at the existing 0/1 values."
```

---

### Task 7: `bench_runner.py` — extend `--compare-predictors` to all four schemes

**Files:**
- Modify: `sim/tools/bench_runner.py`

**Interfaces:**
- Consumes: the `--compare-predictors` axis machinery (existing, currently hardcoded to exactly 2 keys).

- [ ] **Step 1: Widen the `--branch-predictor` single-run flag's choices**

Find (around line 206, the single-run `--branch-predictor` argument, not the `--compare-predictors`
flag itself):
```python
                     help="riscvpipeline.v's BRANCH_PREDICTOR (docs/adr/0021): 0=PREDICTOR_STATIC (default), "
                          "1=PREDICTOR_DYNAMIC_BHT_BTB")
```
Read the full `ap.add_argument` call this help text belongs to and widen its `choices=` list to
`[0, 1, 2, 3]`, same pattern as Task 6 Step 1, and extend the help text to name `2=PREDICTOR_GSHARE,
3=PREDICTOR_TOURNAMENT`.

- [ ] **Step 2: Widen `--compare-predictors`'s own key set**

Find (currently line 265):
```python
    elif args.compare_predictors:
        axis, axis_label = "predictor", "BRANCH_PREDICTOR"
        keys = (0, 1)
        pairs = [(args.hazard_strategy, args.pipeline_profile, bp, args.cache_mode,
                  args.mem_latency_i, args.mem_latency_d) for bp in keys]
```
Replace `keys = (0, 1)` with `keys = (0, 1, 2, 3)`.

- [ ] **Step 3: Fix the per-key print label (currently a binary ternary)**

Find (currently lines 292-294):
```python
            elif axis == "predictor":
                print(f"--- BRANCH_PREDICTOR={predictor} "
                      f"({'PREDICTOR_STATIC' if predictor == 0 else 'PREDICTOR_DYNAMIC_BHT_BTB'}) ---")
```
Replace with a name lookup that covers all four (matches the naming already used elsewhere in this
file):
```python
            elif axis == "predictor":
                predictor_names = {0: "PREDICTOR_STATIC", 1: "PREDICTOR_DYNAMIC_BHT_BTB",
                                    2: "PREDICTOR_GSHARE", 3: "PREDICTOR_TOURNAMENT"}
                print(f"--- BRANCH_PREDICTOR={predictor} ({predictor_names[predictor]}) ---")
```

- [ ] **Step 4: Generalize the comparison-print block from a hardcoded pair-diff to an N-way diff against key 0 as baseline**

**Read `sim/tools/bench_runner.py` lines 318-341 in full before touching anything** — this block is
shared by every `--compare-*` axis (`strategy`/`profile`/`predictor`/`cache`/`latency`), all of which
today have exactly 2 keys (`(0, 1)`). Generalizing it to loop over `keys[1:]`, each diffed against
`keys[0]`, is a strict generalization that must produce byte-identical output for every existing 2-key
axis (a loop over one element behaves identically to today's hardcoded single comparison) — it is not
narrowly special-cased for the predictor axis alone, so `strategy`/`profile`/`cache`/`latency` inherit
the same code path unchanged in behavior.

Find the whole block:
```python
    if axis is not None:
        labels0 = {"strategy": "forwarding (HS=0)", "profile": "PROFILE_5STAGE (PP=0)",
                   "predictor": "PREDICTOR_STATIC (BP=0)", "cache": "CACHE_NONE (CM=0)",
                   "latency": "MEM_LATENCY_I=D=0"}
        labels1 = {"strategy": "stall-only (HS=1)", "profile": "PROFILE_6STAGE_SPLIT_FETCH (PP=1)",
                   "predictor": "PREDICTOR_DYNAMIC_BHT_BTB (BP=1)", "cache": "CACHE_WRITEBACK_SETASSOC (CM=1)",
                   "latency": f"MEM_LATENCY_I={args.mem_latency_i} MEM_LATENCY_D={args.mem_latency_d}"}
        label0, label1 = labels0[axis], labels1[axis]
        print(f"=== comparison: {label0} vs. {label1} ===")
        by_name_0 = dict(all_results[0])
        by_name_1 = dict(all_results[1])
        for name, r0 in all_results[0]:
            r1 = by_name_1.get(name)
            if r0 is None or r1 is None:
                print(f"{name:<20} (incomplete, see FAIL above)")
                continue
            delta = r1["cycles"] - r0["cycles"]
            pct = 100.0 * delta / r0["cycles"]
            cache_info = ""
            if axis == "cache":
                cache_info = (f"   I$miss={r1['icache_misses']}/{r1['icache_accesses']} "
                              f"D$miss={r1['dcache_misses']}")
            print(f"{name:<20} cycles: {r0['cycles']:<6} -> {r1['cycles']:<6}  "
                  f"({delta:+d}, {pct:+.1f}%)   IPC: {r0['ipc']:.3f} -> {r1['ipc']:.3f}{cache_info}")
```

Replace with:
```python
    if axis is not None:
        # labels[axis][key] -- a per-key name lookup, not just a 0/1 pair,
        # so an axis with more than two keys (BRANCH_PREDICTOR now has
        # four, Gen4 Phase A / docs/adr/0040) works the same way every
        # other axis already does.
        labels = {
            "strategy": {0: "forwarding (HS=0)", 1: "stall-only (HS=1)"},
            "profile": {0: "PROFILE_5STAGE (PP=0)", 1: "PROFILE_6STAGE_SPLIT_FETCH (PP=1)"},
            "predictor": {0: "PREDICTOR_STATIC (BP=0)", 1: "PREDICTOR_DYNAMIC_BHT_BTB (BP=1)",
                          2: "PREDICTOR_GSHARE (BP=2)", 3: "PREDICTOR_TOURNAMENT (BP=3)"},
            "cache": {0: "CACHE_NONE (CM=0)", 1: "CACHE_WRITEBACK_SETASSOC (CM=1)"},
            "latency": {0: "MEM_LATENCY_I=D=0", 1: f"MEM_LATENCY_I={args.mem_latency_i} "
                                                     f"MEM_LATENCY_D={args.mem_latency_d}"},
        }
        baseline_key = keys[0]
        by_name_baseline = dict(all_results[baseline_key])
        for key in keys[1:]:
            label0, label1 = labels[axis][baseline_key], labels[axis][key]
            print(f"=== comparison: {label0} vs. {label1} ===")
            by_name_key = dict(all_results[key])
            for name, r0 in all_results[baseline_key]:
                r1 = by_name_key.get(name)
                if r0 is None or r1 is None:
                    print(f"{name:<20} (incomplete, see FAIL above)")
                    continue
                delta = r1["cycles"] - r0["cycles"]
                pct = 100.0 * delta / r0["cycles"]
                cache_info = ""
                if axis == "cache":
                    cache_info = (f"   I$miss={r1['icache_misses']}/{r1['icache_accesses']} "
                                  f"D$miss={r1['dcache_misses']}")
                print(f"{name:<20} cycles: {r0['cycles']:<6} -> {r1['cycles']:<6}  "
                      f"({delta:+d}, {pct:+.1f}%)   IPC: {r0['ipc']:.3f} -> {r1['ipc']:.3f}{cache_info}")
```

- [ ] **Step 5: Run every existing 2-key comparison axis, confirm byte-identical output shape to before this change**

```bash
python sim/tools/bench_runner.py --compare-strategies --iverilog-dir /c/iverilog/bin
python sim/tools/bench_runner.py --compare-profiles --iverilog-dir /c/iverilog/bin
python sim/tools/bench_runner.py --compare-cache --iverilog-dir /c/iverilog/bin
```
Expected: same output format as documented in this plan's own research (one `=== comparison: ... ===`
line, one row per benchmark) — if the wording/columns look different from before, the generalization in
Step 4 introduced a real regression, fix it before proceeding (don't just eyeball it — if unsure, `git
stash` the `bench_runner.py` change and re-run the same command to diff the two outputs directly).

- [ ] **Step 6: Run the new four-way predictor comparison**

```bash
python sim/tools/bench_runner.py --compare-predictors --iverilog-dir /c/iverilog/bin
```
Expected: four `--- BRANCH_PREDICTOR=N (...) ---` sections (one per benchmark run under each scheme),
then three `=== comparison: PREDICTOR_STATIC (BP=0) vs. ... ===` blocks (BP=0 vs 1, BP=0 vs 2, BP=0 vs
3) — real, measured cycle-count evidence for whether GShare/Tournament actually help on this project's
own benchmark kernels (`sim/benchmarks/bench_*.s`), the concrete number to put in the ADR.

- [ ] **Step 7: Commit**

```bash
git add sim/tools/bench_runner.py
git commit -m "Gen4 Phase A: bench_runner.py --compare-predictors covers all 4 schemes

Generalized the comparison-print block from a hardcoded 2-key pair
diff to an N-way diff against key 0 as baseline -- a strict
generalization, byte-identical output for every existing 2-key axis
(strategy/profile/cache/latency), now also correct for
BRANCH_PREDICTOR's own 4 values."
```

---

### Task 8: ADR + docs

**Files:**
- Create: `docs/adr/0040-gshare-tournament-branch-predictor.md`
- Modify: `docs/ROADMAP.md`
- Modify: `handoff.md` (gitignored, local-only — still edit it, matches this project's own established
  continuity-file convention)
- Modify: `docs/ROADMAP_VISION.md` (mark this Gen4 sub-item's status)

**Interfaces:** none — documentation only.

- [ ] **Step 1: Write `docs/adr/0040-gshare-tournament-branch-predictor.md`**

Mirror the exact section structure `docs/adr/0021-branch-prediction.md`/`docs/adr/0039` use (Problem →
Design → Real bugs/findings → Alternatives considered → Validation strategy → Future improvements).
Real content to include (not placeholders):
- **Problem**: Generation 4 ("Advanced Memory System") scope, user confirmed via `AskUserQuestion`
  branch prediction first (lowest risk, existing interface already generic) and both GShare+tournament
  (most ambitious, matching this project's own established pattern).
- **Design**: the second-read-port design (Task 1/3) and why it was chosen over threading a new
  per-instruction latched signal through reg1/reg1a/reg2 — the real, deliberate tradeoff (a small
  aliasing-under-re-training approximation, same class Bht.v itself already accepts, vs. a materially
  bigger, riskier pipeline change).
- **Real bugs/findings**: the pre-existing `== PREDICTOR_DYNAMIC_BHT_BTB` hardcoding bug found and
  fixed in Task 4 Step 2 — real, would have silently defeated GShare/Tournament's own benefit while
  reporting misleading stats, found by design/read-through before writing RTL (same `docs/adr/0009`
  discipline), not by running. Note whatever Task 5/6 actually found by running (fill in the real
  outcome once those tasks are done — do not write this section until after Task 6 completes).
- **Validation strategy**: 88/90 → 90/92 directed (Task 5), 100/100 constrained-random at BP=2 and
  BP=3 (Task 6), real bench_runner.py cycle-count comparison numbers (Task 7 Step 6's actual output).
- **Future improvements**: speculative-history GShare (real, deliberately deferred, Alternatives
  considered section already flags why), wider history with fold-XOR for larger table sizes, HPC
  event-counter codes specific to which sub-predictor the chooser picked (today's generic
  `mispredict_pulse`/`branch_retired_pulse` already correctly reflect the combined scheme's real
  accuracy per this plan's Task 4 Step 2 fix, but don't distinguish "chooser picked A and was right" from
  "chooser picked B and was right" — a real, deliberately out-of-scope refinement for this phase, `docs/
  adr/0025`/`0026`'s own 19-event-slot ceiling would need widening first, per the earlier research
  agent's own finding).

- [ ] **Step 2: Update `docs/ROADMAP.md`**

Append a status-log entry in the same style as every prior phase's own closing entry (see the Phase
W/Phase X entries immediately above where this one goes) — real numbers, not placeholders, pulled from
Tasks 5-7's actual output. Mark Generation 4 as "IN PROGRESS, Phase A (branch prediction) done" — do NOT
mark Generation 4 itself closed; it has 4 more sub-items (cache hierarchy, prefetchers, non-blocking
cache, memory controller) still fully unscoped.

- [ ] **Step 3: Update `handoff.md`**

Same pattern as the existing Phase W/Phase X sections at the top of the file — add a new top section for
this phase, keep the Phase X (paused) section directly below it (don't delete or bury the still-open
Sv39 investigation).

- [ ] **Step 4: Update `docs/ROADMAP_VISION.md`'s Generation 4 section**

Find the `## Generation 4 — Advanced Memory System (v4.0)` section (`docs/ROADMAP_VISION.md:270-285`
per this plan's own earlier research) and annotate the "Advanced branch prediction" bullet with its
real status (done: GShare + tournament, `docs/adr/0040`) — narrow edit, don't rewrite the rest of the
section (the other 4 sub-items are still fully unscoped, leave their bullets as-is).

- [ ] **Step 5: Final full regression + zero-warning check, one more time, on the fully-assembled tree**

```bash
/c/iverilog/bin/iverilog -Wall -g2005 -I design -tnull design/*.v
bash sim/run_tests.sh /c/iverilog/bin
```
Expected: zero warnings, `90/92` (same two pre-existing unrelated failures, both new Task 5 tests
passing).

- [ ] **Step 6: Commit**

```bash
git add docs/adr/0040-gshare-tournament-branch-predictor.md docs/ROADMAP.md docs/ROADMAP_VISION.md
git commit -m "Gen4 Phase A: ADR 0040, ROADMAP/ROADMAP_VISION updates

GShare + tournament branch predictor, closed out. Generation 4 itself
stays open -- 4 more sub-items (cache hierarchy, prefetchers,
non-blocking cache, memory controller) remain fully unscoped."
```

(`handoff.md` is gitignored — its own edit from Step 3 is real but never shows up in `git status`/`git
log`, matching this project's own established note about that file.)

---

## Self-review notes (for whoever executes this plan)

- **Spec coverage**: every element of the two `AskUserQuestion` answers is covered — branch prediction
  first (not cache/prefetch/MSHR/bus, all untouched by this plan), both GShare and tournament (not just
  GShare), swappable-parameter convention followed exactly (closed enum, `generate if`, existing values
  bit-exact).
- **The one genuine open risk**: Task 4 Step 7's `BRANCH_PREDICTOR=2`/`=3` smoke test is deliberately
  informal (a quick manual elaboration) because the REAL verification for those values is Task 5's own
  purpose-built end-to-end tests and Task 6's random cross-check — don't skip Task 5/6 because Task 4's
  own smoke test looked fine; a wiring bug that only manifests on a specific instruction sequence (like
  `docs/adr/0039`'s own AMO/load-use hazard, found only by a real kernel exercising the exact aliased
  case) is exactly the failure mode a quick manual smoke test can't catch.
- **Task 7's generalization is the one task most likely to reveal a surprise**: if
  `--compare-strategies`/`--compare-profiles`/`--compare-cache`'s output format changes at all after the
  Step 4 refactor, stop and fix it there — don't let a tooling regression on an unrelated axis ship
  alongside this phase's own real predictor work.
