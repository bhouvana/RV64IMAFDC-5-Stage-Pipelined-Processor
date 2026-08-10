# Generation 4, Phase F: L2 Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A shared, inclusive L2 cache sitting behind both I$ and D$ (one reusable
`design/L2Cache.v`, two instances), closing the last unscoped item in Generation 4's
"Advanced cache hierarchy" line before hardware prefetchers (the final Gen4 item).

**Architecture:** `design/L2Cache.v` is a Wishbone-slave-in/Wishbone-master-out cache,
closely modeled on `DCache.v`'s own proven S_IDLE/S_HIT_RD/S_WB/S_FILL shape (no MSHR,
no victim buffer, no burst-CTI generation this phase — deliberate scope cuts, same
incremental-phase discipline every prior Gen4 axis followed). One instance splices
between `DCache.v`'s existing `m_*` port and `MemoryController.v`'s `dcache_*` arm;
the other splices between a **new** bus-master port on `ICache.v` (it has none today)
and a **new** `InstructionMemoryWishboneAdapter.v` (mirrors `RamWishboneAdapter.v`,
wraps the existing private `InstructionMemory.v`). Inclusion is enforced by an
unconditional probe-before-evict handshake into whichever L1 owns that line — L2
never trusts its own bookkeeping about what L1 currently holds; L1's probe response
is always authoritative (a ponytail-simplified design: no `present_in_l1` tracking
bit at all, every L2 eviction of a valid line probes L1 unconditionally — bounded
performance cost, zero correctness risk, removes a whole tracking mechanism).

**Tech Stack:** Verilog-2005 (Icarus Verilog), Python 3 verification tooling
(`sim/tools/*.py`), existing `sim/tb/*.v` testbench conventions.

## Global Constraints (research-confirmed facts + locked-in design decisions)

- **Scope, confirmed via `AskUserQuestion`**: shared I$+D$ (not D$-only), inclusive
  (not non-inclusive), independent `L2_REPLACEMENT_POLICY` (not shared with L1's).
- **One module, two instances** — mirrors `VictimCache.v`'s own "one implementation
  shared by both I$/D$" precedent (docs/adr/0042). This project's I$/D$ backing
  stores are physically separate arrays (Harvard-style) — "shared" means code reuse
  via one parameterized module, never a literally-unified address space.
- **`DCache.v`'s current bus port** (`design/DCache.v:142-151`): `m_cyc, m_stb, m_we,
  m_addr, m_data_o, m_sel, m_funct3, m_cti` out; `m_data_i, m_ack` in. Feeds
  `MemoryController.v`'s `dcache_*` arm today (`riscvpipeline.v:3097-3101`). D-side
  L2 instance splices in here — **zero DCache.v FSM changes needed for basic L2
  hit/miss** (DCache.v already just drives a Wishbone-master port and expects
  `m_data_i`/`m_ack` back; L2Cache.v presents an identical slave-side shape).
- **`ICache.v` has NO bus port today** (`design/ICache.v:66-75` — only
  `readAddr/inst/hit/busy/done`). Its private `InstructionMemory` instance
  (`design/ICache.v:262-265`) is read combinationally, no wait states, no bus
  protocol at all. Confirmed: I$'s backing store never goes through
  `MemoryController.v`/`WbDecoder.v` — fully private. The I-side L2 instance's own
  downstream `m_*` port connects **directly, point-to-point** to a new
  `InstructionMemoryWishboneAdapter.v` instance — no shared-bus involvement.
- **`RamWishboneAdapter.v`'s ack pattern is the required precedent to mirror, not
  reinvent** (`design/RamWishboneAdapter.v`): a stuck LEVEL ack (not edge-detected
  per-transaction) silently corrupted every word after the first in a multi-word
  fill — a real bug found in Phase D (docs/adr/0043), invisible until non-zero data
  was involved. `L2Cache.v`'s own slave-port ack logic and the new
  `InstructionMemoryWishboneAdapter.v` must use real per-transaction edge detection
  (`is_new_request`-style, `RamWishboneAdapter.v`'s own `req_active_r` idiom), not a
  bare level — **do not repeat this bug.**
- **`MemoryController.v`'s bus port** (`design/MemoryController.v:52-62`):
  `dcache_cyc, dcache_stb, dcache_we, dcache_addr, dcache_data_o, dcache_sel,
  dcache_funct3, dcache_cti` in — this exact shape is what D-side L2Cache.v's own
  downstream `m_*` port must present.
- **`VictimCache.v`'s port-naming convention** (`design/VictimCache.v:57-88`) is the
  template for `L2Cache.v`'s own probe port: a passive/pulsed-handshake shape, not a
  raw Wishbone transaction, since a probe is point-to-point into a *specific*
  module instance, not a bus transaction.
- **No `present_in_l1` tracking bit.** L2 unconditionally probes L1 before evicting
  ANY valid line (not just ones L2 believes are L1-resident). L1's probe response is
  authoritative regardless of what L2 thought — a stale/over-eager probe costs one
  handshake round-trip (performance only), never a correctness gap. This removes an
  entire bookkeeping mechanism (three separate event sites to keep it accurate) for
  a bounded, honest, documented cost — same `# ponytail`-style tradeoff
  `VictimCache.v`'s own FIFO-only replacement comment already establishes precedent
  for in this codebase.
- **Every word of an L1→L2 multi-word transfer is independently re-evaluated against
  L2's own array**, exactly the way `DCache.v` already independently re-evaluates
  every CPU-side `req_addr` each cycle regardless of `state` — **no separate
  multi-word-transaction tracking is needed in `L2Cache.v`** beyond the per-word ack
  edge-detection above. L1 holds `u_cyc`/`u_stb` continuously across a whole line's
  worth of words (mirrors `DCache.v`'s own `m_cyc = (state==S_WB)||(state==S_FILL)`
  hold-through-the-whole-transfer shape) and just changes `u_addr` between words;
  once the FIRST word of a line resolves hit-or-miss, every subsequent same-line
  word is trivially a hit against the now-resident line.
- **L2's own line size matches whichever L1 it serves** (`L2Cache.v`'s
  `LINE_BYTES` parameter is set per-instantiation to `ICACHE_LINE_BYTES` /
  `DCACHE_LINE_BYTES` respectively) — avoids the real complexity of a wider L2 line
  needing multiple L1-line-sized backing-store fetches per L2 miss. Documented
  scope cut, not enforced by an RTL assertion (matches how `WAYS >= 2` is documented,
  not enforced, in `ICache.v`/`DCache.v` today).
- **L2's own downstream bus traffic is always `CTI_CLASSIC`** this phase — no
  burst-CTI generation on L2's own master port (deferred, "Future improvements";
  `BURST_ENABLE` arrived as its own dedicated Phase D, matching precedent for
  bundling this later rather than now).
- **New top-level `riscvpipeline.v` parameters**: `L2_SIZE_BYTES` (0 = disabled,
  bit-identical to pre-Phase-F behavior for BOTH I$ and D$ — no new bus ports even
  elaborate at 0, via `generate`), `L2_WAYS`, `L2_REPLACEMENT_POLICY` (independent
  of L1's `REPLACEMENT_POLICY`, per the confirmed scope decision). No separate
  `L2_LINE_BYTES` — each instance inherits its own L1's line size directly (see
  above).
- **`ICache.v` gains a new `L2_ENABLE` parameter** (0 = today's exact private-
  `InstructionMemory`-FSM path, byte-for-byte unchanged; 1 = drive the new
  Wishbone-master path instead). `riscvpipeline.v` passes
  `.L2_ENABLE(L2_SIZE_BYTES != 0)` at its own `ICache` instantiation.
- **Testbench include-gap precedent**: every existing testbench that already
  `` `include``s `DCache.v` will need `` `include "L2Cache.v"`` (and, once wired live,
  `` `include "InstructionMemoryWishboneAdapter.v"``) added too, or Icarus fails
  elaboration — the exact same class of bug Phase C (`VictimCache.v`) and Phase E
  (`Scoreboard.v`) both hit. Fixed proactively in F8, not discovered reactively.
- **Verification bar** (matches every prior Gen4 phase): full directed suite
  (`bash sim/run_tests.sh`), zero-warning `iverilog -Wall -g2005 -I design -tnull
  design/*.v`, constrained-random cross-check (`python sim/tools/run_random_tests.py
  --count N --iverilog-dir /c/iverilog/bin`) at real sample size across multiple
  axis combinations including L2 combined with victim-cache/MSHR/burst/MMU (those
  combos caught 4 of Phase E's 6 real bugs — do not skip them for a plain-axis-only
  sweep).

---

## F1: `L2Cache.v` standalone core (no probe port exercised yet)

**Files:**
- Create: `design/L2Cache.v`
- Create: `sim/tb/tb_l2cache_unit.v`

**Interfaces:**
- Produces (consumed by every later task):
  ```verilog
  module L2Cache #(
      parameter XLEN = 32,
      parameter WAYS = 4,
      parameter CACHE_SIZE_BYTES = 8192,
      parameter LINE_BYTES = 16,       // must match the serving L1's own LINE_BYTES
      parameter REPLACEMENT_POLICY = 0, // POLICY_ROUND_ROBIN=0/POLICY_FIFO=1/POLICY_LRU=2, same enum as DCache.v
      parameter WITH_DIRTY = 1         // 0 for the I-side instance (read-only, no writeback ever), 1 for D-side
  )(
      input clk, rst,
      // Upstream slave port -- Wishbone-shaped, facing the L1 cache's own
      // existing m_* Wishbone-master output (DCache.v's shape exactly).
      input                          u_cyc, u_stb, u_we,
      input      [XLEN-1:0]          u_addr, u_data_o,
      input      [`WB_SEL_WIDTH-1:0] u_sel,
      input      [2:0]               u_funct3,
      output     [XLEN-1:0]          u_data_i,
      output                         u_ack,
      // Downstream master port -- Wishbone-shaped, facing MemoryController.v
      // (D-side instance) or InstructionMemoryWishboneAdapter.v (I-side instance).
      output                         m_cyc, m_stb, m_we,
      output     [XLEN-1:0]          m_addr, m_data_o,
      output     [`WB_SEL_WIDTH-1:0] m_sel,
      output     [2:0]               m_funct3,
      input      [XLEN-1:0]          m_data_i,
      input                          m_ack,
      // Inclusion probe port -- added in F2, declared here so F1's port list is
      // final (tie probe_ack=0/probe_dirty=0/probe_data=0 in F1's own testbench,
      // unused by F1's own test cases).
      output                         probe_req,
      output     [XLEN-1:0]          probe_addr,
      input                          probe_ack,
      input                          probe_dirty,
      input      [XLEN*(LINE_BYTES/4)-1:0] probe_data,
      // Perf taps, mirrors DCache.v's own access_hit/access_miss precedent
      // (docs/adr/0025) -- exactly-once-per-real-access.
      output                         access_hit,
      output                         access_miss
  );
  ```
- Internal FSM states (localparam, same pattern as `DCache.v`):
  `S_IDLE`, `S_HIT_RD`, `S_PROBE_WAIT` (F2), `S_WB`, `S_FILL`.
- Array shape: `valid[]`, `dirty[]` (only meaningful if `WITH_DIRTY`), `tag_arr[]`,
  `data_arr[]`, `victim[]`/`age[]` (round-robin/LRU per-set replacement), same
  `set_idx`/`tag`/`word_off` decomposition `DCache.v:167-209` already uses,
  parameterized off `LINE_BYTES`/`CACHE_SIZE_BYTES`/`WAYS` identically.

- [ ] **Step 1: Write `L2Cache.v`'s S_IDLE/S_HIT_RD/S_WB/S_FILL core**, adapted
  directly from `DCache.v:191-1186`'s own proven shape but with the MSHR array,
  victim-cache instantiation, and burst-CTI logic all removed (blocking,
  single-outstanding, always `CTI_CLASSIC` downstream — per Global Constraints).
  `u_cyc && u_stb && !u_we` maps to `DCache.v`'s own `req_read`; `u_we` to
  `req_write`; `u_data_o`/`u_addr` to `req_wdata`/`req_addr`; `u_ack` to
  `resp_ready`; `u_data_i` to `resp_rdata`. A write-hit (`WITH_DIRTY` only —
  I-side instance never receives `u_we=1` in practice, but the write path must
  still compile safely at `WITH_DIRTY=0`, ack combinationally, no-op on the
  array) merges `u_data_o` into `data_arr` and marks `dirty=1`, acking the same
  cycle. A write-miss (defensive fallback — should be unreachable given every
  real upstream write is a writeback of a line the inclusion invariant says L2
  already holds, but must still behave safely if it somehow occurs) falls
  through to the same write-allocate-via-fill-merge technique `DCache.v`'s own
  `fill_do_merge`/`fill_value` already implements (`design/DCache.v:586-589`).
  `access_hit`/`access_miss` mirror `DCache.v:377-380`'s own exactly-once
  discipline. For F1, tie `probe_req` internally to never fire (eviction always
  goes straight to `S_WB`/`S_FILL` with no probe wait) — F2 adds the real probe
  branch.
- [ ] **Step 2: Write `tb_l2cache_unit.v`** — standalone unit test, mirrors
  `tb_mshr_unit.v`/`tb_scoreboard_unit.v`'s own "test the module in isolation with
  a small behavioral mock on its downstream port" shape. Mock the `m_*` downstream
  port with a tiny in-testbench behavioral memory (ack every request 1 cycle
  after `m_cyc&&m_stb`, return a known pattern indexed by `m_addr`). Cases:
  read-miss+fill (verify data + `access_miss` pulse), read-hit after that fill
  (verify data + `access_hit` pulse, no bus traffic), write-hit (verify merge +
  `dirty` set, no bus traffic), write-then-evict (force a second miss into the
  same set/way via a colliding address, verify the dirty line's own writeback
  fires on `m_*` with correct data BEFORE the new fill starts), `WITH_DIRTY=0`
  instantiation (I-side shape) never asserts a writeback regardless of `u_we`
  history.
- [ ] **Step 3: Compile + run.** `iverilog -g2005 -I design -o /tmp/l2u.vvp -I sim/tb sim/tb/tb_l2cache_unit.v && vvp /tmp/l2u.vvp` (adjust to this project's real `sim/run_tests.sh`-style invocation). Expected: all cases pass, zero warnings.
- [ ] **Step 4: Commit.**
  ```bash
  git add design/L2Cache.v sim/tb/tb_l2cache_unit.v
  git commit -m "feat: L2Cache.v standalone core, no inclusion probe yet (Generation 4, Phase F)"
  ```

---

## F2: Inclusion probe logic inside `L2Cache.v`

**Files:**
- Modify: `design/L2Cache.v` (add `S_PROBE_WAIT` state + probe-driven eviction path)
- Modify: `sim/tb/tb_l2cache_unit.v` (add probe-driven cases)

**Interfaces:**
- Consumes: F1's `L2Cache.v` port list (unchanged — probe ports were already
  declared in F1).
- Produces: `L2Cache.v` now genuinely asserts `probe_req`/`probe_addr` before any
  eviction of a currently-valid line, and correctly merges `probe_dirty ?
  probe_data : (L2's own data_arr for that line)` before its own writeback.

- [ ] **Step 1: Add the probe branch.** On a miss whose `victim_target_way` is
  currently `valid` (regardless of L2's own `dirty` bit — unconditional probe,
  per Global Constraints), transition to `S_PROBE_WAIT` instead of going straight
  to `S_WB`/`S_FILL`: assert `probe_req=1`, `probe_addr` = that line's full
  reconstructed address (`{tag_arr[victim], set_idx, {OFFSET_BITS{1'b0}}}`, same
  reconstruction `DCache.v`'s own flush logic already does at
  `design/DCache.v:1068`), and hold until `probe_ack` pulses. On `probe_ack`:
  latch `probe_dirty`/`probe_data` into registers; if `dirty[victim] |
  probe_dirty_latched`, go to `S_WB` using the merged data source (`probe_dirty
  ? probe_data_latched : data_arr[victim line]`); else skip straight to
  `S_FILL`. If `victim_target_way` is NOT currently valid (cold slot, nothing to
  evict), skip the probe entirely (unchanged from F1).
- [ ] **Step 2: Extend `tb_l2cache_unit.v`.** Add a mock L1 probe-responder task
  in the testbench (asserts `probe_ack` N cycles after `probe_req`, with a
  test-controlled `probe_dirty`/`probe_data`). Cases: probe-clean-eviction (L1
  reports not-dirty, L2 writes back its OWN data unchanged), probe-dirty-
  eviction (L1 reports dirty with different data than L2's own copy — the real
  correctness risk — verify L2's own writeback uses the PROBE's data, not its
  stale own copy), probe-not-found (L1 reports "wasn't there", `probe_dirty=0`
  — verify L2 still proceeds correctly, no hang).
- [ ] **Step 3: Compile + run**, zero warnings, all F1+F2 cases pass.
- [ ] **Step 4: Commit.**
  ```bash
  git add design/L2Cache.v sim/tb/tb_l2cache_unit.v
  git commit -m "feat: L2Cache.v inclusion probe-before-evict handshake (Generation 4, Phase F)"
  ```

---

## F3: `DCache.v` probe-responder port

**Files:**
- Modify: `design/DCache.v` (new ports + S_IDLE priority branch)

**Interfaces:**
- Produces (new ports, appended to `DCache.v`'s existing port list):
  ```verilog
  input                       probe_req,
  input      [XLEN-1:0]       probe_addr,
  output                      probe_ack,
  output                      probe_dirty,
  output     [XLEN*LINE_WORDS-1:0] probe_data
  ```

- [ ] **Step 1: Decode `probe_addr` combinationally** the same way `req_addr` is
  decoded (`design/DCache.v:197-209`) — a second, independent `tag`/`set_idx`
  pair (`probe_tag`/`probe_set`) plus an N-way compare against `valid[]`/
  `tag_arr[]` (same shape as `way_hit`/`hit_data_acc`, `design/DCache.v:236-244`),
  producing `probe_found`/`probe_found_way`/`probe_found_line`.
- [ ] **Step 2: Add a new first-priority branch inside the existing `S_IDLE` case**
  (`design/DCache.v:843` onward), ahead of the existing `flush_all`/
  `req_read`/`req_write` chain: `else if (probe_req) begin` — if `probe_found`,
  capture `dirty[probe_found_line]` and the full line's `data_arr` into
  `probe_dirty`/`probe_data` (a flat `LINE_WORDS`-word concat, same shape
  `vc_outgoing_data`'s own generate block already builds,
  `design/DCache.v:304-308`), and invalidate that line (`valid[probe_found_line]
  <= 1'b0`) the same cycle; if not found, `probe_dirty` reads 0, `probe_data` is
  don't-care. `probe_ack` pulses the same cycle this branch is taken
  (combinational, gated on `state==S_IDLE && probe_req`). When `probe_req` is
  tied 0 by the caller (L2 disabled), this entire branch is dead/unreachable —
  bit-identical to pre-Phase-F behavior, confirmed by the regression run in F7.
  **Do not let this branch fire on the same cycle `req_read`/`req_write` is also
  being served** — `probe_req` takes strict priority; a real `req_read`/
  `req_write` held by the caller is simply serviced the following cycle instead
  (safe: `riscvpipeline.v`'s `reg3` holds the request level until `resp_ready`,
  so nothing is lost by a one-cycle defer).
- [ ] **Step 3: Regression.** Run the full existing directed suite
  (`bash sim/run_tests.sh`) with `probe_req` tied 0 at every existing call site
  (no test wires it yet) — must be 100% unchanged pass count, zero new
  failures, zero warnings on `iverilog -Wall -g2005 -I design -tnull design/*.v`.
- [ ] **Step 4: Commit.**
  ```bash
  git add design/DCache.v
  git commit -m "feat: DCache.v inclusion probe-responder port (Generation 4, Phase F)"
  ```

---

## F4: `ICache.v` probe-responder port

**Files:**
- Modify: `design/ICache.v` (new ports + S_IDLE priority branch)

**Interfaces:**
- Produces: `input probe_req, input [XLEN-1:0] probe_addr, output probe_ack` —
  no `probe_dirty`/`probe_data` ports at all (I$ is read-only, nothing to pull
  back; `L2Cache.v`'s I-side instance is instantiated with `WITH_DIRTY=0` and
  its own `probe_dirty`/`probe_data` inputs simply tied to `1'b0`/`{...{1'b0}}`
  at the `riscvpipeline.v` instantiation site in F7, never wired to `ICache.v`
  at all).

- [ ] **Step 1: Same decode-and-invalidate shape as F3**, simpler (no dirty/data
  capture needed) — a `probe_tag`/`probe_set` decode + N-way compare mirroring
  `design/ICache.v:124-152`'s own `way_hit` shape, then a new first-priority
  branch inside `S_IDLE` (`design/ICache.v:354` onward) that invalidates on a
  found line and acks unconditionally (found or not).
- [ ] **Step 2: Regression** — full directed suite, `probe_req` tied 0
  everywhere, 100% unchanged, zero warnings.
- [ ] **Step 3: Commit.**
  ```bash
  git add design/ICache.v
  git commit -m "feat: ICache.v inclusion probe-responder port (Generation 4, Phase F)"
  ```

---

## F5: `InstructionMemoryWishboneAdapter.v`

**Files:**
- Create: `design/InstructionMemoryWishboneAdapter.v`
- Create: `sim/tb/tb_instr_mem_wb_adapter_unit.v` (small standalone smoke test)

**Interfaces:**
- Produces:
  ```verilog
  module InstructionMemoryWishboneAdapter #(
      parameter SIZE_BYTES = 128,
      parameter XLEN = 32,
      parameter INIT_FILE = "sim/programs/arith.mem"
  )(
      input clk, rst,
      input                          s_cyc, s_stb, s_we,   // s_we ignored -- read-only
      input      [XLEN-1:0]          s_addr, s_data_o,      // s_data_o ignored
      input      [`WB_SEL_WIDTH-1:0] s_sel,                 // ignored
      output     [XLEN-1:0]          s_data_i,
      output                         s_ack
  );
  ```

- [ ] **Step 1: Write the adapter.** Mirrors `design/RamWishboneAdapter.v`'s own
  header/port-naming convention exactly, but simpler: `InstructionMemory.v`'s
  own read is combinational (confirmed by research, `design/InstructionMemory.v`
  — no wait states, no internal registered latency, unlike `DataMemoryBRAM.v`),
  so `s_data_i` reads combinationally straight from the wrapped
  `InstructionMemory` instance's own `inst` output, and `s_ack` needs only a
  plain `assign s_ack = s_cyc && s_stb;` — **no `req_active_r`/edge-detection
  register is needed here at all**, since there is no internal latency to
  desynchronize from (unlike `RamWishboneAdapter.v`'s own real bug — this
  module has no equivalent stuck-level risk because there is no pending state
  to get stuck; document this explicitly in a header comment citing why this
  case genuinely differs from `RamWishboneAdapter.v`'s own precedent, not
  silently diverging from the Global Constraint's stated mirror-the-pattern
  guidance without explanation).
- [ ] **Step 2: Write `tb_instr_mem_wb_adapter_unit.v`.** A handful of directed
  reads at known addresses against a small `INIT_FILE`, confirming `s_ack`
  pulses the correct cycle and `s_data_i` matches the expected instruction word.
- [ ] **Step 3: Compile + run**, zero warnings.
- [ ] **Step 4: Commit.**
  ```bash
  git add design/InstructionMemoryWishboneAdapter.v sim/tb/tb_instr_mem_wb_adapter_unit.v
  git commit -m "feat: InstructionMemoryWishboneAdapter.v, Wishbone slave wrapper for I-mem (Generation 4, Phase F)"
  ```

---

## F6: `ICache.v` new bus-master port (`L2_ENABLE`)

**Files:**
- Modify: `design/ICache.v` (new parameter + generate-gated bus-master fill path)
- Create: `sim/tb/tb_icache_l2enable_unit.v` (standalone: both `L2_ENABLE=0` and `=1` paths)

**Interfaces:**
- Produces: new parameter `parameter L2_ENABLE = 0`, and — only elaborated when
  `L2_ENABLE=1` — a new Wishbone-master port:
  ```verilog
  output m_cyc, m_stb,          // m_we tied 0 always -- I$ never writes
  output [XLEN-1:0] m_addr,
  output [`WB_SEL_WIDTH-1:0] m_sel,
  output [2:0] m_funct3,
  input  [XLEN-1:0] m_data_i,
  input             m_ack
  ```
  (declared unconditionally in the port list, per this project's existing
  convention of declaring victim-cache/MSHR ports unconditionally even when
  the enabling parameter is 0 — see `DCache.v`'s own `mshr_accept` etc. Tied to
  `1'b0`/`{...}` internally when `L2_ENABLE=0`.)

- [ ] **Step 1: `generate if (L2_ENABLE==0) / else` split** around
  `design/ICache.v`'s existing fill engine (`S_IDLE`/`S_FILL`,
  `design/ICache.v:247-410`). The `L2_ENABLE==0` branch is the EXISTING code,
  completely unchanged (private `m_imem` instance, `MemoryLatencyModel`
  wrapper, all as today). The `L2_ENABLE==1` branch is a new, parallel FSM of
  the identical S_IDLE/S_FILL shape, source-swapped: instead of reading
  `m_imem`'s combinational output at `imem_addr`, it drives real
  `m_cyc/m_stb/m_addr` (word-by-word, `LINE_WORDS` deep, same `fill_word_r`
  progression) and waits for `m_ack`/`m_data_i` each word, writing into the
  SAME `data_arr`/`tag_arr`/`valid`/`victim`/`age` arrays either branch shares
  (the arrays themselves, and the `way_hit`/hit-detection logic, and the
  victim-cache block, stay OUTSIDE this generate split — only the FILL
  mechanism differs, not the cache storage or hit path).
- [ ] **Step 2: Write `tb_icache_l2enable_unit.v`.** `L2_ENABLE=0` sub-test: a
  byte-for-byte re-run of an existing `tb_icache_unit.v` case, confirming
  identical behavior (regression proof, not just "still compiles"). `L2_ENABLE=1`
  sub-test: a mock downstream Wishbone responder (mirrors F1's own L2Cache.v
  unit-test mock), confirming a correct fill via the new bus path.
- [ ] **Step 3: Compile + run**, zero warnings.
- [ ] **Step 4: Commit.**
  ```bash
  git add design/ICache.v sim/tb/tb_icache_l2enable_unit.v
  git commit -m "feat: ICache.v new Wishbone-master bus port, L2_ENABLE-gated (Generation 4, Phase F)"
  ```

---

## F7: Wire it live in `riscvpipeline.v` — the isolated highest-risk step

**Files:**
- Modify: `design/riscvpipeline.v`
- Create: `sim/tb/tb_cache_l2_f1.v` (end-to-end directed test)
- Create: `sim/programs/cache_l2_f1.s`

**Interfaces:**
- Consumes: `L2Cache.v` (F1-F2), `DCache.v` probe port (F3), `ICache.v` probe
  port + `L2_ENABLE` bus port (F4, F6), `InstructionMemoryWishboneAdapter.v`
  (F5).

- [ ] **Step 1: New top-level parameters.** `L2_SIZE_BYTES = 0`, `L2_WAYS = 4`,
  `L2_REPLACEMENT_POLICY = 0` — added to `riscvpipeline.v`'s own parameter list
  (`riscvpipeline.v:109-168` region), same declaration style/comment
  convention as every prior swappable axis in that list.
- [ ] **Step 2: D-side splice.** At `ICache`/`DCache` instantiation
  (`riscvpipeline.v:478-491` for I$, `riscvpipeline.v:3071-3103` for D$), inside
  a new `generate if (L2_SIZE_BYTES == 0) / else` split: at `L2_SIZE_BYTES==0`,
  wiring stays EXACTLY as today (no `L2Cache` instance, `DCache.v`'s own
  `probe_req` tied 0, `ICache.v`'s own `L2_ENABLE(1'b0)`). At
  `L2_SIZE_BYTES!=0`: rename `DCache.v`'s existing `m_*` output wires to a new
  `dcache_l1_m_*` set, instantiate `L2Cache #(.WITH_DIRTY(1),
  .LINE_BYTES(DCACHE_LINE_BYTES), .WAYS(L2_WAYS), .CACHE_SIZE_BYTES(...),
  .REPLACEMENT_POLICY(L2_REPLACEMENT_POLICY)) m_L2Cache_D` with `.u_*(dcache_l1_m_*)`
  and `.m_*` feeding what used to be `dcache_m_*`'s own connection into
  `MemoryController.v`'s `dcache_*` arm (i.e. `MemoryController` now sees
  L2Cache's downstream port, not DCache's own port directly); cross-wire
  `m_L2Cache_D`'s `probe_req/probe_addr/probe_ack/probe_dirty/probe_data` to
  `DCache.v`'s own new probe port.
- [ ] **Step 3: I-side splice.** `ICache #(..., .L2_ENABLE(L2_SIZE_BYTES != 0))`
  — its new bus-master port (F6) feeds a new `L2Cache #(.WITH_DIRTY(0),
  .LINE_BYTES(ICACHE_LINE_BYTES), .WAYS(L2_WAYS), ...) m_L2Cache_I` instance's
  `u_*` port; `m_L2Cache_I`'s own downstream `m_*` port feeds a new
  `InstructionMemoryWishboneAdapter #(.SIZE_BYTES(MEM_SIZE_BYTES),
  .INIT_FILE(INIT_FILE)) m_IMemAdapter` instance's `s_*` port (point-to-point,
  no `MemoryController`/`WbDecoder` involvement, per Global Constraints);
  cross-wire `m_L2Cache_I`'s probe port to `ICache.v`'s own new probe port
  (`probe_dirty`/`probe_data` on the `L2Cache` side tied `1'b0`/all-zero, since
  `ICache.v` exposes no such outputs). At `L2_SIZE_BYTES==0`, none of this
  generate branch elaborates at all — `ICache.v` keeps using its own private
  `InstructionMemory` instance exactly as today.
- [ ] **Step 4: Regression FIRST, before any new test.** Run the FULL existing
  directed suite (`bash sim/run_tests.sh`) and the zero-warning compile check
  with `L2_SIZE_BYTES` at its default (0) — **must be 100% bit-identical, zero
  new failures.** This is the real correctness gate for the whole phase; do not
  proceed to Step 5 until this passes cleanly.
- [ ] **Step 5: Write `sim/programs/cache_l2_f1.s`** — a hand-built assembly
  program forcing: (a) a D$ line to be filled (real L2 miss, then L2 fill from
  backing store), (b) enough OTHER stores to distinct addresses mapping to the
  SAME L2 set to force L2 to evict that first line while it is still resident
  in D$ (`L2_WAYS` small enough, e.g. 2, to make this easy to force
  deterministically), (c) a further store to the ORIGINAL address's line
  *while it's still resident in D$*, dirtying it in D$ but NOT in L2 (the real
  correctness risk this whole phase exists to get right), (d) enough further
  distinct-set traffic to force L2 to evict that line — verify the inclusion
  probe fires, D$'s own dirty data reaches L2's own writeback to backing
  store, and a final re-read of the original address returns the CORRECT
  (dirtied) value, not L2's stale pre-probe copy.
- [ ] **Step 6: Write `tb_cache_l2_f1.v`** — mirrors `tb_cache_mshr_e1.v`'s own
  shape (a real worked example proving both correctness AND a measured
  cycle-count comparison): runs `cache_l2_f1.s` at `L2_SIZE_BYTES=0` (today's
  behavior, no L2) vs `L2_SIZE_BYTES!=0`, checks final register/memory state
  matches expected (the correctness proof above) at BOTH settings, and reports
  the cycle-count delta (a real L2-hit-avoids-backing-store-latency win is
  only guaranteed to show up if `MEM_LATENCY_D>0` is also set for this specific
  test — set it explicitly in this testbench's own parameters, don't rely on
  the default).
- [ ] **Step 7: Compile + run both new tests**, zero warnings.
- [ ] **Step 8: Commit.**
  ```bash
  git add design/riscvpipeline.v sim/tb/tb_cache_l2_f1.v sim/programs/cache_l2_f1.s
  git commit -m "feat: wire L2 cache live, I\$+D\$ shared, inclusive (Generation 4, Phase F)"
  ```

---

## F8: Tooling + testbench include fix

**Files:**
- Modify: `sim/tools/run_random_tests.py`
- Modify: `sim/tools/bench_runner.py`
- Modify: every existing `sim/tb/*.v` file that already `` `include``s `DCache.v`
  (grep-discovered, real list at implementation time — same class of file set
  Phase E's own `fix:` commit touched)
- Modify: `sim/tb/bench_template.v` (optional L2 hit/miss testbench-side taps,
  Layer A style, mirrors `icache_miss_count`/`dcache_miss_count`'s own
  precedent — cheap, no CSR/HPM-event wiring needed this phase, deferred to
  Future improvements per Global Constraints)

- [ ] **Step 1: `run_random_tests.py` new flags.** `--l2-size` (int, default 0),
  `--l2-ways` (int, default 4), `--l2-replacement` (`{0,1,2}`, default 0) —
  same `.replace("__TOKEN__", ...)` template-substitution mechanism every
  existing cache-family flag already uses (`sim/tools/run_random_tests.py:227-
  286`region). No-op unless `--cache-mode 1` (mirrors `--victim-entries`/
  `--mshr-entries`'s own existing no-op-without-cache-mode convention). Bump
  `max_time`'s own cache-mode margin if L2 fill latency meaningfully extends
  worst-case cycles (re-derive the real number from `tb_cache_l2_f1.v`'s own
  measured worst case, don't guess).
- [ ] **Step 2: `bench_runner.py --compare-l2`.** Same template every existing
  `--compare-*` flag follows (`bench_runner.py:266-490` region): new axis
  `"l2"`, `keys=(0, N)` (disabled vs a real size), forces `cache_mode=1`, one
  more slot in the parameter tuple threaded through `run_bench`, one more
  `labels["l2"]` entry.
- [ ] **Step 3: Include-fix sweep.** `grep -rl 'include "DCache.v"' sim/tb/`
  (and any bench/dump templates outside `sim/tb/` that do the same), add
  `` `include "L2Cache.v"`` and `` `include "InstructionMemoryWishboneAdapter.v"``
  immediately after each existing `DCache.v` include — matches the exact
  fix-class precedent from Phase C/E.
- [ ] **Step 4: Full directed suite + zero-warning compile**, confirming the
  include sweep didn't disturb anything (expected clean, but confirmed).
- [ ] **Step 5: Commit** (as 2-3 separate commits mirroring Phase E's own
  split: one `feat:` for the CLI flags, one `fix:` for the include sweep).

---

## F9: Verification bar, ADR, doc updates

**Files:**
- Create: `docs/adr/0045-l2-cache-phase-f.md`
- Modify: `docs/ROADMAP_VISION.md`, `handoff.md`

- [ ] **Step 1: Full verification bar** — directed suite, zero-warning compile,
  constrained-random cross-check at real sample size (200+) across multiple
  axis combinations: default L2, L2+victim-cache, L2+MSHR, L2+burst+real-
  latency, L2+MMU (mirrors Phase E's own 5-combo bar, same reasoning: the
  combined-axis runs are what actually catch cross-feature bugs, not a
  plain-L2-alone sweep).
- [ ] **Step 2: `bench_runner.py --compare-l2` real run** against
  `sim/benchmarks/bench_*.s` — report the real delta honestly, whatever it is
  (every prior cache-family phase found near-zero on these tiny kernels; don't
  assume this one will differ without actually running it).
- [ ] **Step 3: `docs/adr/0045-l2-cache-phase-f.md`**, mirroring the exact
  6-section structure `docs/adr/0041`-`0044` all use verbatim: `## Problem` →
  `## Design` → `## Real bugs/findings` → `## Alternatives considered` →
  `## Validation strategy` → `## Future improvements`. Future improvements
  must explicitly list: no `present_in_l1` tracking (unconditional-probe
  cost), no L2-side burst-CTI, no L2-side victim buffer, no L2-side MSHR
  (blocking L2), fixed L2-line-size-matches-L1 constraint, no HPM/CSR event
  wiring for L2 hit/miss (testbench-tap-only this phase).
- [ ] **Step 4: `docs/ROADMAP_VISION.md`/`handoff.md`** — narrowly update the
  Generation 4 section (L2 line moves from "unscoped" to done, same pattern
  every prior phase's own closing commit used), Gen4's own remaining item
  (hardware prefetchers) stays the sole open item.
- [ ] **Step 5: Update memory** (`redesign_status.md`).
- [ ] **Step 6: Ask the user about committing** the docs+verification commit
  (matches this project's own established "ask, don't assume" convention for
  the closing commit).

---

## Self-Review Notes (spec coverage / consistency check performed before handoff)

- Every Global-Constraints decision (shared I$+D$, inclusive, independent
  `L2_REPLACEMENT_POLICY`, no `present_in_l1`, L2 line size matches L1, no L2
  burst/MSHR/victim this phase) has a task that implements it: F1-F2 (core +
  probe), F3-F4 (L1 probe responders), F5-F6 (I$ bus port + adapter), F7 (live
  wiring + the real correctness test), F8 (tooling), F9 (verification + ADR).
- Signal names are consistent across tasks: `L2Cache.v`'s `u_*`/`m_*`/`probe_*`
  port names (fixed in F1) are used identically in F2 (internal only), F3/F4
  (the L1-side mirror of the same `probe_*` names), F7 (instantiation).
  `ICache.v`'s new `L2_ENABLE` parameter (F6) is the exact name F7's
  instantiation uses.
- No task references a type/signal not defined in an earlier task.
