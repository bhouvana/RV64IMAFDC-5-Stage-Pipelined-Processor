`default_nettype none

// Alternate hazard strategy (docs/adr/0016-swappable-hazard-strategy.md,
// docs/ROADMAP.md Phase 6): stall on every RAW hazard instead of forwarding
// around it. Selected via riscvpipeline.v's HAZARD_STRATEGY parameter
// (1 = this module + Forward.v disabled; 0, the default, keeps the
// existing Hazard.v + Forward.v pair completely untouched).
//
// Hazard.v only ever needs to catch the *load-use* case (gap=1, producer is
// a load) because Forward.v already covers every other gap=1/2 RAW hazard
// via combinational forwarding, and Register.v's write-first bypass
// (docs/adr/0002) already covers gap=3 for free. With forwarding removed
// entirely, this module has to catch what Forward.v used to:
//   - gap=1 (producer is the instruction now entering EX, i.e. reg2's
//     *current* output, "regde"): its result won't reach the register file
//     for another 2 cycles (EX, then MEM, then WB) -- stall.
//   - gap=2 (producer is now in MEM, i.e. reg3's output, "regem"): one more
//     cycle to WB -- stall.
//   - gap=3 (producer is in WB this exact cycle): Register.v's write-first
//     bypass already returns the correct value combinationally -- no stall
//     needed, same as the forwarding strategy.
// Re-evaluated every cycle like Hazard.v's existing check (not a countdown
// counter) -- stall naturally clears once the producer has moved far
// enough down the pipe for either condition to stop matching.
module HazardNoForward #(
    parameter NUM_REGS = 32
) (
    input wire [$clog2(NUM_REGS)-1:0] readReg1_fd,
    input wire [$clog2(NUM_REGS)-1:0] readReg2_fd,
    input wire regWrite_regde,
    input wire [$clog2(NUM_REGS)-1:0] write_to_Reg_regde,
    input wire regWrite_regem,
    input wire [$clog2(NUM_REGS)-1:0] write_to_Reg_regem,
    input wire branch_taken,   // reg2's *current* occupant (the same one hazard_ex
                           // checks) is resolving a taken branch/jal/jalr/
                           // trap/mret this cycle -- see the real bug this
                           // caught, below.
    output wire flush,
    output wire stall
);

wire hazard_ex  = regWrite_regde && (write_to_Reg_regde != 0) &&
                  ((write_to_Reg_regde == readReg1_fd) || (write_to_Reg_regde == readReg2_fd));
wire hazard_mem = regWrite_regem && (write_to_Reg_regem != 0) &&
                  ((write_to_Reg_regem == readReg1_fd) || (write_to_Reg_regem == readReg2_fd));

// A real bug caught by random cross-checking (docs/adr/0016), in two
// layers. First layer: jal/jalr write a register (their link value) *and*
// redirect the same cycle, so if the ID-stage instruction being checked
// here happens to read that link register, hazard_ex fires for it --
// looked like it should be gated by !branch_taken specifically on
// hazard_ex, since the ID-stage instruction is one of the two squashed by
// the redirect anyway. That gate alone still wasn't enough, though: a
// *second*, independent instruction can be sitting in reg3 (whatever
// hazard_mem is checking) with no relation at all to what's redirecting in
// reg2 -- any stall this module raises, from *either* condition, freezes
// PC.v (which prioritizes stall over accepting a new pc_i) on whatever
// cycle branch_taken happens to be 1, dropping the jump regardless of which
// hazard caused it. Gating the whole output, not just hazard_ex, is what
// actually mirrors reg1.v/reg2.v's own priority (branch_taken over
// everything else) correctly -- confirmed by re-running the exact seed this
// was originally caught on after each attempt, not assumed fixed.
assign stall = (hazard_ex | hazard_mem) & !branch_taken;
assign flush = stall;

// Same invariant Hazard.v checks for its own stall/flush pair -- see that
// module's comment.
`ifdef ASSERT_ON
always @(*) begin
    if (stall !== flush)
        begin $display("ASSERTION FAILED @t=%0t: HazardNoForward.v stall(%b) != flush(%b), expected equal", $time, stall, flush); $finish; end
end
`endif

endmodule

`default_nettype wire
