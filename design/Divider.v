`default_nettype none

// 32-cycle shift-subtract restoring divider (docs/adr/0009-multicycle-divider.md).
// Replaces the single-cycle `/`/`%`-based div/rem from docs/adr/0006 with a
// genuine iterative multi-cycle unit, and is the counterpart interlock logic
// (busy/done) that riscvpipeline.v uses to stall the pipeline while a
// division is in flight -- a different, longer-duration stall than
// Hazard.v's existing 1-cycle load-use stall.
module Divider #(
    parameter XLEN = 32   // docs/adr/0015-xlen-and-regcount-parameterization.md.
                            // Iterates XLEN cycles per division either way --
                            // this only changes the module's own literals from
                            // magic 32s to the named parameter, not the
                            // asymptotic cost.
)(
    input wire clk,
    input wire rst,
    input wire start,          // level: caller ties this to "the instruction currently
                           // presented is a div/rem whose result isn't ready yet"
                           // (see riscvpipeline.v's isDivRem) -- held asserted for
                           // the instruction's entire stay in EX, not a one-shot pulse
    input wire isSigned,        // 1 = div/rem (signed), 0 = divu/remu (unsigned)
    input wire [XLEN-1:0] dividend,
    input wire [XLEN-1:0] divisor,
    output reg busy,       // computation in progress (deasserts the same cycle `done` pulses)
    output reg done,       // one-cycle pulse: quotient/remainder valid this cycle
    output reg [XLEN-1:0] quotient,
    output reg [XLEN-1:0] remainder
);

    localparam CNT_WIDTH = $clog2(XLEN);  // count needs to reach XLEN-1

    reg [XLEN-1:0] R, Q, D;        // working remainder/quotient/divisor (unsigned magnitudes)
    reg [CNT_WIDTH-1:0] count;     // 0..XLEN-1, one bit of the algorithm per cycle
    reg neg_quotient, neg_remainder;
    reg [XLEN-1:0] R_shifted, new_R, new_Q;  // this step's result, computed once and reused

    wire [XLEN-1:0] abs_dividend = (isSigned && dividend[XLEN-1]) ? (-dividend) : dividend;
    wire [XLEN-1:0] abs_divisor  = (isSigned && divisor[XLEN-1])  ? (-divisor)  : divisor;

    always @(posedge clk) begin
        if (~rst) begin
            busy <= 1'b0;
            done <= 1'b0;
            quotient <= {XLEN{1'b0}};
            remainder <= {XLEN{1'b0}};
        end
        else begin
            done <= 1'b0;  // default: one-cycle pulse, cleared unless set below

            // `start` is a level tied to "the div/rem instruction presented
            // this cycle hasn't been resolved yet" (see the port comment
            // above), so it stays asserted through the exact cycle `done`
            // pulses -- the caller's pipeline hold only releases the cycle
            // *after* done, since reg3 needs this instruction's fields one
            // more cycle to latch the result. Without `&& !done` here,
            // busy==0 on the done cycle would look identical to "idle,
            // ready for a new request" and immediately restart a second,
            // bogus division on the same (stale, not-yet-replaced) operands
            // before the real result could be consumed.
            if (start && !busy && !done) begin
                if (divisor == {XLEN{1'b0}}) begin
                    // Divide by zero: spec-mandated result, no iteration needed.
                    quotient <= {XLEN{1'b1}};
                    remainder <= dividend;
                    done <= 1'b1;
                end
                else if (isSigned && dividend == {1'b1, {(XLEN-1){1'b0}}} && divisor == {XLEN{1'b1}}) begin
                    // Signed overflow (INT_MIN / -1): spec-mandated result.
                    quotient <= dividend;
                    remainder <= {XLEN{1'b0}};
                    done <= 1'b1;
                end
                else begin
                    R <= {XLEN{1'b0}};
                    Q <= abs_dividend;
                    D <= abs_divisor;
                    neg_quotient <= isSigned && (dividend[XLEN-1] ^ divisor[XLEN-1]);
                    neg_remainder <= isSigned && dividend[XLEN-1];
                    count <= {CNT_WIDTH{1'b0}};
                    busy <= 1'b1;
                end
            end
            else if (busy) begin
                // One shift-subtract-restore step of the combined {R,Q} 2*XLEN-bit
                // register: shift left by 1, then subtract D from the new R
                // if it fits (restoring division -- always subtract-and-check,
                // never subtract-then-add-back). Computed once into
                // new_R/new_Q (blocking, local to this step) and reused below
                // for both the running R/Q update and the final-cycle output.
                R_shifted = {R[XLEN-2:0], Q[XLEN-1]};
                if (R_shifted >= D) begin
                    new_R = R_shifted - D;
                    new_Q = {Q[XLEN-2:0], 1'b1};
                end
                else begin
                    new_R = R_shifted;
                    new_Q = {Q[XLEN-2:0], 1'b0};
                end
                R <= new_R;
                Q <= new_Q;

                if (count == XLEN-1) begin
                    busy <= 1'b0;
                    done <= 1'b1;
                    quotient  <= neg_quotient  ? (-new_Q) : new_Q;
                    remainder <= neg_remainder ? (-new_R) : new_R;
                end
                count <= count + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
