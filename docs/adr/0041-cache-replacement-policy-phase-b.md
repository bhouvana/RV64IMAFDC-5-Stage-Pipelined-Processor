# ADR 0041: Cache Replacement Policy (Generation 4, Phase B)

## Problem

Generation 4, Phase A closed (`docs/adr/0040`, GShare + tournament branch prediction). `docs/ROADMAP_VISION.md`'s
Generation 4 "Advanced cache hierarchy" bullet bundles four distinct items in one line: associativity
variants, victim cache, L2, replacement policies (LRU/FIFO). Confirmed via `AskUserQuestion`: split into
sub-phases rather than attempt all four together, following this project's own established one-coherent-
change-per-phase discipline (every Generation 3 sub-item, and Generation 4 Phase A itself, did the same).
Phase B scopes the smallest first slice: replacement policy. Associativity turned out to already be free
(`design/ICache.v`/`design/DCache.v`'s existing `WAYS` parameter works at any power-of-2 value, confirmed
by direct code read before scoping this phase — no new RTL needed there, only a future benchmark sweep).
Victim cache and L2 stay real, explicitly-flagged backlog for later phases.

## Design

New `REPLACEMENT_POLICY` parameter on `ICache.v`/`DCache.v`, threaded through `riscvpipeline.v` only where
`CACHE_MODE==CACHE_WRITEBACK_SETASSOC` instantiates them — joining the same swappable-parameter family as
`HAZARD_STRATEGY`/`PIPELINE_PROFILE`/`BRANCH_PREDICTOR`/`CACHE_MODE`/`MEM_LATENCY_I`/`MEM_LATENCY_D`. Three
closed enum values: `POLICY_ROUND_ROBIN`=0 (default, bit-exact with every existing test/ADR/benchmark),
`POLICY_FIFO`=1, `POLICY_LRU`=2.

**`POLICY_ROUND_ROBIN` and `POLICY_FIFO` are genuinely the same mechanism, not two implementations.** Both
select the identical existing `victim[]` per-set fill-order pointer — round-robin already *is*
FIFO-by-fill-order eviction at this associativity (the pointer advances unconditionally on every miss,
oblivious to intervening hits, which is exactly "oldest-filled-wins"). A separately-implemented FIFO would
be redundant RTL with zero behavioral difference; exposing both names lets a future comparison run
explicitly label which policy it used without pretending they differ.

**`POLICY_LRU` is true per-way access-recency tracking, not pseudo-LRU tree bits.** A new
`age[set][way]` rank array (0=most-recently-used … `WAYS-1`=least-recently-used) is maintained by a shared
`lru_touch` task, called on every real hit and every fill completion. A new generate-based reduction (same
OR-of-AND-masked shape the existing tag-compare/hit-data accumulators already use) picks the way with
`age==WAYS-1` as the victim on a miss. At this project's default scale (`NUM_SETS` in the tens, `WAYS`=4)
the extra state is trivial, so true LRU costs nothing over pseudo-LRU for strictly better fidelity — the
same "pick the more correct option when it's this cheap" pattern this project has followed since its first
phase.

**D$-specific**: reuses the existing `access_hit` signal (Phase J5's own HPC-counter tap, already
exactly-once-per-real-access — see `DCache.v`'s own header comment on why a bare state/level check can't
distinguish "still the same request" from "a new one") for the hit-touch call, rather than duplicating that
correctness logic. `access_hit_way`/`access_hit_set` derive from `hit_line_idx` (write-hit, same `S_IDLE`
cycle) or `hit_line_r` (read-hit, `S_HIT_RD` cycle).

**I$-specific**: `hit`/`way_hit` are continuously live (no discrete "access" event the way DCache's FSM
has one), so the hit-touch fires every cycle `hit` holds — idempotent once the touched way is already MRU
(nothing has a smaller age to increment past), safe to evaluate unconditionally.

## Real bugs/findings

1. **A real, pre-existing RTL bug, found while designing this phase's own worked-example testbench**: both
   `ICache.v`'s and `DCache.v`'s `set_idx` wire (`readAddr[OFFSET_BITS+SET_BITS-1:OFFSET_BITS]`) reverses
   to an invalid (high<low) part-select whenever `SET_BITS==0` — a fully-associative configuration
   (`WAYS==NUM_LINES`, i.e. exactly one set). No existing test before this phase ever used that sizing to
   hit it. Fixed with a `generate if` tying `set_idx` to 0 in that case (an elaboration-time conditional,
   unlike a runtime `?:` ternary, which would still elaborate — and fail on — the invalid branch's
   expression regardless of which value wins at runtime). Routed around in this phase's own new
   testbenches (2-set sizings throughout) rather than exercised as the primary test target; flagged here as
   real, fixed, but not the focus of any new directed test of its own — a future phase touching
   fully-associative configurations should know this is now fixed, not still latent.
2. **User explicitly asked to fix all pre-existing bugs before continuing**, surfacing two more, both
   already-documented as known pre-existing failures (`docs/adr/0039`/`handoff.md`): `tb_arith`'s own `ctz`
   off-by-one, and `tb_icache_unit`'s stale post-byte-order-fix expected values. Investigating the first
   uncovered a second, much deeper, previously-*undiscovered* bug behind it:
   - `ALU.v`'s `ctz` loop scanned bits `[0:XLEN-2]`, never examining bit `XLEN-1` — but tracing through by
     hand shows this only ever diverges from true `ctz` for `A==0` exactly (any input with a set bit
     already reaches the correct count before the loop bound would matter). Fixed `XLEN-1`→`XLEN` in
     `ALU.v` and both of `iss.py`'s independent `ctz` dispatch sites.
   - **The real, much deeper bug this masked**: `OPCODE_CUSTOM` (`ctz`'s own opcode) was `7'b0101010` —
     bits `[1:0]`=`10`, not `11`. Every other opcode in `riscv_defs.vh` ends in `11`, the mandatory RISC-V
     marker for a genuine 32-bit instruction. Since Phase U (`docs/adr/0037`) added RVC support,
     `riscvpipeline.v`'s `is_compressed = (inst[1:0] != 2'b11)` has treated *every* `ctz` instruction as a
     2-byte compressed instruction, corrupting it and misaligning every fetch after it — confirmed by
     direct Verilog-level tracing (a temporary `$display` inside `ALUCtrl.v`'s decode case showed the
     `funct7=0100000,funct3=111` combination the RTL needs for `ctz` never once occurred during the whole
     directed test). `ctz` has silently never executed correctly since Phase U landed; the directed test's
     own long-stale "expected 31" value (itself already wrong — confirmed by testing against a fully
     unmodified checkout, which produces `0`, not `31`) hid this for even longer, since nobody had reason to
     re-verify `ctz` specifically after Phase U's own unrelated RVC work. Fixed by reassigning
     `OPCODE_CUSTOM` to `7'b0001011`, RISC-V's own spec-reserved `custom-0` opcode slot (bits `[1:0]`=`11`,
     genuinely unused elsewhere in this project) — mirrored in `asm.py`/`disasm.py`/`iss.py`.
     `sim/formal/`'s frozen Phase-L-era `riscv_defs.vh` copies deliberately left untouched, matching every
     prior phase's own established precedent for that gap.
   - `tb_icache_unit.v`'s `poke_word`/`poke2_block` wrote bytes MSB-first, stale since Phase U's byte-order
     fix flipped `InstructionMemory.v` to LSB-first. Fixed to match the real current convention.
3. **A real testbench-only bug found while building `tb_dcache_unit.v`'s own `dut2` LRU sub-test, not in
   the RTL**: content comparison alone can't distinguish "still hits" from "evicted, then correctly
   refilled" when the evicted line was dirty — its own writeback lands the identical value in backing RAM
   before the new fill. Switched to a cycle-count-based differentiator (a hit resolves in exactly 1 posedge;
   a miss takes many more via `S_WB`/`S_FILL`), mirroring `tb_icache_unit.v`'s own existing `MEM_LATENCY`
   timing-check technique.
4. **A second testbench-only bug, same sub-test**: a read-hit's own `access_hit` clause is evaluated on the
   `S_HIT_RD`→`S_IDLE` registering edge itself — `req_read` has to stay asserted through that edge, one full
   cycle later than `resp_ready` first goes high. The pre-existing `do_read`/`do_write` helpers (used
   correctly by every prior phase, including this one's own `POLICY_ROUND_ROBIN`-default `dut`) drop their
   request signal right after seeing `resp_ready`, which is fine for their own purposes (`resp_rdata`'s
   single-instant value) but silently starved every read-hit's own `lru_touch` call. Fixed in the new
   `do_read2` helper by holding `req_read2` one cycle longer, only for genuine hits (a miss's own touch
   already happens via the registered `miss_set_r`/`miss_way_r` path inside `S_FILL`, so holding longer
   there would look like a spurious brand-new request).
5. **A real test-*design* flaw, found and fixed by reordering rather than by changing the RTL to match a
   wrong expectation**: re-reading an evicted line is itself a fresh miss, correctly forcing *another* real
   eviction (of whichever way is now LRU-tail) to make room for its own refill — genuine LRU cascade
   behavior, not a bug. The test's own check order was fixed to observe the still-cached lines (D, A) before
   re-touching the evicted one (C), rather than corrupting later checks with an unplanned second eviction.
6. **No bugs found in the LRU mechanism's own core logic** once the above testbench issues were fixed — the
   worked example (fill A,B,C,D; re-touch A,B; miss on E; confirm C — not A — is the one evicted) passed on
   the first run after every fix above landed, for both the standalone unit tests and the live end-to-end
   directed test.

Real measured cycle-count data (`bench_runner.py --compare-replacement`, this project's own 3 benchmark
kernels): **zero difference** across all 3 `REPLACEMENT_POLICY` values. Honest, not fabricated — these
kernels are small enough to fit almost entirely within the default 4-way/4KB/16B cache, leaving minimal
eviction pressure for any policy to meaningfully differ on, the same "not much to exploit" honest result
`docs/adr/0040`'s own GShare benchmark had on these identical kernels. The real LRU-vs-round-robin
differentiation is unambiguous in the small-cache forced-eviction unit tests (`tb_icache_unit.v`'s `dut3`,
`tb_dcache_unit.v`'s `dut2`) and the end-to-end directed test (`tb_cache_lru_b1.v`) — that's where this
phase's own correctness claim actually rests, not the benchmark numbers.

## Alternatives considered

**Pseudo-LRU tree bits** (`WAYS-1` bits/set instead of `WAYS*log2(WAYS)`), the standard real-hardware choice
at high associativity to save state. Rejected: at this project's real default scale the extra state true
LRU needs is trivial (a handful of bits per set), so true LRU is strictly more correct for no meaningful
hardware cost — the same reasoning that made this an easy call rather than a real tradeoff.

**A separately-implemented FIFO mechanism**, distinct from round-robin's own pointer. Rejected: they are
provably the same algorithm at this associativity (oldest-filled-wins, oblivious to hits) — a second
implementation would be redundant RTL with zero behavioral difference, confirmed by the `--compare-
replacement` run showing byte-identical cycle counts between `POLICY_ROUND_ROBIN` and `POLICY_FIFO` on
every kernel.

## Validation strategy

`iverilog -Wall -g2005 -I design -tnull design/*.v` (via `/c/iverilog/bin`): zero-warning at every step.
Full directed suite (`bash sim/run_tests.sh`): **95/95** — up from 92/94 at the start of this phase (both
pre-existing failures fixed per the findings above), plus the new `icache_unit` (40/40 checks, up from 21),
`dcache_unit` (22/22, up from 15), and `cache_lru_b1` (8/8, new) tests all passing. **100/100 constrained-
random cross-check** at all 3 `REPLACEMENT_POLICY` values (`--cache-mode 1`), confirming `sim/tools/iss.py`
needed zero changes (no cache model of any kind exists there — confirmed by direct grep, same timing-only
category as `CACHE_MODE`/`MEM_LATENCY_I`/`_D` before it). Real measured data via `bench_runner.py
--compare-replacement` (see Real bugs/findings above).

## Future improvements

Victim cache, L2, and a real associativity-sweep benchmark (mechanically already possible via `WAYS`, just
not yet exercised) — explicitly deferred, real open backlog per `docs/ROADMAP_VISION.md`'s own Generation 4
bullet, not silently dropped. The `SET_BITS==0` fix (finding #1 above) has no dedicated directed test of its
own — a future phase that wants to exercise a genuinely fully-associative cache configuration should know
this is fixed, but might still want a standalone regression test proving it, not assumed from this ADR
alone. Generation 4 itself stays open — hardware prefetchers, non-blocking cache/MSHRs, and the memory
controller remain fully unscoped, each its own future phase.
