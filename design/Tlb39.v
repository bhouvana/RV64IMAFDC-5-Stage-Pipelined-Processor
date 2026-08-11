`default_nettype none

`include "riscv_defs.vh"

// docs/adr/00NN-sv39-mmu-phase-p.md (Phase P1). Sv39 counterpart to Tlb.v
// (Phase F4's Sv32 TLB) -- a genuinely new module, not a port, per the
// roadmap's own "Generation 3's MMU is a new design" framing, but the
// *shape* carries over unchanged: small, direct-mapped, unified (one
// array, two independent combinational read ports -- fetch-side,
// load/store-side), and genuinely TAGGED (a TLB hit feeds an address
// directly into a real memory access, unlike a branch predictor's hit,
// which is always re-verified downstream before it can affect
// architectural state -- see Tlb.v's own header for the full reasoning,
// unchanged here).
//
// The only real difference from Tlb.v: Sv39's virtual address is 39 bits
// (VPN[2]/VPN[1]/VPN[0], 9 bits each, `riscv_defs.vh`'s SV39_VPN2_HI down
// to SV39_VPN0_LO = va[38:12]), so the VPN tag widens from Sv32's 20 bits
// to 27. Everything else -- what's stored (PPN + R/W/X/U permission bits,
// not G/A/D, for the same reasons Tlb.v's header documents), the fill/
// flush_all contract, NUM_ENTRIES default -- is identical.
module Tlb39 #(
    parameter XLEN = 64,
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

    // Synchronous fill, driven by Ptw39.v on a successful walk.
    input                  wire fill_valid,
    input      wire [XLEN-1:0]  fill_vaddr,   // only bits [38:12] (the VPN) are used
    input      wire [XLEN-1:0]  fill_ppn,
    input                  wire fill_perm_r,
    input                  wire fill_perm_w,
    input                  wire fill_perm_x,
    input                  wire fill_perm_u,

    // sfence.vma -- unconditional whole-TLB flush (same scoping default as
    // Tlb.v: no selective ASID/address invalidation).
    input                  wire flush_all
);

localparam INDEX_WIDTH = $clog2(NUM_ENTRIES);
localparam VPN_WIDTH   = `SV39_VPN2_HI - `SV39_VPN0_LO + 1;   // 27 bits: va[38:12]

reg                 valid  [0:NUM_ENTRIES-1];
reg [VPN_WIDTH-1:0] tag    [0:NUM_ENTRIES-1];
reg [XLEN-1:0]      ppn_r  [0:NUM_ENTRIES-1];
reg                 perm_r_r [0:NUM_ENTRIES-1];
reg                 perm_w_r [0:NUM_ENTRIES-1];
reg                 perm_x_r [0:NUM_ENTRIES-1];
reg                 perm_u_r [0:NUM_ENTRIES-1];
integer reset_i;

wire [VPN_WIDTH-1:0] fetch_vpn = fetch_vaddr[`SV39_VPN2_HI:`SV39_VPN0_LO];
wire [VPN_WIDTH-1:0] ls_vpn    = ls_vaddr[`SV39_VPN2_HI:`SV39_VPN0_LO];
wire [VPN_WIDTH-1:0] fill_vpn  = fill_vaddr[`SV39_VPN2_HI:`SV39_VPN0_LO];

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
// follows a Ptw39.v walk completing, and flush_all only ever comes from a
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
