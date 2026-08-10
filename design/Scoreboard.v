`default_nettype none

// Generation 4, Phase E (docs/adr/0044-non-blocking-dcache-mshr-phase-e.md).
// Tracks which architectural registers have a still-outstanding MSHR fill
// pending, so Hazard.v can stall a consumer (RAW) or a new producer (WAW)
// the same way it already stalls on an ordinary load-use hazard --
// generalized from "one cycle, one register" to "however many cycles an
// MSHR takes, however many registers are simultaneously pending."
//
// Deliberately keyed by REGISTER NUMBER directly, not by MSHR slot index
// (the original design sketch): the caller (riscvpipeline.v) is expected
// to enforce WAW itself (never dispatch a second load targeting a register
// this scoreboard already reports pending) via reg_pending's own query
// port -- given that invariant, at most one MSHR is ever pending per
// register at a time, so no slot-indirection bookkeeping is needed at all,
// a real simplification found during design, not carried over from the
// original plan unexamined. x0 is architecturally write-discarded
// (RISC-V's own permanent zero register) -- alloc_reg==0 is silently
// ignored, never marked pending, matching every other write path in this
// core (RegisterFile.v's own existing x0 hardwire).
module Scoreboard #(
    parameter REG_BITS = 5,
    // Not truly independently variable -- always 1<<REG_BITS -- but plain
    // Verilog-2005 (-g2005, this project's own compile flag) doesn't allow
    // a `localparam` inside a module's parameter port list (that needs
    // SystemVerilog); an ordinary `parameter` that depends on an earlier
    // one in the same list is legal instead, same escape hatch, no caller
    // should ever override it.
    parameter NUM_REGS = 1 << REG_BITS
)(
    input  wire                clk,
    input  wire                rst,

    // Pulses the SAME cycle DCache.v's own mshr_accept fires for a load.
    input  wire                alloc_valid,
    input  wire [REG_BITS-1:0] alloc_reg,

    // Pulses the SAME cycle DCache.v's own mshr_complete fires.
    input  wire                complete_valid,
    input  wire [REG_BITS-1:0] complete_reg,

    // Combinational query -- ID stage checks every cycle for both its
    // source registers (RAW) and its own destination register (WAW).
    input  wire [REG_BITS-1:0] check_reg,
    output wire                reg_pending,

    // The whole pending set as a flat bus, one bit per register --
    // riscvpipeline.v needs THREE simultaneous queries every cycle (rs1,
    // rs2, and the decode-stage instruction's own rd for WAW), and adding
    // three separate check_reg/reg_pending port pairs would just be this
    // same bit-select done three times inside the module instead of once
    // at the call site. NUM_REGS (32) bits is trivial cost at this
    // project's real scale, same reasoning docs/adr/0041's own LRU age[]
    // array used.
    output wire [NUM_REGS-1:0] pending_mask
);

reg pending [0:NUM_REGS-1];

assign reg_pending = pending[check_reg];

genvar gp;
generate
    for (gp = 0; gp < NUM_REGS; gp = gp + 1) begin : gen_pending_mask
        assign pending_mask[gp] = pending[gp];
    end
endgenerate

integer i;
always @(posedge clk) begin
    if (~rst) begin
        for (i = 0; i < NUM_REGS; i = i + 1)
            pending[i] <= 1'b0;
    end
    else begin
        // alloc and complete can coincide on the SAME register only if the
        // caller violates its own WAW-stall invariant (a new alloc for a
        // register whose own prior MSHR is completing this exact cycle) --
        // not expected in practice (Hazard.v's own WAW check would have
        // stalled the second dispatch), but if it ever happens, alloc wins
        // (the register stays freshly pending, not cleared) -- a
        // defensive, explicit ordering choice, not a silent assumption.
        if (complete_valid && !(alloc_valid && alloc_reg == complete_reg))
            pending[complete_reg] <= 1'b0;
        if (alloc_valid && alloc_reg != {REG_BITS{1'b0}})
            pending[alloc_reg] <= 1'b1;
    end
end

endmodule

`default_nettype wire
