# Generation 4, Phase G: Hardware Prefetchers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Next-line/stride/stream hardware prefetchers for both I$ and D$, closing the
last unscoped item in Generation 4 — closing this phase closes Generation 4 itself
(docs/ROADMAP_VISION.md).

**Architecture:** One new standalone `design/Prefetcher.v` (a tiny single-global-entry
address predictor — no PC-indexed table, since research confirmed neither `ICache.v`
nor `DCache.v` has a per-access PC available today; see Global Constraints), one
implementation instantiated twice (I$+D$, mirrors `VictimCache.v`'s "one implementation
shared by both" precedent). It updates on every genuine demand-miss (reusing each
cache's own existing miss-detection condition — no new hook) and outputs a single
predicted next-line address. Each cache turns that into an **opportunistic** fill using
its OWN existing fill machinery: D$ allocates an ordinary MSHR entry (flagged
`mshr_is_prefetch`) only when otherwise idle and MSHR has a spare slot; I$ (no MSHR)
reuses its single fill FSM only when the cache is otherwise idle (a real hit this
cycle, no fill in progress). **No new bus-master port, no `MemoryController.v` change**
— this sidesteps the bus-preemption gap ADR 0043/0045 already flagged for a would-be
second master.

**Tech Stack:** Verilog-2005 (Icarus Verilog), Python 3 verification tooling
(`sim/tools/*.py`).

## Global Constraints (research-confirmed facts + locked-in design decisions)

- **Scope, confirmed via `AskUserQuestion`**: both I$ and D$ (not D$-only); all three
  techniques — next-line/stride/stream — as one swappable `PREFETCH_MODE` parameter
  (0=off/1/2/3), mirroring `REPLACEMENT_POLICY`'s exact shape; opportunistic reuse of
  existing MSHR/FSM machinery (no new bus master, no `MemoryController.v` change);
  fixed 1-line-ahead degree for every mode, no new tunable.
- **No PC available inside either cache today** (`design/ICache.v:80` / `design/DCache.v:85`
  — only the request's own address, confirmed by research). `Prefetcher.v` therefore
  tracks a SINGLE global last-address/stride entry, not a PC-indexed table — a real,
  deliberate simplification of a classical stride/stream prefetcher (most designs key
  off PC; this one keys off the raw miss-address stream instead, since no PC reaches
  this level without new pipeline plumbing that's out of scope for this phase).
  `# ponytail`-tagged in `Prefetcher.v` itself: table-of-1, PC-indexed table if a
  future phase threads PC into the caches and wants better multi-stream accuracy.
- **`Prefetcher.v` fires on demand-miss resolution only**, not every access — reuses
  each cache's own existing miss-detected condition (`DCache.v`'s `access_miss`,
  `ICache.v`'s own S_IDLE genuine-miss branch) as the update trigger. Zero new hooks
  into either cache's hit path.
- **`ICache.v` has NO bus port unless `L2_ENABLE=1`** (`design/ICache.v:75` — the
  `L2_ENABLE==0` branch is a private, always-combinational `InstructionMemory`
  instance with no real miss latency to hide). I$ prefetch is gated
  `PREFETCH_MODE != PF_OFF && L2_ENABLE` — a documented no-op otherwise, same
  "meaningless without X" convention `--compare-l2`/`--compare-burst` already use.
- **`icache_busy`/`icache_done` are dead wires in `riscvpipeline.v`**
  (`design/riscvpipeline.v:494,519-520` — declared, connected to `ICache`, never
  read anywhere else; confirmed by direct grep, zero other references).
  `pc_stall`'s own `icache_miss` term is purely `!icache_hit`-based
  (`design/riscvpipeline.v:2769`). This means an opportunistic I$ prefetch occupying
  `ICache.v`'s internal FSM is **externally invisible** to the pipeline as long as
  the CURRENT `readAddr` keeps hitting combinationally (the array read path
  `way_hit`/`inst_acc` is always live, independent of `state`) — no correctness risk,
  confirmed by tracing the actual consumers, not assumed.
- **D$: a demand miss racing an in-flight prefetch fill for a DIFFERENT line is
  already handled by Phase E's existing non-blocking MSHR machinery** (`mshr_room`/
  `mshr_busy_dispatch_miss`, `design/DCache.v:741-742`) — no new logic needed there.
  A demand ACCESS to the SAME line as an in-flight prefetch simply waits one extra
  cycle via the existing `mshr_addr_line_conflict` gate (`design/DCache.v:706-714`)
  until the prefetch's own fill lands, then hits normally next cycle — a documented,
  bounded, honest cost of "opportunistic, no preemption," not a bug.
- **I$: has no MSHR at all** — a demand miss racing an in-flight prefetch fill for a
  DIFFERENT line must wait for the single FSM to free up (bounded to `LINE_WORDS`
  cycles worst case) before its own miss can even be recognized. A real, honest,
  documented cost, worse than D$'s (D$ can overlap; I$ cannot) — flagged explicitly
  in the ADR's Future improvements, not silently accepted without noting it.
- **A prefetch must never evict a dirty D$ line.** `prefetch_fire` is gated
  `!pf_victim_is_dirty` — if the target set's chosen victim way is currently
  valid+dirty, the prefetch simply doesn't fire that cycle (re-evaluated next idle
  cycle against whatever the table predicts then). I$ has no dirty bit at all, so no
  equivalent guard is needed there — any I$ line is safe to evict.
  Prefetches are **read-only, always committed clean** (`dirty[...] <= mshr_is_write[...]`,
  which is `1'b0` for every prefetch entry since `a_is_write` is always passed `1'b0`) —
  `fence`'s existing whole-cache-flush logic needs ZERO changes; a prefetched line is
  an ordinary clean line to it, unlike the victim buffer's own documented fence gap.
- **Dedupe, both caches**: skip firing if the predicted line is already resident
  (an N-way tag/set compare against the predicted address, mirroring the inclusion
  probe port's own "second independent decode against an arbitrary address" pattern,
  `design/DCache.v:295-314` / `design/ICache.v:194-213`) or (D$ only) already the
  target of an outstanding MSHR entry (mirrors `mshr_addr_line_conflict`,
  `design/DCache.v:707-714`, computed a second time against the predicted tag/set).
- **`mshr_complete`/`resp_ready`/`resp_rdata`'s S_FILL arms must all explicitly
  exclude a completing prefetch entry** (`&& !mshr_is_prefetch[mshr_head_r]`) — a
  prefetch entry has no real caller waiting, so it must never accidentally satisfy a
  real request's `resp_ready`/`mshr_complete` pulse. The array-commit logic itself
  (writing `data_arr`/`valid`/`tag_arr`/`dirty`/`victim`/`age`) needs **no such
  exclusion** — it's correct and desired for a prefetch fill too, verbatim.
- **`mshr_alloc`'s existing 3-call-site "shared field-writer" task**
  (`design/DCache.v:823-858`, its own header comment explicitly anticipates being
  extended this way) gains one new `a_is_prefetch` input — the two EXISTING call
  sites (`design/DCache.v:942-949` busy-dispatch, `:1091-1098` fresh-dispatch) pass
  `1'b0`; the new prefetch-dispatch call site (this phase) passes `1'b1`.
- **`ICache.v`'s S_FILL completion logic needs ZERO changes for a prefetch fill** —
  unlike D$, I$ has no per-request completion signal at all (`busy`/`done` are the
  proven-dead wires above), so the exact same array-commit code that runs for a
  demand miss runs verbatim for a prefetch, correctly marking the line MRU on
  completion either way.
- **Testbench include-gap precedent**: every existing testbench that already
  `` `include``s `ICache.v` or `DCache.v` needs `` `include "Prefetcher.v"`` added too,
  or Icarus fails elaboration — the same class of bug Phase C (`VictimCache.v`) and
  Phase F (`L2Cache.v`) both hit. Fixed proactively in G5, not discovered reactively.
- **`iss.py` needs ZERO changes** (timing-only feature, same precedent every prior
  cache-family parameter established — confirmed by research: no cache-family
  parameter has ever been referenced in `iss.py`).
- **`random_gen.py` needs ZERO changes** (generator stays cache-agnostic, same
  precedent every prior cache-family parameter established).
- **Verification bar** (matches every prior Gen4 phase): full directed suite
  (`bash sim/run_tests.sh`), zero-warning `iverilog -Wall -g2005 -I design -tnull
  design/*.v`, constrained-random cross-check at real sample size across multiple
  axis combinations including prefetch combined with victim-cache/MSHR/L2/burst/MMU
  (those combos caught most of Phase E/F's own real bugs — do not skip them for a
  plain-axis-only sweep).

---

## G1: `Prefetcher.v` standalone + unit test

**Files:**
- Create: `design/Prefetcher.v`
- Create: `sim/tb/tb_prefetcher_unit.v`

**Interfaces:**
- Produces (consumed by every later task):
  ```verilog
  module Prefetcher #(
      parameter XLEN = 32,
      parameter LINE_BYTES = 16,
      parameter MODE = 0   // PF_OFF=0 / PF_NEXT_LINE=1 / PF_STRIDE=2 / PF_STREAM=3
  )(
      input clk, rst,
      input                  update_valid,  // pulses once per genuine demand miss
      input      [XLEN-1:0]  update_addr,   // that miss's line-aligned address
      output                 pf_valid,
      output     [XLEN-1:0]  pf_addr        // predicted next line-aligned address
  );
  ```

- [ ] **Step 1: Write `Prefetcher.v`.**
  ```verilog
  `default_nettype none

  // docs/adr/0046-hardware-prefetchers-phase-g.md (Generation 4, Phase G). A
  // single-global-entry address predictor -- NOT a PC-indexed table. Neither
  // ICache.v nor DCache.v has a per-access PC available at the point a miss
  // is recognized (confirmed by direct research before writing this module,
  // not assumed) -- adding one would mean new pipeline plumbing, out of scope
  // for this phase. # ponytail: table-of-1, keyed on the raw miss-address
  // stream, not per-PC -- upgrade to an N-entry PC-indexed table only if a
  // future phase threads PC into the caches and multi-stream interleaving
  // turns out to matter.
  //
  // Fires only on a genuine demand-miss (update_valid pulses once per real
  // miss, reusing each caller's own existing miss-detection condition) --
  // never on a hit. Fixed 1-line-ahead prediction for every mode (confirmed
  // via AskUserQuestion: no PREFETCH_DEGREE parameter, this project's own
  // tiny benchmark kernels can't meaningfully validate a different value
  // either way).
  module Prefetcher #(
      parameter XLEN = 32,
      parameter LINE_BYTES = 16,
      parameter MODE = 0
  )(
      input clk, rst,
      input                  update_valid,
      input      [XLEN-1:0]  update_addr,
      output                 pf_valid,
      output     [XLEN-1:0]  pf_addr
  );

  localparam PF_OFF       = 0;
  localparam PF_NEXT_LINE = 1;
  localparam PF_STRIDE    = 2;
  localparam PF_STREAM    = 3;

  // A stream is only trusted after this many CONSECUTIVE matching strides --
  // distinguishes a genuine sequential/strided pattern from a one-off
  // coincidental stride match. Stride mode (2) trusts a single match (needs
  // only the LAST two accesses); stream mode (3) needs a longer, more
  // confident run before it starts prefetching ahead -- same
  // more-confidence-for-a-stronger-claim distinction real HW stream
  // detectors make.
  localparam STREAM_CONFIRM_RUN = 2;

  reg                have_last_r;
  reg [XLEN-1:0]     last_addr_r;
  reg                have_stride_r;
  reg signed [XLEN-1:0] last_stride_r;
  reg [7:0]          run_count_r;   // consecutive matching strides, saturates informally (never realistically overflows at 8 bits for this project's own tiny test programs)

  wire signed [XLEN-1:0] new_stride = $signed(update_addr) - $signed(last_addr_r);
  wire stride_matches = have_stride_r && (new_stride == last_stride_r) && (new_stride != 0);

  always @(posedge clk) begin
      if (~rst) begin
          have_last_r   <= 1'b0;
          have_stride_r <= 1'b0;
          run_count_r   <= 8'd0;
          last_addr_r   <= {XLEN{1'b0}};
          last_stride_r <= {XLEN{1'b0}};
      end
      else if (update_valid) begin
          if (have_last_r) begin
              last_stride_r <= new_stride;
              have_stride_r <= 1'b1;
              run_count_r   <= stride_matches ? (run_count_r + 8'd1) : 8'd0;
          end
          last_addr_r <= update_addr;
          have_last_r <= 1'b1;
      end
  end

  wire [XLEN-1:0] next_line_addr = last_addr_r + LINE_BYTES[XLEN-1:0];
  wire [XLEN-1:0] strided_addr   = last_addr_r + last_stride_r[XLEN-1:0];

  assign pf_valid = (MODE == PF_NEXT_LINE) ? have_last_r
                   : (MODE == PF_STRIDE)   ? (have_stride_r && (new_stride == last_stride_r) && (last_stride_r != 0))
                   : (MODE == PF_STREAM)   ? (run_count_r >= STREAM_CONFIRM_RUN[7:0])
                   : 1'b0;
  assign pf_addr  = (MODE == PF_NEXT_LINE) ? next_line_addr : strided_addr;

  endmodule

  `default_nettype wire
  ```
  Note: `pf_valid`/`pf_addr` for stride/stream read the registers as they
  stand BEFORE this cycle's own `update_valid` (if any) is processed —
  correct, since a caller only ever samples `pf_valid`/`pf_addr` while idle,
  never on the exact same cycle `update_valid` pulses (a miss just got
  detected that same cycle, the FSM is about to go busy servicing IT, not a
  prefetch).
- [ ] **Step 2: Write `tb_prefetcher_unit.v`.** Standalone unit test, mirrors
  `tb_mshr_unit.v`'s own "drive inputs directly, check outputs" shape (no
  bus/mock needed — this module has no bus port at all). Cases:
  - `MODE=PF_OFF`: `pf_valid` stays 0 regardless of any `update_valid` pulses.
  - `MODE=PF_NEXT_LINE`: after one `update_valid` pulse at address `A`,
    `pf_valid=1` and `pf_addr == A + LINE_BYTES`; a second pulse at a
    completely unrelated address `B` updates `pf_addr` to `B + LINE_BYTES`
    (next-line never needs a stride, only the last address).
  - `MODE=PF_STRIDE`, single match: pulses at `A`, `A+2*LINE_BYTES` (stride
    `2*LINE_BYTES`) — after the SECOND pulse, `pf_valid=1`,
    `pf_addr == A+2*LINE_BYTES + 2*LINE_BYTES` is WRONG (only one stride seen
    so far, `have_stride_r` just became 1 but `new_stride==last_stride_r`
    can't yet be true from a single observation) — verify `pf_valid=0` after
    only 2 pulses, `pf_valid=1` and `pf_addr` correct only after a THIRD pulse
    continuing the same stride (`A+4*LINE_BYTES`).
  - `MODE=PF_STRIDE`, stride breaks: three pulses confirm a stride, a fourth
    pulse at an unrelated address — verify `pf_valid` drops back to 0 (the
    newly observed stride no longer matches `last_stride_r`) until two more
    consistent pulses re-confirm a new stride.
  - `MODE=PF_STREAM`: same 3-pulse sequence that made `PF_STRIDE` fire after
    pulse 3 — verify `PF_STREAM` does NOT yet fire (`STREAM_CONFIRM_RUN=2`
    needs 2 consecutive MATCHES, i.e. 3 matching strides total / 4 pulses),
    fires only after a 4th consistent pulse.
  - Reset mid-sequence: confirm `pf_valid` drops to 0 and state re-cold-starts
    (matches `PF_NEXT_LINE`'s own single-pulse-then-fires behavior again from
    scratch).
- [ ] **Step 3: Compile + run.**
  ```bash
  iverilog -g2005 -Wall -I design -o /tmp/pfu.vvp sim/tb/tb_prefetcher_unit.v && vvp /tmp/pfu.vvp
  ```
  Expected: all cases pass, zero warnings.
- [ ] **Step 4: Commit.**
  ```bash
  git add design/Prefetcher.v sim/tb/tb_prefetcher_unit.v
  git commit -m "feat: Prefetcher.v standalone address predictor (Generation 4, Phase G)"
  ```

---

## G2: `DCache.v` prefetch integration (MSHR-based)

**Files:**
- Modify: `design/DCache.v`

**Interfaces:**
- Consumes: `Prefetcher.v` (G1) exact port list.
- Produces: new parameter `PREFETCH_MODE = 0` on `DCache.v` — no new ports (fully
  internal; a prefetch never crosses this module's own boundary except via the
  existing `m_*` bus port it already drives for demand misses).

- [ ] **Step 1: `` `include "Prefetcher.v" `` and new parameter/localparams.**
  Add near the top of `design/DCache.v` (alongside the existing
  `` `include "wb_defs.vh" ``/`` `include "riscv_defs.vh" `` block) and add
  `parameter PREFETCH_MODE = 0` to the module's parameter list (alongside
  `MSHR_ENTRIES`), plus:
  ```verilog
  localparam PF_OFF       = 0;
  localparam PF_NEXT_LINE = 1;
  localparam PF_STRIDE    = 2;
  localparam PF_STREAM    = 3;
  ```
- [ ] **Step 2: Instantiate `Prefetcher.v` and decode its predicted address.**
  Place near the existing `VictimCache`/`age[]` declarations (after `hit`/
  `access_miss` are defined, since the update trigger reuses `access_miss`):
  ```verilog
  wire pf_valid_w;
  wire [XLEN-1:0] pf_addr_w;
  Prefetcher #(.XLEN(XLEN), .LINE_BYTES(LINE_BYTES), .MODE(PREFETCH_MODE)) m_prefetcher(
      .clk(clk), .rst(rst),
      .update_valid(access_miss),
      .update_addr({req_addr[XLEN-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}}),
      .pf_valid(pf_valid_w), .pf_addr(pf_addr_w)
  );

  // Second, independent tag/set decode against the PREDICTED address --
  // same "arbitrary address, not req_addr" pattern the inclusion probe port
  // already establishes (see probe_tag/probe_set_idx above).
  wire [SET_BITS-1:0] pf_set_idx;
  generate
  if (SET_BITS == 0) begin : gen_pf_set_idx_fully_assoc
      assign pf_set_idx = 1'b0;
  end else begin : gen_pf_set_idx_normal
      assign pf_set_idx = pf_addr_w[OFFSET_BITS+SET_BITS-1:OFFSET_BITS];
  end
  endgenerate
  wire [TAG_BITS-1:0] pf_tag = pf_addr_w[XLEN-1:OFFSET_BITS+SET_BITS];

  wire [WAYS-1:0] pf_way_hit;
  generate
      for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_pf_compare
          assign pf_way_hit[gw] = valid[pf_set_idx*WAYS + gw] && (tag_arr[pf_set_idx*WAYS + gw] == pf_tag);
      end
  endgenerate
  wire pf_found = |pf_way_hit;

  // Same conflict check mshr_addr_line_conflict already performs against
  // req_addr's own tag/set, mirrored here against the PREDICTED tag/set.
  wire [MSHR_ENTRIES-1:0] pf_mshr_line_match;
  generate
      for (gm = 0; gm < MSHR_ENTRIES; gm = gm + 1) begin : gen_pf_mshr_conflict
          assign pf_mshr_line_match[gm] = mshr_valid[gm] && (mshr_tag[gm] == pf_tag) && (mshr_set[gm] == pf_set_idx);
      end
  endgenerate
  wire pf_mshr_conflict = |pf_mshr_line_match;

  // Victim-way choice for the PREDICTED set -- same POLICY_LRU/round-robin
  // choice victim_target_way already makes for req_addr's own set, mirrored
  // for pf_set_idx (age[]/victim[] are indexed by set, this just reads a
  // different set's own entries).
  wire [WAYS-1:0]     pf_is_lru_way;
  wire [WAY_BITS-1:0] pf_lru_way_acc [0:WAYS];
  assign pf_lru_way_acc[0] = {WAY_BITS{1'b0}};
  generate
      for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_pf_lru_victim
          assign pf_is_lru_way[gw]    = (age[pf_set_idx][gw] == WAYS-1);
          assign pf_lru_way_acc[gw+1] = pf_lru_way_acc[gw] | (pf_is_lru_way[gw] ? gw[WAY_BITS-1:0] : {WAY_BITS{1'b0}});
      end
  endgenerate
  wire [WAY_BITS-1:0] pf_victim_way = (REPLACEMENT_POLICY == POLICY_LRU) ? pf_lru_way_acc[WAYS] : victim[pf_set_idx];
  wire pf_victim_is_dirty = valid[pf_set_idx*WAYS + pf_victim_way] && dirty[pf_set_idx*WAYS + pf_victim_way];

  // A prefetch never fires without a spare MSHR slot to hold it non-
  // blockingly -- MSHR_ENTRIES==1 permanently disables prefetching (a solo
  // prefetch would otherwise block a real access with no way to overlap it,
  // see Global Constraints). Never evicts a dirty line, never targets an
  // already-resident or already-in-flight line.
  wire prefetch_fire = (PREFETCH_MODE != PF_OFF) && (MSHR_ENTRIES > 1)
      && pf_valid_w && !pf_found && !pf_mshr_conflict && !pf_victim_is_dirty
      && (mshr_count_r < MSHR_ENTRIES);
  ```
- [ ] **Step 3: `mshr_is_prefetch[]` array + reset.** Add
  `reg mshr_is_prefetch [0:MSHR_ENTRIES-1];` alongside the other `mshr_*[]`
  declarations, and reset it to 0 alongside `mshr_valid`'s own reset loop
  (`for (reset_m = 0; reset_m < MSHR_ENTRIES; reset_m = reset_m + 1)
  mshr_is_prefetch[reset_m] <= 1'b0;`).
- [ ] **Step 4: Extend `mshr_alloc`'s signature and both existing call
  sites.** Add `input a_is_prefetch;` to the task's input list and
  `mshr_is_prefetch[slot] <= a_is_prefetch;` to its body. Update the TWO
  existing call sites to pass `1'b0` as the new final argument: the
  busy-dispatch call (currently ending `..., 1'b1);` — becomes
  `..., 1'b1, 1'b0);`) and the fresh-dispatch call (currently ending
  `..., mshr_fresh_load_miss);` — becomes `..., mshr_fresh_load_miss, 1'b0);`).
- [ ] **Step 5: New S_IDLE dispatch arm.** In the `case(state)` `S_IDLE`
  block, add a third arm after the existing `if (flush_all...) ... else if
  (req_read || req_write) ... `:
  ```verilog
  else if (prefetch_fire) begin
      mshr_alloc(mshr_tail_r, pf_set_idx, pf_victim_way, pf_tag, pf_addr_w,
                 {WORD_OFF_BITS{1'b0}}, 2'b00, 3'b010, 5'b0, {XLEN{1'b0}},
                 1'b0, {XLEN{1'b0}},           // never a write, no write data
                 1'b0, {LINE_IDX_BITS{1'b0}}, {XLEN{1'b0}},  // never needs a writeback -- prefetch_fire already excludes a dirty victim
                 1'b1,                          // early-retired -- irrelevant, mshr_complete/resp_ready/resp_rdata separately exclude mshr_is_prefetch below regardless
                 1'b1);                         // a_is_prefetch
      mshr_count_r  <= mshr_count_r + 1'b1;
      mshr_tail_r   <= (mshr_tail_r == MSHR_ENTRIES-1) ? {MSHR_IDX_BITS{1'b0}} : mshr_tail_r + 1'b1;
      vwb_pending_r <= 1'b0;
      vwb_active_r  <= 1'b0;
      fill_word_r   <= {WORD_OFF_BITS{1'b0}};
      state         <= S_FILL;
  end
  ```
- [ ] **Step 6: Exclude a completing prefetch from resp_ready/resp_rdata/
  mshr_complete.** Three edits:
  - `assign mshr_complete = (state == S_FILL) && m_ack && fill_is_last_word && mshr_early_retired[mshr_head_r] && !mshr_is_prefetch[mshr_head_r];`
  - `resp_ready`'s S_FILL disjunct gains `&& !mshr_is_prefetch[mshr_head_r]`
    right after its existing `!mshr_early_retired[mshr_head_r]` term.
  - `resp_rdata`'s S_FILL ternary condition gains the identical
    `&& !mshr_is_prefetch[mshr_head_r]` term.
  Do NOT touch the S_FILL array-commit logic itself (`data_arr`/`valid`/
  `tag_arr`/`dirty`/`victim`/`age`/`mshr_count_after_complete` machinery) —
  it is correct verbatim for a prefetch entry (commits clean, since
  `mshr_is_write[mshr_head_r]` is `1'b0` for every prefetch entry).
- [ ] **Step 7: Regression.** `PREFETCH_MODE` defaults to 0 (`PF_OFF`), which
  makes `prefetch_fire` permanently false — run the full existing directed
  suite (`bash sim/run_tests.sh`) and zero-warning compile
  (`iverilog -Wall -g2005 -I design -tnull design/*.v`); must be 100%
  unchanged, zero new failures/warnings.
- [ ] **Step 8: Commit.**
  ```bash
  git add design/DCache.v
  git commit -m "feat: DCache.v opportunistic prefetch via MSHR (Generation 4, Phase G)"
  ```

---

## G3: `ICache.v` prefetch integration (opportunistic FSM reuse)

**Files:**
- Modify: `design/ICache.v`

**Interfaces:**
- Consumes: `Prefetcher.v` (G1).
- Produces: new parameter `PREFETCH_MODE = 0` on `ICache.v` — no new ports.

- [ ] **Step 1: `` `include``, parameter, localparams** — same shape as G2 Step 1.
- [ ] **Step 2: Instantiate `Prefetcher.v` + decode.** Same pattern as G2
  Step 2 but simpler (no MSHR, no dirty bit):
  ```verilog
  wire icache_pf_update_valid = (state == S_IDLE) && !hit_main && !vc_lookup_hit;
  wire [XLEN-1:0] icache_pf_update_addr = {readAddr[XLEN-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
  wire pf_valid_w;
  wire [XLEN-1:0] pf_addr_w;
  Prefetcher #(.XLEN(XLEN), .LINE_BYTES(LINE_BYTES), .MODE(PREFETCH_MODE)) m_prefetcher(
      .clk(clk), .rst(rst),
      .update_valid(icache_pf_update_valid),
      .update_addr(icache_pf_update_addr),
      .pf_valid(pf_valid_w), .pf_addr(pf_addr_w)
  );

  wire [SET_BITS-1:0] pf_set_idx;
  generate
  if (SET_BITS == 0) begin : gen_pf_set_idx_fully_assoc
      assign pf_set_idx = 1'b0;
  end else begin : gen_pf_set_idx_normal
      assign pf_set_idx = pf_addr_w[OFFSET_BITS+SET_BITS-1:OFFSET_BITS];
  end
  endgenerate
  wire [TAG_BITS-1:0] pf_tag = pf_addr_w[XLEN-1:OFFSET_BITS+SET_BITS];

  wire [WAYS-1:0] pf_way_hit;
  generate
      for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_pf_compare
          assign pf_way_hit[gw] = valid[pf_set_idx*WAYS + gw] && (tag_arr[pf_set_idx*WAYS + gw] == pf_tag);
      end
  endgenerate
  wire pf_found = |pf_way_hit;

  wire [WAYS-1:0]     pf_is_lru_way;
  wire [WAY_BITS-1:0] pf_lru_way_acc [0:WAYS];
  assign pf_lru_way_acc[0] = {WAY_BITS{1'b0}};
  generate
      for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_pf_lru_victim
          assign pf_is_lru_way[gw]    = (age[pf_set_idx][gw] == WAYS-1);
          assign pf_lru_way_acc[gw+1] = pf_lru_way_acc[gw] | (pf_is_lru_way[gw] ? gw[WAY_BITS-1:0] : {WAY_BITS{1'b0}});
      end
  endgenerate
  wire [WAY_BITS-1:0] pf_victim_way = (REPLACEMENT_POLICY == POLICY_LRU) ? pf_lru_way_acc[WAYS] : victim[pf_set_idx];

  // No dirty guard needed -- I$ has no dirty bit, any line is safe to evict.
  // Gated on L2_ENABLE: under L2_ENABLE=0 there's no real miss latency to
  // hide (private InstructionMemory is always-combinational), so prefetching
  // there would only cost FSM-busy cycles for no benefit -- documented no-op.
  wire prefetch_fire = (PREFETCH_MODE != PF_OFF) && L2_ENABLE && pf_valid_w && !pf_found;
  ```
- [ ] **Step 3: New S_IDLE dispatch arm.** Change the existing
  ```verilog
  S_IDLE: begin
      if (!hit_main) begin
          ...
      end
  end
  ```
  to:
  ```verilog
  S_IDLE: begin
      if (!hit_main) begin
          ...   // unchanged -- promote or genuine-miss fork
      end
      else if (prefetch_fire) begin
          fill_set_r  <= pf_set_idx;
          fill_tag_r  <= pf_tag;
          fill_way_r  <= pf_victim_way;
          fill_base_r <= pf_addr_w;
          fill_word_r <= {WORD_OFF_BITS{1'b0}};
          busy_r      <= 1'b1;
          state       <= S_FILL;
      end
  end
  ```
  No other change needed — S_FILL's own completion logic (data_arr/valid/
  tag_arr/victim/age commit, `done_r<=1'b1`) runs verbatim for this fill,
  correctly marking the prefetched line MRU on completion. `busy_r`/`done_r`
  pulsing for a prefetch is externally inert (see Global Constraints).
- [ ] **Step 4: Regression.** `PREFETCH_MODE` defaults to 0 — full directed
  suite + zero-warning compile, 100% unchanged.
- [ ] **Step 5: Commit.**
  ```bash
  git add design/ICache.v
  git commit -m "feat: ICache.v opportunistic prefetch, L2_ENABLE-gated (Generation 4, Phase G)"
  ```

---

## G4: Wire `PREFETCH_MODE` live in `riscvpipeline.v` + testbench-include audit

**Files:**
- Modify: `design/riscvpipeline.v`
- Modify: every existing `sim/tb/*.v` file that already `` `include``s `ICache.v` or
  `DCache.v` (grep-discovered, real list at implementation time)

- [ ] **Step 1: New top-level parameter.** Add `parameter PREFETCH_MODE = 0`
  to `riscvpipeline.v`'s own parameter list, same declaration style as
  `VICTIM_ENTRIES`/`MSHR_ENTRIES`/`L2_SIZE_BYTES`.
- [ ] **Step 2: Pass through at both instantiation sites.** Add
  `.PREFETCH_MODE(PREFETCH_MODE)` to the `ICache` instantiation
  (`design/riscvpipeline.v:514` region) and the `DCache` instantiation
  (`design/riscvpipeline.v:3071-3103` region).
- [ ] **Step 3: Regression FIRST.** `PREFETCH_MODE` defaults to 0 — run the
  full directed suite and zero-warning compile; must be 100% bit-identical,
  zero new failures. Do not proceed to Step 4 until clean.
- [ ] **Step 4: Include-fix sweep.**
  ```bash
  for f in $(grep -l '`include.*\(ICache\|DCache\)\.v' sim/tb/*.v); do
      grep -q '`include.*Prefetcher' "$f" || echo "$f"
  done
  ```
  For every file listed, add `` `include "Prefetcher.v"`` immediately after
  its existing `` `include "ICache.v"``/`` `include "DCache.v"`` line.
- [ ] **Step 5: Full directed suite + zero-warning compile**, confirming the
  include sweep didn't disturb anything.
- [ ] **Step 6: Commit.**
  ```bash
  git add design/riscvpipeline.v sim/tb/*.v
  git commit -m "feat: wire PREFETCH_MODE live, I\$+D\$ (Generation 4, Phase G)"
  ```

---

## G5: End-to-end directed test

**Files:**
- Create: `sim/programs/cache_prefetch_g1.s`
- Create: `sim/tb/tb_cache_prefetch_g1.v`

**Interfaces:**
- Consumes: `riscvpipeline.v` with `PREFETCH_MODE` live (G4).

- [ ] **Step 1: Write `sim/programs/cache_prefetch_g1.s`.** A hand-built
  program with a real strided D$ access pattern: N loads from addresses
  `base, base+STRIDE, base+2*STRIDE, ...` (STRIDE a multiple of
  `DCACHE_LINE_BYTES` so each access is a genuine, distinct-line miss the
  first time), repeated in a SECOND pass over the exact same addresses —
  at `PREFETCH_MODE=PF_STRIDE` (or `PF_STREAM`, whichever the testbench
  parameterizes), the third-and-later first-pass accesses should already be
  prefetched by the time the CPU's own demand access reaches them (a real
  hit-instead-of-miss, not just "still correct"). Use at least 5 distinct
  strided addresses so `PF_STREAM`'s own `STREAM_CONFIRM_RUN=2` threshold has
  a chance to confirm before the pattern ends.
- [ ] **Step 2: Write `tb_cache_prefetch_g1.v`.** Mirrors `tb_cache_mshr_e1.v`'s
  own shape (a real worked example proving both correctness AND a measured
  cycle-count win): instantiates `PIPELINED` at `PREFETCH_MODE=0` (today's
  behavior) vs `PREFETCH_MODE=PF_STRIDE` (or `PF_STREAM`), with
  `MSHR_ENTRIES=2` (required — `MSHR_ENTRIES=1` permanently disables D$
  prefetching, see Global Constraints) and `MEM_LATENCY_D` set explicitly to
  a nonzero value (a real prefetch win only shows up when there's real
  backing-store latency to hide, matching `tb_cache_l2_f1.v`'s own precedent
  of not relying on the default). Checks final register/memory state matches
  expected at BOTH settings (correctness), and reports the cycle-count delta
  (expected: fewer cycles at `PREFETCH_MODE!=0`, since the second-pass
  strided reloads should now hit).
- [ ] **Step 3: Compile + run both new files**, zero warnings.
  ```bash
  iverilog -g2005 -Wall -I design -I sim/tb -o /tmp/pfg1.vvp sim/tb/tb_cache_prefetch_g1.v && vvp /tmp/pfg1.vvp
  ```
- [ ] **Step 4: Commit.**
  ```bash
  git add sim/programs/cache_prefetch_g1.s sim/tb/tb_cache_prefetch_g1.v
  git commit -m "test: end-to-end prefetch correctness + cycle-count proof (Generation 4, Phase G)"
  ```

---

## G6: Tooling — `run_random_tests.py` / `bench_runner.py`

**Files:**
- Modify: `sim/tools/run_random_tests.py`
- Modify: `sim/tools/bench_runner.py`

- [ ] **Step 1: `run_random_tests.py` new flag.** `--prefetch-mode` (int,
  `{0,1,2,3}`, default 0) — same `.replace("__TOKEN__", ...)` template-
  substitution mechanism every existing cache-family flag already uses
  (`sim/tools/run_random_tests.py:227-286` region, same pattern
  `--victim-entries`/`--mshr-entries` follow). No-op unless `--cache-mode 1`
  AND `--mshr-entries` > 1 (documented in the flag's own help text — D$
  prefetching is inert at `MSHR_ENTRIES<=1`, see Global Constraints). Thread
  it into `run_one()`'s kwargs and the template substitution
  (`__PREFETCH_MODE__`), and into `main()`'s `run_one(...)` call.
- [ ] **Step 2: `bench_runner.py --compare-prefetch`.** Same 4-place template
  every existing `--compare-*` flag follows (argparse mutually-exclusive
  flag, a forcing block setting `cache_mode=1`/`mshr_entries=2` and a
  nonzero `prefetch_mode` default if unset, one more tuple element in every
  `pairs`/unpack site, a `"prefetch"` entry in `labels`).
- [ ] **Step 3: Full directed suite + zero-warning compile**, confirming no
  regression from the tooling changes (tooling doesn't touch RTL, but
  confirms nothing else broke).
- [ ] **Step 4: Commit.**
  ```bash
  git add sim/tools/run_random_tests.py sim/tools/bench_runner.py
  git commit -m "feat: --prefetch-mode / --compare-prefetch tooling (Generation 4, Phase G)"
  ```

---

## G7: Constrained-random cross-check + benchmark measurement

- [ ] **Step 1: Constrained-random cross-check**, real sample size (200+)
  across axis combinations mirroring Phase F's own 5-combo bar: default
  prefetch off (regression), `--prefetch-mode 1/2/3` alone (`--mshr-entries 2`
  required), prefetch+victim-cache, prefetch+L2, prefetch+burst+real-latency,
  prefetch+MMU.
  ```bash
  python sim/tools/run_random_tests.py --count 200 --iverilog-dir /c/iverilog/bin --cache-mode 1 --mshr-entries 2 --prefetch-mode 1
  ```
  (repeat per mode/combo per the list above). Fix any real bug found before
  proceeding — do not skip a failing combo.
- [ ] **Step 2: `bench_runner.py --compare-prefetch` real run** against
  `sim/benchmarks/bench_*.s` — report the real delta honestly, whatever it
  is (every prior cache-family phase found near-zero on these tiny kernels;
  don't assume this one differs without actually running it).
- [ ] **Step 3: Full directed suite + zero-warning compile**, final
  confirmation before writing the ADR.

---

## G8: ADR, docs update, Gen4 closure

**Files:**
- Create: `docs/adr/0046-hardware-prefetchers-phase-g.md`
- Modify: `docs/ROADMAP_VISION.md`, `docs/ROADMAP.md`, `handoff.md`

- [ ] **Step 1: `docs/adr/0046-hardware-prefetchers-phase-g.md`**, mirroring
  the exact 6-section structure `docs/adr/0041`-`0045` all use verbatim:
  `## Problem` → `## Design` → `## Real bugs/findings` → `## Alternatives
  considered` → `## Validation strategy` → `## Future improvements`. Future
  improvements must explicitly list: single-global-entry predictor, not
  PC-indexed (no PC available in either cache today); fixed 1-line-ahead
  degree, no `PREFETCH_DEGREE` parameter; D$ prefetch requires
  `MSHR_ENTRIES>1`; I$ prefetch requires `L2_ENABLE=1`; no cross-cache
  prefetch (D$ misses never trigger an I$ prefetch or vice versa); I$'s own
  demand-miss-races-a-prefetch cost is worse than D$'s (no MSHR to overlap).
- [ ] **Step 2: `docs/ROADMAP_VISION.md`/`docs/ROADMAP.md`/`handoff.md`** —
  narrowly update the Generation 4 section (prefetchers line moves from
  "unscoped" to done), and **declare Generation 4 (Advanced Memory
  Architecture v4.0) CLOSED** — this was the sole remaining item.
- [ ] **Step 3: Update memory** (`redesign_status.md`).
- [ ] **Step 4: Ask the user about committing** the docs+ADR commit (matches
  this project's own established "ask, don't assume" convention for a
  closing commit).

---

## Self-Review Notes (spec coverage / consistency check performed before handoff)

- Every Global-Constraints decision (both caches, all 3 modes, opportunistic
  reuse of existing MSHR/FSM, no new bus master, fixed degree=1,
  never-evict-dirty, dedupe, exclude-prefetch-from-real-completion-signals)
  has a task that implements it: G1 (predictor), G2 (D$), G3 (I$), G4 (wire
  live + include audit), G5 (end-to-end test), G6 (tooling), G7
  (verification), G8 (ADR + closure).
- Signal names are consistent across tasks: `Prefetcher.v`'s `pf_valid`/
  `pf_addr` port names (fixed in G1) are used identically in G2 and G3.
  `mshr_is_prefetch[]` (introduced in G2 Step 3) is the exact name used in
  G2 Steps 4/5/6. `PREFETCH_MODE`/`PF_OFF`/`PF_NEXT_LINE`/`PF_STRIDE`/
  `PF_STREAM` are the exact names used in G2, G3, and G4's parameter
  pass-through.
- No task references a type/signal not defined in an earlier task.
