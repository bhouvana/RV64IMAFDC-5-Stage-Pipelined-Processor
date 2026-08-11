`default_nettype none

`include "wb_defs.vh"

// docs/adr/0020-soc-integration.md (Phase D2). Thin Wishbone slave wrapper
// around the existing, already-verified DataMemoryBRAM.v -- deliberately
// does NOT modify that module at all, keeping its proven 1-cycle
// registered-read timing and existing test coverage completely
// undisturbed (the same "wrap, don't touch a verified module" pattern
// this project used repeatedly in Phase C, e.g. keeping FALU.v unmodified
// when C7 added forwarding around it).
//
// One deliberate, documented deviation from "pure" Wishbone: `funct3` is
// an extra, out-of-band port beyond the standard cyc/stb/we/addr/data_o/
// sel/data_i/ack set (see wb_defs.vh). DataMemoryBRAM.v bakes load width
// *and signedness* together into its funct3 input (lb vs lbu both
// address a single byte -- the same `sel` byte-enable pattern either way
// -- but need different sign-extension behavior); a pure byte-enable
// `sel` mask alone cannot distinguish them. Rather than either (a)
// modifying DataMemoryBRAM.v to move sign-extension out to the bus
// master, or (b) losing lb/lh's sign-extension correctness, this module
// takes `funct3` directly as a side-band tag, wired point-to-point from
// riscvpipeline.v's LSU in D3 (bypassing WbDecoder.v's generic broadcast
// entirely -- no other slave needs it, so WbDecoder.v itself needed no
// changes for this). A real vendor-neutral Wishbone bus with a
// width-and-signedness-aware slave would define this as a TGD (tag) signal
// in the same spirit; this is that idea without inventing generality
// nothing here yet needs.
module RamWishboneAdapter #(
    parameter SIZE_BYTES = 128,
    parameter XLEN = 32,
    parameter DATA_INIT_FILE = "",
    parameter ZERO_INIT_LIMIT_OVERRIDE = 0  // docs/adr/0036 -- threaded straight through to DataMemoryBRAM.v
)(
    input wire clk,
    input wire rst,

    input                          wire s_cyc,
    input                          wire s_stb,
    input                          wire s_we,
    input      wire [XLEN-1:0]          s_addr,
    input      wire [XLEN-1:0]          s_data_o,
    input      wire [`WB_SEL_WIDTH-1:0] s_sel,   // unused: funct3 already carries width (see header)
    input      wire [2:0]               funct3,  // side-band width+signedness tag
    output     wire [XLEN-1:0]          s_data_i,
    output                         wire s_ack
);

wire mem_write = s_cyc && s_stb && s_we;
wire mem_read  = s_cyc && s_stb && !s_we;

DataMemoryBRAM #(.SIZE_BYTES(SIZE_BYTES), .XLEN(XLEN), .DATA_INIT_FILE(DATA_INIT_FILE), .ZERO_INIT_LIMIT_OVERRIDE(ZERO_INIT_LIMIT_OVERRIDE)) m_ram(
    .clk(clk), .rst(rst),
    .memWrite(mem_write), .memRead(mem_read),
    .address(s_addr), .writeData(s_data_o), .funct3(funct3),
    .readData(s_data_i)
);

// A write commits on the same clock edge DataMemoryBRAM.v samples
// memWrite (a plain synchronous register write, same as this core's
// existing memWrite_regem wiring already assumed with no stall at all --
// mem_stall today gates only on memRead) -- ack combinationally, so the
// master never waits an extra cycle beyond what it already didn't wait
// for. A read is registered one cycle later inside DataMemoryBRAM.v
// itself (docs/adr/0013); mem_read_pending_r mirrors that exact same
// one-cycle delay so s_ack lands on precisely the cycle s_data_i
// (DataMemoryBRAM's own readData) actually becomes valid.
//
// docs/adr/0043-memory-controller-phase-d.md (Generation 4, Phase D). A
// real, pre-existing bug found while building this phase's own burst-CTI
// test, confirmed against the EXISTING unmodified DCache.v multi-word fill
// path (nothing to do with burst/CTI itself): mem_read_pending_r used to
// be a plain 1-cycle-delayed COPY of mem_read -- a LEVEL, not a
// per-transaction pulse. DCache.v/Ptw.v hold cyc/stb continuously across a
// multi-word sequence, changing only the ADDRESS between words, so
// mem_read never actually dropped -- the old ack stayed stuck high from
// the second word onward. DCache.v's own S_FILL loop (`if (m_ack) ...`, a
// plain level check, no edge detection of its own) advanced fill_word_r
// and committed data EVERY cycle once first asserted, reusing ONE real
// round-trip's worth of latency across every remaining word -- silently
// corrupting any word after the first with the PREVIOUS word's stale
// raw_word_r content, whenever the backing memory genuinely holds
// different values per word. Invisible in every existing test before this
// phase, which only ever exercised fresh, zero-initialized lines where
// every word already happened to be 0 -- confirmed by tracing dut2's own
// pre-existing, unmodified LRU-D sub-test in tb_dcache_unit.v cycle-by-
// cycle before touching anything here.
//
// Fixed with real per-request edge-detection: mirrors the EXACT
// is_new_request idiom riscvpipeline.v's own MEM_LATENCY_D wrapper already
// uses (docs/adr/0024-variable-latency-memory.md, Phase I2) -- tracking
// the (address, we) actually being serviced and only pulsing a fresh ack
// when that genuinely changes (or this is the very first request), rather
// than trusting a bare level. This makes the correct behavior the DEFAULT
// here, not something that only happens to hold when a latency wrapper is
// layered on top.
// req_active_r means "there is a request outstanding that has NOT yet
// received its own ack" -- cleared the INSTANT that ack is delivered (not
// only when the bus goes fully idle). This distinction matters: a genuinely
// NEW, different instruction can legitimately target the exact same
// address as the one immediately before it (e.g. `lb`/`lbu` reading the
// same byte back-to-back) -- if req_active_r stayed set as long as the bus
// merely kept presenting the same (addr, we), that second, real access
// would be silently mistaken for "still the same outstanding repeat" and
// never re-armed. Clearing it as soon as its own ack fires means the VERY
// NEXT cycle's access -- same address or not -- is correctly treated as
// fresh, while a request that's still genuinely WAITING (no ack yet)
// continues to be correctly recognized as unchanged.
reg [XLEN-1:0] req_addr_r;
reg            req_we_r;
reg            req_active_r;
wire is_new_request = (mem_read || mem_write) &&
    (!req_active_r || s_addr != req_addr_r || s_we != req_we_r);

reg mem_read_pending_r;
always @(posedge clk) begin
    if (~rst) begin
        mem_read_pending_r <= 1'b0;
        req_active_r <= 1'b0;
    end
    else if (is_new_request) begin
        req_active_r <= 1'b1;
        req_addr_r   <= s_addr;
        req_we_r     <= s_we;
        mem_read_pending_r <= mem_read;
    end
    else if (mem_read_pending_r) begin
        // This exact request's own ack is being delivered THIS cycle --
        // satisfied. Clear both so any later access (even to this same
        // address) is treated as a fresh request, not a stale repeat.
        mem_read_pending_r <= 1'b0;
        req_active_r <= 1'b0;
    end
    // else: still holding the same, already-issued, not-yet-acked request
    // -- nothing to do but keep waiting.
end
assign s_ack = mem_write || mem_read_pending_r;

endmodule

`default_nettype wire
