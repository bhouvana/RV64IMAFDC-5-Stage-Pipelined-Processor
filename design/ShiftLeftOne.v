`default_nettype none

// `imm << 1`: branch/jal immediates are counted in multiples of 2 bytes per
// RV32I's encoding (bit 0 is implicit 0), so this recovers the real byte
// offset before it reaches the target-address adder. jalr does NOT use
// this -- its immediate is a plain, unshifted I-type value (see
// riscvpipeline.v's target_off mux).
module ShiftLeftOne #(
    parameter Width = 32   // Generation 2 (Phase M, docs/adr/0028-rv64-
                             // migration-phase-m.md): was hardcoded 32-bit,
                             // silently truncating imm_regde (XLEN-wide) at
                             // XLEN=64 before shifting -- found via a real
                             // -Wall width-mismatch warning once a testbench
                             // actually instantiated PIPELINED at XLEN=64,
                             // not anticipated in the plan.
)(
    input wire signed [Width-1:0] i,
    output wire signed [Width-1:0] o
);

   assign o = i << 1;

endmodule

`default_nettype wire
