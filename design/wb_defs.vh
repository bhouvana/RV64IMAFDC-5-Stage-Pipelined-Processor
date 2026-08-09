// docs/adr/0020-soc-integration.md (Phase D1). Naming convention and shared
// width constants for this core's classic (non-pipelined) Wishbone-style
// bus -- every module that speaks this bus (WbDecoder.v, and later
// RamWishboneAdapter.v/Uart.v/Timer.v) uses this exact signal shape:
//
//   cyc     -- transaction in progress (asserted for the whole request)
//   stb     -- this cycle's request is valid (classic Wishbone keeps cyc/stb
//               distinct even though a single-master bus like this one
//               always asserts them together; kept as two signals anyway
//               since that's the real protocol, not a simplification of it)
//   we      -- 1=write, 0=read
//   addr    -- byte address (XLEN-wide, matching every other address bus
//               in this core -- see docs/adr/0015)
//   data_o  -- write data (master-to-slave)
//   sel     -- byte-enable lanes (4 bits for a 32-bit bus, one per byte)
//   data_i  -- read data (slave-to-master), valid the cycle `ack` is high
//   ack     -- this transaction is complete (the generalized replacement
//               for today's single-BRAM-shaped `mem_stall`: "freeze while
//               `!ack`" reduces to today's exact 1-cycle timing against a
//               registered-read RAM, but composes with variable-latency
//               peripherals too)
//
// Signals are prefixed `m_` (master-side, i.e. what riscvpipeline.v's LSU
// adapter drives/reads) or `s_` (slave-side, i.e. what each peripheral
// drives/reads) at any module boundary where both exist (WbDecoder.v).
// A peripheral's own testbench-facing ports (e.g. Uart.v's tx/rx pins)
// are unrelated to this bus convention and named on their own terms.
`ifndef WB_DEFS_VH
`define WB_DEFS_VH

`define WB_SEL_WIDTH 4  // one byte-enable bit per byte of a 32-bit data bus

// docs/adr/0043-memory-controller-phase-d.md (Generation 4, Phase D). Real
// Wishbone B3 cycle-type-identifier encoding (a 3-bit `cti` side-band,
// same "not part of the original bare signal list, added because a real
// consumer needs it" precedent `funct3` already established here). Only
// DCache.v's own fill/writeback engine ever drives a non-classic value --
// PTW/the raw LSU never burst, always CTI_CLASSIC. BTE (burst-type
// extension) is NOT a runtime signal here -- only one burst mode (linear
// incrementing) is ever used, so it's a fixed constant wherever consumed,
// not a port.
`define CTI_CLASSIC     3'b000  // single, non-burst cycle -- every requester's default
`define CTI_INCR_BURST  3'b010  // incrementing-address burst, more beats coming
`define CTI_END_OF_BURST 3'b111 // this is the burst's last beat

`endif
