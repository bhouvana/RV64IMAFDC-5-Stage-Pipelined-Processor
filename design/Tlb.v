`default_nettype none

`include "riscv_defs.vh"

// docs/adr/00NN-mmu-sv32.md (Phase F4). Small, direct-mapped, and --
// unlike Bht.v/Btb.v (Phase E) -- genuinely TAGGED. A branch predictor's
// stale hit only ever costs an extra misprediction bubble, always
// re-verified downstream against ground truth in EX before it can affect
// architectural state; a TLB has no such downstream re-check on the *hit*
// path -- its output feeds directly into the address a memory access
// actually uses, so an untagged design could silently return a
// *different* VPN's stale translation as if it were a real hit. Each
// entry therefore stores a full 20-bit VPN tag, compared on every lookup
// (hit = valid[index] && tag[index] == query_vpn), not just an index.
//
// Unified: one array, two independent combinational read ports (fetch-side,
// load/store-side) -- cheap in behavioral Verilog (not real dual-port
// BRAM), so no separate I-TLB/D-TLB module is needed (see the phase plan's
// own "why unified" reasoning).
//
// Stores only what riscvpipeline.v's translation gate (F5) actually
// checks -- the PPN and R/W/X/U permission bits. G (global) and A/D
// (accessed/dirty) are real PTE fields Ptw.v reads off memory
// (riscv_defs.vh's own PTE_G_BIT/PTE_A_BIT/PTE_D_BIT comments) but this
// phase never special-cases any of the three -- sfence.vma always flushes
// the whole TLB regardless of G, and A/D are read but neither enforced
// nor auto-set (a real, separable future optimization) -- so there is
// nothing for the TLB itself to do with them.
module Tlb #(
    parameter XLEN = 32,
    parameter NUM_ENTRIES = 16   // must be a power of 2. Correctness doesn't
                                  // depend on size, only hit rate does, and
                                  // this core's test programs are tiny.
)(
    input wire clk,
    input wire rst,

    // Fetch-side query (combinational).
    input      wire [XLEN-1:0] fetch_vaddr,
    output                wire fetch_hit,
    output     wire [XLEN-1:0] fetch_ppn,
    output                wire fetch_perm_r,
    output                wire fetch_perm_w,
    output                wire fetch_perm_x,
    output                wire fetch_perm_u,

    // Load/store-side query (combinational).
    input      wire [XLEN-1:0] ls_vaddr,
    output                wire ls_hit,
    output     wire [XLEN-1:0] ls_ppn,
    output                wire ls_perm_r,
    output                wire ls_perm_w,
    output                wire ls_perm_x,
    output                wire ls_perm_u,

    // Synchronous fill, driven by Ptw.v on a successful walk.
    input                  wire fill_valid,
    input      wire [XLEN-1:0]  fill_vaddr,   // only bits [31:12] (the VPN) are used
    input      wire [XLEN-1:0]  fill_ppn,
    input                  wire fill_perm_r,
    input                  wire fill_perm_w,
    input                  wire fill_perm_x,
    input                  wire fill_perm_u,

    // sfence.vma -- unconditional whole-TLB flush (phase plan's scoping
    // default: no selective ASID/address invalidation).
    input                  wire flush_all
);

localparam INDEX_WIDTH = $clog2(NUM_ENTRIES);
localparam VPN_WIDTH   = `VPN1_HI - `VPN0_LO + 1;   // 20 bits: va[31:12]

reg                 valid  [0:NUM_ENTRIES-1];
reg [VPN_WIDTH-1:0] tag    [0:NUM_ENTRIES-1];
reg [XLEN-1:0]      ppn_r  [0:NUM_ENTRIES-1];
reg                 perm_r_r [0:NUM_ENTRIES-1];
reg                 perm_w_r [0:NUM_ENTRIES-1];
reg                 perm_x_r [0:NUM_ENTRIES-1];
reg                 perm_u_r [0:NUM_ENTRIES-1];
integer reset_i;

wire [VPN_WIDTH-1:0] fetch_vpn = fetch_vaddr[`VPN1_HI:`VPN0_LO];
wire [VPN_WIDTH-1:0] ls_vpn    = ls_vaddr[`VPN1_HI:`VPN0_LO];
wire [VPN_WIDTH-1:0] fill_vpn  = fill_vaddr[`VPN1_HI:`VPN0_LO];

wire [INDEX_WIDTH-1:0] fetch_index = fetch_vpn[INDEX_WIDTH-1:0];
wire [INDEX_WIDTH-1:0] ls_index    = ls_vpn[INDEX_WIDTH-1:0];
wire [INDEX_WIDTH-1:0] fill_index  = fill_vpn[INDEX_WIDTH-1:0];

assign fetch_hit    = valid[fetch_index] && (tag[fetch_index] == fetch_vpn);
assign fetch_ppn    = ppn_r[fetch_index];
assign fetch_perm_r = perm_r_r[fetch_index];
assign fetch_perm_w = perm_w_r[fetch_index];
assign fetch_perm_x = perm_x_r[fetch_index];
assign fetch_perm_u = perm_u_r[fetch_index];

assign ls_hit    = valid[ls_index] && (tag[ls_index] == ls_vpn);
assign ls_ppn    = ppn_r[ls_index];
assign ls_perm_r = perm_r_r[ls_index];
assign ls_perm_w = perm_w_r[ls_index];
assign ls_perm_x = perm_x_r[ls_index];
assign ls_perm_u = perm_u_r[ls_index];

// Fill and flush_all can never coincide in practice (a fill only ever
// follows a Ptw.v walk completing, and flush_all only ever comes from a
// retiring sfence.vma -- one instruction at a time through this pipeline)
// but flush_all is given priority below for a well-defined result either way.
always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < NUM_ENTRIES; reset_i = reset_i + 1)
            valid[reset_i] <= 1'b0;
    end
    else if (flush_all) begin
        for (reset_i = 0; reset_i < NUM_ENTRIES; reset_i = reset_i + 1)
            valid[reset_i] <= 1'b0;
    end
    else if (fill_valid) begin
        valid[fill_index]    <= 1'b1;
        tag[fill_index]      <= fill_vpn;
        ppn_r[fill_index]    <= fill_ppn;
        perm_r_r[fill_index] <= fill_perm_r;
        perm_w_r[fill_index] <= fill_perm_w;
        perm_x_r[fill_index] <= fill_perm_x;
        perm_u_r[fill_index] <= fill_perm_u;
    end
end

endmodule

`default_nettype wire
