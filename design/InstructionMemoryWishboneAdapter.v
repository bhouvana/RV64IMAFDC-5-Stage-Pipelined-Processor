`default_nettype none
`include "wb_defs.vh"

// docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). Thin Wishbone
// slave wrapper around the existing, already-verified InstructionMemory.v --
// mirrors RamWishboneAdapter.v's own "wrap, don't touch a verified module"
// precedent (docs/adr/0020), point-to-point behind the I-side L2Cache.v
// instance only (this project's I-mem/D-mem are physically separate arrays,
// never sharing MemoryController.v/WbDecoder.v -- confirmed by research
// before this phase's own design pass).
//
// Read-only: `s_we`/`s_data_o`/`s_sel` are accepted (Wishbone-master-shaped
// uniformity, matching every other slave in this project) but ignored --
// I$ never legitimately writes.
//
// Deliberately simpler than RamWishboneAdapter.v: InstructionMemory.v's own
// read is purely COMBINATIONAL (no internal registered latency at all,
// unlike DataMemoryBRAM.v's real 1-cycle read) -- there is no pending
// request state to desynchronize from, so this module has no equivalent of
// RamWishboneAdapter.v's own req_active_r/is_new_request edge-detection
// machinery, and no equivalent of the real stuck-level-ack bug that
// machinery exists to avoid (docs/adr/0043's own Finding 1). A plain level
// ack (`s_cyc && s_stb`) is correct here because the DATA it exposes is
// ALWAYS freshly, combinationally re-derived from whatever `s_addr`
// currently presents -- there is nothing that can go stale.
module InstructionMemoryWishboneAdapter #(
    parameter SIZE_BYTES = 128,
    parameter XLEN = 32,
    parameter INIT_FILE = "sim/programs/arith.mem",
    parameter ZERO_INIT_LIMIT_OVERRIDE = 0
)(
    input clk,
    input rst,

    input                          s_cyc,
    input                          s_stb,
    input                          s_we,      // ignored -- read-only
    input      [XLEN-1:0]          s_addr,
    input      [XLEN-1:0]          s_data_o,  // ignored -- read-only
    input      [`WB_SEL_WIDTH-1:0] s_sel,     // ignored -- InstructionMemory.v has no sub-word granularity
    output     [XLEN-1:0]          s_data_i,
    output                         s_ack
);

InstructionMemory #(.INIT_FILE(INIT_FILE), .SIZE_BYTES(SIZE_BYTES), .XLEN(XLEN),
                     .ZERO_INIT_LIMIT_OVERRIDE(ZERO_INIT_LIMIT_OVERRIDE)) m_imem(
    .readAddr(s_addr),
    .inst(s_data_i)
);

assign s_ack = s_cyc && s_stb;

endmodule

`default_nettype wire
