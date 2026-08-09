`default_nettype none
`include "wb_defs.vh"

// docs/adr/0043-memory-controller-phase-d.md (Generation 4, Phase D). Real
// module boundary for the multi-requester shared-bus mux that used to live
// inline in riscvpipeline.v's own gen_bus_mux_none/gen_bus_mux_cached
// generate blocks (docs/adr/0022/0023). A MECHANICAL extraction, not a
// policy change: priority is still dcache > ptw > lsu, the exact same
// relative order both pre-existing generate branches already used (none
// mode's own ptw>lsu is a special case of this chain with dcache's own
// input tied off; cached mode's own dcache>ptw is the same chain with lsu's
// own input tied off) -- confirmed by direct comparison against the code
// this replaces before writing this module, not paraphrased from memory.
//
// Purely combinational -- no clk/rst needed, matching the pure `assign`
// shape of the code this replaces.
//
// ptw's own SELECT condition is `ptw_busy` (a separate signal from
// `ptw_cyc`), NOT `ptw_cyc` itself -- preserved exactly as the original
// code used it (docs/adr/0022's own D-side-always-wins gating lives
// upstream of this module, in ptw_start's own !lsu_cyc/!dcache_flush_busy
// gates -- this module only mux-selects, it doesn't re-derive priority).
// dcache's own select IS its own `dcache_cyc` directly, same as before.
//
// New in this phase: `m_cti` (docs/adr/0043) passes through whichever
// requester currently owns the bus -- only dcache ever drives a
// non-classic value (DCache.v's own BURST_ENABLE, wired at its call site);
// ptw/lsu always present `CTI_CLASSIC` (tied off at the call site, since
// neither Ptw.v/Ptw39.v nor the raw LSU ever bursts -- a page-table walk's
// own successive levels aren't even contiguous addresses, so it can't be
// one anyway).
module MemoryController #(
    parameter XLEN = 32
)(
    // Raw LSU requester (CACHE_NONE only -- tied off by the caller under
    // CACHE_WRITEBACK_SETASSOC, matching the original gen_bus_mux_cached's
    // own "no lsu_* arm at all" shape).
    input  wire                lsu_cyc, lsu_stb, lsu_we,
    input  wire [XLEN-1:0]     lsu_addr, lsu_data_o,
    input  wire [3:0]          lsu_sel,
    input  wire [2:0]          lsu_funct3,

    // Ptw.v/Ptw39.v page-table-walker requester.
    input  wire                ptw_busy,   // SELECT condition -- see header comment
    input  wire                ptw_cyc, ptw_stb, ptw_we,
    input  wire [XLEN-1:0]     ptw_addr, ptw_data_o,
    input  wire [3:0]          ptw_sel,
    input  wire [2:0]          ptw_funct3,

    // DCache.v fill/writeback requester (CACHE_WRITEBACK_SETASSOC only --
    // tied off by the caller under CACHE_NONE).
    input  wire                dcache_cyc, dcache_stb, dcache_we,   // dcache_cyc doubles as its own select
    input  wire [XLEN-1:0]     dcache_addr, dcache_data_o,
    input  wire [3:0]          dcache_sel,
    input  wire [2:0]          dcache_funct3,
    input  wire [2:0]          dcache_cti,

    output wire                m_cyc, m_stb, m_we,
    output wire [XLEN-1:0]     m_addr, m_data_o,
    output wire [3:0]          m_sel,
    output wire [2:0]          m_funct3,
    output wire [2:0]          m_cti
);

assign m_cyc    = dcache_cyc ? 1'b1          : (ptw_busy ? ptw_cyc     : lsu_cyc);
assign m_stb    = dcache_cyc ? dcache_stb    : (ptw_busy ? ptw_stb     : lsu_stb);
assign m_we     = dcache_cyc ? dcache_we     : (ptw_busy ? ptw_we      : lsu_we);
assign m_addr   = dcache_cyc ? dcache_addr   : (ptw_busy ? ptw_addr    : lsu_addr);
assign m_data_o = dcache_cyc ? dcache_data_o : (ptw_busy ? ptw_data_o  : lsu_data_o);
assign m_sel    = dcache_cyc ? dcache_sel    : (ptw_busy ? ptw_sel     : lsu_sel);
assign m_funct3 = dcache_cyc ? dcache_funct3 : (ptw_busy ? ptw_funct3  : lsu_funct3);
assign m_cti    = dcache_cyc ? dcache_cti    : `CTI_CLASSIC;

endmodule

`default_nettype wire
