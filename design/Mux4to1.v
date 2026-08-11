`default_nettype none

// Generic parameterized mux with 3 real inputs (s0/s1/s2) and a 2-bit
// select -- despite the name, only 3 of the 4 possible select codes are
// ever driven; sel=2'b11 falls back to s0. Used for the lui/auipc
// ALU-A-operand select in riscvpipeline.v (the two forwarding-mux uses
// moved to the generalized MuxN.v, docs/adr/0018).
module Mux4to1 #(
    parameter size = 32
)
(
    input wire [1:0] sel,
    input wire signed [size-1:0] s0, //read from rs1
    input wire signed [size-1:0] s1, //read from ALU after ex reg buffer
    input wire signed [size-1:0] s2, //read from mem
    output wire signed [size-1:0] out
);

assign out = (sel == 2'b00) ? s0 : ((sel == 2'b01) ? s1 : ((sel == 2'b10) ? s2 : s0));   // default (sel=2'b11 falls back to s0 -- no s3 input, despite the name)

endmodule

`default_nettype wire
