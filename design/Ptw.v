`default_nettype none

`include "riscv_defs.vh"
`include "wb_defs.vh"

// docs/adr/00NN-mmu-sv32.md (Phase F4). Sv32 page-table walker: a
// `busy`/`done` multi-cycle state machine, mirroring Divider.v/FDivider.v's
// own interlock shape exactly (`start` is a level held by the caller for
// the walk's entire duration, `done` is a one-cycle pulse, `start` must
// drop -- or a new one never re-arms while `done` is still asserted, same
// `!busy && !done` guard Divider.v uses -- before a second walk can begin).
// Standalone this phase (F4): its own Wishbone-master-shaped read port is
// built to match RamWishboneAdapter.v's real 1-cycle-registered-read
// timing (assert cyc/stb, hold until `m_ack`, `m_data_i` valid the same
// cycle as `m_ack`) but is not yet wired to the live shared bus -- that
// mux (sharing the LSU's existing master port, per the phase plan's own
// arbiter-avoidance reasoning: a walk only ever happens while the pipeline
// is already stalled waiting for it) is F5's job.
//
// A real, documented scope simplification worth preserving here: Sv32's
// spec-width PPN field is 22 bits (a PTE's bits [31:10]), which would
// combine with the 12-bit page offset into a 34-bit physical address --
// wider than every other address bus in this core (XLEN=32 throughout,
// docs/adr/0015). This core's actual physical memory tops out at tens of
// KB, so only the low 20 bits of any PPN are ever meaningful; widening
// every bus signal in the design to 34 bits to support >4GB of physical
// RAM no test program here could ever exercise is out of scope. Every PTE
// is read and decoded at its full, spec-correct 22-bit PPN width (a page
// table built by a real, spec-compliant piece of software still parses
// correctly); only the *result* physical address this walker ever forms
// (both the intermediate level-0 table address and the final translated
// PPN) truncates to the low 20 bits. This never causes an incorrect
// translation for any address this core's memory can actually contain,
// since bits [21:20] of a real PPN would only ever be nonzero for
// physical memory this design doesn't have.
//
// Access-type/privilege permission check (leaf PTEs at either level):
// requested access (X -> pte_x, W -> pte_w, else R -> pte_r) AND the U-bit
// match (`priv_is_u ? pte_u : !pte_u` -- no SUM implemented, so S can never
// match a U=1 page, the phase's own scoping default, riscv_defs.vh's own
// PTE_U_BIT comment). Either check failing is a page fault, the same
// cause class as an invalid/malformed PTE -- not a distinct error type.
module Ptw #(
    parameter XLEN = 32   // Sv32 itself is fixed-width; this only widens
                           // the bus ports to match every other XLEN-wide
                           // bus in the core (docs/adr/0015), same as
                           // Divider.v's own XLEN parameter.
)(
    input wire clk,
    input wire rst,

    // Request. `start` is a level, held by the caller for the walk's
    // entire duration (mirrors Divider.v's own `start` contract exactly).
    input                  wire start,
    input      wire [XLEN-1:0]  vaddr,
    input      wire [21:0]      satp_ppn,   // satp's own real spec width (bits [21:0])
    input                  wire is_fetch,   // 1 = instruction fetch (X access)
    input                  wire is_store,   // 1 = store (W access); is_fetch=is_store=0 => load (R access)
    input                  wire priv_is_u,  // 1 = current privilege is U, 0 = S (M-mode never calls this -- see header)

    output reg             busy,
    output reg             done,       // one-cycle pulse: result/fault valid this cycle
    output reg             fault,      // valid alongside done: 1 = page fault, 0 = translation succeeded
    output reg [XLEN-1:0]  result_ppn, // valid when done && !fault (low 20 bits meaningful, see header)
    output reg             result_perm_r,
    output reg             result_perm_w,
    output reg             result_perm_x,
    output reg             result_perm_u,

    // Wishbone master (own port, not yet muxed onto the shared bus -- F5).
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
localparam S_L1_WAIT   = 3'd1;   // cyc/stb asserted for the level-1 PDE read
localparam S_L1_DECODE = 3'd2;
localparam S_L0_WAIT   = 3'd3;   // cyc/stb asserted for the level-0 PTE read
localparam S_L0_DECODE = 3'd4;

reg [2:0]  state;
reg [9:0]  vpn1_r, vpn0_r;
reg [21:0] satp_ppn_r;
reg        is_fetch_r, is_store_r, priv_is_u_r;
reg [31:0] pte_r;   // holds whichever level's PTE was most recently read --
                     // level-1's own fields (vpn1_r/satp_ppn_r) are already
                     // consumed forming l0_addr below before level-0's read
                     // ever overwrites this, so one register safely serves
                     // both levels of this exactly-2-level walk

// Only the low 20 bits of any PPN ever address this core's real memory --
// see the module header for why. `<<12` (page-align) then OR in a 12-bit
// index*4 (whose own low 2 bits are always 0) -- never overlaps, so OR and
// `+` are equivalent here; OR makes the "these two fields never overlap"
// invariant visible directly in the RTL.
wire [19:0] satp_ppn20 = satp_ppn_r[19:0];
wire [19:0] pte_ppn20  = pte_r[29:10];

wire [31:0] l1_addr = {satp_ppn20, 12'b0} | {22'b0, vpn1_r, 2'b00};
wire [31:0] l0_addr = {pte_ppn20, 12'b0} | {22'b0, vpn0_r, 2'b00};

assign m_cyc    = (state == S_L1_WAIT) || (state == S_L0_WAIT);
assign m_stb    = m_cyc;
assign m_we     = 1'b0;
assign m_addr   = (state == S_L1_WAIT) ? l1_addr : l0_addr;
assign m_data_o = {XLEN{1'b0}};   // the walker never writes -- no A/D auto-set, see riscv_defs.vh's PTE_A_BIT/PTE_D_BIT comment
assign m_sel    = {`WB_SEL_WIDTH{1'b1}};   // always a full 4-byte PTE word read

// Permission check, shared shape for both leaf cases (level-1 megapage,
// level-0 4KB page) -- duplicated per-call-site below rather than factored
// into a function, since the two call sites are the only two that will
// ever exist (this walker is exactly 2 levels, Sv32's own fixed depth) --
// not a case warranting an abstraction over real duplication.

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
                    vpn1_r      <= vaddr[`VPN1_HI:`VPN1_LO];
                    vpn0_r      <= vaddr[`VPN0_HI:`VPN0_LO];
                    satp_ppn_r  <= satp_ppn;
                    is_fetch_r  <= is_fetch;
                    is_store_r  <= is_store;
                    priv_is_u_r <= priv_is_u;
                    busy        <= 1'b1;
                    state       <= S_L1_WAIT;
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
                    // Leaf at level 1: a megapage.
                    if (pte_r[19:10] != 10'b0) begin
                        // Misaligned superpage (PPN[0] must be 0) -- a page fault, spec-mandated.
                        busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                        state <= S_IDLE;
                    end
                    else begin
                        if ((is_fetch_r ? pte_r[`PTE_X_BIT] : (is_store_r ? pte_r[`PTE_W_BIT] : pte_r[`PTE_R_BIT]))
                            && (priv_is_u_r ? pte_r[`PTE_U_BIT] : !pte_r[`PTE_U_BIT])) begin
                            result_ppn      <= {12'b0, pte_r[29:20], vpn0_r};
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
                    pte_r <= m_data_i;   // reuses pte_r's storage for the level-0 PTE -- see its
                                         // own declaration comment for why that's safe here
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
                    // Non-leaf at level 0: Sv32 only has 2 levels, so this is malformed -- a page fault.
                    busy <= 1'b0; done <= 1'b1; fault <= 1'b1;
                    state <= S_IDLE;
                end
                else begin
                    // Leaf: an ordinary 4KB page, no alignment check needed (unlike a megapage).
                    if ((is_fetch_r ? pte_r[`PTE_X_BIT] : (is_store_r ? pte_r[`PTE_W_BIT] : pte_r[`PTE_R_BIT]))
                        && (priv_is_u_r ? pte_r[`PTE_U_BIT] : !pte_r[`PTE_U_BIT])) begin
                        result_ppn      <= {12'b0, pte_r[29:10]};
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
