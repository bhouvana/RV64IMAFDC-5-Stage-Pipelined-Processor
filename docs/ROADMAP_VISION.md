# Long-range vision: Generations 1-10

This is the user-supplied master roadmap for where this core goes after the
current RV32IMAF work closes out — confirmed 2026-08-02 as "the roadmap I'd
follow." It is deliberately kept **separate from `docs/ROADMAP.md`**, which
stays the authoritative, actively-maintained phased backlog for work that's
actually scheduled (see "How this relates to `docs/ROADMAP.md` and the
A-E/F-H phase letters" below for why, and for the reconciliation decision
that governs how the two documents interact). Think of this file as the
10-year plan; `docs/ROADMAP.md` as the current sprint.

Numbered as **Generations**, not "Phases," specifically to avoid collision:
this project already has two live phase-letter sequences (`docs/adr/0018`-
`0021`'s Phase A-E, all complete, and the in-progress second wave's Phase
F-H — MMU/caches/dual-issue). The source roadmap this file is built from
used "Phase E" through "Phase N" for what's called Generation 1 (tail end)
through Generation 10 below — those letters are **not** this project's
Phase E/F/G/H and must never be conflated with them. Where a generation's
own internal sub-item lettering is preserved from the source material
(e.g. "G-B: MMU"), it's always written as "Gen `N`-`X`", never bare
"Phase `X`", for exactly this reason.

## How this relates to `docs/ROADMAP.md` and the A-E/F-H phase letters

Confirmed with the user (2026-08-02, `AskUserQuestion`): **finish the
current in-flight MMU work under its existing lettering first, then adopt
this generational structure for everything after.** Concretely:

- The project's own Phase A-E (variable pipeline depth, code-quality pass,
  F-extension, SoC integration, branch prediction) are complete and are
  **retroactively Generation 1's own foundational work** — no renaming, no
  action needed, they already match what this file calls Generation 1
  (RV32IMAF).
- The project's own second-wave Phase F (Sv32 MMU) is **mid-flight right
  now** (F1-F4 done, F5-F9 remaining — see `handoff.md`'s own "IN PROGRESS"
  section for exact status) and **keeps its existing F1-F9 lettering to
  completion**. Do not rename it to match this file's Generation 3 (which
  also covers privilege/MMU/TLB/page-tables, see the open question below)
  while it's still in progress.
- The project's own second-wave Phase G (caches) **keeps its existing
  lettering** and is now explicitly framed as Generation-1 work (see below
  — its scope already matches Generation 1's own cache items). **Phase H
  (dual-issue) is dropped from near-term scope** (decided 2026-08-02, see
  below) — it was never a Generation 1 item and has no sunk cost yet.
- **Once Phase F (through F9) and Phase G close out**, plus the
  Generation-1 items the second wave never scoped (variable-latency
  memory, HPC performance-monitoring CSRs, a profiler, formal
  verification — see below), this project's phase-lettering convention
  (A, B, C... reused per-session, ADR-numbered) retires in favor of this
  file's Generation numbering for anything new. At that point: update
  `docs/ROADMAP.md`'s own phase list to point here for what's next, and
  open a new ADR closing out "the whole A-E/F-G arc" the same way
  `docs/adr/0018` closed out Phase A and `docs/adr/0021` closed out Phase E.

### Generation 1 scope — decided 2026-08-02 (was an open question, now resolved)

The source roadmap's own Generation 1 (its "Phase E — Performance
Architecture") scope is: dynamic branch prediction (done, this project's
own Phase E) + variable-latency memory + an I-cache + a D-cache + hardware
performance-monitoring CSRs + a performance profiler + formal verification
— then a "RV32IMAF Research Processor v1.0" release closes it out.

This does **not** line up cleanly with the second wave (Phase F: MMU;
Phase G: caches; Phase H: dual-issue) — MMU is actually Generation 3's own
item (`G-B`/`G-C`/`G-D` below), not Generation 1's, and dual-issue was
never asked for by Generation 1 at all. Confirmed with the user
(`AskUserQuestion`, 2026-08-02): **Generation 1 completion is now the
explicit driver of what gets built next, not "finish F/G/H because they
were queued."** Concretely:

- **Phase F (MMU) finishes to F9** — already substantially done (F1-F5,
  including real bugs found and fixed), cheap to close out cleanly, and
  it's real groundwork for Generation 3 later even though it isn't a
  Generation 1 requirement itself.
- **Phase H (dual-issue) is dropped from near-term scope entirely** — not
  a Generation 1 item, not started, no sunk cost. Revisit at Generation 6
  (out-of-order) or later if still wanted; not a standing commitment.
- **Phase G (caches) continues, folded into Generation 1 directly** — its
  own "I$+D$, set-associative, write-back" scope already matches
  Generation 1's own I-cache/D-cache items.
- **The Generation-1 items the second wave never scoped** — variable-
  latency memory, hardware performance-monitoring CSRs, a performance
  profiler, and formal verification — are now real, committed work, not
  deferred. These get their own research+design pass each, same
  discipline as every phase before them, sequenced after Phase F closes
  (F6-F9, then these, likely reusing the G/H letters or moving straight to
  new phase letters — decide the exact lettering when Phase F actually
  closes, not now).

Once all of Generation 1's actual items are done (branch prediction
[done], caches, variable-latency memory, HPC CSRs, profiler, formal
verification), that's what closes out "RV32IMAF Research Processor v1.0"
and hands off to Generation 2 (RV64) under this file's own numbering.

A second, related open question for **Generation 3** (`G-B`/`G-C`/`G-D`:
MMU/TLB/page tables) specifically: this project's in-progress Sv32 MMU
(current Phase F) is built for the **RV32** core, ahead of the RV64
migration this file's own Generation 2 calls for. Sv32's translation
scheme (2-level page tables, 32-bit PTEs) is not what a real RV64 target
would use (Sv39/Sv48, 3-4 level, 64-bit PTEs) — so Generation 3's own MMU
work is very likely a **substantially new implementation**, not a rename
or a straightforward reuse of Phase F's `Tlb.v`/`Ptw.v`, even though the
architectural lessons (delegation, TLB tagging discipline, PTW-shares-bus-
via-mux) should carry over directly. Don't assume Phase F's MMU "becomes"
Generation 3's MMU without a real design pass when that generation starts.

---

## Generation 1 — RV32IMAF Research Processor (v1.0)

*(source material: "Phase E — Performance Architecture"; this project's own
Phase A-E already delivered the ISA/SoC/branch-prediction foundation this
generation sits on top of, and the second-wave Phase F-H is currently
extending it further — see the open question above for how these
reconcile before release.)*

**Objective:** turn the verified RV32IMAF processor into a high-performance
research-grade in-order core.

- **Dynamic branch prediction** — ✅ done, this project's own Phase E
  (`docs/adr/0021`): BTB + 2-bit saturating counters, predict in IF,
  update in EX, misprediction recovery, `bench_runner.py
  --compare-predictors` for accuracy/IPC comparison.
- **Variable-latency memory** — not started. Configurable I-mem/D-mem
  latency, a wait-state model, pipeline interlocks, latency benchmarking.
  New module: `MemoryLatencyModel.v`.
- **Instruction cache** — not started (this project's own second-wave
  Phase G covers I$+D$ together, see the open question above on how these
  merge). Direct-mapped L1, configurable size/line-size, tag array, valid
  bits, cache controller, hit/miss statistics. New module: `ICache.v`.
- **Data cache** — not started (same Phase G note). Direct-mapped L1,
  write-through, write-allocate, configurable size, performance counters.
  New module: `DCache.v`.
- **Hardware performance monitoring** — not started. CSRs for cycle count,
  instructions retired, IPC, CPI, branches, branch misses, cache hits/
  misses, pipeline stalls, interrupt count, exception count.
- **Performance profiler** — not started. Automated reports: pipeline
  utilization, stall breakdown, branch accuracy, cache statistics, IPC,
  CPI, instruction mix.
- **Formal verification** — not started. Prove register correctness,
  hazard correctness, forwarding correctness, pipeline correctness, CSR
  correctness, via a formal tool (none set up in this project yet).

**Release:** RV32IMAF Research Processor v1.0.

---

## Generation 2 — RV64 Migration (v2.0) — ✅ CLOSED as of 2026-08-03

*(source material: "Phase F — RV64 Migration")*

**Objective:** upgrade the architecture to a modern 64-bit implementation.

- **XLEN migration** — ✅ Done (`docs/adr/0028-rv64-migration-phase-m.md`,
  Phase M). Widen every datapath to 64 bits; update pipeline registers, the
  forwarding network, hazards. (`XLEN` was already a named parameter as of
  `docs/adr/0015`, but wasn't truly variable at other values — RV32I's own
  32-bit instruction word and 5-bit register-field encoding are baked in
  independent of the parameter. Phase M is where that parameter's promise
  actually got exercised: `XLEN=64` is now a real, fully-verified
  configuration.)
- **Register file** — ✅ Done, 64-bit integer registers, updated writeback logic.
- **ALU** — ✅ Done, 64-bit arithmetic/shifts/comparisons plus the new
  `*w`-suffixed 32-bit-result family (`addw`/`subw`/`sllw`/`srlw`/`sraw`/
  `mulw`/`divw`/`divuw`/`remw`/`remuw`/`addiw`/`slliw`/`srliw`/`sraiw`).
- **Divider** — ✅ Done. `Divider.v` was already fully XLEN-parameterized;
  the `*w` divide family wraps it unmodified rather than needing changes.
- **Memory** — ✅ Done. `ld`/`sd`/`lwu` real (Generation 1's own alignment
  behavior — this core has never enforced access alignment at any width,
  a real, pre-existing, non-faulting byte-addressable design choice —
  carries over unchanged, not a new gap).
- **Toolchain** — ✅ Done, real RV64 awareness (not just a wider `XLEN`)
  throughout `sim/tools/asm.py`/`iss.py`/`disasm.py`/`debugger.py`/
  `gen_trace.py`/`random_gen.py`/`run_random_tests.py`/`bench_runner.py`.
- **Verification** — directed tests ✅, random tests ✅, differential
  testing ✅ (`sim/tools/iss.py` cross-checked continuously against the
  RTL). **RISC-V compliance testing (riscv-arch-test) — deliberately NOT
  done, real documented backlog, not silently dropped.**
  `docs/adr/0029-generation-2-closure.md` has the full story: blocked on
  two independent findings, not a scope cut for convenience — (1) neither
  Spike nor Sail (both generations of the official framework require one
  as a live reference model) publishes a Windows-native binary, and this
  environment has no from-source build path for either; (2) more
  fundamentally, this core's own branch-instruction encoding
  (`docs/ARCHITECTURE.md` sec 5's documented `blt`/`bge`/custom-`ble`/`bgt`
  funct3 deviation from the real RV32I spec) means a real, spec-compliant
  test binary would be silently misdecoded regardless of tooling — a real
  compliance run needs that fixed first, as its own prerequisite phase.
  **Update: the encoding half is now fixed** (Phase N,
  `docs/adr/0030-branch-encoding-fix.md` — `blt`/`bge` moved to real spec
  funct3 positions). The Windows-native reference-model tooling half of
  this blocker is unchanged and still open.

**Release: RV64IMAF Processor v2.0.** Confirmed with the user
(`AskUserQuestion`) to close Generation 2 on this basis rather than block
release on either the toolchain bootstrap or the encoding-fix prerequisite.

---

## Generation 3 — Operating System Support (v3.0)

*(source material: "Phase G — Operating System Support". See the open
question above: this is very likely a new MMU design against RV64/Sv39,
not a reuse of the current Phase F's RV32/Sv32 `Tlb.v`/`Ptw.v`, even though
the lessons carry over.)*

**Prerequisite done**: the branch-encoding fix (Phase N,
`docs/adr/0030-branch-encoding-fix.md`) that real Linux boot needed —
`blt`/`bge` now sit at real RISC-V spec funct3 positions, so a stock
`riscv64-gcc`-compiled kernel's branches decode correctly. Generation 3
itself (privilege/MMU/TLB/page-tables/Linux-boot below) can now start.

**Phases O-V all closed.** Feasibility research (this environment has no
Verilator/FPGA execution *initially* — Phase T later found and bootstrapped
a real Verilator install, see below — only `iverilog` software simulation
at first, and no confirmed Windows-native `riscv64-linux-gnu` glibc
toolchain) reshaped this generation into a longer phase sequence, confirmed
with the user: **Phase O** (privilege/CSR groundwork for RV64/Sv39, DONE —
`docs/adr/0031`) → **Phase P** (a from-scratch Sv39 MMU/TLB/PTW, DONE —
`docs/adr/0032`: `Tlb39.v`/`Ptw39.v` wired live, 100/100 Sv39-MMU random
sweep) → **Phase Q** (memory-capacity scale-up, DONE — `docs/adr/0033`:
`MEM_SIZE_BYTES` gained a real, fully-verified 64MB operating point) →
**Phase R** (`Uart.v`/`Timer.v` register-layout redesign for ns16550a/CLINT
Linux-driver compatibility, DONE — `docs/adr/0034`: real 8-register
ns16550a UART map, real CLINT `msip`/`mtimecmp`/`mtime`) → **Phase S** (a
hand-rolled minimal SBI firmware + DTB, DONE — `docs/adr/0035`: real M-mode
SBI firmware verified end-to-end against a self-written S-mode test
payload) → **Phase T** (a real Verilator harness bootstrapped from an
existing OSS CAD Suite install, ~1.4M cycles/sec; SBI extended to real
v0.2+; a real riscv64 kernel `Image`+initramfs sourced and verified
genuine — DONE, `docs/adr/0036`: found the kernel's own first instruction
is a real compressed `c.j` this core couldn't decode at all, a hard,
scope-defining blocker) → **Phase U** (a from-scratch RVC/"C"-extension
decoder, `design/CompressedExpander.v` — DONE, `docs/adr/0037`: also found
and fixed a real, project-wide `InstructionMemory.v` byte-order bug RVC
exposed) → **Phase V** (a from-scratch 'A'/atomic-extension implementation,
a new 2-phase MEM-stage interlock — DONE, `docs/adr/0038`). **Real result**:
the real kernel now executes correctly through its own compressed-
instruction-heavy entry sequence and a real `amoadd.w` hart-check, hundreds
of millions of cycles with zero crashes — the deepest, most correct real-
Linux-code execution this core has ever achieved. It currently parks in a
real polling loop waiting on `sp`/`tp` values this project's own minimal
single-hart SBI/DTB environment never publishes — a real environment gap
(not an RTL bug), needing Linux kernel source archaeology to close, and the
honest stopping point for Generation 3 as currently scoped. See
`docs/adr/0036`-`0038` for the full story.

**Objective:** build a Linux-capable processor.

- **Privilege architecture** — M/S/U modes. (Substantial overlap with the
  current in-progress Phase F1/F3's privilege-mode/CSR/trap-delegation
  work — re-verify against RV64/Sv39 rather than assuming it transfers
  unchanged.)
- **MMU** — virtual-to-physical address translation.
- **TLB** — I-TLB, D-TLB, refill logic. (Current Phase F4's `Tlb.v` is
  unified/single-array by design choice, not split — re-decide this for
  RV64 rather than assuming the same choice still holds.)
- **Page tables** — multi-level page walker, access bits, dirty bits,
  permission checking. (Current Phase F4's `Ptw.v` is Sv32-specific,
  2-level; RV64/Sv39 is 3-level with a different PTE layout — new design,
  not a port.)
- **Memory protection** — page faults, access faults, permission faults.
- **Linux boot** — BusyBox Linux, UART console, interactive shell. (Net
  new scope; nothing in this project's history has attempted this yet.)

**Release:** Linux-capable RV64 Processor v3.0.

---

## Generation 4 — Advanced Memory System (v4.0)

*(source material: "Phase H — Advanced Memory System")*

**Objective:** bring the memory subsystem closer to a modern CPU.

- **Advanced branch prediction** — static, 1-bit, 2-bit (already have this
  shape from Generation 1's own BHT/BTB, see above), GShare, tournament
  predictor; benchmark all. **DONE (Phase A, `docs/adr/0040`)**: GShare
  (`design/Gshare.v`) and tournament (`design/Chooser.v` + `Bht.v`+`Gshare.v`)
  both live as `BRANCH_PREDICTOR=2`/`3`, real benchmarked cycle-count data
  via `bench_runner.py --compare-predictors`.
- **Advanced cache hierarchy** — 2-way and 4-way set-associative, victim
  cache, L2, replacement policies (LRU/FIFO).
- **Hardware prefetchers** — next-line, stride, stream.
- **Non-blocking cache** — multiple outstanding misses, MSHRs.
- **Memory controller** — burst transfers, improved arbitration.

**Release:** Advanced Memory Architecture v4.0.

---

## Generation 5 — Multicore SoC (v5.0)

*(source material: "Phase I — Multicore SoC")*

**Objective:** scale beyond a single core.

- Dual core.
- Quad core.
- Shared memory system.
- Bus arbiter.
- MESI cache coherence.
- Atomic instructions.

**Release:** Multicore RISC-V SoC v5.0.

---

## Generation 6 — Out-of-Order Core (v6.0)

*(source material: "Phase J — Next-Generation Core". Explicitly called out
in the source material as **a new core, not a modification of the existing
pipeline** — worth repeating here so a future session doesn't try to
retrofit register renaming onto `riscvpipeline.v`'s existing in-order
5-stage structure.)*

- Register renaming.
- Physical register file.
- Reservation stations.
- Reorder buffer.
- Load/store queue.
- Tomasulo scheduling.
- Speculative execution.
- Dual-issue pipeline. (Note: this project's own second-wave Phase H
  already delivers an in-order dual-issue design earlier than this,
  against the *existing* pipeline — that's a genuinely different, smaller
  step than this generation's own from-scratch OoO dual-issue core. Both
  are legitimate; don't conflate them when this generation starts.)

**Release:** Out-of-Order RV64 Processor v6.0.

---

## Generation 7 — Vector Processing (v7.0)

*(source material: "Phase K — Vector Processing")*

- Vector register file.
- Vector ALU.
- Vector load/store.
- Mask operations.
- Vector benchmarks.

**Release:** RV64 Vector Processor v7.0.

---

## Generation 8 — Reliability & Security (v8.0)

*(source material: "Phase L — Reliability & Security")*

- Physical Memory Protection (PMP).
- Secure boot.
- ECC memory support.
- Watchdog timer.
- Built-In Self-Test (BIST).
- Fault injection framework.
- Clock gating.
- Power optimization.

**Release:** Production-Ready Secure Processor v8.0.

---

## Generation 9 — FPGA SoC Platform (v9.0)

*(source material: "Phase M — FPGA SoC Platform". Note: this project's own
Phase 7 (`docs/ROADMAP.md`) already has FPGA bring-up scaffolding
(`fpga/top.v`, `fpga/constraints_template.xdc`) and has never touched real
hardware — that's a much smaller, still-open item, not the same scope as
this generation's full peripheral platform.)*

Support for: DDR memory, Ethernet, HDMI/VGA, SD card, USB UART, GPIO, SPI
Flash, audio; FPGA timing closure and resource optimization.

**Release:** Complete FPGA SoC v9.0.

---

## Generation 10 — CPU Architecture Laboratory (final vision)

*(source material: "Phase N — CPU Architecture Laboratory")*

Instead of one fixed CPU, a configurable research platform: choose RV32 or
RV64, pipeline depth, hazard strategy, branch predictor, cache size/
associativity, memory latency, divider implementation, FPU on/off, MMU
on/off, core count, vector extension on/off — then one command generates
the configured RTL, builds it, runs directed + constrained-random
verification, runs benchmarks, generates IPC/CPI reports, compares
configurations, and produces HTML/PDF reports with performance graphs.

(Note: this project already has real precedent for exactly this pattern at
smaller scale — `HAZARD_STRATEGY`, `PIPELINE_PROFILE`, and
`BRANCH_PREDICTOR` are all closed, named, elaboration-time-selected
parameters today, each with its own `bench_runner.py --compare-*` report.
Generation 10 is that same discipline generalized across every axis in the
list above, not a new idea introduced from scratch.)

---

## Evolution summary

```
Gen 1  RV32IMAF Research Processor        (this project's Phase A-E, + in-progress F-H)
Gen 2  RV64 Processor
Gen 3  Linux-capable RV64 Processor
Gen 4  Advanced Memory Architecture
Gen 5  Multicore SoC
Gen 6  Out-of-Order Processor
Gen 7  Vector Processor
Gen 8  Secure & Reliable Processor
Gen 9  Complete FPGA SoC
Gen 10 CPU Architecture Laboratory
```
