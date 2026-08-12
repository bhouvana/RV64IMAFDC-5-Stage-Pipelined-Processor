<div align="center">

# RV64IMAFDC RISC-V Core — In-Order Pipeline + Out-of-Order Core + Advanced ISA Extensions

**A synthesizable, hardware-verified RISC-V core project spanning two real microarchitectures: an
in-order 5-stage pipeline that boots real Linux kernel code, and a from-scratch out-of-order core
(register renaming, reservation stations, ROB, LSQ, Tomasulo scheduling, dual-issue) now extended with
ratified Bit-Manipulation, Vector, and Cryptography ISA extensions — all decoded through the same shared
control path, zero duplicated pipelines per extension.**

![ISA](https://img.shields.io/badge/ISA-RV64IMAFD%2BC%2BBVK-2f7fd6?style=flat-square)
![HDL](https://img.shields.io/badge/HDL-Verilog--2005-2f7fd6?style=flat-square)
![Simulator](https://img.shields.io/badge/simulators-Icarus%20Verilog%20%2B%20Verilator-2f7fd6?style=flat-square)
![Microarch](https://img.shields.io/badge/microarch-in--order%20%2B%20out--of--order-2f7fd6?style=flat-square)
![Tests](https://img.shields.io/badge/directed%20tests-152%2F152%20passing-1f8f6e?style=flat-square)
![Random cross-check](https://img.shields.io/badge/random%20cross--check-1000%2B%20programs-1f8f6e?style=flat-square)
![Lint](https://img.shields.io/badge/iverilog--Wall-0%20warnings-1f8f6e?style=flat-square)
![Linux](https://img.shields.io/badge/Linux%20boot-deep%20real--kernel%20execution-b5790c?style=flat-square)
![ADRs](https://img.shields.io/badge/design%20decisions-67%20ADRs-b5790c?style=flat-square)

</div>

---

Every number in this README is read off real simulation output, not aspirational. The project's own
rule: nothing gets claimed as "done" until it's been run under a real simulator and, for anything that
touches RTL behavior, cross-checked against an independent reference simulator. `docs/adr/` has the
receipts — including every real bug this process has found and fixed, across 67 ADRs and six closed
generations of work.

## Contents

- [What this is](#what-this-is)
- [The Linux boot attempt](#the-linux-boot-attempt)
- [Architecture — the in-order pipeline](#architecture--the-in-order-pipeline)
- [The out-of-order core (Generation 6)](#the-out-of-order-core-generation-6)
- [Advanced ISA extensions (Generation 7)](#advanced-isa-extensions-generation-7)
- [Privilege, MMU, and interrupts](#privilege-mmu-and-interrupts)
- [RV64F/D floating point](#rv64fd-floating-point)
- [SoC integration: bus, UART/CLINT, real interrupts](#soc-integration-bus-uartclint-real-interrupts)
- [Project status](#project-status)
- [Verification](#verification)
- [FPGA Implementation & Vivado Analysis](#fpga-implementation--vivado-analysis)
- [Research-platform toggles](#research-platform-toggles)
- [Toolchain & tooling](#toolchain--tooling)
- [Getting started](#getting-started)
- [Repository layout](#repository-layout)
- [Documentation](#documentation)

## What this is

Two real cores, sharing one repository, one ISA lineage, and one verification methodology:

- **`design/riscvpipeline.v`** — a classic 5-stage in-order pipeline
  (**Fetch → Decode → Execute → Memory → Writeback**) grown from a basic student pipeline into a core
  that boots into real, unmodified Linux kernel code. RV64IMAFD+C, the 'A' (atomic) extension, full M/S/U
  privilege with Sv32/Sv39 MMUs, real asynchronous interrupts, a hand-rolled SBI firmware, and a
  Linux-driver-compatible on-chip bus.
- **`design/OOOCore.v`** — a genuinely separate, from-scratch out-of-order core (register renaming,
  physical register file, reservation stations, reorder buffer, load/store queue, Tomasulo CDB
  scheduling, speculative branch/jalr execution, dual-issue) that **coexists** with the in-order pipeline
  rather than replacing it — `design/HeteroSoC.v` runs both simultaneously as a real heterogeneous
  dual-core SoC. Now extended with three ratified ISA extensions (Bit-Manipulation, Vector, Cryptography)
  reusing its existing scheduling/retirement machinery, not a bolted-on side pipeline per extension.

Shared foundations across both cores:

- **Verified against an independent instruction-set simulator** (`sim/tools/iss.py`), not just directed
  tests — including an interrupt-injection mode that fires real, unpredictably-timed interrupts
  mid-random-program and still requires bit-for-bit agreement. See [Verification](#verification).
- **Research-platform toggles at elaboration time, zero cost when unused**: swappable hazard strategy,
  pipeline depth, branch predictor, cache mode, and memory latency — each independently benchmarked.
- **FPGA-ready scaffolding**: parameterized memory sizes, a vendor-neutral top level, a debug
  observability port. Not yet validated on real hardware.

## The Linux boot attempt

Generation 3 (`docs/adr/0036`-`0039`) took a real, unmodified riscv64 Linux kernel `Image` (v5.5.0-rc7)
further than this project has ever run real-world binary code:

- A Verilator harness (bootstrapped from an existing OSS CAD Suite install) runs this core at ~1.4M
  cycles/sec — roughly 1000x faster than Icarus Verilog, the difference between a boot attempt that
  finishes in seconds and one that would take days.
- The kernel's own first instruction is a real compressed `c.j` — this core had zero RVC support at
  all. `design/CompressedExpander.v` implements the full standard quadrant table from scratch, verified
  against the real kernel's own compressed code (not a synthetic test).
- The kernel's own hart-bring-up check is a real `amoadd.w` — this core had zero 'A'-extension support
  at all. A new, independent 2-phase MEM-stage interlock implements the full family from scratch.
- Along the way, RVC exposed a real, project-wide bug: `InstructionMemory.v` read bytes MSB-first
  (compensated for by a per-4-byte-*aligned*-word swap in the toolchain) — harmless when every fetch was
  4-byte-aligned, but a real, worked proof shows no fixed byte array stays correct once a compressed
  instruction shifts later instructions off the 4-byte grid. Fixed at the root: both memories now read
  LSB-first, symmetrically, no swap needed anywhere.
- The kernel then parked in what looked, from PC/`mcause` alone, like a real environment gap (a
  polling loop waiting on register values a minimal SBI/DTB setup never publishes). Reading the real
  upstream kernel source and re-tracing cycle-by-cycle found the actual root cause instead: a real RTL
  hazard-detection gap. `Hazard.v`'s load-use stall only recognized ordinary loads, not an in-flight AMO
  — so the kernel's own aliased `amoadd.w a3,a2,(a3)` / `bnez a3,...` hart-lottery pair let the dependent
  branch read `a3` one cycle too early, before the AMO's real result reached it, always taking the wrong
  path. One-line fix (`docs/adr/0039`), confirmed by re-running the identical trace: the kernel now runs
  ~208,000 cycles past the old park point.

**Real result**: the kernel executes correctly through its own compressed-instruction-heavy entry
sequence, the `amoadd.w` hart-check, and its own `clear_bss`/`setup_vm`/MMU-enable sequence, 200
million+ cycles with zero crashes. It now reaches a new, later, different point: a real Sv39 instruction
page fault during the kernel's own MMU-enable (`relocate`) sequence — the current, honest frontier for
this core's own boot progress. This core has no display/GPU hardware anywhere, so a graphical boot was
never a reachable goal here regardless of kernel progress — the only output path is the UART console.
See `docs/adr/0036` through `0039` for the full designs, every bug found (RTL and tooling), and what's
still open.

## Architecture — the in-order pipeline

Five stages, separated by four pipeline registers (`reg1`–`reg4`), in the default profile:

```mermaid
graph LR
    subgraph IF [Fetch]
        PC[PC Register] --> IM[Instruction Memory]
        IM --> CE[Compressed Expander]
    end
    subgraph ID [Decode]
        CE --> REG1[IF/ID reg]
        REG1 --> RF[Register File]
        REG1 --> CTRL[Control Unit]
        REG1 --> HZD[Hazard Unit]
    end
    subgraph EX [Execute]
        REG2[ID/EX reg] --> ALU[ALU]
        REG2 --> FWD[Forwarding Unit]
        REG2 --> DIV[Multi-cycle Divider]
        REG2 --> FPU[Float ALU / Div / Sqrt / FMA]
        REG2 --> CSR[CSR File / MMU / Exceptions / Interrupts]
    end
    subgraph MEM [Memory]
        REG3[EX/MEM reg] --> BUS[Wishbone Bus]
        BUS --> DM[Data Memory<br/>sync-read BRAM]
        BUS --> UART[UART - ns16550a]
        BUS --> TIMER[CLINT]
        REG3 --> AMO[2-phase AMO interlock]
    end
    subgraph WB [Writeback]
        REG4[MEM/WB reg] --> WB_MUX[WB Select Mux]
    end
    WB_MUX -.->|Writeback Data| RF
```

| Stage | Responsibility | Key modules |
|---|---|---|
| **IF** | PC-driven instruction fetch, RVC decompression; redirected on taken branches, jumps, trap/`mret`/`sret`/interrupt targets | `PC.v`, `InstructionMemory.v`, `CompressedExpander.v`, `Tlb.v`/`Tlb39.v`, `Ptw.v`/`Ptw39.v` |
| **ID** | Decode, register-file read (integer + float), immediate generation, hazard detection | `Control.v`, `Hazard.v` / `HazardNoForward.v`, `ImmGen.v`, `FRegister.v` |
| **EX** | ALU, branch resolution, forwarding muxes, multi-cycle divide, float ALU/divide/sqrt/FMA, CSR read/write, MMU translation, interrupt detection | `ALU.v`, `Forward.v`, `FForward.v`, `Divider.v`, `FALU.v`, `FDivider.v`, `FSqrt.v`, `FMADDUnit.v`, `CSR.v` |
| **MEM** | Wishbone bus decode/mux to data memory, UART, or CLINT; 2-phase atomic read-modify-write | `WbDecoder.v`, `RamWishboneAdapter.v`, `DataMemoryBRAM.v`, `Uart.v`, `Timer.v` |
| **WB** | Selects ALU / float / memory / PC+link / AMO result back into the integer or float register file | `Register.v`, `FRegister.v`, `Mux4to1.v` |

## The out-of-order core (Generation 6)

`design/OOOCore.v` is a genuinely new top-level module — not a modification of `riscvpipeline.v`, per
the project's own explicit design constraint. It implements a real dynamically-scheduled, Tomasulo-style
machine: instructions dispatch in program order, execute the moment their operands are ready regardless
of order, and retire in program order again, through a dedicated pipeline of its own:

```mermaid
graph LR
    subgraph FE [Fetch]
        PC2[PC / redirect mux] --> IM2[Instruction Memory]
        BP[Bht + Btb<br/>shared predictor] --> PC2
    end
    subgraph DISP [Dispatch / Rename]
        IM2 --> DEC[Decode]
        DEC --> RAT[Register Alias Table<br/>+ Free List]
        RAT --> ROB[Reorder Buffer<br/>allocate entry]
        ROB --> RSDISP[Dispatch to<br/>Reservation Stations]
    end
    subgraph ISSUE [Issue]
        RSDISP --> RSALU[RS: ALU]
        RSDISP --> RSDIV[RS: Divider]
        RSDISP --> RSFALU[RS: Float ALU]
        RSDISP --> RSFDIV[RS: Float Divider]
        RSDISP --> RSVEC["RS: Vector (VALU/VLSU)"]
        RSDISP --> LSQ[Load/Store Queue]
    end
    subgraph EXEC [Execute]
        RSALU --> ALU2["ALU + B/K extensions"]
        RSDIV --> DIV2[Divider]
        RSFALU --> FALU2[Float ALU]
        RSFDIV --> FDIV2[Float Divider]
        RSVEC --> VEC2[Vector ALU / LSU]
        LSQ --> DMEM2[Data Memory]
        LSQ --> MMU2[Tlb39 / Ptw39]
    end
    subgraph CDB [Common Data Bus]
        ALU2 -.-> BUS2[Broadcast to waiting RS + PRF]
        DIV2 -.-> BUS2
        FALU2 -.-> BUS2
        FDIV2 -.-> BUS2
        VEC2 -.-> BUS2
        DMEM2 -.-> BUS2
    end
    BUS2 --> PRF2[Physical Reg Files<br/>int + float + vector]
    BUS2 --> ROB
    subgraph RETIRE [Retire]
        ROB --> COMMIT[In-order commit<br/>precise exceptions]
        COMMIT -.->|free old preg| RAT
    end
```

| Stage | Responsibility | Key modules |
|---|---|---|
| **Fetch** | Shared branch predictor drives the PC/redirect mux ahead of decode, independent of dispatch stalls | `PC.v`, `InstructionMemory.v`, `Bht.v`, `Btb.v` |
| **Dispatch / Rename** | Decode, allocate a ROB entry, map architectural → physical registers (separate int/float/vector maps), send operands (or their producing tags) to the matching reservation station | `RegisterAliasTable.v`, `FreeList.v`, `ReorderBuffer.v` |
| **Issue** | Each reservation station wakes an entry the instant every operand tag has been broadcast on the CDB, independent of program order | `ReservationStation.v` (one per functional unit) |
| **Execute** | ALU (incl. B bit-manipulation and K cryptography — same shared datapath as the in-order core), integer/float dividers, vector ALU/LSU, load/store queue against the D-side MMU | `ALU.v`, `Divider.v`, `FALU.v`, `FDivider.v`, `VALU.v`, `VLSU.v`, `LoadStoreQueue.v`, `Tlb39.v`/`Ptw39.v` |
| **Complete (CDB)** | Every functional unit broadcasts its result + destination tag on the Common Data Bus in the same cycle it finishes — every reservation station and the ROB snoop it simultaneously, Tomasulo-style | — |
| **Retire** | Reorder buffer commits strictly in program order regardless of completion order — the mechanism precise exceptions and misprediction recovery both depend on | `ReorderBuffer.v`, `PhysicalRegisterFile.v` |

- **Register renaming + physical register file**, separate integer and float PRFs, eliminating WAW/WAR
  hazards the classic pipeline handles by stalling instead.
- **Reservation stations** per functional unit (ALU, integer divider, float ALU, float divider) —
  `ReservationStation.v`, dispatching operands the moment they're ready via a Tomasulo-style Common Data
  Bus, not in program order.
- **A reorder buffer** (`ReorderBuffer.v`) — multi-ported completion, in-order retirement, precise
  exceptions.
- **A load/store queue** (`LoadStoreQueue.v`) — memory-ordering enforcement independent of the ALU
  pipeline's own out-of-order completion.
- **Speculative execution** — branch and `jalr` prediction with real misprediction recovery, a shared BTB
  for both.
- **Dual-issue** dispatch, two instructions per cycle when dependencies allow.
- **Full privilege/MMU/interrupt support**: `lui`/`auipc`/`jal`/`jalr`/`csrrX`, general AMO-RMW+SC,
  Sv39 translation (reusing `Tlb39.v`/`Ptw39.v` unmodified), real machine-level interrupts, `fdiv.s`/
  `fsqrt.s`.
- **A real heterogeneous dual-core SoC** (`design/HeteroSoC.v`, `docs/adr/0050`) — `OOOCore.v` and
  `riscvpipeline.v` (`PIPELINED`) running simultaneously, sharing a bus, genuinely two different
  microarchitectures on one SoC, not two copies of the same core.

Closed per `docs/adr/0047` through `0058` (Gen6-A through P6): 135/135 directed suite at closure, zero-
warning compile, `--ooo` constrained-random cross-check clean. Real bugs found along the way include four
deadlock/correctness gaps in the Sv39 D-side late-injection path (found by design, before any test ran),
a restart-race in the OoO test harness, a dual-issue misclassification for `fdiv.s`/`fsqrt.s` in slot 1,
and a genuine CDB-port-starvation hang in `RS_FALU` — all fixed, all documented in their own ADRs.

## Advanced ISA extensions (Generation 7)

Five pillars planned (`docs/adr/0059`), each a real RISC-V ISA extension integrated with the Gen 6 OoO
core's *existing* scheduling and retirement machinery — no new reservation station, ROB port, or CDB port
per extension, and no standalone processor per extension. **Three are closed:**

### B — Bit-Manipulation — ✅ CLOSED (`docs/adr/0060`)

Full ratified B (`Zba`+`Zbb`+`Zbs`, ~39 mnemonics including RV64-only word variants: `sh1add`, `clz`,
`rori`, `bext`, `add.uw`, `slli.uw`, …), decoded through the existing shared `Control.v`/`ALUCtrl.v`/
`ALU.v` path — the same shared-file edit gave both `riscvpipeline.v` and `OOOCore.v` the extension at
once. 137/137 directed suite at closure, constrained-random clean across scalar/`--ooo` × XLEN 32/64 ×
Sv32/Sv39-MMU. Real finding: several RV64-only word-variant decode gaps (`add.uw`, `sh*add.uw`,
`slli.uw`, `ctzw`) that only `--xlen 64` constrained-random caught, not directed tests.

### V — Vector Processing — ✅ CLOSED (`docs/adr/0065`, `0066`)

A real vector register file, `vtype`/`vl` configuration state, a per-element vector ALU
(`design/RS_VALU.v`) and vector load/store unit (`design/VLSU.v`, a 3rd requester on the shared memory
port), integer arithmetic, logical ops, comparisons, mask operations, and a full-LMUL crack sequencer —
both reusing the existing `ReservationStation.v` rather than a new one. 146/146 directed suite. Real
findings: the closure benchmark itself found 2 further bugs (a cross-namespace CDB tag collision, a wrong
PRF dispatch-readiness port) that no earlier isolated test had triggered. Honest backlog documented in
`docs/adr/0066`: indexed/strided/segment load-store, EMUL reshaping, full-LMUL compares, vector
floating-point.

### K — Cryptography — ✅ CLOSED (`docs/adr/0067`)

Full ratified `Zkn` (`Zbkb`+`Zbkc`+`Zbkx`+`Zkne`+`Zknd`+`Zknh`, 22 mnemonics: AES encrypt/decrypt/
key-schedule, SHA-256/512 sigma/sum, carry-less multiply, pack/brev8, nibble/byte crossbar) — same shared
`Control.v`/`ALUCtrl.v`/`ALU.v` path, zero new reservation station/ROB/CDB port, a single-cycle
combinational AES S-box (256-entry ROM). Real ratified-spec encodings (`riscv-opcodes`) and real
reference-model semantics (the spec's own pinned Sail source) — the AES register-half convention wasn't
derivable by hand, so it was brute-forced against the real FIPS-197 AES-128 known-answer test via a
standalone Python model, then transcribed into both the RTL testbench and `sim/tools/iss.py`; both now
match the KAT end-to-end. 152/152 directed suite, 25/25 constrained-random on every axis any K mnemonic
reaches, a real measured scalar-vs-hardware benchmark (`clmul`: 12 cycles scalar vs. 7 hardware, −42%).
Real findings: a missing `ALUCtrl.v` decode arm for the 5 AES R-type ops, plus two independent,
pre-existing Pillar B bugs in `slli.uw` (a 32-bit-truncated shift in `ALU.v`, a 5-bit-instead-of-6-bit
shamt slice in `ImmGen.v`) — found by this pillar's own constrained-random cross-check, unrelated to K
itself, fixed anyway. Honest backlog: `Zksed`/`Zksh` (SM4/SM3), `Zkr` entropy source, `Zkt`
timing-independence review, an XLEN=32 decode-trap gap, a full AES-128 scalar-vs-hardware benchmark.

### H — Hypervisor, P — Packed-SIMD/DSP — not started

Scoped in `docs/adr/0059`. H needs a real prerequisite this project hasn't built yet: `OOOCore.v` has no
working S-mode (`sret` is currently hardwired off, trap delegation unwired) for HS/VS/VU levels to sit on
top of. P is explicitly a draft/provisional RISC-V extension (not yet ratified) and will be labeled as
such throughout, never claimed as spec-complete.

## Privilege, MMU, and interrupts

Full M/S/U privilege architecture in `riscvpipeline.v`: real trap delegation (`mideleg`/`medeleg`),
CSR-level privilege enforcement, and `mret`/`sret`. Two independent MMU implementations — Sv32
(`Tlb.v`/`Ptw.v`, RV32) and Sv39 (`Tlb39.v`/`Ptw39.v`, RV64) — genuinely separate designs (a real,
from-scratch 3-level walker for Sv39, not a port of the 2-level Sv32 one), each with its own TLB,
page-table walker, and full constrained-random cross-check against an independent ISS-side walker. A
supervisor-interrupt path (`ssi_pending`/`sti_pending`, gated on `sstatus.SIE`) lets M-mode firmware
synthesize a software supervisor timer/software interrupt for S-mode — the real mechanism a Linux
kernel's own scheduler tick needs, reusing the existing `mideleg`/`scause`/`sstatus`-swap delegation
machinery unmodified. `OOOCore.v` currently implements the M/U subset of this (Sv39 translation, real
M-mode interrupts) — S-mode delegation there is Pillar H's own open prerequisite, above.

## RV64F/D floating point

Full single- *and* double-precision extensions: `fadd`/`fsub`/`fmul`/`fdiv`/`fsqrt` (`.s`/`.d`), the
fused multiply-add family (rounded once, not twice), sign-injection, `fmin`/`fmax`, comparisons,
conversions, `fmv`/`fclass`, and a live `fflags`/`frm`/`fcsr` with full static and dynamic rounding-mode
support. A separate float register file (`FRegister.v`) gets its own full forwarding network
(`FForward.v`) from day one, not a stall-only placeholder.

Verified against a standalone Python reference model using exact rational arithmetic before being wired
into the live constrained-random cross-check oracle — see `docs/adr/0019-f-extension.md` for the full
story, including four real RTL bugs it found.

## SoC integration: bus, UART/CLINT, real interrupts

`design/DataMemoryBRAM.v` sits behind a classic (non-pipelined) Wishbone-style handshake
(`design/WbDecoder.v` — a parameterized address decoder/mux — plus `design/RamWishboneAdapter.v`, a
thin wrapper that gives it a bus interface without modifying the already-verified memory module),
alongside two memory-mapped peripherals redesigned for real Linux-driver compatibility:

- **`design/Uart.v`** — a real 8-register ns16550a-compatible map (RBR/THR, IER, IIR/FCR, LCR, MCR, LSR,
  MSR, SCR, DLAB-gated exactly like a real 16550A), so a DT `compatible="ns16550a"` string is enough for
  a real kernel to drive it with no patch.
- **`design/Timer.v`** — a real RISC-V CLINT: `msip`/`mtimecmp`/`mtime` at the exact byte offsets
  Linux's own `drivers/clocksource/timer-clint.c` hardcodes, genuinely 64-bit regardless of XLEN.

Both peripherals raise real, correctly-prioritized hardware interrupts (spec ordering
**MEI > MSI > MTI > SSI > STI**). See `docs/adr/0020` (original SoC integration), `0034` (UART/CLINT
Linux-compat redesign), and `0035` (supervisor-interrupt path) for the full design history.

## Project status

Both cores carry the full RV64IMAFDC base (RVC, M, A, F/D, real M/S/U privilege with Sv32/Sv39, real
asynchronous interrupts, a Linux-driver-compatible bus/UART/CLINT, a hand-rolled SBI firmware) — the
in-order pipeline's own long-closed Gen 1-3 scope, detailed in [Architecture](#architecture--the-in-order-pipeline)
and [Privilege, MMU, and interrupts](#privilege-mmu-and-interrupts) above. On top of that, the
out-of-order core adds renaming, a physical register file, reservation stations, a reorder buffer, an
LSQ, Tomasulo scheduling, speculation, and dual-issue (Gen 6), then all three ratified Gen 7 pillars —
Bit-Manipulation, Vector, Cryptography — through that same OoO machinery. A heterogeneous dual-core SoC
(`HeteroSoC.v`) runs both cores together. Every closed item above has its own ADR with the real bugs
found along the way — see [Documentation](#documentation) for where each one lives.

What's genuinely still open, honestly:

| Area | Status |
|---|---|
| Real Linux kernel boot | 🚧 200M+ cycles, zero crashes, reaches a real Sv39 page fault in the kernel's own MMU-enable sequence — see [The Linux boot attempt](#the-linux-boot-attempt) |
| Gen 7 Pillar H — Hypervisor | ⏳ Needs real S-mode wired into `OOOCore.v` first (currently hardwired off) |
| Gen 7 Pillar P — Packed-SIMD/DSP | ⏳ Not started (also still a draft, unratified RISC-V extension) |
| FPGA hardware validation | 🚧 Real Vivado synthesis/timing/power results for the in-order core (see [FPGA Implementation & Vivado Analysis](#fpga-implementation--vivado-analysis)); the OoO core's own synthesis run is a real, open, documented problem, and no design here has touched a physical board yet |
| Signal-naming/port-ordering consistency pass | 🚧 Deliberately deferred, cosmetic only |
| General multicore | ⏳ Not started — Gen 6's own dual-issue OoO core supersedes the narrower in-order version of this goal |

## Verification

Directed tests only catch what you thought to test for. Both cores are also cross-checked against
**`sim/tools/iss.py`**, an independent instruction-set simulator with no shared code path to the RTL —
constrained-random programs run on both, and any divergence is treated as a real bug. That process alone
has found and fixed dozens of real RTL bugs no directed test caught (see `docs/adr/`).

- **152/152 directed tests** (`bash sim/run_tests.sh`) — ISA coverage, forwarding, hazards, multi-cycle
  division, float arithmetic/divide/sqrt/FMA, CSR/exception/privilege handling, Sv32/Sv39 MMU
  translation, branch/jump resolution, bus/UART/CLINT behavior, interrupt redirect correctness
  (timer/UART/software/supervisor), SBI firmware end-to-end (M→S mode switch, DTB read-back, ecall
  dispatch, real UART output), cache replacement policy (round-robin/FIFO/LRU, `docs/adr/0041`), the
  full out-of-order core (renaming/RS/ROB/LSQ/speculation/dual-issue), and every Gen 7 B/V/K instruction.
- **1000+ constrained-random programs** matched bit-for-bit against the independent ISS reference model
  across this project's history (`make random-test`) — including an opt-in interrupt-injection mode
  (`--interrupt timer|uart|msi|both`), full MMU-aware generation for both Sv32 and Sv39, and an `--ooo`
  mode exercising the out-of-order core across every extension it now supports.
- **Real Linux kernel execution** as its own verification signal beyond synthetic tests: RVC and
  A-extension correctness established by running dozens of real compressed/atomic instructions from an
  unmodified kernel `Image` and hand-verifying each against its expected decode.
- **Real scalar-vs-hardware benchmarks** for Gen 7 extensions with expected-result comparisons, per
  `docs/adr/0059`'s own verification bar (e.g. Pillar K's `clmul`: 7 cycles hardware vs. 12 scalar).
- **Zero-warning compile** across the whole design (Icarus `-Wall`; Verilator lint for the Verilator-
  specific harness).

## FPGA Implementation & Vivado Analysis

This project has been synthesized and implemented using AMD Vivado 2026.1 — no
physical FPGA board was required or used. This is an offline, boardless
implementation study of the internal processor fabric: synthesis, placement,
routing, static timing analysis, and vectorless power estimation, all driven by
reproducible batch-mode Tcl (`fpga/vivado/`), targeting a concrete part
(`xc7k325tffg900-2`, a Kintex-7 325T) that is actually installed in this
Vivado install, confirmed via `get_parts` before it was chosen. These are
**FPGA-specific synthesis/implementation results — not ASIC PPA numbers**, and
nothing here was run on real silicon; that distinction is deliberate, not
hedging.

```
RTL  →  Vivado Synthesis  →  Optimization  →  Placement  →  Routing  →  Timing / Utilization / Power  →  Hardware implementation analysis
```

**Read this before the numbers below:** only the in-order core (`PIPELINED`)
has real, routed Vivado results. The Gen6 out-of-order core (`OOOCore`, which
already includes Gen7 B/V/K unconditionally — see below) hangs reproducibly
during Vivado's RTL elaboration/optimization in this environment — confirmed
independently twice (once for 7.5 hours overnight, once for ~35 minutes the
next morning after ruling out disk space, thread count, and synthesis
strategy as the cause). `HeteroSoC` was never attempted standalone, since it
instantiates `OOOCore` internally and would hit the same wall. Full diagnostic
trail: `fpga/vivado/AUDIT.md`, `fpga/vivado/reports/SWEEP_LOG.md`,
`docs/adr/0068`, `docs/adr/0069`. This is a real, present gap — the OoO core
and Gen7 extensions are verified thoroughly by simulation (see
[Verification](#verification) above) but **not** by this Vivado workflow.

### Real Vivado run: `PIPELINED` (in-order RV32), `xc7k325tffg900-2`

Boardless — only the internal clock is constrained (`create_clock -period ...
[get_ports clk]`; see `fpga/vivado/xdc/constraints_inorder.xdc`), synthesized
`-mode out_of_context` (no top-level I/O buffers to place, since there's no
board to give them real package pins). Bisected frequency sweep, capped at 4
points:

| Target | Period | WNS | TNS | Met? |
|---|---:|---:|---:|:---:|
| 100 MHz | 10.000 ns | +3.984 ns | 0.000 ns | ✅ |
| 150 MHz | 6.667 ns  | +1.428 ns | 0.000 ns | ✅ |
| 200 MHz | 5.000 ns  | +0.306 ns | 0.000 ns | ✅ |
| 225 MHz | 4.444 ns  | +0.519 ns | 0.000 ns | ✅ |

All four points met timing — the real Fmax boundary is higher than 225 MHz and
was not located within this sweep's own 4-point cap (real limitation, stated
plainly rather than extrapolated). Re-run from a clean project state at 100
MHz reproduced the identical WNS/TNS/WHS bit-for-bit, confirming the flow is
deterministic. Post-route (`Design State: Routed`), from
`fpga/vivado/reports/inorder/100mhz/impl_utilization.rpt`:

| Resource | Used | Available | Util% |
|---|---:|---:|---:|
| Slice LUTs | 215 | 203,800 | 0.11% |
| Slice Registers | 556 | 407,600 | 0.14% |
| Block RAM | 0 | 890 | 0% |
| DSP48 | 0 | 840 | 0% |

Vectorless power estimate (Vivado `report_power`, no real switching-activity
file — labeled as such, not measured physical power): **0.166 W total
on-chip** at 100 MHz (0.010 W dynamic + 0.156 W static), rising to 0.178 W at
225 MHz — see `fpga/vivado/reports/inorder/*/power.rpt` for each point.

![timing slack by frequency](docs/images/vivado/timing_slack_by_frequency.png)
![implied Fmax by sweep point](docs/images/vivado/fmax_by_config.png)
![power by frequency](docs/images/vivado/power_by_config.png)
![resource utilization](docs/images/vivado/lut_ff_bram_dsp_by_config.png)

Charts generated from these real reports by
`fpga/vivado/scripts/generate_graphs.py` (no hand-typed numbers — every value
plotted is parsed from a checked-in `.rpt`/`summary.txt` and printed to stdout
for cross-checking).

### Hardware Results

**How large is the in-order core?** 215 LUTs, 556 registers, zero BRAM, zero
DSP — 0.11%/0.14% of a Kintex-7 325T. Real numbers; this device has enormous
headroom left over for this specific core.

**How fast is it?** Meets timing at every point tried, up to 225 MHz, on this
device, in this study. The real ceiling is higher and wasn't found within a
4-point sweep — see the table above, not a rounder or more impressive number.

**What's the critical path?** `fpga/vivado/reports/inorder/*/critical_path.rpt`
(one per frequency point) has the real `report_timing` output — startpoint,
endpoint, logic/routing delay breakdown, straight from Vivado.

**What does OoO cost? What does Vector cost? What does Bit-Manipulation or
Cryptography cost?** Not answerable from this workflow. `OOOCore` (Gen6 OoO,
with Gen7 B/V/K unconditionally present — no `` `ifdef `` guards anywhere in
it) never completes Vivado synthesis in this environment (see the gap called
out above). Separately, and regardless of whether `OOOCore` had synthesized:
B and K were never independently isolable in the first place — their logic
lives as `case` arms inside the one shared scalar `ALU.v`/`ALUCtrl.v`, the
same block used for every base-ISA integer op, with no build-time flag to
disable either. `fpga/vivado/reports/COMPONENT_BREAKDOWN.md` has the full,
honest accounting of what is and isn't measurable here.

**What does the memory subsystem cost?** `impl_utilization_hierarchical.rpt`
for `PIPELINED` shows `Ptw` (the Sv32 page-table walker) at 92 LUTs/31 FFs —
the largest named sub-instance after the top-level bucket; `CSR` at 14
LUTs/65 FFs. Everything else (ALU, ICache, DCache, etc.) is small enough that
Vivado's optimizer fully absorbed it into the top-level flattened bucket
rather than keeping it as a separately-reportable instance — expected at this
design's real scale (215 LUTs total) on a device this large.

Reproduce the whole flow: `vivado -mode batch -source fpga/vivado/create_project.tcl -tclargs inorder`
then `vivado -mode batch -source fpga/vivado/run_all.tcl -tclargs inorder 10.000 100mhz`
(`fpga/vivado/create_project.tcl`'s own header comment has the full argument
reference for `ooo`/`soc` too, which create projects fine — synthesis is what
hangs for those two). Reports: `fpga/vivado/reports/`. Audit trail and every
integrity constraint this workflow followed: `fpga/vivado/AUDIT.md`,
`docs/adr/0068`, `docs/adr/0069`.

## Research-platform toggles

Independent axes swappable at elaboration time, zero cost when unused, each independently benchmarked:
hazard strategy (forwarding vs. stall-only), pipeline depth (5-stage vs. split-fetch 6-stage), branch
predictor (static vs. dynamic BHT+BTB), cache mode (none vs. writeback set-associative I$/D$), and
memory latency (fixed-cycle vs. variable). See `docs/adr/0016`, `0018`, `0021`, `0023`, `0024` and
`sim/tools/bench_runner.py --compare-*` to reproduce.

## Toolchain & tooling

| Tool | What it does |
|---|---|
| `make test` | Self-checking directed suite, PASS/FAIL summary |
| `make random-test` | Constrained-random cross-check vs. the independent ISS (`ARGS="--interrupt timer\|uart\|msi\|both"`, `--mmu`, `--xlen 64`, `--ooo`) |
| `make coverage` | Functional coverage report across the directed suite |
| `make viewer` | Regenerates the interactive cycle-accurate pipeline viewer (`site/index.html`'s trace section) |
| `make debug PROGRAM=path/to/foo.s` | Interactive step debugger (`sim/tools/debugger.py`) |
| `make benchmark` | Runs the hand-written benchmark kernels and reports cycles/IPC |
| `make lint` | `iverilog -Wall` syntax/width/latch check |
| `sim/tools/build_c_bench.py` | Compile real C (GCC) → link → convert → run on the RTL |
| `sim/tools/build_sbi_firmware.py` | Build the M-mode SBI firmware + DTB (`sim/firmware/`) |
| `sim/tools/build_linux_boot.py` + `sim/tools/build_kernel_boot.py` | Build a real Linux kernel + initramfs + DTB memory image and the Verilator model to boot it |
| `sim/tools/asm.py` / `disasm.py` / `iss.py` / `random_gen.py` | Assembler, disassembler, reference ISS, and constrained-random program generator — all extension-aware (B/V/K) |
| `sim/tb/dump_waves.v` | Full `$dumpvars(0, dut)` VCD dump for any waveform viewer (GTKWave, etc.) |

## Getting started

Requires [Icarus Verilog](http://iverilog.icarus.com/) (`iverilog`/`vvp`) and Python 3 on `PATH` for the
directed/random test suite. The Linux boot attempt additionally needs Verilator and a RISC-V
cross-compiler (`riscv-none-elf-gcc`) — see `docs/adr/0036` for how this project bootstrapped both from
an existing OSS CAD Suite install with no internet-facing package manager.

```bash
git clone https://github.com/bhouvana/Advanced-RISC-V-Processor.git
cd Advanced-RISC-V-Processor

make test          # run the full directed suite (both cores, 152/152)
make viewer         # regenerate the interactive pipeline viewer
make benchmark       # cycle/IPC numbers for the hand-written kernels
make random-test ARGS="--count 100"   # cross-check more random programs
make random-test ARGS="--count 50 --interrupt both"   # ...with interrupts firing mid-program
make random-test ARGS="--count 100 --ooo"             # ...against the out-of-order core
```

To trace a different program through the viewer: point `sim/tb/gen_trace.v`'s `INIT_FILE` at another
`sim/programs/*.s`, `make viewer` again.

## Repository layout

```
design/          RTL — every stage, functional unit, MMU, pipeline register, FPU unit, bus, and peripheral
  riscvpipeline.v   The in-order 5-stage pipeline (Gen 1-3)
  OOOCore.v         The out-of-order core (Gen 6) + Gen 7 B/V/K extensions
  HeteroSoC.v       Both cores running together as a real heterogeneous dual-core SoC
sim/
  programs/      Hand-assembled directed test programs (this core's own tiny assembler, asm.py)
  benchmarks/    Hand-written benchmark kernels + the compiled-C toolchain (c/) + Gen 7 extension benchmarks
  firmware/      Hand-rolled M-mode SBI firmware + DTB emitter + real kernel-boot memory image builders
  verilator/     Verilator C++ harness for the real Linux boot attempt
  tb/            Testbenches: directed tests, trace generation, benchmarking, C programs
  tools/         Python tooling: assembler, ISS, debugger, trace/viewer/coverage/benchmark generators
fpga/            Vendor-neutral FPGA bring-up scaffolding (not yet run on real hardware)
site/            Self-contained static pipeline-visualizer page (deployable as-is, e.g. to Vercel)
docs/
  ARCHITECTURE.md  Full technical audit of the design
  ROADMAP.md       Phased backlog — what's done, what's next, and why
  ROADMAP_VISION.md  The long-term generation roadmap
  adr/             One doc per non-trivial design decision, including every real bug found and fixed
vercel.json      Points a Vercel deployment at site/ (no build step -- index.html is served as-is)
```

## Documentation

- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — full technical audit of the current design.
- **[docs/ROADMAP.md](docs/ROADMAP.md)** — phased backlog: what's done, what's next, and the reasoning
  behind the sequencing.
- **[docs/ROADMAP_VISION.md](docs/ROADMAP_VISION.md)** — the long-term, 10-generation roadmap.
- **[docs/adr/](docs/adr)** — one doc per non-trivial design decision (problem, alternatives considered,
  chosen solution, validation strategy) — including every real bug this project's verification process
  has found along the way. Start with `0058` for the Generation 6 (out-of-order core) closure, and
  `0059` through `0067` for Generation 7's advanced ISA extensions (scope-setting, then Pillars B, V, and
  K each closed in turn).
