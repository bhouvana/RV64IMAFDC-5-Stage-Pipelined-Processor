`default_nettype none

`include "riscv_defs.vh"
`include "wb_defs.vh"

// docs/adr/00NN-sv39-mmu-phase-p.md (Phase P2). Sv39 page-table walker --
// a genuinely new module, not a port of Ptw.v (Phase F4's Sv32 walker),
// per the roadmap's own "Generation 3's MMU is a new design" framing:
// Sv39 is a real 3-level walk over 8-byte PTEs (vs. Sv32's 2-level/4-byte),
// with two possible superpage leaf points (a 1GB gigapage at level 2, a
// 2MB megapage at level 1) instead of Sv32's single megapage level. The
// *interlock shape* carries over unchanged from Ptw.v (itself mirroring
// Divider.v/FDivider.v): `start` is a level held by the caller for the
// walk's entire duration, `done` is a one-cycle pulse, a new walk can't
// re-arm until `start` drops (or a stale one hasn't yet, via the same
// `!busy && !done` guard). Standalone this phase (P2): its own Wishbone-
// master-shaped read port matches RamWishboneAdapter.v's real
// 1-cycle-registered-read timing but is not yet wired to the live shared
// bus -- that mux is P3's job, mirroring Ptw.v's own F4-then-F5 split.
//
// Same documented scope simplification as Ptw.v, extended: Sv39's
// spec-width PPN is 44 bits (PPN[2]=26b/PPN[1]=9b/PPN[0]=9b, riscv_defs.vh's
// SV39_PTE_PPN2/1/0_HI/LO), which would need a real >44-bit physical
// address space -- wildly beyond what this core's actual tiny memory
// (tens of KB) could ever use. Every PTE is still read and decoded at its
// full, spec-correct 64-bit/44-bit-PPN width (a real page table built by
// spec-compliant software still parses correctly, and every alignment
// check below tests the PTE's own real, untruncated bit positions); only
// the *addresses this walker itself forms* -- each level's table address,
// and the final translated PPN -- truncate to the low 20 bits, exactly
// mirroring Ptw.v's own truncation decision (confirmed via
// AskUserQuestion as the right default again here). A genuinely useful
// fact this truncation relies on: the low-20-bits slice of any PPN sits
// at the *same* PTE bit positions (`pte[29:10]`) in both the 32-bit Sv32
// PTE and the 64-bit Sv39 PTE, since PPN starts at bit 10 in both formats
// -- so `pte_ppn20` below needs no format-specific logic at all, only the
// *superpage reconstruction* built on top of it differs.
//
// Leaf reconstruction (derived from the real, untruncated PTE bit
// positions, then re-expressed in terms of the truncated 20-bit
// `pte_ppn20` field for the actual RTL below):
//   - Level-0 leaf (ordinary 4KB page): the full low-20-bits PPN slice
//     *is* the answer already -- `pte_ppn20` unchanged, identical to
//     Ptw.v's own level-0 case.
//   - Level-1 leaf (2MB megapage): real alignment requires PPN[0]
//     (`pte[18:10]`, 9 bits) be zero. Physical PPN = {PPN[2], PPN[1],
//     VPN[0]} -- in truncated terms, the top 11 bits of `pte_ppn20`
//     (`pte_ppn20[19:9]`, = 2 low bits of PPN[2] followed by all of
//     PPN[1]) supply the upper part, VPN[0] (9 bits) supplies the rest.
//   - Level-2 leaf (1GB gigapage): real alignment requires PPN[1:0]
//     (`pte[27:10]`, 18 bits) be zero. Physical PPN = {PPN[2], VPN[1],
//     VPN[0]} -- in truncated terms, only the top 2 bits of `pte_ppn20`
//     (PPN[2]'s own low 2 bits) survive; VPN[1]/VPN[0] (9 bits each)
//     supply the rest.
//
// Access-type/privilege permission check (leaf PTEs at any of the 3
// levels): identical shape to Ptw.v -- requested access (X -> pte_x,
// W -> pte_w, else R -> pte_r) AND the U-bit match (`priv_is_u ? pte_u :
// !pte_u` -- no SUM, same scoping default). Either check failing, an
// invalid PDE at any level, a misaligned superpage, or a non-leaf PTE at
// level 0 (Sv39 is exactly 3 levels) are all page faults, not distinct
// error types.
//
// Known, explicitly out-of-scope-for-this-step item, flagged for P3 (the
// live-wiring step) exactly like Ptw.v's own header flagged its
// RamWishboneAdapter-side concerns for F5: the real bus needs `funct3`
// forced to `F3_LOAD_LD` (3'b011, the 8-byte-read encoding) during a Sv39
// walk, not Sv32/F5's `3'b010` (lw) -- this module's own standalone
// testbench uses a mock slave returning a full 64-bit register directly,
// so it does not yet exercise this.
module Ptw39 #(
    parameter XLEN = 64   // Sv39 itself is fixed-shape; this only widens
                           // the bus ports to match every other XLEN-wide
                           // bus in the core, same as Ptw.v's own XLEN
                           // parameter (real only at XLEN=64 -- Sv39
                           // doesn't exist at XLEN=32).
)(
    input wire clk,
    input wire rst,

    // Request. `start` is a level, held by the caller for the walk's
    // entire duration (mirrors Ptw.v's own `start` contract exactly).
    input                  wire start,
    input      wire [XLEN-1:0]  vaddr,
    input      wire [43:0]      satp_ppn,   // satp's own real Sv39 spec width (bits [43:0])
    input                  wire is_fetch,   // 1 = instruction fetch (X access)
    input                  wire is_store,   // 1 = store (W access); is_fetch=is_store=0 => load (R access)
    input                  wire priv_is_u,  // 1 = current privilege is U, 0 = S (M-mode never calls this)

    output reg             busy,
    output reg             done,       // one-cycle pulse: result/fault valid this cycle
    output reg             fault,      // valid alongside done: 1 = page fault, 0 = translation succeeded
    output reg [XLEN-1:0]  result_ppn, // valid when done && !fault (low 20 bits meaningful, see header)
    output reg             result_perm_r,
    output reg             result_perm_w,
    output reg             result_perm_x,
    output reg             result_perm_u,

    // Wishbone master (own port, not yet muxed onto the shared bus -- P3).
    output                          wire m_cyc,
    output                          wire m_stb,
    output                          wire m_we,
    output     wire [XLEN-1:0]           m_addr,
    output     wire [XLEN-1:0]           m_data_o,
    output     wire [`WB_SEL_WIDTH-1:0]  m_sel,
    input      wire [XLEN-1:0]           m_data_i,
    input                           wire m_ack
);

localparam S_IDLE      = 3'd0;
localparam S_L2_WAIT   = 3'd1;   // cyc/stb asserted for the level-2 PDE read
localparam S_L2_DECODE = 3'd2;
localparam S_L1_WAIT   = 3'd3;   // cyc/stb asserted for the level-1 PDE read
localparam S_L1_DECODE = 3'd4;
localparam S_L0_WAIT   = 3'd5;   // cyc/stb asserted for the level-0 PTE read
localparam S_L0_DECODE = 3'd6;

reg [2:0]  state;
reg [8:0]  vpn2_r, vpn1_r, vpn0_r;
reg [43:0] satp_ppn_r;
reg        is_fetch_r, is_store_r, priv_is_u_r;
reg [63:0] pte_r;   // holds whichever level's PTE was most recently read --
                     // each level's own fields are already consumed forming
                     // the next level's table address below before that
                     // level's own read overwrites this, so one register
                     // safely serves all three levels of this walk

// Only the low 20 bits of any PPN ever address this core's real memory --
// see the module header for why. Note this slice (`pte[29:10]`) is the
// same bit range regardless of PTE width (Sv32's 32-bit PTE or Sv39's
// 64-bit one), since PPN starts at bit 10 in both formats.
wire [19:0] satp_ppn20 = satp_ppn_r[19:0];
wire [19:0] pte_ppn20  = pte_r[29:10];

// Sv39 PTEs are 8 bytes wide (RV64), so each level's table index is
// `vpn_field * 8`, i.e. `{vpn_field, 3'b000}` -- 9+3=12 bits, exactly the
// page-offset range, same "index*stride never overlaps the page-aligned
// base, so OR and + are equivalent" invariant Ptw.v's own l0_addr uses.
wire [31:0] l2_addr32 = {satp_ppn20, 12'b0} | {20'b0, vpn2_r, 3'b000};
wire [31:0] l1_addr32 = {pte_ppn20,  12'b0} | {20'b0, vpn1_r, 3'b000};
wire [31:0] l0_addr32 = {pte_ppn20,  12'b0} | {20'b0, vpn0_r, 3'b000};

wire [31:0] m_addr32 = (state == S_L2_WAIT) ? l2_addr32 :
                        (state == S_L1_WAIT) ? l1_addr32 : l0_addr32;

assign m_cyc    = (state == S_L2_WAIT) || (state == S_L1_WAIT) || (state == S_L0_WAIT);
assign m_stb    = m_cyc;
assign m_we     = 1'b0;
assign m_addr   = {{(XLEN-32){1'b0}}, m_addr32};
assign m_data_o = {XLEN{1'b0}};   // the walker never writes -- no A/D auto-set, same as Ptw.v
assign m_sel    = {`WB_SEL_WIDTH{1'b1}};   // vestigial on the real adapter (funct3 carries width there, P3's job)

always @(posedge clk) begin
    if (~rst) begin
        state <= S_IDLE;
        busy  <= 1'b0;
        done  <= 1'b0;
        fault <= 1'b0;
    end
    else begin
        done <= 1'b0;   // default: one-cycle pulse, cleared unless set below

        case (state)
            S_IDLE: begin
                if (start && !busy && !done) begin
                    vpn2_r      <= vaddr[`SV39_VPN2_HI:`SV39_VPN2_LO];
                    vpn1_r      <= vaddr[`SV39_VPN1_HI:`SV39_VPN1_LO];
                    vpn0_r      <= vaddr[`SV39_VPN0_HI:`SV39_VPN0_LO];
                    satp_ppn_r  <= satp_ppn;
                    is_fetch_r  <= is_fetch;
                    is_store_r  <= is_store;
                    priv_is_u_r <= priv_is_u;
                    busy        <= 1'b1;
                    state       <= S_L2_WAIT;
                end
            end

            S_L2_WAIT: begin
                if (m_ack) begin
                    pte_r <= m_data_i;
                    state <= S_L2_DECODE;
                end
            end

            S_L2_DECODE: begin
                if (!pte_r[`PTE_V_BIT]) begin
                    // Invalid level-2 PDE.
                    busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                    state <= S_IDLE;
                end
                else if (pte_r[`PTE_R_BIT] || pte_r[`PTE_W_BIT] || pte_r[`PTE_X_BIT]) begin
                    // Leaf at level 2: a gigapage. Real alignment: PPN[1:0] must be 0.
                    if (pte_r[27:10] != 18'b0) begin
                        busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                        state <= S_IDLE;
                    end
                    else begin
                        if ((is_fetch_r ? pte_r[`PTE_X_BIT] : (is_store_r ? pte_r[`PTE_W_BIT] : pte_r[`PTE_R_BIT]))
                            && (priv_is_u_r ? pte_r[`PTE_U_BIT] : !pte_r[`PTE_U_BIT])) begin
                            result_ppn      <= {{(XLEN-20){1'b0}}, pte_ppn20[19:18], vpn1_r, vpn0_r};
                            result_perm_r   <= pte_r[`PTE_R_BIT];
                            result_perm_w   <= pte_r[`PTE_W_BIT];
                            result_perm_x   <= pte_r[`PTE_X_BIT];
                            result_perm_u   <= pte_r[`PTE_U_BIT];
                            busy <= 1'b0; done <= 1'b1; fault <= 1'b0;
                        end
                        else begin
                            busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                        end
                        state <= S_IDLE;
                    end
                end
                else begin
                    // Non-leaf: descend to level 1.
                    state <= S_L1_WAIT;
                end
            end

            S_L1_WAIT: begin
                if (m_ack) begin
                    pte_r <= m_data_i;
                    state <= S_L1_DECODE;
                end
            end

            S_L1_DECODE: begin
                if (!pte_r[`PTE_V_BIT]) begin
                    // Invalid level-1 PDE.
                    busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                    state <= S_IDLE;
                end
                else if (pte_r[`PTE_R_BIT] || pte_r[`PTE_W_BIT] || pte_r[`PTE_X_BIT]) begin
                    // Leaf at level 1: a megapage. Real alignment: PPN[0] must be 0.
                    if (pte_r[18:10] != 9'b0) begin
                        busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                        state <= S_IDLE;
                    end
                    else begin
                        if ((is_fetch_r ? pte_r[`PTE_X_BIT] : (is_store_r ? pte_r[`PTE_W_BIT] : pte_r[`PTE_R_BIT]))
                            && (priv_is_u_r ? pte_r[`PTE_U_BIT] : !pte_r[`PTE_U_BIT])) begin
                            result_ppn      <= {{(XLEN-20){1'b0}}, pte_ppn20[19:9], vpn0_r};
                            result_perm_r   <= pte_r[`PTE_R_BIT];
                            result_perm_w   <= pte_r[`PTE_W_BIT];
                            result_perm_x   <= pte_r[`PTE_X_BIT];
                            result_perm_u   <= pte_r[`PTE_U_BIT];
                            busy <= 1'b0; done <= 1'b1; fault <= 1'b0;
                        end
                        else begin
                            busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                        end
                        state <= S_IDLE;
                    end
                end
                else begin
                    // Non-leaf: descend to level 0.
                    state <= S_L0_WAIT;
                end
            end

            S_L0_WAIT: begin
                if (m_ack) begin
                    pte_r <= m_data_i;
                    state <= S_L0_DECODE;
                end
            end

            S_L0_DECODE: begin
                if (!pte_r[`PTE_V_BIT]) begin
                    // Invalid level-0 PTE.
                    busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                    state <= S_IDLE;
                end
                else if (!(pte_r[`PTE_R_BIT] || pte_r[`PTE_W_BIT] || pte_r[`PTE_X_BIT])) begin
                    // Non-leaf at level 0: Sv39 only has 3 levels, so this is malformed -- a page fault.
                    busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                    state <= S_IDLE;
                end
                else begin
                    // Leaf: an ordinary 4KB page, no alignment check needed (unlike a super/gigapage).
                    if ((is_fetch_r ? pte_r[`PTE_X_BIT] : (is_store_r ? pte_r[`PTE_W_BIT] : pte_r[`PTE_R_BIT]))
                        && (priv_is_u_r ? pte_r[`PTE_U_BIT] : !pte_r[`PTE_U_BIT])) begin
                        result_ppn      <= {{(XLEN-20){1'b0}}, pte_ppn20};
                        result_perm_r   <= pte_r[`PTE_R_BIT];
                        result_perm_w   <= pte_r[`PTE_W_BIT];
                        result_perm_x   <= pte_r[`PTE_X_BIT];
                        result_perm_u   <= pte_r[`PTE_U_BIT];
                        busy <= 1'b0; done <= 1'b1; fault <= 1'b0;
                    end
                    else begin
                        busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                    end
                    state <= S_IDLE;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

endmodule

`default_nettype wire
