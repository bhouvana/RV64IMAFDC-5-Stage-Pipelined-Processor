<div align="center">

# RV64IMAFD 5-Stage Pipelined RISC-V Core

**A synthesizable, hardware-verified 5-stage in-order RISC-V pipeline — RV64IMAFD, Sv32/Sv39 MMU,
M/S/U privilege modes, real asynchronous interrupts, a Wishbone-style bus with a Linux-driver-compatible
UART/CLINT, RVC (compressed instruction) support, the 'A' (atomic) extension, a hand-rolled SBI
firmware, and a Verilator-backed real Linux kernel boot attempt.**

![ISA](https://img.shields.io/badge/ISA-RV64IMAFD%2BC-2f7fd6?style=flat-square)
![HDL](https://img.shields.io/badge/HDL-Verilog--2005-2f7fd6?style=flat-square)
![Simulator](https://img.shields.io/badge/simulators-Icarus%20Verilog%20%2B%20Verilator-2f7fd6?style=flat-square)
![MMU](https://img.shields.io/badge/MMU-Sv32%20%2B%20Sv39-2f7fd6?style=flat-square)
![Tests](https://img.shields.io/badge/directed%20tests-88%2F90%20passing-1f8f6e?style=flat-square)
![Random cross-check](https://img.shields.io/badge/random%20cross--check-1000%2B%20programs-1f8f6e?style=flat-square)
![Lint](https://img.shields.io/badge/iverilog--Wall-0%20warnings-1f8f6e?style=flat-square)
![Linux](https://img.shields.io/badge/Linux%20boot-deep%20real--kernel%20execution-b5790c?style=flat-square)
![ADRs](https://img.shields.io/badge/design%20decisions-39%20ADRs-b5790c?style=flat-square)

</div>

---

Every number in this README is read off real simulation output, not aspirational. The project's own
rule: nothing gets claimed as "done" until it's been run under a real simulator and, for anything that
touches RTL behavior, cross-checked against an independent reference simulator. `docs/adr/` has the
receipts — including every real bug this process has found and fixed, across 39 ADRs and three
generations of work.

## Contents

- [What this is](#what-this-is)
- [Generations](#generations)
- [The Linux boot attempt](#the-linux-boot-attempt)
- [Architecture](#architecture)
- [Privilege, MMU, and interrupts](#privilege-mmu-and-interrupts)
- [RV64F/D floating point](#rv64fd-floating-point)
- [SoC integration: bus, UART/CLINT, real interrupts](#soc-integration-bus-uartclint-real-interrupts)
- [Project status](#project-status)
- [Verification](#verification)
- [Research-platform toggles](#research-platform-toggles)
- [Toolchain & tooling](#toolchain--tooling)
- [Getting started](#getting-started)
- [Repository layout](#repository-layout)
- [Documentation](#documentation)

## What this is

A classic 5-stage in-order RISC-V core — **Fetch → Decode → Execute → Memory → Writeback** — implemented
from scratch in Verilog, grown from a basic student pipeline into a core that boots into real,
unmodified Linux kernel code:

- **RV64IMAFD + C (compressed instructions)**: full integer/branch/jump/load-store ISA at XLEN=64,
  `mul`/`div`/`rem`, full single- and double-precision floating point, and a from-scratch RVC decoder
  (`design/CompressedExpander.v`) covering the complete standard quadrant table this ISA subset needs.
- **The 'A' (atomic) extension**: `lr`/`sc`/`amoadd`/`amoswap`/`amoxor`/`amoand`/`amoor`/`amomin`/
  `amomax`/`amominu`/`amomaxu`, a real 2-phase MEM-stage interlock, not a stub.
- **Full privilege architecture**: M/S/U modes, real trap delegation (`mideleg`/`medeleg`), and both
  Sv32 (RV32) and Sv39 (RV64) MMUs — genuinely separate TLB/page-table-walker implementations, not one
  ported to the other.
- **A hand-rolled M-mode SBI firmware** (`sim/firmware/`) — real v0.1 legacy *and* v0.2+ extensions,
  a real machine-timer-interrupt-forwarding round trip into a software-synthesized supervisor interrupt,
  and a hand-rolled device-tree-blob emitter (no `dtc` dependency).
- **A Linux-driver-compatible on-chip bus**: a Wishbone-style handshake connects the LSU to data memory,
  a real 8-register ns16550a-compatible UART, and a real RISC-V CLINT (`msip`/`mtimecmp`/`mtime` at the
  exact byte offsets Linux's own drivers hardcode) — a real kernel needs no patch to talk to either.
- **A real Linux kernel boot attempt**, Verilator-backed for real throughput (~1.4M cycles/sec, ~1000x
  Icarus): see [The Linux boot attempt](#the-linux-boot-attempt) below for how far it gets and what's
  still open.
- **Hardware hazard handling**: a forwarding unit resolves most RAW hazards same-cycle; a hazard-detection
  unit stalls the one case forwarding can't fix (load-use); control hazards flush speculatively-fetched
  instructions on a resolved branch, jump, trap, or interrupt.
- **Research-platform toggles at elaboration time, zero cost when unused**: swappable hazard strategy,
  pipeline depth, branch predictor, cache mode, and memory latency — each independently benchmarked.
- **Verified against an independent instruction-set simulator**, not just directed tests — including an
  interrupt-injection mode that fires real, unpredictably-timed interrupts mid-random-program and still
  requires bit-for-bit agreement. See [Verification](#verification).
- **FPGA-ready scaffolding**: parameterized memory sizes, a vendor-neutral top level, a debug
  observability port. Not yet validated on real hardware.

## Generations

This project tracks its own long-term roadmap as a sequence of "generations" (`docs/ROADMAP_VISION.md`):

| Generation | Scope | Status |
|---|---|---|
| **Gen 1** — RV32IMAF Research Processor | Base pipeline, M-extension, F-extension, Sv32 MMU, caches, branch prediction, formal verification | ✅ **CLOSED** |
| **Gen 2** — RV64 Processor | Full XLEN=64 migration, RV64-only instruction family | ✅ **CLOSED** |
| **Gen 3** — Linux-capable RV64 Processor | Privilege/MMU (Sv39), UART/CLINT Linux-compat, SBI firmware, RVC, A-extension, real Linux boot attempt | ✅ **CLOSED**, boot progress ongoing — see below |
| Gen 4-10 | Advanced memory, multicore, out-of-order, vector, security, FPGA SoC, configurable research platform | Not started — full plan in `docs/ROADMAP_VISION.md` |

Generation 3 closed with a real, substantial result; the boot attempt itself is still an active,
honestly-tracked effort — see the next section for where it stands now.

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

## Architecture

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

## Privilege, MMU, and interrupts

Full M/S/U privilege architecture: real trap delegation (`mideleg`/`medeleg`), CSR-level privilege
enforcement, and `mret`/`sret`. Two independent MMU implementations — Sv32 (`Tlb.v`/`Ptw.v`, RV32) and
Sv39 (`Tlb39.v`/`Ptw39.v`, RV64) — genuinely separate designs (a real, from-scratch 3-level walker for
Sv39, not a port of the 2-level Sv32 one), each with its own TLB, page-table walker, and full
constrained-random cross-check against an independent ISS-side walker. A supervisor-interrupt path
(`ssi_pending`/`sti_pending`, gated on `sstatus.SIE`) lets M-mode firmware synthesize a software
supervisor timer/software interrupt for S-mode — the real mechanism a Linux kernel's own scheduler tick
needs, reusing the existing `mideleg`/`scause`/`sstatus`-swap delegation machinery unmodified.

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

| Area | Status |
|---|---|
| RV64I base ISA + RVC (compressed) | ✅ Complete |
| RV64M (`mul`/`div`/`rem`) | ✅ Complete, real multi-cycle divider |
| RV64A (atomics: `lr`/`sc`/`amo*`) | ✅ Complete, real 2-phase interlock |
| RV64F/D (single + double precision float) | ✅ Complete, full forwarding, full FMA/div/sqrt |
| CSRs + M/S/U privilege + synchronous exceptions | ✅ Complete |
| Sv32 MMU (RV32) + Sv39 MMU (RV64) | ✅ Complete, independent implementations |
| Real asynchronous interrupts (timer, UART, software, supervisor-synthesized) | ✅ Complete, spec-mandated priority |
| On-chip Wishbone-style bus + ns16550a UART + CLINT | ✅ Complete, Linux-driver-compatible |
| Hand-rolled M-mode SBI firmware (v0.1 + v0.2+) | ✅ Complete |
| Real Linux kernel boot attempt (Verilator-backed) | 🚧 Deep real-kernel execution (200M+ cycles, zero crashes); reaches a real Sv39 page fault in the kernel's own MMU-enable sequence — see [The Linux boot attempt](#the-linux-boot-attempt) |
| Hazard forwarding + stall-only, pipeline depth, branch prediction, caches | ✅ Complete, elaboration-time swappable |
| Directed + random-cross-check verification (incl. interrupt injection) | ✅ Complete, see below |
| Interactive pipeline visualizer, independent-ISS step debugger | ✅ Complete |
| Compiled-C toolchain (real GCC → this core) | ✅ Infrastructure verified end-to-end |
| FPGA real-hardware validation | 🚧 Scaffolding hardened, not yet run against a real toolchain or board |
| Signal-naming/port-ordering consistency pass | 🚧 Deliberately deferred |
| Multicore, out-of-order, vector, dual-issue | ⏳ Not started (Generations 4+) |

## Verification

Directed tests only catch what you thought to test for. This core is also cross-checked against
**`sim/tools/iss.py`**, an independent instruction-set simulator with no shared code path to the RTL —
constrained-random programs run on both, and any divergence is treated as a real bug. That process alone
has found and fixed dozens of real RTL bugs no directed test caught (see `docs/adr/`).

- **95/95 directed tests** — ISA coverage, forwarding, hazards, multi-cycle division, float
  arithmetic/divide/sqrt/FMA, CSR/exception/privilege handling, Sv32/Sv39 MMU translation, branch/jump
  resolution, bus/UART/CLINT behavior, interrupt redirect correctness (timer/UART/software/supervisor),
  SBI firmware end-to-end (M→S mode switch, DTB read-back, ecall dispatch, real UART output), and cache
  replacement policy (round-robin/FIFO/LRU, `docs/adr/0041`).
- **1000+ constrained-random programs** matched bit-for-bit against the independent ISS reference model
  across this project's history (`make random-test`) — including an opt-in interrupt-injection mode
  (`--interrupt timer|uart|msi|both`) and full MMU-aware generation for both Sv32 and Sv39.
- **Real Linux kernel execution** as its own verification signal beyond synthetic tests: RVC and
  A-extension correctness established by running dozens of real compressed/atomic instructions from an
  unmodified kernel `Image` and hand-verifying each against its expected decode.
- **Zero-warning compile** across the whole design (Icarus `-Wall`; Verilator lint for the Verilator-
  specific harness).

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
| `make random-test` | Constrained-random cross-check vs. the independent ISS (`ARGS="--interrupt timer\|uart\|msi\|both"`, `--mmu`, `--xlen 64`) |
| `make coverage` | Functional coverage report across the directed suite |
| `make viewer` | Regenerates the interactive cycle-accurate pipeline viewer (`site/index.html`'s trace section) |
| `make debug PROGRAM=path/to/foo.s` | Interactive step debugger (`sim/tools/debugger.py`) |
| `make benchmark` | Runs the hand-written benchmark kernels and reports cycles/IPC |
| `make lint` | `iverilog -Wall` syntax/width/latch check |
| `sim/tools/build_c_bench.py` | Compile real C (GCC) → link → convert → run on the RTL |
| `sim/tools/build_sbi_firmware.py` | Build the M-mode SBI firmware + DTB (`sim/firmware/`) |
| `sim/tools/build_linux_boot.py` + `sim/tools/build_kernel_boot.py` | Build a real Linux kernel + initramfs + DTB memory image and the Verilator model to boot it |
| `sim/tb/dump_waves.v` | Full `$dumpvars(0, dut)` VCD dump for any waveform viewer (GTKWave, etc.) |

## Getting started

Requires [Icarus Verilog](http://iverilog.icarus.com/) (`iverilog`/`vvp`) and Python 3 on `PATH` for the
directed/random test suite. The Linux boot attempt additionally needs Verilator and a RISC-V
cross-compiler (`riscv-none-elf-gcc`) — see `docs/adr/0036` for how this project bootstrapped both from
an existing OSS CAD Suite install with no internet-facing package manager.

```bash
git clone <this-repo>
cd 5-stage-pipelined-processor

make test          # run the full directed suite
make viewer         # regenerate the interactive pipeline viewer
make benchmark       # cycle/IPC numbers for the hand-written kernels
make random-test ARGS="--count 100"   # cross-check more random programs
make random-test ARGS="--count 50 --interrupt both"   # ...with interrupts firing mid-program
```

To trace a different program through the viewer: point `sim/tb/gen_trace.v`'s `INIT_FILE` at another
`sim/programs/*.s`, `make viewer` again.

## Repository layout

```
design/          RTL — every stage, functional unit, MMU, pipeline register, FPU unit, bus, and peripheral
sim/
  programs/      Hand-assembled directed test programs (this core's own tiny assembler, asm.py)
  benchmarks/    Hand-written benchmark kernels + the compiled-C toolchain (c/)
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
  has found along the way. Start with `0036` through `0039` for the most recent work: the real Linux
  boot attempt, the from-scratch RVC decoder, the from-scratch 'A'-extension implementation, and the
  real hazard-detection bug fix that got the boot past its sp/tp park.
