`default_nettype none

// Program counter register. `stall` (Hazard.v's load-use detection, or a
// multi-cycle EX operation's interlock) holds pc_o instead of latching
// pc_i -- the fetch-stage half of freezing the pipeline. Redirect targets
// (branch/jal/jalr, traps, mret) arrive on pc_i like any other value; this
// module has no notion of "redirect" versus "sequential fetch", the mux
// feeding pc_i in riscvpipeline.v already picked the right one.
module PC #(
    parameter XLEN = 32   // docs/adr/0015-xlen-and-regcount-parameterization.md
)(
    input wire clk,
    input wire rst,
    input wire stall,
    input wire [XLEN-1:0] pc_i,
    output reg [XLEN-1:0] pc_o
);

always @(posedge clk) begin
    if (~rst)
        pc_o <= {XLEN{1'b0}};
    else if (stall)
        pc_o <= pc_o;
    else
        pc_o <= pc_i;
end
endmodule

`default_nettype wire
