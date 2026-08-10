`default_nettype none

// Generation 6 (out-of-order core), Gen6-A rename-stage skeleton
// (C:\Users\poorn\.claude\plans\gen6-ooo-core.md), extended in Gen6-E. 6
// read ports (originally 4: 2 dispatch-time readiness-check + 2 RS_ALU
// issue-time operand fetch; Gen6-E added 2 more for
// LoadStoreQueue.v's own head-entry base/store-data value fetch -- same
// "expose which preg you need, caller wires a real read port" discipline
// ReservationStation.v established, just now with a second consumer), 3
// write ports (Gen6-F added a 3rd for Divider.v's own independent
// multi-cycle completion, alongside RS_ALU's instant broadcast and
// LSQ's own multi-cycle load completion). Generalizes Register.v's fixed
// 2R2W shape
// to a wider, tag-addressed array -- Research (this session) confirmed
// Register.v itself is NOT reusable here: OoO needs many simultaneous
// in-flight writers to the same ARCHITECTURAL register, disambiguated by
// physical register tag, which is exactly the invariant Register.v's
// existing 2nd write port (docs/adr/0044) does NOT provide (it relies on
// "at most one outstanding writer per architectural register").
//
// Carries one `valid` bit per physical register -- a fresh preg granted
// by FreeList.v at rename time holds no real data yet (its producer
// hasn't executed), so a consumer reading it before that write lands must
// know to wait rather than read garbage. This is the direct OoO
// generalization of Scoreboard.v's own per-ARCHITECTURAL-register pending
// bit (docs/adr/0044) to per-PHYSICAL-register -- same idea, finer grain,
// because physical registers (unlike architectural ones under Phase E's
// scheme) really can have many simultaneously in different pending
// states.
//
// x0 is never renamed (RegisterAliasTable.v's own invariant) so preg 0
// always holds the areg-x0 mapping; hardwired to read 0 and valid=1 here
// too, same belt-and-suspenders style as Register.v's own x0 handling.
//
// HARDWIRE_PREG0 (Gen6-H): mirrors RegisterAliasTable.v's own
// HARDWIRE_REG0 exactly, same reason -- f0-f31 has no hardwired-zero
// register (FRegister.v's own header comment), so a float-register-file
// instance (HARDWIRE_PREG0=0) needs preg 0 to behave like any other
// physical register: real storage, real valid tracking, no special-case
// short-circuit on either the read or write side.
module PhysicalRegisterFile #(
    parameter XLEN      = 64,
    parameter NUM_PREGS = 64,
    parameter NUM_AREGS = 32,
    parameter HARDWIRE_PREG0 = 1,
    parameter PREG_BITS = $clog2(NUM_PREGS),
    parameter SP_INIT   = 64'd128   // preg 2 == areg x2/sp at the reset
                                     // identity mapping; mirrors
                                     // Register.v's own SP_INIT. Meaningless
                                     // (pass 0) for a float-register instance.
)(
    input  wire                 clk,
    input  wire                 rst,

    // Combinational reads, write-first bypassed against BOTH write ports
    // the same cycle (a dependent instruction can wake up and issue the
    // exact cycle its producer's CDB write lands).
    input  wire [PREG_BITS-1:0] raddr0,
    input  wire [PREG_BITS-1:0] raddr1,
    input  wire [PREG_BITS-1:0] raddr2,
    input  wire [PREG_BITS-1:0] raddr3,
    input  wire [PREG_BITS-1:0] raddr4,
    input  wire [PREG_BITS-1:0] raddr5,
    input  wire [PREG_BITS-1:0] raddr6,
    input  wire [PREG_BITS-1:0] raddr7,
    input  wire [PREG_BITS-1:0] raddr8,
    input  wire [PREG_BITS-1:0] raddr9,
    input  wire [PREG_BITS-1:0] raddr10,
    output wire [XLEN-1:0]      rdata0,
    output wire [XLEN-1:0]      rdata1,
    output wire [XLEN-1:0]      rdata2,
    output wire [XLEN-1:0]      rdata3,
    output wire [XLEN-1:0]      rdata4,
    output wire [XLEN-1:0]      rdata5,
    output wire [XLEN-1:0]      rdata6,
    output wire [XLEN-1:0]      rdata7,
    output wire [XLEN-1:0]      rdata8,
    output wire [XLEN-1:0]      rdata9,
    output wire [XLEN-1:0]      rdata10,
    output wire                 rvalid0,
    output wire                 rvalid1,
    output wire                 rvalid2,
    output wire                 rvalid3,
    output wire                 rvalid4,
    output wire                 rvalid5,
    output wire                 rvalid6,
    output wire                 rvalid7,
    output wire                 rvalid8,
    output wire                 rvalid9,
    output wire                 rvalid10,

    // CDB writeback, up to 3/cycle (Gen6-F, up from 2) -- sets data AND
    // marks valid. Port2 is Divider.v's own multi-cycle DIV/REM
    // completion -- a genuinely independent, never-coincide-safely
    // source alongside port0 (RS_ALU's instant broadcast) and port1
    // (LSQ's own multi-cycle load completion); see ReorderBuffer.v's
    // matching 3rd complete port for the full "why not just OR two
    // sources onto one port" rationale.
    input  wire                 wen0,
    input  wire [PREG_BITS-1:0] waddr0,
    input  wire [XLEN-1:0]      wdata0,
    input  wire                 wen1,
    input  wire [PREG_BITS-1:0] waddr1,
    input  wire [XLEN-1:0]      wdata1,
    input  wire                 wen2,
    input  wire [PREG_BITS-1:0] waddr2,
    input  wire [XLEN-1:0]      wdata2,

    // Rename allocation, up to 2/cycle -- clears valid for a freshly
    // granted (from FreeList.v) physical register; its data is don't-care
    // until a future CDB write. Does not touch `regs[]` itself.
    input  wire                 alloc_en0,
    input  wire [PREG_BITS-1:0] alloc_preg0,
    input  wire                 alloc_en1,
    input  wire [PREG_BITS-1:0] alloc_preg1
);

reg [XLEN-1:0] regs  [0:NUM_PREGS-1];
reg            valid [0:NUM_PREGS-1];

// Deliberately NOT a `function` called from these assigns -- Icarus (this
// project's own -g2005 toolchain) only tracks a continuous assign's
// EXPLICIT argument expressions for re-evaluation, not signals a called
// function reads internally (wen0/waddr0/wdata0/regs[] here) -- a read
// port whose address holds steady across a write would silently show
// stale data in simulation (real synthesized hardware wouldn't have this
// gap; this is a simulation-modeling trap, found by this phase's own
// standalone testbench). Register.v's own working readData1/readData2
// (docs/adr/0002) already established the fix: inline ternary chains
// directly in the assign, so every operand is a genuine explicit part of
// the expression Icarus re-evaluates on.
assign rdata0  = (HARDWIRE_PREG0 && raddr0 == 0) ? {XLEN{1'b0}} :
                  (wen0 && waddr0 == raddr0) ? wdata0 :
                  (wen1 && waddr1 == raddr0) ? wdata1 :
                  (wen2 && waddr2 == raddr0) ? wdata2 :
                  regs[raddr0];
assign rdata1  = (HARDWIRE_PREG0 && raddr1 == 0) ? {XLEN{1'b0}} :
                  (wen0 && waddr0 == raddr1) ? wdata0 :
                  (wen1 && waddr1 == raddr1) ? wdata1 :
                  (wen2 && waddr2 == raddr1) ? wdata2 :
                  regs[raddr1];
assign rdata2  = (HARDWIRE_PREG0 && raddr2 == 0) ? {XLEN{1'b0}} :
                  (wen0 && waddr0 == raddr2) ? wdata0 :
                  (wen1 && waddr1 == raddr2) ? wdata1 :
                  (wen2 && waddr2 == raddr2) ? wdata2 :
                  regs[raddr2];
assign rdata3  = (HARDWIRE_PREG0 && raddr3 == 0) ? {XLEN{1'b0}} :
                  (wen0 && waddr0 == raddr3) ? wdata0 :
                  (wen1 && waddr1 == raddr3) ? wdata1 :
                  (wen2 && waddr2 == raddr3) ? wdata2 :
                  regs[raddr3];
assign rdata4  = (HARDWIRE_PREG0 && raddr4 == 0) ? {XLEN{1'b0}} :
                  (wen0 && waddr0 == raddr4) ? wdata0 :
                  (wen1 && waddr1 == raddr4) ? wdata1 :
                  (wen2 && waddr2 == raddr4) ? wdata2 :
                  regs[raddr4];
assign rdata5  = (HARDWIRE_PREG0 && raddr5 == 0) ? {XLEN{1'b0}} :
                  (wen0 && waddr0 == raddr5) ? wdata0 :
                  (wen1 && waddr1 == raddr5) ? wdata1 :
                  (wen2 && waddr2 == raddr5) ? wdata2 :
                  regs[raddr5];
assign rdata6  = (HARDWIRE_PREG0 && raddr6 == 0) ? {XLEN{1'b0}} :
                  (wen0 && waddr0 == raddr6) ? wdata0 :
                  (wen1 && waddr1 == raddr6) ? wdata1 :
                  (wen2 && waddr2 == raddr6) ? wdata2 :
                  regs[raddr6];
assign rdata7  = (HARDWIRE_PREG0 && raddr7 == 0) ? {XLEN{1'b0}} :
                  (wen0 && waddr0 == raddr7) ? wdata0 :
                  (wen1 && waddr1 == raddr7) ? wdata1 :
                  (wen2 && waddr2 == raddr7) ? wdata2 :
                  regs[raddr7];
assign rdata8  = (HARDWIRE_PREG0 && raddr8 == 0) ? {XLEN{1'b0}} :
                  (wen0 && waddr0 == raddr8) ? wdata0 :
                  (wen1 && waddr1 == raddr8) ? wdata1 :
                  (wen2 && waddr2 == raddr8) ? wdata2 :
                  regs[raddr8];
assign rdata9  = (HARDWIRE_PREG0 && raddr9 == 0) ? {XLEN{1'b0}} :
                  (wen0 && waddr0 == raddr9) ? wdata0 :
                  (wen1 && waddr1 == raddr9) ? wdata1 :
                  (wen2 && waddr2 == raddr9) ? wdata2 :
                  regs[raddr9];
assign rdata10 = (HARDWIRE_PREG0 && raddr10 == 0) ? {XLEN{1'b0}} :
                  (wen0 && waddr0 == raddr10) ? wdata0 :
                  (wen1 && waddr1 == raddr10) ? wdata1 :
                  (wen2 && waddr2 == raddr10) ? wdata2 :
                  regs[raddr10];
assign rvalid0 = (HARDWIRE_PREG0 && raddr0 == 0) || (wen0 && waddr0 == raddr0) || (wen1 && waddr1 == raddr0) || (wen2 && waddr2 == raddr0) || valid[raddr0];
assign rvalid1 = (HARDWIRE_PREG0 && raddr1 == 0) || (wen0 && waddr0 == raddr1) || (wen1 && waddr1 == raddr1) || (wen2 && waddr2 == raddr1) || valid[raddr1];
assign rvalid2 = (HARDWIRE_PREG0 && raddr2 == 0) || (wen0 && waddr0 == raddr2) || (wen1 && waddr1 == raddr2) || (wen2 && waddr2 == raddr2) || valid[raddr2];
assign rvalid3 = (HARDWIRE_PREG0 && raddr3 == 0) || (wen0 && waddr0 == raddr3) || (wen1 && waddr1 == raddr3) || (wen2 && waddr2 == raddr3) || valid[raddr3];
assign rvalid4 = (HARDWIRE_PREG0 && raddr4 == 0) || (wen0 && waddr0 == raddr4) || (wen1 && waddr1 == raddr4) || (wen2 && waddr2 == raddr4) || valid[raddr4];
assign rvalid5 = (HARDWIRE_PREG0 && raddr5 == 0) || (wen0 && waddr0 == raddr5) || (wen1 && waddr1 == raddr5) || (wen2 && waddr2 == raddr5) || valid[raddr5];
assign rvalid6 = (HARDWIRE_PREG0 && raddr6 == 0) || (wen0 && waddr0 == raddr6) || (wen1 && waddr1 == raddr6) || (wen2 && waddr2 == raddr6) || valid[raddr6];
assign rvalid7 = (HARDWIRE_PREG0 && raddr7 == 0) || (wen0 && waddr0 == raddr7) || (wen1 && waddr1 == raddr7) || (wen2 && waddr2 == raddr7) || valid[raddr7];
assign rvalid8 = (HARDWIRE_PREG0 && raddr8 == 0) || (wen0 && waddr0 == raddr8) || (wen1 && waddr1 == raddr8) || (wen2 && waddr2 == raddr8) || valid[raddr8];
assign rvalid9 = (HARDWIRE_PREG0 && raddr9 == 0) || (wen0 && waddr0 == raddr9) || (wen1 && waddr1 == raddr9) || (wen2 && waddr2 == raddr9) || valid[raddr9];
assign rvalid10 = (HARDWIRE_PREG0 && raddr10 == 0) || (wen0 && waddr0 == raddr10) || (wen1 && waddr1 == raddr10) || (wen2 && waddr2 == raddr10) || valid[raddr10];

integer reset_i;
always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < NUM_PREGS; reset_i = reset_i + 1) begin
            regs[reset_i]  <= {XLEN{1'b0}};
            valid[reset_i] <= (reset_i < NUM_AREGS) ? 1'b1 : 1'b0;
        end
        regs[2] <= SP_INIT[XLEN-1:0];
    end
    else begin
        if (alloc_en0 && (!HARDWIRE_PREG0 || alloc_preg0 != 0))
            valid[alloc_preg0] <= 1'b0;
        if (alloc_en1 && (!HARDWIRE_PREG0 || alloc_preg1 != 0))
            valid[alloc_preg1] <= 1'b0;

        if (wen0 && (!HARDWIRE_PREG0 || waddr0 != 0)) begin
            regs[waddr0]  <= wdata0;
            valid[waddr0] <= 1'b1;
        end
        if (wen1 && (!HARDWIRE_PREG0 || waddr1 != 0)) begin
            regs[waddr1]  <= wdata1;
            valid[waddr1] <= 1'b1;
        end
        if (wen2 && (!HARDWIRE_PREG0 || waddr2 != 0)) begin
            regs[waddr2]  <= wdata2;
            valid[waddr2] <= 1'b1;
        end
    end
end

`ifdef ASSERT_ON
always @(posedge clk) begin
    if (rst && HARDWIRE_PREG0 && (regs[0] !== {XLEN{1'b0}} || valid[0] !== 1'b1))
        begin $display("ASSERTION FAILED @t=%0t: preg0 (x0) must always read 0/valid", $time); $finish; end
    if (rst && wen0 && wen1 && (waddr0 == waddr1) && (waddr0 != 0))
        begin $display("ASSERTION FAILED @t=%0t: PRF write-port collision, ports 0/1 both targeting preg%0d", $time, waddr0); $finish; end
    if (rst && wen0 && wen2 && (waddr0 == waddr2) && (waddr0 != 0))
        begin $display("ASSERTION FAILED @t=%0t: PRF write-port collision, ports 0/2 both targeting preg%0d", $time, waddr0); $finish; end
    if (rst && wen1 && wen2 && (waddr1 == waddr2) && (waddr1 != 0))
        begin $display("ASSERTION FAILED @t=%0t: PRF write-port collision, ports 1/2 both targeting preg%0d", $time, waddr1); $finish; end
end
`endif

endmodule

`default_nettype wire
