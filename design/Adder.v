`default_nettype none

// Generic parameterized adder, reused wherever the pipeline needs a plain
// sum: PC+4 (both the fetch-stage increment and jal's link value) and the
// branch/jal/jalr target-address computation (riscvpipeline.v's Adder_1/2/3).
module Adder #(
    parameter XLEN = 32   // docs/adr/0015-xlen-and-regcount-parameterization.md --
                            // named, not truly variable: this core is RV32I-only,
                            // so 32 is the only ISA-valid value. Threaded through
                            // for a single source of truth (matching CQ-1's
                            // riscv_defs.vh spirit) rather than scattered literals.
)(
    input wire signed [XLEN-1:0] a,
    input wire signed [XLEN-1:0] b,
    output wire signed [XLEN-1:0] sum
);

 assign sum = a + b;

endmodule

`default_nettype wire
