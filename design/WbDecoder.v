`default_nettype none

`include "wb_defs.vh"

// docs/adr/0020-soc-integration.md (Phase D1). Classic (non-pipelined)
// Wishbone-style address decoder/mux: routes the single LSU-side master's
// request to exactly one of NUM_SLAVES memory-mapped devices based on
// m_addr, and muxes that slave's data_i/ack back to the master. Purely
// combinational -- CYC/STB pass straight through to whichever slave's
// [BASE, BASE+SIZE) range contains m_addr; every unselected slave's own
// cyc/stb stays deasserted so it never sees a spurious transaction. BASE/
// SIZE are elaboration-time parameters (the address map is fixed at build
// time, not per-cycle data), flattened NUM_SLAVES-wide the same way
// Forward.v/MuxN.v (docs/adr/0018 Phase A5) flatten a variable producer
// count into one bus.
//
// An address matching no slave's range gets m_ack tied low forever (a
// hung bus, not a silent wrong-data read) -- deliberate: this core has no
// exception path for a bad memory address today (docs/adr/0011 documents
// M-mode-only synchronous exceptions with no memory-protection-fault
// cause), so "visibly stuck" is more honest than "silently returns 0."
// BASE/SIZE ranges are assumed non-overlapping by construction (a fixed,
// integrator-controlled map) -- not defensively checked, the same "trust
// internal invariants" convention this project applies elsewhere.
module WbDecoder #(
    parameter XLEN = 32,
    parameter NUM_SLAVES = 1,
    parameter [NUM_SLAVES*XLEN-1:0] BASE = 0,
    parameter [NUM_SLAVES*XLEN-1:0] SIZE = 0
)(
    // Master side (from riscvpipeline.v's LSU-to-bus adapter)
    input                              wire m_cyc,
    input                              wire m_stb,
    input                              wire m_we,
    input      wire [XLEN-1:0]              m_addr,
    input      wire [XLEN-1:0]              m_data_o,
    input      wire [`WB_SEL_WIDTH-1:0]     m_sel,
    output reg [XLEN-1:0]              m_data_i,
    output reg                         m_ack,

    // Slave side, flattened NUM_SLAVES-wide (index order matches BASE/SIZE)
    output     wire [NUM_SLAVES-1:0]        s_cyc,
    output     wire [NUM_SLAVES-1:0]        s_stb,
    output                             wire s_we,
    output     wire [XLEN-1:0]              s_addr,
    output     wire [XLEN-1:0]              s_data_o,
    output     wire [`WB_SEL_WIDTH-1:0]     s_sel,
    input      wire [NUM_SLAVES*XLEN-1:0]   s_data_i,
    input      wire [NUM_SLAVES-1:0]        s_ack
);

// we/addr/data_o/sel are identical for every slave -- only cyc/stb (below)
// actually select which one responds, matching classic Wishbone's shared
// address/data bus with per-slave chip-selects.
assign s_we     = m_we;
assign s_addr   = m_addr;
assign s_data_o = m_data_o;
assign s_sel    = m_sel;

wire [NUM_SLAVES-1:0] hit;
genvar g;
generate
    for (g = 0; g < NUM_SLAVES; g = g + 1) begin : gen_hit
        assign hit[g] = (m_addr >= BASE[g*XLEN +: XLEN]) &&
                         (m_addr <  BASE[g*XLEN +: XLEN] + SIZE[g*XLEN +: XLEN]);
        assign s_cyc[g] = m_cyc && hit[g];
        assign s_stb[g] = m_stb && hit[g];
    end
endgenerate

integer i;
always @(*) begin
    m_data_i = {XLEN{1'b0}};
    m_ack    = 1'b0;
    for (i = 0; i < NUM_SLAVES; i = i + 1) begin
        if (hit[i]) begin
            m_data_i = s_data_i[i*XLEN +: XLEN];
            m_ack    = s_ack[i];
        end
    end
end

endmodule

`default_nettype wire
