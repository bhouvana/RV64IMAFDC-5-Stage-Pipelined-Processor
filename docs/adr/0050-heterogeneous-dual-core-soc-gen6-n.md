# ADR 0050: Heterogeneous Dual-Core SoC — PIPELINED + OOOCore.v (Gen6-N)

## Problem

The user asked for the out-of-order core to be genuinely integrated with PIPELINED so both "work
together," not just coexist in the same repository. Confirmed via `AskUserQuestion`: heterogeneous
dual-core (big-little), both cores simultaneously instantiated, real work handoff — not a build-time
core-select switch, not a lockstep checker pair. This effectively revives Generation 5 (multicore),
explicitly skipped earlier this session by user request, in asymmetric form.

Real interaction requires shared memory or signaling. Neither core exposed any external memory/signal
bus before this phase: `OOOCore.v`'s `DataMemoryBRAM` was fully private (trivial to add ports, it's
this generation's own module), but `PIPELINED`'s (`design/riscvpipeline.v`) was too — and this whole
project has held "never modify PIPELINED" as a hard rule across every ADR since Gen6 started. Confirmed
via a second `AskUserQuestion`: add a small, additive, backward-compatible port to PIPELINED (every
existing instantiation keeps working unchanged), rather than settle for a simulation-only hierarchical
peek that isn't real synthesizable hardware.

## Design

### `design/Mailbox.v` — the real handoff surface

A small (`NUM_WORDS`, default matching `MAILBOX_SIZE`/4 = 64) word-only dual-port memory. Two fully
independent ports:
- **Port A**: a real classic (non-pipelined) Wishbone slave — the exact shape `WbDecoder.v` already
  routes to for `Uart.v`/`Timer.v`/`RamWishboneAdapter.v`. Combinational, same-cycle ack, matching
  `Uart.v`'s own established "this slave always completes in the same cycle it's addressed" convention.
- **Port B**: the same simple direct interface `DataMemoryBRAM.v` exposes
  (`memRead`/`memWrite`/`address`/`writeData`/`readData`, word-only). **Registered, 1-cycle read
  latency, bit-for-bit matching `DataMemoryBRAM.v`'s own `raw_word_r` timing** — `LoadStoreQueue.v`
  (Gen6-E) assumes exactly this fixed latency (no real wait-state model), so this port needed to
  present it identically to be a true drop-in address-range peer, not just a same-shaped port.

Both ports read/write the same cycle without stalling either core (a real dual-port memory, not
arbitrated) — a same-cycle same-word write from both ports is a real, unspecified race, same "caller
enforces the contract" discipline `FreeList.v`/`DCache.v`'s own MSHR array already establish. The real
protocol (below) partitions words so each core only ever writes its own designated words.

### `design/OOOCore.v` — new mailbox port (this generation's own module, freely editable)

New top-level ports (`mailbox_memWrite`/`memRead`/`address`/`writeData`/`readData`), unconnected in
every existing standalone test (changes nothing there). An address-range split before `m_DMem`
(mirroring `WbDecoder.v`'s own BASE/SIZE hit-test idiom, a single fixed range so a plain compare is
simpler than the general N-slave module for one slave) routes a `MAILBOX_BASE`/`MAILBOX_SIZE` access
to the new mailbox port instead of the private `DataMemoryBRAM`. A registered select bit
(`mailbox_hit_r`) muxes the two memories' own read-back data — needed because the request that
determines the hit lands one cycle, but the DATA it produces isn't valid until the next (matching both
memories' own registered-read timing).

### `design/riscvpipeline.v` — new mailbox port (additive, minimal surgery)

`WbDecoder.v`'s own `NUM_SLAVES` widened 3→4 — slave 3 (`MAILBOX_BASE`) **appended** as the new
highest slot specifically so slots 0/1/2 (RAM/UART/TIMER)'s own indices stay exactly what every other
hardcoded `wb_s_cyc[N]` reference in the file already assumes (zero renumbering risk). New top-level
ports (`mailbox_m_cyc`/`stb`/`we`/`addr`/`data_o`/`sel` outputs, `mailbox_s_data_i`/`s_ack` inputs) —
a plain passthrough to slot 3, touching zero existing execution/decode logic. Every one of the ~80
existing PIPELINED testbenches leaves these unconnected (the same "unconnected changes nothing" shape
every `debug_*` tap in this file already uses) — this produces a dangling-input `-Wall` warning on
each, but `sim/run_tests.sh`'s own actual compile flags don't use `-Wall`, so none of them break; a
spot-check on a real (non-template) testbench confirmed exactly the 2 expected new warnings and
nothing else.

`riscv_defs.vh` gains `MAILBOX_BASE`/`MAILBOX_SIZE` (0x1020_0000, 256 bytes) — a fresh 0x10000-aligned
base off `TIMER_BASE`, the same precedent `TIMER_BASE` itself already used off `UART_BASE`.

### `design/HeteroSoC.v` — the new top-level SoC

Instantiates `PIPELINED` + `OOOCore` + `Mailbox`, each core with its own private instruction/data
memory (own program each — a real, deliberate simplification: sharing IMEM would need a second
arbitration dimension with no real benefit, since the two cores run genuinely different programs by
construction). Two independent resets (`rst_ooo`, active-low; `start_pipelined`, active-high) —
preserved exactly as each core's own module already defines its own reset polarity, not homogenized.

### The real ISA constraint, and the protocol it forces

`OOOCore.v` cannot execute jal/jalr/lui/auipc/csrrX/general-AMO/interrupts (its own header,
`docs/adr/0048`'s own findings). Whatever program the "little core" runs must avoid every one of
those — large constants via the same chunked `addi`/`slli` idiom `random_gen.py`'s own `no_lui` mode
established, control flow via conditional branches only, no function calls. A real, load-bearing
limitation on what can be offloaded to it today, not hidden.

**A genuinely useful discovery made while writing the worker program**: `beq x0, x0, <label>` is
*always* taken (x0 always equals x0) — a real, working infinite self-loop using only a conditional
branch, an instruction class OOOCore.v actually executes correctly (Gen6-G). Unlike
`random_gen.py`'s own jal-based halt trailer (which doesn't work in OOOCore.v — PC falls through
instead of looping, see `docs/adr/0048`), this one genuinely halts. Both the mailbox-poll loops and
the final halt in `sim/programs/hetero_ooo_n1.s` use this idiom.

### Mailbox protocol (this phase's own directed test)

Word layout: `+0` GO (PIPELINED writes last, after every input word is committed), `+4` N (element
count), `+8` DONE (OOOCore.v writes once finished), `+12` RESULT, `+16..` data[0..N-1]. PIPELINED
(`sim/programs/hetero_pipelined_n1.s`) writes a 6-element array, raises GO, polls DONE, reads RESULT
into x10 (the same "the" result-register convention `debug_x10`/`EXPECTED_X10` already use elsewhere).
OOOCore.v (`sim/programs/hetero_ooo_n1.s`) polls GO, sums the array, writes RESULT + DONE.

## Testing

`tb_mailbox_unit.v`: 6/6 checks — cross-port visibility both directions, each port's own latency
convention, word-addressing, non-interference between words.

`tb_hetero_soc_n1.v`: 11/11 checks, first clean run — PIPELINED's own x10 == 21 (1+2+...+6), every
mailbox word checked directly (GO/N/DONE/RESULT/every data word), proving this is a genuine cross-core
handoff (OOOCore.v actually computed the sum and PIPELINED actually read it back), not two cores that
merely coexist in one file.

Full directed regression 125/125 (up from 123 pre-Gen6-N). `run_random_tests.py --ooo` (15/15) and
`bench_runner.py --compare-ooo` (both kernels clean, unaffected) re-confirmed unaffected by the
`OOOCore.v` port additions.

## Alternatives considered

- **Sharing one DataMemoryBRAM between both cores via a real contested Wishbone arbiter**: rejected —
  `LoadStoreQueue.v` (Gen6-E) assumes DataMemoryBRAM's own fixed, always-ready latency with no
  wait-state model at all; introducing real bus contention would need extending Gen6-E's own LSQ to
  tolerate variable latency, a much larger, separate piece of surgery. A small dedicated dual-port
  mailbox (genuinely uncontended, matching each core's own existing timing assumptions exactly) is the
  minimal-surgery, real-risk-appropriate design for what a handoff protocol actually needs.
- **Sharing instruction memory**: rejected — the two cores run different programs by construction (a
  general-ISA control core vs. a narrow-ISA numeric worker); nothing is gained by contending for fetch
  bandwidth on top of that.
- **Retrofitting an interrupt-based wakeup for OOOCore.v instead of polling**: rejected — OOOCore.v
  has no interrupt support at all (`docs/adr/0047`'s own scope), and building one is a separate, real
  RTL phase, not a Gen6-N tooling/integration concern. Polling on a real conditional branch
  (`beq x0,x0,poll`-style spin) is a legitimate, working mechanism given that constraint.

## Future improvements

- Real interrupt-driven wakeup for OOOCore.v (removes polling latency) — needs OOOCore.v interrupt
  support first, real future work already flagged.
- A richer mailbox protocol (multiple outstanding tasks, a real work queue instead of one
  go/done pair) once there's a real multi-task workload to justify it.
- Dynamic instruction loading for OOOCore.v (today's worker program is fixed at elaboration time via
  `IMEM_INIT_FILE`) — would need a real instruction-memory write path, not attempted here.
- Everything `docs/adr/0049`'s own Future improvements section still lists (jal/jalr/lui/auipc/csrrX
  implementation — would also widen what a worker program can do — deep speculation, general AMO-RMW
  +SC, Sv39 MMU+interrupts, FDIV/FSQRT/FMADD/FLW/FSW/FCVT/FCMP) remains open.
