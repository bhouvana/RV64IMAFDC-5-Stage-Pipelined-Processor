# FPGA bring-up

**A real, run Vivado workflow now exists** for the in-order core — see
`fpga/vivado/` and the top-level README's own
[FPGA Implementation & Vivado Analysis](../README.md#fpga-implementation--vivado-analysis)
section for real synthesis/implementation/timing/power results on
`xc7k325tffg900-2` (boardless, no physical board needed). The Gen6 OoO core
hangs Vivado synthesis in this environment — documented honestly, not hidden,
in `fpga/vivado/AUDIT.md` and `docs/adr/0069`. This directory's own files
below (`top.v`, `build.tcl`, `constraints_template.xdc`) remain what they
always were: a separate, still-genuinely-unrun, board-targeted bring-up path.

Status, honestly, for *this directory's own files*: **scaffolding only.** Everything in this directory has been
written to compile cleanly and to follow each tool's documented interface
correctly, but none of it has been run against a real vendor toolchain or a
real board -- this repo was developed in an environment with neither
installed. Don't read "the files exist and look complete" as "this has been
validated on hardware." `docs/adr/0012-fpga-readiness.md` and
`docs/ROADMAP.md` (Phase 7) both say the same thing: real hardware
validation is the one item in this phase that's still genuinely open.

## What's here

- `top.v` -- vendor-neutral bring-up wrapper around `PIPELINED`. A heartbeat
  LED (independent of the CPU, so a dead board/clock is distinguishable from
  a CPU bug) and an 8-bit `leds` output tracking `x10`/`a0`, so a test
  program that does `addi a0, x0, <pattern>` then spins is directly
  observable. Deliberately not a full SoC -- no UART, no memory-mapped I/O,
  no boot ROM.
- `constraints_template.xdc` -- Xilinx/Vivado XDC syntax, every pin a
  placeholder (`CLK_PIN`, `LED0_PIN`, etc.). **Not usable as-is.**
- `build.tcl` -- non-interactive Vivado batch script: create a project, add
  `design/*.v` + `top.v`, add a (real, filled-in) constraints file, run
  synthesis, run implementation, write a bitstream, report utilization and
  timing. Follows Vivado's documented batch-mode Tcl API; unrun against a
  real Vivado install for the same reason as everything else here.

## What you'd actually need to do, on a real machine with a real board

1. **Pick a board and get its real constraints file.** Every FPGA vendor/
   board publishes a master XDC (Xilinx) / PCF (Lattice) / QSF (Intel) with
   the board's actual pin numbers -- don't hand-guess these from a datasheet
   PDF; get the vendor/board maker's own file (e.g. Digilent publishes one
   per board on their resource pages, and most are also mirrored in that
   board's own GitHub template repo). Copy the four constraints this design
   needs (`clk_i`'s pin + period, `btn_rst_ni`'s pin, `leds[7:0]`'s 8 pins,
   the `set_false_path` for the async reset) out of
   `constraints_template.xdc`'s structure into
   `fpga/constraints_<yourboard>.xdc`, filled in with real values from that
   board's file.
   - If your board has fewer than 8 discrete LEDs (common -- many boards
     split their user LEDs into a handful of simple on/off ones plus
     separate RGB LEDs, which are 3 pins each, not 1), narrow `leds` in
     `top.v` to match what you actually have rather than leaving pins
     unconstrained.
   - Retune `HEARTBEAT_DIV_BITS` (a `top.v` parameter) if your board's
     oscillator is far outside the ~50-100MHz range the default assumes --
     the goal is just a blink rate a human can see, nothing precise.
2. **Run the build**, from the repo root, with Vivado's `bin/` on `PATH`:
   ```
   vivado -mode batch -source fpga/build.tcl -tclargs fpga/constraints_<yourboard>.xdc [part_number]
   ```
   `build.tcl`'s header comment has the full argument details, including the
   default part number (an Arty A7-35T's) to override for a different board.
   Read `fpga/build/utilization.rpt` and `timing_summary.rpt` afterward --
   don't just check that a `.bit` file exists; check the design actually met
   timing at whatever clock period you constrained.
3. **Flash the bitstream** with your vendor's normal programming flow
   (Vivado Hardware Manager for Xilinx, or the equivalent for your
   toolchain) and confirm the heartbeat LED blinks first (proves board/
   clock/bitstream are fine, independent of the CPU), then load a real test
   program into `INIT_FILE` at synthesis time and confirm `leds[6:0]` shows
   the expected `x10` pattern.
4. **For a non-Xilinx target** (Lattice iCE40/ECP5 via open-source
   yosys+nextpnr, Intel/Altera Quartus): the constraint file *syntax*
   differs entirely (`.pcf`, `.qsf`) and `build.tcl` is Vivado-specific, but
   the same four signals need equivalent pin/timing constraints -- translate
   the *intent*, not the Tcl/XDC text itself.

## What would make this a stronger validation, beyond "an LED blinks"

- A UART (even a bit-banged, software-driven one) would let a real test
  program report a pass/fail result instead of just a static LED pattern --
  currently out of scope (see `top.v`'s header comment).
- A second board-independent smoke check worth adding once any vendor
  toolchain is available in-session: run synthesis-only (no implementation/
  bitstream) as a fast "does this actually elaborate/synthesize cleanly"
  gate, distinct from Icarus Verilog's simulation-only checking
  (`make lint`) -- `iverilog -Wall` catches syntax/width/latch issues but
  says nothing about real synthesis-tool inference (BRAM, DSP, etc.).
