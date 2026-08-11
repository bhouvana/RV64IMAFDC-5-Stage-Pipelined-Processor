`default_nettype none

// Generic parameterized 2:1 mux, reused wherever the pipeline needs a plain
// binary select (PC source, ALU-B operand, writeback source).
module Mux2to1 #(
    parameter size = 32
)
(
    input wire sel,
    input wire signed [size-1:0] s0,
    input wire signed [size-1:0] s1,
    output wire signed [size-1:0] out
);
    
assign out = sel ? s1 : s0;
    
endmodule

`default_nettype wire
