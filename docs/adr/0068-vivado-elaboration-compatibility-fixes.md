# ADR 0068: Vivado elaboration compatibility fixes (net types + genvar ordering)

## Problem

First real Vivado 2026.1 batch run (`fpga/vivado/create_project.tcl` + `run_all.tcl`
against `PIPELINED`, part `xc7k325tffg900-2`) failed at RTL elaboration:

```
ERROR: [Synth 8-6735] net type must be explicitly specified for 'ALUCtl' when default_nettype
is none [design/ALU.v:14]
ERROR: [Synth 8-9844] non-net port 'ALUCtl' cannot be of mode input [design/ALU.v:14]
```

Every `design/*.v` file opens with `` `default_nettype none `` (strict-mode
Verilog, presumably chosen deliberately to catch accidental implicit-wire
typos elsewhere in the design). Under IEEE 1364, an ANSI-style port declared
as bare `input [N:0] name` (no `wire`/`reg` keyword) has no net type at all
once `default_nettype none` is active -- it needs `input wire [N:0] name`
instead. Icarus Verilog and Verilator both default such a port to `wire`
regardless of `` `default_nettype ``, so `sim/run_tests.sh` (`iverilog`-based)
and the Verilator harness under `sim/verilator/` never caught this -- exactly
`fpga/vivado/AUDIT.md`'s own standing warning: a simulator accepting the RTL
never meant a synthesis tool would.

Audited via direct grep (not guessed): 48 of 63 `design/*.v` files had at
least one bare port in their own module port list -- `design/riscvpipeline.v`
(51), `design/CSR.v` (57), `design/DCache.v` (36) among the largest. This
blocked RTL elaboration for all three Vivado top modules (`PIPELINED`,
`OOOCore`, `HeteroSoC` all depend on `ALU.v` alone, let alone the other 47).

## Decision

Add explicit `wire` to every bare port in those 48 files' own module port
lists -- and only there. A small Python script
(`fpga/vivado/scripts/` history -- not checked in, one-shot) scoped edits
strictly to each file's port-list region (from its `module` line to the
line that closes it, `` `);` ``), so function-local `input`/`output`
argument declarations elsewhere in the same files (a different, unrelated
Verilog construct that must never get a `wire` keyword) were never touched.

One file (`design/DCache.v`) needed a second, manual, equally-mechanical
fix: `mshr_accept` was originally declared bare in the port header and
given its actual net type by a separate `wire mshr_accept = ...;`
continuous-assignment declaration in the module body (a legal, if now
dated, Verilog-1995 idiom -- declare the port's direction in the header,
its type+drive in the body). Making the header explicit turned that into a
real duplicate declaration (`design/DCache.v:857: error: 'mshr_accept' has
already been declared in this scope`); fixed by changing the body line to
a plain `assign mshr_accept = ...;`, since the header now already declares
the net.

**This is a net-type-keyword-only change.** No port width, name, order,
direction, or logic changed anywhere. Verified zero behavioral change by
running `sim/run_tests.sh` (iverilog, `-DASSERT_ON`, every directed
testbench) before and after: **152/152 both times, output byte-for-byte
identical** (`diff` of the two full run logs is empty).

This is the one explicit exception this project's Vivado workflow makes to
"do not modify RTL to make Vivado happy" -- reviewed and approved by the
user before any file was touched (not applied unilaterally), specifically
because it is provably a pure syntax/strictness compatibility fix (adding
information the header was implicitly relying on `` `default_nettype ``
to supply, now made explicit) rather than any change to what the hardware
does. `docs/superpowers/plans/2026-08-11-vivado-fpga-synthesis-workflow.md`
records the approval.

## Second, same-class issue: `genvar` declared after first use (`DCache.v`)

Fixing the net-type issue above unblocked `ALU.v`/etc. but exposed the next
real failure in the same `synth_design` run, this time in `design/DCache.v`:

```
ERROR: [Synth 8-9502] generate loop index 'gm' is not defined as a genvar [design/DCache.v:512]
ERROR: [Synth 8-8891] 'gm' is already declared [design/DCache.v:820]
```

Two independent `generate`/`for` blocks (`gen_pf_mshr_conflict` and
`gen_mshr_conflict`) both use a loop variable named `gm`, but only one
`genvar gm;` declaration existed, textually *after* the first loop that
uses it. Icarus tolerates a genvar used before its own declaration line;
Vivado requires declaration-before-use. Fixed by moving a single
`genvar gm;` up next to the file's existing `genvar gw;` (both loop
variables now declared together, before either generate block), and
deleting the now-duplicate declaration at the second loop's original site.
Zero synthesized-hardware difference -- a `genvar` is a compile-time
generate-loop index, not a signal. Verified the same way: `sim/run_tests.sh`
152/152, identical output, before and after.

Per the user's own follow-up decision (same conversation as the original
net-type approval): further issues in this same class -- pure elaboration/
strictness gaps, fixed by a mechanical non-semantic edit, verified by an
identical before/after `sim/run_tests.sh` diff -- are pre-authorized to fix
and log here directly, without a fresh approval round each time. Anything
that changes behavior, is ambiguous, or produces a regression diff still
stops and asks.

## Alternatives considered

- **Don't fix it; report the Vivado phase as blocked.** Would have been the
  honest fallback if the user hadn't approved a fix -- correctly matches
  this project's "document real failure, don't hide it" standard, but
  throws away the rest of the Vivado phase (Phases 4-15) over a one-line
  net-type keyword.
- **`` `default_nettype wire `` for the whole project instead.** Would have
  fixed Vivado elaboration with a one-line change per file (delete the
  `` `default_nettype none ``/`` `default_nettype wire `` pair entirely)
  instead of 578 individual port edits. Rejected: weakens the exact
  protection those directives exist for (catching a genuinely undeclared/
  misspelled signal name, which would otherwise silently synthesize as an
  implicit 1-bit wire) project-wide, for every future change, not just this
  one-time compatibility gap. The per-port fix is more diff but strictly
  safer going forward.
