# Phase 1 audit: RTL readiness for Vivado synthesis

Written before any Vivado project existed. Purpose: establish, from reading
the RTL (not from "Icarus/Verilator accepted it"), whether `design/*.v`
synthesizes as-is, and what a Vivado project actually needs to point at.

## Top-level modules

Three real, distinct top modules exist in `design/`, none behind a build
flag -- each is a genuinely separate `.v` file's own `module` declaration:

| Config | Top module | File | Size |
|---|---|---|---|
| In-order | `PIPELINED` | `design/riscvpipeline.v` | 3843 lines |
| Gen6 OoO + Gen7 B/V/K | `OOOCore` | `design/OOOCore.v` | 3052 lines |
| Heterogeneous dual-core SoC | `HeteroSoC` | `design/HeteroSoC.v` | 119 lines (instantiates both of the above) |

Clock port name is `clk` on all three (confirmed by reading each module's
own port list, not assumed). Reset convention differs per module and is NOT
homogenized here (matches this project's own established pattern of
preserving each module's own convention rather than forcing uniformity):

- `PIPELINED`: `start` (active-HIGH run/reset, per `riscvpipeline.v`'s own
  header comment).
- `OOOCore`: `rst` (active-LOW, "same convention as every other module in
  this project").
- `HeteroSoC`: `rst_ooo` (active-LOW, feeds `OOOCore`'s `rst`) and
  `start_pipelined` (active-HIGH, feeds `PIPELINED`'s `start`) as two
  independent top-level ports -- the two cores are genuinely independent
  bus masters, not lockstepped, per the module's own port comments.

All three also expose debug/mailbox/interrupt ports beyond clock+reset
(`debug_*` taps, `mailbox_*` Wishbone-ish signals, `msip_pending`/
`timer_pending`/`ext_pending`). For a boardless internal-fabric study none of
these get a real pin; Vivado treats unconnected top-level input/output ports
as ordinary (unconstrained) top-level pins -- this is normal and does not
block synthesis or implementation, only leaves those specific signals'
timing/placement unconstrained, which is expected and undesirable to hide
(see the XDC files' own comments).

## Full RTL file inventory

`design/*.v` = 63 files (`ls design/*.v | wc -l`). No `.sv` files exist
anywhere in `design/` -- this project is plain Verilog-2005 throughout
(matches `docs/ROADMAP.md`'s own CQ-5 language-mode note), so Vivado's
project `target_language`/mixed-language settings need no special handling.

Functional grouping (for Phase 2's source-file question and Phase 7's later
component-cost question):

- **Memories:** `DataMemoryBRAM.v`, `InstructionMemory.v`, `Mailbox.v`,
  `InstructionMemoryWishboneAdapter.v`, `RamWishboneAdapter.v`,
  `MemoryLatencyModel.v`.
- **Caches:** `ICache.v`, `DCache.v`, `L2Cache.v`, `VictimCache.v`,
  `MemoryController.v`, `Prefetcher.v`.
- **MMU:** `Tlb.v`/`Ptw.v` (Sv32), `Tlb39.v`/`Ptw39.v` (Sv39, used by
  `OOOCore`).
- **Branch prediction:** `Bht.v`, `Btb.v`, `Gshare.v`, `Chooser.v`.
- **OoO scheduling core:** `FreeList.v`, `RegisterAliasTable.v`,
  `PhysicalRegisterFile.v`, `ReorderBuffer.v`, `ReservationStation.v`,
  `LoadStoreQueue.v`, `Scoreboard.v`.
- **Vector unit (Gen7 Pillar V):** `VALU.v`, `VLSU.v` -- distinct modules,
  each instantiated exactly once inside `OOOCore.v` (`m_VALU` at
  `OOOCore.v:2707`, `m_VLSU` at `OOOCore.v:2829`), alongside their own
  dedicated `FreeList`/`RegisterAliasTable`/`PhysicalRegisterFile`
  instances (`m_FreeList_Vec`, `m_RAT_Vec`, `m_PRF_Vec`). This makes V's
  hardware cost independently visible in a hierarchical utilization report
  without needing a separate build.
- **Bit-manipulation (Gen7 Pillar B) and cryptography (Gen7 Pillar K):**
  **not separate modules.** `grep -c "ifdef" design/OOOCore.v` returns `0` --
  there is no compile-time guard anywhere in the OoO core. AES round/key-
  schedule ops (`ALUCTL_AES64ESM/AES64ES/AES64DSM/AES64DS/AES64IM/
  AES64KS1I/AES64KS2`), SHA-256/512 sum/sig ops, and CLMUL/CLMULH all live
  as `case` arms inside `design/ALU.v` and `design/ALUCtrl.v` -- the exact
  same combinational block that also implements every base-ISA integer ALU
  op, feeding the single `m_ALU` instance (`OOOCore.v:2179`). Zbb/Zbs
  bit-manip ops share this same file. **There is no way to build "OoO
  without B" or "OoO without K" without editing `ALU.v`/`ALUCtrl.v` --
  which this workflow will not do, per the plan's own integrity rules.**
  B's and K's incremental hardware cost is therefore not independently
  measurable from this RTL as it exists today; any report below that
  touches `m_ALU`'s resource usage is reporting "base ISA + B + K combined
  ALU cost," not any one of the three alone.
- **Buses/interconnect:** `RamWishboneAdapter.v`,
  `InstructionMemoryWishboneAdapter.v`, `Mailbox.v` (the `HeteroSoC`
  inter-core channel).
- **Peripherals:** `Timer.v`, `Uart.v` (present in `design/` but not
  instantiated inside `OOOCore.v` itself -- confirmed by the Gen6 closure
  ADR's own backlog note: "a real Timer.v/Uart.v ... for OOOCore.v ...
  neither attempted").
- **Everything else** (`ALU.v`, `ALUCtrl.v`, `Adder.v`, `CSR.v`,
  `CompressedExpander.v`, `Control.v`, `Divider.v`, `FALU.v`, `FDivider.v`,
  `FForward.v`, `FMADDUnit.v`, `FRegister.v`, `FSqrt.v`, `Forward.v`,
  `Hazard.v`, `HazardNoForward.v`, `ImmGen.v`, `Mux2to1.v`, `Mux4to1.v`,
  `MuxN.v`, `PC.v`, `Register.v`, `ShiftLeftOne.v`, `WbDecoder.v`,
  `reg1.v`/`reg1a.v`/`reg2.v`/`reg3.v`/`reg4.v` (pipeline stage registers))
  are ordinary combinational/sequential logic, no special synthesis concern
  found.

## Simulation-only construct sweep

Searched every `design/*.v` file for `$display`, `$finish`, `$stop`,
`$dumpvars`, `$dumpfile`, `$monitor`, and bare delay statements (`#N`).

**Result: every hit is behind `` `ifdef ASSERT_ON `` or `` `ifdef COVERAGE ``,
both undefined by default.** 14 files carry `` `ifdef ASSERT_ON ``-guarded
assertion blocks (`$display` + `$finish` pairs that fire only when an
internal invariant is violated -- e.g. `FreeList.v`'s count-exceeds-capacity
check, `PhysicalRegisterFile.v`'s x0-must-read-0 check): `FForward.v`,
`Forward.v`, `FreeList.v`, `Hazard.v`, `HazardNoForward.v`,
`LoadStoreQueue.v`, `PhysicalRegisterFile.v`, `Register.v`,
`RegisterAliasTable.v`, `ReorderBuffer.v`, `ReservationStation.v`,
`VALU.v`, `VLSU.v`, `riscvpipeline.v`. `riscvpipeline.v` additionally has a
`` `ifdef COVERAGE ``-guarded `dump_coverage` task (a Verilog-2005 `task`,
since this project's language mode has no SystemVerilog `final` block).
Since `ASSERT_ON`/`COVERAGE` are not defined by a normal Vivado synthesis
run (nothing in this workflow's Tcl passes `-verilog_define`), **all of
these blocks compile out of the design entirely** before Vivado's
elaborator ever sees them -- this is not "Vivado will ignore
non-synthesizable statements," it's "the preprocessor removes the text."

No unguarded `$finish`/`$dumpvars`/`$monitor` exists anywhere in
`design/*.v`. No delay statement (`#N`) exists in `design/*.v` either
(checked separately from the assertion sweep, excluding bit-width literals
like `64'd128`).

## Memory initialization

`design/DataMemoryBRAM.v` and `design/InstructionMemory.v` use
`$readmemh` against their own `INIT_FILE` parameter to preload memory
content. This is a standard, Vivado-synthesizable idiom for BRAM
initialization (infers initial content on the Block RAM primitive) and is
already the same idiom the existing (unrun) `fpga/build.tcl` relies on for
`fpga/top.v`'s `PIPELINED` instantiation -- nothing new here, just confirmed
still true for `OOOCore`'s own `InstructionMemory`/`DataMemoryBRAM`
instances too.

## Conclusion

All three top modules (`PIPELINED`, `OOOCore`, `HeteroSoC`) are
synthesizable as-is. No architectural RTL changes are needed to make Vivado
accept this design. The one real, load-bearing limitation this audit found
is **B and K's lack of isolation** -- documented above, and carried forward
honestly into every later report/README section that touches `m_ALU`'s
resource cost, rather than worked around by editing RTL.

## What Icarus/Verilator accepting this RTL does NOT tell us

Confirmed separately (see `fpga/vivado/reports/`): Icarus Verilog's
`-Wall` lint (this project's `make lint`) checks syntax/width/latch issues,
not real synthesis-tool inference (BRAM/DSP mapping, timing closure,
resource fit on a real device). This audit is based on reading the RTL
directly against Vivado's own synthesizable-subset rules, and the actual
`synth_1`/`impl_1` runs in `fpga/vivado/reports/` are the real confirmation
-- this document is the *before*, not a substitute for the *after*.
