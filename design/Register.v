`default_nettype none

// Architectural register file (x0-x31): x0 hardwired to 0 on both the write
// and read paths, write-first bypass on a same-cycle write/read to the same
// register (see the assign block below for exactly which hazard this covers
// and which it doesn't -- it is not redundant with Forward.v).
module Register #(
    // docs/adr/0015-xlen-and-regcount-parameterization.md -- named, not truly
    // variable: RV32I's rs1/rs2/rd instruction-encoding fields are a fixed
    // 5 bits wide regardless of NUM_REGS, so changing NUM_REGS away from 32
    // (or XLEN away from 32) would stop being RV32I-compliant. Threaded
    // through for a single source of truth and as groundwork for a possible
    // future RV64I variant (same 5-bit register fields, wider XLEN), not to
    // claim this core works at other values today.
    parameter XLEN = 32,
    parameter NUM_REGS = 32,
    parameter SP_INIT = 32'd128   // x2/sp's reset value -- historically the
                                   // data memory size; riscvpipeline.v wires
                                   // this to its own MEM_SIZE_BYTES so the
                                   // two can't silently drift apart.
) (
    input clk,
    input rst,
    input regWrite,
    input [$clog2(NUM_REGS)-1:0] readReg1,
    input [$clog2(NUM_REGS)-1:0] readReg2,
    input [$clog2(NUM_REGS)-1:0] writeReg,
    input [XLEN-1:0] writeData,
    // Generation 4, Phase E (docs/adr/0044-non-blocking-dcache-mshr-phase-e.md).
    // A second, independent write port for MSHR-completion writeback -- a
    // load that retired early (see Scoreboard.v) needs its result written
    // OUT OF BAND from the normal WB-stage write above, since its own
    // pipeline slot already moved on by the time its data arrives. No
    // arbitration logic needed here: the scoreboard's own WAW stall (a new
    // instruction can never target a register with a pending MSHR) is what
    // guarantees these two ports never race for the SAME register on the
    // SAME cycle -- the ASSERT_ON block below flags a violation loudly
    // rather than silently dropping one write, matching this project's own
    // "never fail silently" discipline (docs/adr/0043's own stuck-ack bug
    // went undetected for exactly this class of reason).
    input we2,
    input [$clog2(NUM_REGS)-1:0] waddr2,
    input [XLEN-1:0] wdata2,
    output [XLEN-1:0] readData1,
    output [XLEN-1:0] readData2
);
    reg [XLEN-1:0] regs [0:NUM_REGS-1];
    integer reset_i;

    // Write-first bypass. Without this, a read of the register a same-cycle
    // write is targeting returns the pre-write (stale) value: the write
    // below is a synchronous posedge update while reads are combinational.
    // This is NOT redundant with Forward.v's EX/MEM and MEM/WB forwarding --
    // those only cover a producer still resident in a pipeline register.
    // They do not cover a producer whose WB-stage cycle exactly coincides
    // with a *different* instruction's ID-stage read (concretely: producer
    // and consumer exactly 3 instructions apart with no intervening hazard).
    // That gap fell through every existing hazard/forwarding path silently
    // until sim/programs/arith.s caught it -- see docs/adr/0002-register-file-write-first-bypass.md.
    // The we2/waddr2/wdata2 arm extends the identical bypass to the new
    // MSHR-completion port -- an ID-stage read landing the exact cycle a
    // completion writes back must see the fresh value too.
    assign readData1 = (readReg1 == 0) ? {XLEN{1'b0}} :
                        (regWrite && writeReg == readReg1) ? writeData :
                        (we2 && waddr2 == readReg1) ? wdata2 :
                        regs[readReg1];
    assign readData2 = (readReg2 == 0) ? {XLEN{1'b0}} :
                        (regWrite && writeReg == readReg2) ? writeData :
                        (we2 && waddr2 == readReg2) ? wdata2 :
                        regs[readReg2];

    always @(posedge clk) begin
        if(~rst) begin
            for (reset_i = 0; reset_i < NUM_REGS; reset_i = reset_i + 1)
                regs[reset_i] <= {XLEN{1'b0}};
            regs[2] <= SP_INIT;
        end
        else begin
            if (we2 && waddr2 != 0)
                regs[waddr2] <= wdata2;
            if (regWrite)
                regs[writeReg] <= (writeReg == 0) ? {XLEN{1'b0}} : writeData;
        end
    end

// Generation 4, Phase E. See we2's own header comment above -- the
// scoreboard's WAW stall should make this unreachable; assert it loudly if
// it ever isn't, rather than silently letting regWrite's own write win.
`ifdef ASSERT_ON
always @(posedge clk) begin
    if (rst && regWrite && we2 && waddr2 == writeReg && waddr2 != 0)
        begin $display("ASSERTION FAILED @t=%0t: regfile write-port collision, both ports targeting x%0d", $time, waddr2); $finish; end
end
`endif

// Compiled in only with -DASSERT_ON (see sim/run_tests.sh). x0 is hardwired
// to 0 in two independent places above (the write path and the write-first
// bypass reads) -- this checks the invariant the whole ISA depends on
// (x0 reads as 0, always) rather than trusting those two sites never drift
// out of sync with each other.
`ifdef ASSERT_ON
always @(posedge clk) begin
    if (rst && regs[0] !== {XLEN{1'b0}})
        begin $display("ASSERTION FAILED @t=%0t: regs[0] = %0d, x0 must always read 0", $time, regs[0]); $finish; end
end
`endif

endmodule

`default_nettype wire
