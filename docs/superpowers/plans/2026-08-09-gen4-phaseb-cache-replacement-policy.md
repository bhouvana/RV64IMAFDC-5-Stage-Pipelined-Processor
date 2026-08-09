# Gen4 Phase B: Cache Replacement Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a `REPLACEMENT_POLICY` swappable parameter (`POLICY_ROUND_ROBIN`=0 default/`POLICY_FIFO`=1/`POLICY_LRU`=2) to `ICache.v`/`DCache.v`, wire it live in `riscvpipeline.v`, and verify true LRU genuinely diverges from today's round-robin eviction.

**Architecture:** Both caches gain a per-set/per-way `age[]` rank array (0=MRU…WAYS-1=LRU), updated via a shared `lru_touch` task on every real hit and every fill completion; a new combinational reduction picks the way with `age==WAYS-1` as the LRU victim. `POLICY_ROUND_ROBIN`/`POLICY_FIFO` both select today's existing `victim[]` pointer unchanged (genuinely the same mechanism, not two implementations).

**Tech Stack:** Verilog (Icarus `iverilog`/`vvp`, `/c/iverilog/bin` on PATH), Python 3 (`sim/tools/*.py`).

## Global Constraints

- `POLICY_ROUND_ROBIN`=0 must stay bit-exact default — every existing test/ADR/benchmark assumes it.
- `sim/tools/iss.py` needs **zero changes** (no cache model exists there — confirmed by design, same category as branch prediction/cache/latency).
- Full directed suite (`bash sim/run_tests.sh`) and zero-warning `iverilog -Wall -g2005 -I design -tnull design/*.v` must stay clean after every task.
- Design spec: `docs/superpowers/specs/2026-08-09-gen4-phaseb-cache-replacement-policy-design.md`.
- Toolchain note: use `/c/iverilog/bin`, not whatever OSS CAD Suite bundles (`docs/adr/0039`'s own finding — the other install fails elaboration on pre-existing `generate` wire-ordering).

---

### Task 1: Declare `REPLACEMENT_POLICY` parameter + enum in `riscvpipeline.v` (no consumers yet)

**Files:**
- Modify: `design/riscvpipeline.v:122-130` (parameter list, right after `MEM_LATENCY_D`)
- Modify: `design/riscvpipeline.v:229-233` (enum block, right after `CACHE_WRITEBACK_SETASSOC`)

**Interfaces:**
- Produces: `PIPELINED`'s new `REPLACEMENT_POLICY` parameter (default 0) and `POLICY_ROUND_ROBIN`/`POLICY_FIFO`/`POLICY_LRU` localparams, for Task 4 to consume when instantiating `ICache`/`DCache`.

- [ ] **Step 1: Add the parameter**

In `design/riscvpipeline.v`, find:
```verilog
    parameter MEM_LATENCY_I = 0,
    parameter MEM_LATENCY_D = 0
)(
```
Replace with:
```verilog
    parameter MEM_LATENCY_I = 0,
    parameter MEM_LATENCY_D = 0,
    // docs/adr/0041-cache-replacement-policy-phase-b.md (Generation 4, Phase
    // B). A closed, named enum (same honesty convention as HAZARD_STRATEGY/
    // PIPELINE_PROFILE/BRANCH_PREDICTOR/CACHE_MODE above). POLICY_ROUND_ROBIN
    // (0, default): today's exact per-set fill-order pointer, bit-exact,
    // what every existing test/ADR/benchmark in this repo assumes.
    // POLICY_FIFO (1): the SAME underlying mechanism as POLICY_ROUND_ROBIN --
    // round-robin already IS fill-order/FIFO eviction at this associativity;
    // a separately-implemented FIFO would be redundant RTL with zero
    // behavioral difference, so both select the identical non-LRU branch in
    // ICache.v/DCache.v. POLICY_LRU (2): true per-way access-recency
    // tracking, updated on every real hit AND every fill completion, not
    // just fills. Only meaningful under CACHE_WRITEBACK_SETASSOC. Not yet
    // consumed anywhere as of this commit.
    parameter REPLACEMENT_POLICY = 0
)(
```

- [ ] **Step 2: Add the enum localparams**

Find:
```verilog
localparam CACHE_NONE = 0;
localparam CACHE_WRITEBACK_SETASSOC = 1;
```
Replace with:
```verilog
localparam CACHE_NONE = 0;
localparam CACHE_WRITEBACK_SETASSOC = 1;

// REPLACEMENT_POLICY values (docs/adr/0041-cache-replacement-policy-phase-b.md)
// -- named constants purely for readability at the instantiation sites that
// consume this parameter; not yet consumed anywhere as of this commit.
localparam POLICY_ROUND_ROBIN = 0;
localparam POLICY_FIFO        = 1;
localparam POLICY_LRU         = 2;
```

- [ ] **Step 3: Compile check (declaration-only, no behavior change yet)**

Run: `/c/iverilog/bin/iverilog -Wall -g2005 -I design -tnull design/*.v`
Expected: zero warnings, zero errors (parameter/localparam additions with no consumers are always safe to declare).

- [ ] **Step 4: Full regression (must be untouched — nothing consumes the new parameter yet)**

Run: `bash sim/run_tests.sh`
Expected: same pass count as `HEAD` (92/94 per `handoff.md`'s current state, 2 pre-existing unrelated failures).

- [ ] **Step 5: Commit**

```bash
git add design/riscvpipeline.v
git commit -m "Gen4 Phase B: declare REPLACEMENT_POLICY parameter/enum, no consumers yet

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 2: `ICache.v` — add `REPLACEMENT_POLICY`/LRU mechanism, standalone (not yet wired from `riscvpipeline.v`)

**Files:**
- Modify: `design/ICache.v`
- Modify: `sim/tb/tb_icache_unit.v` (new `dut3` LRU sub-test)

**Interfaces:**
- Consumes: nothing new from other tasks.
- Produces: `ICache`'s new `REPLACEMENT_POLICY` parameter (default 0, values 0/1/2 as Task 1's enum), for Task 4 to pass through from `riscvpipeline.v`.

- [ ] **Step 1: Add the parameter**

Find (in `design/ICache.v`):
```verilog
    parameter WAYS = 4,             // must be >= 2 (round-robin victim counter needs $clog2(WAYS) >= 1)
    parameter CACHE_SIZE_BYTES = 4096,
    parameter LINE_BYTES = 16,      // must be a multiple of 4 (word-sized fetch)
    // docs/adr/0024-variable-latency-memory.md (Phase I4). Extra wait-state
```
Replace with:
```verilog
    parameter WAYS = 4,             // must be >= 2 (round-robin victim counter needs $clog2(WAYS) >= 1)
    parameter CACHE_SIZE_BYTES = 4096,
    parameter LINE_BYTES = 16,      // must be a multiple of 4 (word-sized fetch)
    // docs/adr/0041-cache-replacement-policy-phase-b.md (Generation 4, Phase
    // B). POLICY_ROUND_ROBIN (0, default): today's exact behavior, bit-exact.
    // POLICY_FIFO (1): identical mechanism to POLICY_ROUND_ROBIN (both select
    // the non-LRU branch below -- round-robin already IS FIFO-by-fill-order
    // at this associativity). POLICY_LRU (2): true per-way access-recency
    // tracking via the new age[] array below.
    parameter REPLACEMENT_POLICY = 0,
    // docs/adr/0024-variable-latency-memory.md (Phase I4). Extra wait-state
```

- [ ] **Step 2: Add the local enum**

Find:
```verilog
localparam WAY_BITS     = $clog2(WAYS);

wire [WORD_OFF_BITS-1:0] word_off = readAddr[OFFSET_BITS-1:2];
```
Replace with:
```verilog
localparam WAY_BITS     = $clog2(WAYS);

// REPLACEMENT_POLICY values -- named purely for readability at the sites
// that consume this parameter below (docs/adr/0041).
localparam POLICY_ROUND_ROBIN = 0;
localparam POLICY_FIFO        = 1;
localparam POLICY_LRU         = 2;

wire [WORD_OFF_BITS-1:0] word_off = readAddr[OFFSET_BITS-1:2];
```

- [ ] **Step 3: Add the `age[]` array**

Find:
```verilog
reg [WAY_BITS-1:0]  victim  [0:NUM_SETS-1];   // per-set round-robin fill pointer
```
Replace with:
```verilog
reg [WAY_BITS-1:0]  victim  [0:NUM_SETS-1];   // per-set round-robin fill pointer
// docs/adr/0041. Per-set, per-way access-recency rank: 0=most-recently-used,
// WAYS-1=least-recently-used. Only consumed under POLICY_LRU -- maintained
// regardless of REPLACEMENT_POLICY (same "unselected state costs nothing
// but exists" convention every other swappable parameter in this project
# ponytail: always-maintained, never gated on REPLACEMENT_POLICY==POLICY_LRU
# for the *update* itself -- cheaper than adding an extra generate branch,
# and harmless since nothing reads age[] under the other two policies.
// already follows).
reg [WAY_BITS-1:0]  age     [0:NUM_SETS-1][0:WAYS-1];
```

- [ ] **Step 4: Extend the way-compare generate block with a hit-way-index accumulator, and add the LRU-victim reduction**

Find:
```verilog
genvar gw;
wire [WAYS-1:0]    way_hit;
wire [XLEN-1:0]     way_data [0:WAYS-1];
wire [XLEN-1:0]     inst_acc [0:WAYS];
assign inst_acc[0] = {XLEN{1'b0}};
generate
    for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_way_compare
        assign way_hit[gw]  = valid[set_idx*WAYS + gw] && (tag_arr[set_idx*WAYS + gw] == tag);
        assign way_data[gw] = data_arr[(set_idx*WAYS + gw)*LINE_WORDS + word_off];
        assign inst_acc[gw+1] = inst_acc[gw] | (way_hit[gw] ? way_data[gw] : {XLEN{1'b0}});
    end
endgenerate

assign hit  = |way_hit;
assign inst = inst_acc[WAYS];
```
Replace with:
```verilog
genvar gw;
wire [WAYS-1:0]    way_hit;
wire [XLEN-1:0]     way_data [0:WAYS-1];
wire [XLEN-1:0]     inst_acc [0:WAYS];
// docs/adr/0041. Same accumulator-reduction shape as inst_acc above, just
// producing the winning way's own index instead of its data -- needed so
// POLICY_LRU knows WHICH way a hit touched.
wire [WAY_BITS-1:0] hit_way_acc [0:WAYS];
assign inst_acc[0]    = {XLEN{1'b0}};
assign hit_way_acc[0] = {WAY_BITS{1'b0}};
generate
    for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_way_compare
        assign way_hit[gw]  = valid[set_idx*WAYS + gw] && (tag_arr[set_idx*WAYS + gw] == tag);
        assign way_data[gw] = data_arr[(set_idx*WAYS + gw)*LINE_WORDS + word_off];
        assign inst_acc[gw+1]    = inst_acc[gw]    | (way_hit[gw] ? way_data[gw]     : {XLEN{1'b0}});
        assign hit_way_acc[gw+1] = hit_way_acc[gw] | (way_hit[gw] ? gw[WAY_BITS-1:0] : {WAY_BITS{1'b0}});
    end
endgenerate

assign hit  = |way_hit;
assign inst = inst_acc[WAYS];
wire [WAY_BITS-1:0] hit_way_idx = hit_way_acc[WAYS];

// docs/adr/0041. POLICY_LRU's own victim choice: the way whose age[] entry
// is genuinely WAYS-1 (least-recently-used) for the set a miss is about to
// fill into. Same OR-of-AND-masked reduction shape as way_hit/inst_acc
// above -- safe because lru_touch (below) maintains age[] as a real total
// order, so exactly one way ever holds WAYS-1 at a time.
wire [WAYS-1:0]     is_lru_way;
wire [WAY_BITS-1:0] lru_way_acc [0:WAYS];
assign lru_way_acc[0] = {WAY_BITS{1'b0}};
generate
    for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_lru_victim
        assign is_lru_way[gw]    = (age[set_idx][gw] == WAYS-1);
        assign lru_way_acc[gw+1] = lru_way_acc[gw] | (is_lru_way[gw] ? gw[WAY_BITS-1:0] : {WAY_BITS{1'b0}});
    end
endgenerate
wire [WAY_BITS-1:0] lru_way_idx = lru_way_acc[WAYS];
```

- [ ] **Step 5: Add the `lru_touch` task**

Find:
```verilog
integer reset_i;
always @(posedge clk) begin
    if (~rst) begin
        state  <= S_IDLE;
```
Replace with:
```verilog
// docs/adr/0041. Standard LRU-stack update: the touched way becomes rank 0
// (MRU); every way that was more-recently-used than it (age < its OLD age)
// ages by one step to make room. Task calls containing non-blocking
// assignments, invoked from inside the always @(posedge clk) block below,
// are ordinary, legal Verilog.
task lru_touch;
    input [SET_BITS-1:0] t_set;
    input [WAY_BITS-1:0] t_way;
    integer k;
    begin
        for (k = 0; k < WAYS; k = k + 1) begin
            if (k[WAY_BITS-1:0] == t_way)
                age[t_set][k] <= {WAY_BITS{1'b0}};
            else if (age[t_set][k] < age[t_set][t_way])
                age[t_set][k] <= age[t_set][k] + 1'b1;
        end
    end
endtask

integer reset_i, reset_j;
always @(posedge clk) begin
    if (~rst) begin
        state  <= S_IDLE;
```

- [ ] **Step 6: Reset the `age[]` array, extend `fill_way_r`'s select, add the two `lru_touch` call sites**

Find:
```verilog
        for (reset_i = 0; reset_i < NUM_LINES; reset_i = reset_i + 1)
            valid[reset_i] <= 1'b0;
        for (reset_i = 0; reset_i < NUM_SETS; reset_i = reset_i + 1)
            victim[reset_i] <= {WAY_BITS{1'b0}};
    end
    else begin
        done_r <= 1'b0;   // default: one-cycle pulse, cleared unless set below

        case (state)
            S_IDLE: begin
                if (!hit) begin
                    fill_set_r  <= set_idx;
                    fill_tag_r  <= tag;
                    fill_way_r  <= victim[set_idx];
                    fill_base_r <= {readAddr[XLEN-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
                    fill_word_r <= {WORD_OFF_BITS{1'b0}};
                    busy_r      <= 1'b1;
                    state       <= S_FILL;
                end
            end

            S_FILL: begin
                if (fillword_ready) begin
                    data_arr[(fill_set_r*WAYS + fill_way_r)*LINE_WORDS + fill_word_r] <= imem_data;
                    if (fill_word_r == LINE_WORDS-1) begin
                        valid[fill_set_r*WAYS + fill_way_r]   <= 1'b1;
                        tag_arr[fill_set_r*WAYS + fill_way_r] <= fill_tag_r;
                        victim[fill_set_r] <= (fill_way_r == WAYS-1) ? {WAY_BITS{1'b0}} : fill_way_r + 1'b1;
                        busy_r <= 1'b0;
                        done_r <= 1'b1;
                        state  <= S_IDLE;
                    end
                    else begin
                        fill_word_r <= fill_word_r + 1'b1;
                    end
                end
            end
        endcase
    end
end
```
Replace with:
```verilog
        for (reset_i = 0; reset_i < NUM_LINES; reset_i = reset_i + 1)
            valid[reset_i] <= 1'b0;
        for (reset_i = 0; reset_i < NUM_SETS; reset_i = reset_i + 1) begin
            victim[reset_i] <= {WAY_BITS{1'b0}};
            // docs/adr/0041. Arbitrary-but-valid initial total order (any
            // deterministic starting state is fine -- only relative order
            // after real accesses matters, same convention victim[]'s own
            // reset-to-0 already established).
            for (reset_j = 0; reset_j < WAYS; reset_j = reset_j + 1)
                age[reset_i][reset_j] <= reset_j[WAY_BITS-1:0];
        end
    end
    else begin
        done_r <= 1'b0;   // default: one-cycle pulse, cleared unless set below

        // docs/adr/0041. POLICY_LRU: touch the hit way every cycle `hit`
        // holds -- idempotent once already MRU (age[touched]==0 already, so
        // nothing else has a smaller age to increment past), safe to
        // evaluate every cycle regardless of FSM state, since `hit` is
        // combinational against `readAddr` independent of any in-progress
        // fill for a different line.
        if (REPLACEMENT_POLICY == POLICY_LRU && hit)
            lru_touch(set_idx, hit_way_idx);

        case (state)
            S_IDLE: begin
                if (!hit) begin
                    fill_set_r  <= set_idx;
                    fill_tag_r  <= tag;
                    fill_way_r  <= (REPLACEMENT_POLICY == POLICY_LRU) ? lru_way_idx : victim[set_idx];
                    fill_base_r <= {readAddr[XLEN-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
                    fill_word_r <= {WORD_OFF_BITS{1'b0}};
                    busy_r      <= 1'b1;
                    state       <= S_FILL;
                end
            end

            S_FILL: begin
                if (fillword_ready) begin
                    data_arr[(fill_set_r*WAYS + fill_way_r)*LINE_WORDS + fill_word_r] <= imem_data;
                    if (fill_word_r == LINE_WORDS-1) begin
                        valid[fill_set_r*WAYS + fill_way_r]   <= 1'b1;
                        tag_arr[fill_set_r*WAYS + fill_way_r] <= fill_tag_r;
                        victim[fill_set_r] <= (fill_way_r == WAYS-1) ? {WAY_BITS{1'b0}} : fill_way_r + 1'b1;
                        if (REPLACEMENT_POLICY == POLICY_LRU)
                            lru_touch(fill_set_r, fill_way_r);
                        busy_r <= 1'b0;
                        done_r <= 1'b1;
                        state  <= S_IDLE;
                    end
                    else begin
                        fill_word_r <= fill_word_r + 1'b1;
                    end
                end
            end
        endcase
    end
end
```

- [ ] **Step 7: Remove the stray `# ponytail` comment typo from Step 3**

The Step 3 block above has a malformed comment (`#`-prefixed lines aren't Verilog comment syntax — `//` is). Find:
```verilog
// docs/adr/0041. Per-set, per-way access-recency rank: 0=most-recently-used,
// WAYS-1=least-recently-used. Only consumed under POLICY_LRU -- maintained
// regardless of REPLACEMENT_POLICY (same "unselected state costs nothing
// but exists" convention every other swappable parameter in this project
# ponytail: always-maintained, never gated on REPLACEMENT_POLICY==POLICY_LRU
# for the *update* itself -- cheaper than adding an extra generate branch,
# and harmless since nothing reads age[] under the other two policies.
// already follows).
reg [WAY_BITS-1:0]  age     [0:NUM_SETS-1][0:WAYS-1];
```
Replace with:
```verilog
// docs/adr/0041. Per-set, per-way access-recency rank: 0=most-recently-used,
// WAYS-1=least-recently-used. Only consumed under POLICY_LRU.
// ponytail: age[] update always runs regardless of REPLACEMENT_POLICY,
// never gated on ==POLICY_LRU -- cheaper than an extra generate branch, and
// harmless since nothing reads age[] under the other two policies.
reg [WAY_BITS-1:0]  age     [0:NUM_SETS-1][0:WAYS-1];
```

- [ ] **Step 8: Compile check**

Run: `/c/iverilog/bin/iverilog -Wall -g2005 -I design -tnull design/*.v`
Expected: zero warnings, zero errors.

- [ ] **Step 9: Full regression (still untouched — `riscvpipeline.v` doesn't pass `REPLACEMENT_POLICY` to `ICache` yet)**

Run: `bash sim/run_tests.sh`
Expected: same as `HEAD`.

- [ ] **Step 10: Add the `dut3` LRU sub-test to `tb_icache_unit.v`**

In `sim/tb/tb_icache_unit.v`, find the `dut2` declaration block (lines ~48-58) and add a third instance right after it:
```verilog
    localparam MEM_LATENCY_TEST = 3;
    reg rst2 = 0;
    reg [31:0] readAddr2 = 0;
    wire [31:0] inst_o2;
    wire hit_o2, busy_o2, done_o2;
    ICache #(.INIT_FILE(""), .IMEM_SIZE_BYTES(64), .XLEN(32),
             .WAYS(2), .CACHE_SIZE_BYTES(32), .LINE_BYTES(8),
             .MEM_LATENCY(MEM_LATENCY_TEST)) dut2(
        .clk(clk), .rst(rst2), .readAddr(readAddr2),
        .inst(inst_o2), .hit(hit_o2), .busy(busy_o2), .done(done_o2)
    );

    // docs/adr/0041-cache-replacement-policy-phase-b.md. A third instance,
    // 4-way/1-set (32B cache, 8B lines -> 4 lines / 4 ways = 1 set), so
    // every one of 4 fills lands in the SAME set and a 5th distinct address
    // forces a real eviction choice -- the worked example REPLACEMENT_POLICY=2
    // (POLICY_LRU) needs to prove it genuinely diverges from round-robin.
    reg rst3 = 0;
    reg [31:0] readAddr3 = 0;
    wire [31:0] inst_o3;
    wire hit_o3, busy_o3, done_o3;
    ICache #(.INIT_FILE(""), .IMEM_SIZE_BYTES(64), .XLEN(32),
             .WAYS(4), .CACHE_SIZE_BYTES(32), .LINE_BYTES(8),
             .REPLACEMENT_POLICY(2)) dut3(
        .clk(clk), .rst(rst3), .readAddr(readAddr3),
        .inst(inst_o3), .hit(hit_o3), .busy(busy_o3), .done(done_o3)
    );
```

- [ ] **Step 11: Add `dut3`'s test sequence**

Find (near the end of the `initial` block, right before the final pass/fail summary):
```verilog
        check_bit(hit_o2, 1'b1, "MEM_LATENCY>0: addr4 (same line) hits with no extra fill");
        check_word(inst_o2, val_at(4), "MEM_LATENCY>0: addr4 content correct");

        if (fails == 0)
```
Replace with:
```verilog
        check_bit(hit_o2, 1'b1, "MEM_LATENCY>0: addr4 (same line) hits with no extra fill");
        check_word(inst_o2, val_at(4), "MEM_LATENCY>0: addr4 content correct");

        // -- POLICY_LRU sub-test (dut3): docs/adr/0041's own worked example.
        // 1 set, 4 ways, 5 distinct 8-byte-aligned lines (A=0,B=8,C=16,D=24,
        // E=32). Fill A,B,C,D in order (fills way0..way3 -- round-robin's
        // pointer wraps back to way0 after). Then re-touch A and B (hits,
        // not fills). Miss on E forces eviction: round-robin blindly evicts
        // whatever the wrapped pointer already points at (way0/A), oblivious
        // to the two intervening hits; true LRU's real order at that point
        // is B,A,D,C (MRU->LRU), so it evicts C (way2), not A.
        readAddr3 = 0;
        @(posedge clk); rst3 <= 0;
        @(posedge clk); rst3 <= 1;
        poke_word_dut3(0,  val_at(0));
        poke_word_dut3(8,  val_at(8));
        poke_word_dut3(16, val_at(16));
        poke_word_dut3(24, val_at(24));
        poke_word_dut3(32, val_at(32));

        set_addr3(0);  wait_ready3;  check_bit(hit_o3, 1'b1, "LRU: addr0 (A) fills way0");
        set_addr3(8);  wait_ready3;  check_bit(hit_o3, 1'b1, "LRU: addr8 (B) fills way1");
        set_addr3(16); wait_ready3;  check_bit(hit_o3, 1'b1, "LRU: addr16 (C) fills way2");
        set_addr3(24); wait_ready3;  check_bit(hit_o3, 1'b1, "LRU: addr24 (D) fills way3 -- all 4 ways now full");

        // Re-touch A then B (real hits, no fill -- moves them to MRU).
        set_addr3(0);
        check_bit(hit_o3, 1'b1, "LRU: addr0 (A) re-touch is a hit, not a fill");
        set_addr3(8);
        check_bit(hit_o3, 1'b1, "LRU: addr8 (B) re-touch is a hit, not a fill");

        // Miss on E (addr32, a 5th distinct tag) forces an eviction.
        set_addr3(32);
        check_bit(hit_o3, 1'b0, "LRU: addr32 (E) cold-misses");
        wait_ready3;
        check_bit(hit_o3, 1'b1, "LRU: addr32 (E) hits after fill");
        check_word(inst_o3, val_at(32), "LRU: addr32 content correct");

        // The real differentiator: C (way2, least-recently-touched) must be
        // gone; D (way3, never re-touched but still more-recent than C at
        // fill time) must survive. Round-robin would instead have evicted A.
        set_addr3(16);
        check_bit(hit_o3, 1'b0, "LRU: addr16 (C) now MISSES -- true LRU evicted the actual least-recently-used way");
        set_addr3(24);
        check_bit(hit_o3, 1'b1, "LRU: addr24 (D) still hits -- LRU correctly spared it over C");
        set_addr3(0);
        check_bit(hit_o3, 1'b1, "LRU: addr0 (A) still hits -- round-robin's blind choice (evict A) would have failed this check");

        if (fails == 0)
```

- [ ] **Step 12: Add `dut3`'s helper tasks (`poke_word_dut3`/`set_addr3`/`wait_ready3`)**

Find the existing `poke_word`/`wait_ready`/`set_addr` task definitions (lines ~93-137) and add three `dut3`-scoped twins right after `set_addr`'s `endtask`:
```verilog
    task poke_word_dut3;
        input [31:0] addr;
        input [31:0] val;
        begin
            dut3.m_imem.insts[addr]   = val[31:24];
            dut3.m_imem.insts[addr+1] = val[23:16];
            dut3.m_imem.insts[addr+2] = val[15:8];
            dut3.m_imem.insts[addr+3] = val[7:0];
        end
    endtask

    task wait_ready3;
        integer i;
        begin
            i = 0;
            while (!hit_o3 && i < 10) begin
                @(posedge clk);
                i = i + 1;
            end
        end
    endtask

    task set_addr3;
        input [31:0] addr;
        begin
            @(negedge clk);
            readAddr3 = addr;
            #1;
        end
    endtask
```

- [ ] **Step 13: Run the unit test directly**

Run: `cd sim/tb && /c/iverilog/bin/iverilog -g2005 -I ../../design -o /tmp/tb_icache_unit ../../design/riscv_defs.vh tb_icache_unit.v && /c/iverilog/bin/vvp /tmp/tb_icache_unit`

(Adjust include path to however `sim/run_tests.sh` normally invokes a single testbench if this exact incantation errors — check that script's own per-file invocation pattern first.)

Expected: `PASS  icache_unit (N checks)` with the new LRU checks all `pass`, zero `FAIL` lines. If `addr16 (C) now MISSES` fails (shows a hit instead), the LRU age-tracking logic has a bug — debug before proceeding, don't adjust the test to match wrong behavior.

- [ ] **Step 14: Full regression + zero-warning compile**

Run: `bash sim/run_tests.sh` and `/c/iverilog/bin/iverilog -Wall -g2005 -I design -tnull design/*.v`
Expected: same pass count as `HEAD` plus the new dut3 checks all passing within `icache_unit`'s own line in the summary; zero warnings.

- [ ] **Step 15: Commit**

```bash
git add design/ICache.v sim/tb/tb_icache_unit.v
git commit -m "Gen4 Phase B: ICache.v gains REPLACEMENT_POLICY (LRU/FIFO/round-robin), standalone

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 3: `DCache.v` — add `REPLACEMENT_POLICY`/LRU mechanism, standalone

**Files:**
- Modify: `design/DCache.v`
- Modify: `sim/tb/tb_dcache_unit.v` (new `dut2` LRU sub-test)

**Interfaces:**
- Consumes: nothing new from other tasks (mirrors Task 2's shape independently).
- Produces: `DCache`'s new `REPLACEMENT_POLICY` parameter, for Task 4.

- [ ] **Step 1: Add the parameter**

Find:
```verilog
    parameter CACHE_SIZE_BYTES = 4096,
    parameter LINE_BYTES = 16
)(
```
Replace with:
```verilog
    parameter CACHE_SIZE_BYTES = 4096,
    parameter LINE_BYTES = 16,
    // docs/adr/0041-cache-replacement-policy-phase-b.md (Generation 4, Phase
    // B). Same closed enum ICache.v's own REPLACEMENT_POLICY uses (see its
    // header comment for the full POLICY_ROUND_ROBIN/FIFO/LRU rationale --
    // not repeated here to avoid drift between two independently-maintained
    // copies of the same explanation).
    parameter REPLACEMENT_POLICY = 0
)(
```

- [ ] **Step 2: Add the local enum**

Find:
```verilog
localparam WAY_BITS      = $clog2(WAYS);
localparam LINE_IDX_BITS = SET_BITS + WAY_BITS;

wire [WORD_OFF_BITS-1:0] word_off = req_addr[OFFSET_BITS-1:2];
```
Replace with:
```verilog
localparam WAY_BITS      = $clog2(WAYS);
localparam LINE_IDX_BITS = SET_BITS + WAY_BITS;

// REPLACEMENT_POLICY values (docs/adr/0041) -- same three values as
// ICache.v's own copy.
localparam POLICY_ROUND_ROBIN = 0;
localparam POLICY_FIFO        = 1;
localparam POLICY_LRU         = 2;

wire [WORD_OFF_BITS-1:0] word_off = req_addr[OFFSET_BITS-1:2];
```

- [ ] **Step 3: Add the `age[]` array**

Find:
```verilog
reg [WAY_BITS-1:0]  victim  [0:NUM_SETS-1];
```
Replace with:
```verilog
reg [WAY_BITS-1:0]  victim  [0:NUM_SETS-1];
// docs/adr/0041. Same per-set/per-way access-recency rank ICache.v's own
// age[] tracks -- see its header comment for the full rationale.
// ponytail: always-maintained regardless of REPLACEMENT_POLICY, same
// rationale as ICache.v's own copy.
reg [WAY_BITS-1:0]  age     [0:NUM_SETS-1][0:WAYS-1];
```

- [ ] **Step 4: Add the LRU-victim reduction (right after the existing way-compare generate block)**

Find:
```verilog
wire hit = |way_hit;
wire [XLEN-1:0]          hit_data     = hit_data_acc[WAYS];
wire [LINE_IDX_BITS-1:0] hit_line_idx = hit_lineidx_acc[WAYS];
```
Replace with:
```verilog
wire hit = |way_hit;
wire [XLEN-1:0]          hit_data     = hit_data_acc[WAYS];
wire [LINE_IDX_BITS-1:0] hit_line_idx = hit_lineidx_acc[WAYS];

// docs/adr/0041. POLICY_LRU's own victim choice -- same shape as
// ICache.v's own gen_lru_victim block. (hit_line_idx already gives a
// hit's own way via its low WAY_BITS bits -- line_idx = set*WAYS+way with
// WAYS a power of 2, per this file's own header comment -- so no separate
// hit-way accumulator is needed here the way ICache.v's is.)
wire [WAYS-1:0]     is_lru_way;
wire [WAY_BITS-1:0] lru_way_acc [0:WAYS];
assign lru_way_acc[0] = {WAY_BITS{1'b0}};
generate
    for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_lru_victim
        assign is_lru_way[gw]    = (age[set_idx][gw] == WAYS-1);
        assign lru_way_acc[gw+1] = lru_way_acc[gw] | (is_lru_way[gw] ? gw[WAY_BITS-1:0] : {WAY_BITS{1'b0}});
    end
endgenerate
wire [WAY_BITS-1:0] lru_way_idx = lru_way_acc[WAYS];
```

- [ ] **Step 5: Add `access_hit_way`/`access_hit_set` derivation (reusing the existing `access_hit`/`hit_line_r`/`hit_line_idx` signals)**

Find:
```verilog
wire [31:0] hit_rd_word = data_arr[hit_line_r*LINE_WORDS + hit_word_r];
```
Replace with:
```verilog
wire [31:0] hit_rd_word = data_arr[hit_line_r*LINE_WORDS + hit_word_r];

// docs/adr/0041. The way/set access_hit (declared above) touched: at
// S_IDLE (the write-hit case, resp_ready fires the SAME cycle) it's
// hit_line_idx, still live combinationally; at S_HIT_RD (the read-hit
// case, completing one cycle later) it's hit_line_r, latched back at
// S_IDLE detection time and still valid through S_HIT_RD.
wire [WAY_BITS-1:0] access_hit_way = (state == S_IDLE) ? hit_line_idx[WAY_BITS-1:0]
                                                        : hit_line_r[WAY_BITS-1:0];
wire [SET_BITS-1:0] access_hit_set = (state == S_IDLE) ? hit_line_idx[LINE_IDX_BITS-1:WAY_BITS]
                                                        : hit_line_r[LINE_IDX_BITS-1:WAY_BITS];
```

- [ ] **Step 6: Add the `lru_touch` task**

Find:
```verilog
integer reset_i;
always @(posedge clk) begin
    if (~rst) begin
        state <= S_IDLE;
```
Replace with:
```verilog
// docs/adr/0041. Same LRU-stack update ICache.v's own lru_touch performs.
task lru_touch;
    input [SET_BITS-1:0] t_set;
    input [WAY_BITS-1:0] t_way;
    integer k;
    begin
        for (k = 0; k < WAYS; k = k + 1) begin
            if (k[WAY_BITS-1:0] == t_way)
                age[t_set][k] <= {WAY_BITS{1'b0}};
            else if (age[t_set][k] < age[t_set][t_way])
                age[t_set][k] <= age[t_set][k] + 1'b1;
        end
    end
endtask

integer reset_i, reset_j;
always @(posedge clk) begin
    if (~rst) begin
        state <= S_IDLE;
```

- [ ] **Step 7: Reset `age[]`, add the two `lru_touch` call sites, extend `miss_way_r`'s select**

Find:
```verilog
        for (reset_i = 0; reset_i < NUM_LINES; reset_i = reset_i + 1) begin
            valid[reset_i] <= 1'b0;
            dirty[reset_i] <= 1'b0;
        end
        for (reset_i = 0; reset_i < NUM_SETS; reset_i = reset_i + 1)
            victim[reset_i] <= {WAY_BITS{1'b0}};
    end
    else begin
        flush_done_r <= 1'b0;   // default: one-cycle pulse, cleared unless set below

        case (state)
```
Replace with:
```verilog
        for (reset_i = 0; reset_i < NUM_LINES; reset_i = reset_i + 1) begin
            valid[reset_i] <= 1'b0;
            dirty[reset_i] <= 1'b0;
        end
        for (reset_i = 0; reset_i < NUM_SETS; reset_i = reset_i + 1) begin
            victim[reset_i] <= {WAY_BITS{1'b0}};
            for (reset_j = 0; reset_j < WAYS; reset_j = reset_j + 1)
                age[reset_i][reset_j] <= reset_j[WAY_BITS-1:0];
        end
    end
    else begin
        flush_done_r <= 1'b0;   // default: one-cycle pulse, cleared unless set below

        // docs/adr/0041. POLICY_LRU: touch on every real access-hit (reuses
        // the existing J5 access_hit signal, already exactly-once-per-real-
        // access -- see its own header comment) and on every fill
        // completion (below, inside S_FILL).
        if (REPLACEMENT_POLICY == POLICY_LRU && access_hit)
            lru_touch(access_hit_set, access_hit_way);

        case (state)
```

Find:
```verilog
                        miss_way_r      <= victim[set_idx];
```
Replace with:
```verilog
                        miss_way_r      <= (REPLACEMENT_POLICY == POLICY_LRU) ? lru_way_idx : victim[set_idx];
```

Find:
```verilog
                        victim[miss_set_r] <= (miss_way_r == WAYS-1) ? {WAY_BITS{1'b0}} : miss_way_r + 1'b1;
                        state <= S_IDLE;
```
Replace with:
```verilog
                        victim[miss_set_r] <= (miss_way_r == WAYS-1) ? {WAY_BITS{1'b0}} : miss_way_r + 1'b1;
                        if (REPLACEMENT_POLICY == POLICY_LRU)
                            lru_touch(miss_set_r, miss_way_r);
                        state <= S_IDLE;
```

- [ ] **Step 8: Compile check + full regression (still untouched from `riscvpipeline.v`'s side)**

Run: `/c/iverilog/bin/iverilog -Wall -g2005 -I design -tnull design/*.v` then `bash sim/run_tests.sh`
Expected: zero warnings; same pass count as `HEAD`.

- [ ] **Step 9: Add `dut2` LRU sub-test to `tb_dcache_unit.v`**

In `sim/tb/tb_dcache_unit.v`, find the single `dut` instantiation:
```verilog
    DCache #(.XLEN(32), .WAYS(2), .CACHE_SIZE_BYTES(32), .LINE_BYTES(8)) dut(
        .clk(clk), .rst(rst),
        .req_read(req_read), .req_write(req_write), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_funct3(req_funct3),
        .resp_rdata(resp_rdata), .resp_ready(resp_ready),
        .flush_all(flush_all), .flush_busy(flush_busy), .flush_done(flush_done),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_addr(m_addr),
        .m_data_o(m_data_o), .m_sel(m_sel), .m_funct3(m_funct3),
        .m_data_i(m_data_i), .m_ack(m_ack)
    );

    // Real backing memory, 64 bytes -- room for several distinct tags'
    // worth of lines at this cache's own small sizing.
    RamWishboneAdapter #(.SIZE_BYTES(64), .XLEN(32)) m_ram_adapter(
        .clk(clk), .rst(rst),
        .s_cyc(m_cyc), .s_stb(m_stb), .s_we(m_we), .s_addr(m_addr),
        .s_data_o(m_data_o), .s_sel(m_sel), .funct3(m_funct3),
        .s_data_i(m_data_i), .s_ack(m_ack)
    );
```
Add a second, independent DUT + backing RAM right after it:
```verilog
    // docs/adr/0041-cache-replacement-policy-phase-b.md. A second, fully
    // independent DUT: 4-way/1-set (32B cache, 8B lines -> 4 lines / 4 ways
    // = 1 set), REPLACEMENT_POLICY=2 (POLICY_LRU) -- same worked example
    // tb_icache_unit.v's own dut3 proves, adapted for D-side read/write.
    reg         req_read2 = 0;
    reg         req_write2 = 0;
    reg  [31:0] req_addr2 = 0;
    reg  [31:0] req_wdata2 = 0;
    reg  [2:0]  req_funct32 = 3'b010;
    wire [31:0] resp_rdata2;
    wire        resp_ready2;
    reg         flush_all2 = 0;
    wire        flush_busy2, flush_done2;
    wire        m_cyc2, m_stb2, m_we2;
    wire [31:0] m_addr2, m_data_o2;
    wire [3:0]  m_sel2;
    wire [2:0]  m_funct32;
    wire [31:0] m_data_i2;
    wire        m_ack2;

    DCache #(.XLEN(32), .WAYS(4), .CACHE_SIZE_BYTES(32), .LINE_BYTES(8),
             .REPLACEMENT_POLICY(2)) dut2(
        .clk(clk), .rst(rst2),
        .req_read(req_read2), .req_write(req_write2), .req_addr(req_addr2),
        .req_wdata(req_wdata2), .req_funct3(req_funct32),
        .resp_rdata(resp_rdata2), .resp_ready(resp_ready2),
        .flush_all(flush_all2), .flush_busy(flush_busy2), .flush_done(flush_done2),
        .m_cyc(m_cyc2), .m_stb(m_stb2), .m_we(m_we2), .m_addr(m_addr2),
        .m_data_o(m_data_o2), .m_sel(m_sel2), .m_funct3(m_funct32),
        .m_data_i(m_data_i2), .m_ack(m_ack2)
    );
    RamWishboneAdapter #(.SIZE_BYTES(64), .XLEN(32)) m_ram_adapter2(
        .clk(clk), .rst(rst2),
        .s_cyc(m_cyc2), .s_stb(m_stb2), .s_we(m_we2), .s_addr(m_addr2),
        .s_data_o(m_data_o2), .s_sel(m_sel2), .funct3(m_funct32),
        .s_data_i(m_data_i2), .s_ack(m_ack2)
    );
    reg rst2 = 0;
```

- [ ] **Step 10: Add `dut2`'s helper tasks and test sequence**

Find the existing `do_read`/`do_write`/`do_flush` task definitions and add `dut2`-scoped twins right after `do_flush`'s `endtask`:
```verilog
    reg [31:0] last_rdata2;
    task do_read2;
        input [31:0] addr;
        input [2:0] funct3;
        reg ready_seen;
        begin
            @(negedge clk);
            req_addr2 = addr; req_funct32 = funct3; req_read2 = 1; req_write2 = 0;
            ready_seen = 0;
            while (!ready_seen) begin
                @(posedge clk);
                #1;
                if (resp_ready2) begin
                    ready_seen = 1;
                    last_rdata2 = resp_rdata2;
                end
            end
            @(negedge clk);
            req_read2 = 0;
        end
    endtask

    task do_write2;
        input [31:0] addr;
        input [31:0] wdata;
        input [2:0] funct3;
        reg ready_seen;
        begin
            @(negedge clk);
            req_addr2 = addr; req_wdata2 = wdata; req_funct32 = funct3; req_write2 = 1; req_read2 = 0;
            ready_seen = 0;
            while (!ready_seen) begin
                @(posedge clk);
                #1;
                if (resp_ready2) ready_seen = 1;
            end
            @(negedge clk);
            req_write2 = 0;
        end
    endtask
```

Find the final `if (fails == 0)` summary block and insert the LRU sub-test right before it:
```verilog
        // -- POLICY_LRU sub-test (dut2): same worked example as
        // tb_icache_unit.v's own dut3 -- fill A(0),B(8),C(16),D(24) (one
        // per way), re-touch A and B (hits), miss on E(32) forces eviction.
        // Round-robin's blind pointer would evict A; true LRU evicts C.
        @(posedge clk); rst2 <= 0;
        @(posedge clk); rst2 <= 1;

        do_write2(0,  32'hAAAA0000, 3'b010);
        do_write2(8,  32'hBBBB0000, 3'b010);
        do_write2(16, 32'hCCCC0000, 3'b010);
        do_write2(24, 32'hDDDD0000, 3'b010);   // all 4 ways of the 1 set now full

        do_read2(0, 3'b010);
        check_word(last_rdata2, 32'hAAAA0000, "LRU-D: addr0 (A) re-touch hit, correct data");
        do_read2(8, 3'b010);
        check_word(last_rdata2, 32'hBBBB0000, "LRU-D: addr8 (B) re-touch hit, correct data");

        do_write2(32, 32'hEEEE0000, 3'b010);   // 5th distinct tag: forces eviction
        do_read2(32, 3'b010);
        check_word(last_rdata2, 32'hEEEE0000, "LRU-D: addr32 (E) fill/read-back correct");

        do_read2(16, 3'b010);
        check_word(last_rdata2, 32'h0, "LRU-D: addr16 (C) evicted -- re-fills from clean backing RAM (0), true LRU chose C not A");
        do_read2(24, 3'b010);
        check_word(last_rdata2, 32'hDDDD0000, "LRU-D: addr24 (D) still hits, undisturbed");
        do_read2(0, 3'b010);
        check_word(last_rdata2, 32'hAAAA0000, "LRU-D: addr0 (A) still hits -- round-robin's blind choice (evict A) would have failed this");

        if (fails == 0)
```

- [ ] **Step 11: Run the unit test, full regression, zero-warning compile**

Run: `cd sim/tb && /c/iverilog/bin/iverilog -g2005 -I ../../design -o /tmp/tb_dcache_unit tb_dcache_unit.v && /c/iverilog/bin/vvp /tmp/tb_dcache_unit`
(Adjust to `sim/run_tests.sh`'s own per-file invocation pattern if this exact command errors.)
Then: `bash sim/run_tests.sh` and `/c/iverilog/bin/iverilog -Wall -g2005 -I design -tnull design/*.v`

Expected: `PASS  dcache_unit (N checks)`, all new LRU-D checks passing; full regression unchanged from `HEAD`; zero warnings. If `addr16 (C) evicted` shows non-zero (a stale hit), debug the LRU logic — don't adjust the check.

- [ ] **Step 12: Commit**

```bash
git add design/DCache.v sim/tb/tb_dcache_unit.v
git commit -m "Gen4 Phase B: DCache.v gains REPLACEMENT_POLICY (LRU/FIFO/round-robin), standalone

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 4: Wire `REPLACEMENT_POLICY` live in `riscvpipeline.v` (the isolated, highest-risk step)

**Files:**
- Modify: `design/riscvpipeline.v:436-440` (ICache instantiation)
- Modify: `design/riscvpipeline.v:2933-2936` (DCache instantiation)

**Interfaces:**
- Consumes: `REPLACEMENT_POLICY` parameter from Task 1, `ICache`/`DCache`'s own `REPLACEMENT_POLICY` port from Tasks 2/3.
- Produces: `PIPELINED`'s `REPLACEMENT_POLICY` becomes live end-to-end.

- [ ] **Step 1: Pass `REPLACEMENT_POLICY` to `ICache`**

Find:
```verilog
        ICache #(.INIT_FILE(INIT_FILE), .IMEM_SIZE_BYTES(MEM_SIZE_BYTES), .XLEN(XLEN),
                 .WAYS(ICACHE_WAYS), .CACHE_SIZE_BYTES(ICACHE_SIZE_BYTES), .LINE_BYTES(ICACHE_LINE_BYTES),
                 .MEM_LATENCY(MEM_LATENCY_I)) m_ICache(
```
Replace with:
```verilog
        ICache #(.INIT_FILE(INIT_FILE), .IMEM_SIZE_BYTES(MEM_SIZE_BYTES), .XLEN(XLEN),
                 .WAYS(ICACHE_WAYS), .CACHE_SIZE_BYTES(ICACHE_SIZE_BYTES), .LINE_BYTES(ICACHE_LINE_BYTES),
                 .MEM_LATENCY(MEM_LATENCY_I), .REPLACEMENT_POLICY(REPLACEMENT_POLICY)) m_ICache(
```

- [ ] **Step 2: Pass `REPLACEMENT_POLICY` to `DCache`**

Find:
```verilog
        DCache #(.XLEN(XLEN), .WAYS(DCACHE_WAYS), .CACHE_SIZE_BYTES(DCACHE_SIZE_BYTES),
                 .LINE_BYTES(DCACHE_LINE_BYTES)) m_DCache(
```
Replace with:
```verilog
        DCache #(.XLEN(XLEN), .WAYS(DCACHE_WAYS), .CACHE_SIZE_BYTES(DCACHE_SIZE_BYTES),
                 .LINE_BYTES(DCACHE_LINE_BYTES), .REPLACEMENT_POLICY(REPLACEMENT_POLICY)) m_DCache(
```

- [ ] **Step 3: Compile check + full regression at default (`REPLACEMENT_POLICY=0`, must stay bit-exact)**

Run: `/c/iverilog/bin/iverilog -Wall -g2005 -I design -tnull design/*.v` then `bash sim/run_tests.sh`
Expected: zero warnings; identical pass count to `HEAD` (default `REPLACEMENT_POLICY=0` selects the unchanged round-robin path in both caches).

- [ ] **Step 4: Commit**

```bash
git add design/riscvpipeline.v
git commit -m "Gen4 Phase B: wire REPLACEMENT_POLICY live (ICache/DCache instantiation)

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 5: End-to-end directed test proving `REPLACEMENT_POLICY=2` through the full pipeline

**Files:**
- Create: `sim/programs/cache_lru_b1.s`
- Create: `sim/tb/tb_cache_lru_b1.v`

**Interfaces:**
- Consumes: `PIPELINED`'s live `REPLACEMENT_POLICY` parameter (Task 4).
- Produces: nothing consumed by later tasks — this is a leaf directed test, mirroring Gen4 Phase A's own "end-to-end directed tests for GShare/Tournament" step.

- [ ] **Step 1: Find the closest existing full-pipeline cache directed test to copy the shape from**

Run: `grep -n "CACHE_MODE\|CACHE_WRITEBACK_SETASSOC" sim/tb/tb_icache_live_g3.v | head -20`

Read that file in full before writing the new one — it's the established template for instantiating `PIPELINED` with `CACHE_MODE=1` and small cache-size overrides in a directed test.

- [ ] **Step 2: Write `sim/programs/cache_lru_b1.s`**

A small store/load sequence touching 5 distinct cache lines within one set (mirroring Task 2/3's own address layout, scaled to whatever `DCACHE_SIZE_BYTES`/`DCACHE_LINE_BYTES` override this test's own testbench uses — follow `tb_icache_live_g3.v`'s own override convention exactly, likely also 1-set/4-way at a small size), storing a distinct known value to each line, re-touching two of them, then reading back all five and checking via `x`-register comparisons (`sim/tb/check_tasks.vh`'s `check_reg`) that the two round-robin-vs-LRU-divergent lines (the one LRU evicts vs. the one round-robin would have evicted) come back with the RIGHT content — a real miss (re-fetched from backing memory, zeroed/different) vs. a real hit (original stored value) is directly observable through register values after the loads.

- [ ] **Step 3: Write `sim/tb/tb_cache_lru_b1.v`**

Instantiate `PIPELINED` with `CACHE_MODE=CACHE_WRITEBACK_SETASSOC`, `REPLACEMENT_POLICY=2`, and small `DCACHE_WAYS`/`DCACHE_SIZE_BYTES`/`DCACHE_LINE_BYTES` overrides matching Step 2's program layout (mirror `tb_icache_live_g3.v`'s exact instantiation pattern, `` `include``s, halt-loop detection, and `check_tasks.vh` usage — copy its structure, don't invent a new harness shape).

- [ ] **Step 4: Run the new test standalone, then full regression**

Run: `bash sim/run_tests.sh` (it globs `tb_*.v` automatically, per `handoff.md`'s own documented convention — no harness changes needed for a new file to be picked up)
Expected: new test passes; overall count increases by 1 over Task 4's baseline; zero regressions elsewhere.

- [ ] **Step 5: Zero-warning compile**

Run: `/c/iverilog/bin/iverilog -Wall -g2005 -I design -tnull design/*.v`
Expected: zero warnings.

- [ ] **Step 6: Commit**

```bash
git add sim/programs/cache_lru_b1.s sim/tb/tb_cache_lru_b1.v
git commit -m "Gen4 Phase B: end-to-end directed test for REPLACEMENT_POLICY=2 (LRU) through the live pipeline

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 6: Constrained-random cross-check across all 3 `REPLACEMENT_POLICY` values

**Files:**
- Modify: `sim/tools/random_gen.py` (or wherever the existing `--branch-predictor`-style CLI passthrough lives — locate via grep first)
- Modify: `sim/tools/run_random_tests.py` (same)

**Interfaces:**
- Consumes: `PIPELINED`'s live `REPLACEMENT_POLICY` parameter (Task 4).
- Produces: `--replacement-policy {0,1,2}` CLI flag, mirroring `--branch-predictor`'s existing shape exactly.

- [ ] **Step 1: Locate the existing `--branch-predictor` passthrough as the exact template**

Run: `grep -n "branch.predictor\|BRANCH_PREDICTOR" sim/tools/run_random_tests.py sim/tools/random_gen.py`

Read both matched sections in full before writing the new flag — copy the identical argparse/passthrough shape, substituting `REPLACEMENT_POLICY`/`replacement-policy`/`{0,1,2}` for `BRANCH_PREDICTOR`/`branch-predictor`/`{0,1,2,3}`. `random_gen.py` itself needs no *generation-logic* changes (this parameter is timing-only, exactly like `BRANCH_PREDICTOR`/`CACHE_MODE`/`MEM_LATENCY_I/D` before it — the ISS has no cache model, confirmed in the design spec) — only the CLI passthrough to the RTL instantiation matters.

- [ ] **Step 2: Confirm `sim/tools/iss.py` needs no changes**

Run: `grep -n "cache\|CACHE" sim/tools/iss.py`
Expected: no hits, or only comments — confirms by direct inspection (not just the design spec's claim) that no cache model exists there to update.

- [ ] **Step 3: Run the cross-check at all 3 policy values, `CACHE_MODE=1` only**

Run (adjust exact flag names to whatever Step 1 actually produced):
```bash
python sim/tools/run_random_tests.py --count 100 --cache-mode 1 --replacement-policy 0 --iverilog-dir /c/iverilog/bin
python sim/tools/run_random_tests.py --count 100 --cache-mode 1 --replacement-policy 1 --iverilog-dir /c/iverilog/bin
python sim/tools/run_random_tests.py --count 100 --cache-mode 1 --replacement-policy 2 --iverilog-dir /c/iverilog/bin
```
Expected: 100/100 at every value. A failure at `--replacement-policy 2` specifically (not 0/1) points at the LRU logic; a failure at all three points at something Task 4's wiring broke generally.

- [ ] **Step 4: Commit**

```bash
git add sim/tools/random_gen.py sim/tools/run_random_tests.py
git commit -m "Gen4 Phase B: --replacement-policy CLI passthrough, 100/100 cross-check at all 3 values

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 7: `bench_runner.py --compare-replacement`

**Files:**
- Modify: `sim/tools/bench_runner.py`

**Interfaces:**
- Consumes: `PIPELINED`'s live `REPLACEMENT_POLICY` parameter (Task 4).
- Produces: `--compare-replacement` CLI flag, mirroring `--compare-predictors`/`--compare-cache`/`--compare-latency`/`--compare-profiles`/`--compare-strategies`' existing shape exactly.

- [ ] **Step 1: Locate `--compare-predictors` as the exact template**

Run: `grep -n "compare.predictors\|compare_predictors" sim/tools/bench_runner.py`

Read the matched function in full — copy its shape (run each benchmark kernel once per axis value, report cycle counts / a hit-rate delta table), substituting the 3 `REPLACEMENT_POLICY` values for the 4 `BRANCH_PREDICTOR` ones, and forcing `CACHE_MODE=CACHE_WRITEBACK_SETASSOC` for every run (the parameter is a no-op otherwise, same guard `--compare-cache`'s own implementation already needs).

- [ ] **Step 2: Run it, capture the real numbers**

Run: `python sim/tools/bench_runner.py --compare-replacement`
Expected: a real table across `bench_fib`/`bench_bubble_sort`/`bench_sum_array` for round-robin vs FIFO (identical numbers to round-robin, confirming Step-1's "same mechanism" claim empirically, not just by design) vs LRU. Record the actual output for the ADR (Task 8) — don't fabricate placeholder numbers.

- [ ] **Step 3: Commit**

```bash
git add sim/tools/bench_runner.py
git commit -m "Gen4 Phase B: bench_runner.py --compare-replacement, real measured hit-rate/cycle data

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

---

### Task 8: ADR + docs updates

**Files:**
- Create: `docs/adr/0041-cache-replacement-policy-phase-b.md`
- Modify: `docs/ROADMAP.md` (the "Advanced cache hierarchy" line item, mirroring how `docs/adr/0040` updated the "Advanced branch prediction" one)
- Modify: `docs/ROADMAP_VISION.md` (Generation 4 bullet — mark replacement-policy sub-item done, leave victim cache/L2/associativity-sweep open)
- Modify: `handoff.md` (new top section, mirroring the existing "Generation 4, Phase A" section's exact shape — NOT committed, per `[[phase-workflow]]`'s own note that `handoff.md` is gitignored)

**Interfaces:** none — terminal documentation task.

- [ ] **Step 1: Write the ADR**

Mirror `docs/adr/0040`'s exact section structure: Problem, Background, Design (the `age[]`/`lru_touch`/victim-argmax mechanism, the ROUND_ROBIN==FIFO identity), real bugs/findings from Tasks 2-7 (fill in honestly — don't claim zero bugs if the implementation hit any), Alternatives considered (pseudo-LRU tree bits, rejected — true LRU costs nothing extra at this scale), Validation strategy (the worked A/B/C/D/E example, 100/100 cross-check at 3 values, `bench_runner.py` real numbers from Task 7), Future improvements (victim cache, L2, associativity sweep — explicitly still open, per the design spec's non-goals).

- [ ] **Step 2: Update `docs/ROADMAP.md`/`docs/ROADMAP_VISION.md`**

Narrow, targeted edits only — fix the specific stale claim (the "Advanced cache hierarchy" bullet currently lists all 4 items as open; mark replacement-policy done, keep the other 3 as real open backlog, same pattern `docs/adr/0040`'s own doc update used for branch prediction).

- [ ] **Step 3: Update `handoff.md`**

Add a new top section (above the existing "Generation 4, Phase A" one) titled "Generation 4, Phase B (cache replacement policy, `docs/adr/0041`) — CLOSED", following that section's exact prose shape and level of detail. This file is gitignored — editing it needs no commit.

- [ ] **Step 4: Commit the ADR + ROADMAP changes (not `handoff.md`)**

```bash
git add docs/adr/0041-cache-replacement-policy-phase-b.md docs/ROADMAP.md docs/ROADMAP_VISION.md
git commit -m "Gen4 Phase B: ADR 0041, ROADMAP/ROADMAP_VISION updates

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>"
```

- [ ] **Step 5: Push, if the user asks**

Per `[[phase-workflow]]`'s established convention: don't push without being asked, even though every prior phase ends up pushed eventually. Ask.
