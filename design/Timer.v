`default_nettype none

`include "wb_defs.vh"
`include "riscv_defs.vh"

// docs/adr/0020-soc-integration.md (Phase D6) built the original free-
// running mtime/mtimecmp comparator, unchanged in spirit by this phase.
// docs/adr/0034-uart-clint-register-compat-phase-r.md (Phase R) replaced the
// old 32-bit 2-register map with a real CLINT-compatible one: msip/
// mtimecmp/mtime at the exact byte offsets Linux's own
// drivers/clocksource/timer-clint.c hardcodes (CLINT_OFF_MSIP/_MTIMECMP/
// _MTIME, riscv_defs.vh), and mtime/mtimecmp genuinely 64-bit regardless of
// XLEN (a 32-bit CLINT exposes its 64-bit mtime/mtimecmp via two 32-bit
// halves at consecutive offsets -- exactly what this module does at
// XLEN=32; a 64-bit CLINT's own registers are just 64 bits wide, read/
// written in one shot -- exactly what this module does at XLEN=64).
//
// Native Wishbone slave, decoded on s_addr[15:0] directly (no BASE
// parameter inside this module -- same "decode raw address bits" idiom
// Uart.v uses, relying on riscv_defs.vh's own TIMER_BASE being 0x10000-
// aligned so these offsets read correctly off the *absolute* system
// address with no subtraction needed):
//   CLINT_OFF_MSIP     (0x0000, R/W): hart0's own software-interrupt-
//                      pending bit (bit0 only meaningful) -- Phase R's
//                      mip.MSIP source. Always a plain 32-bit access
//                      regardless of XLEN (real CLINT drivers use
//                      writel/readl for msip specifically, even at RV64).
//   CLINT_OFF_MTIMECMP (0x4000, R/W) [+ 0x4 = mtimecmph, XLEN=32 only]:
//                      compare value. `pending` (MTIP) asserts
//                      combinationally whenever mtime >= mtimecmp.
//   CLINT_OFF_MTIME    (0xBFF8, R/W) [+ 0x4 = mtimeh, XLEN=32 only]:
//                      free-running counter, increments every cycle it
//                      isn't itself being written.
//
// At XLEN>=64, a bus write exactly at CLINT_OFF_MTIMECMP/CLINT_OFF_MTIME
// writes the FULL 64-bit register in one shot from the full-width
// s_data_o -- what a real single `sd` from a 64-bit Linux kernel driver
// does. At XLEN<64, the same offset only ever carries the low 32 bits
// (s_data_o itself is 32 bits wide at that XLEN), and the separate +4
// high-half offsets are independently writable/readable -- the real
// two-32-bit-half CLINT access pattern an RV32 kernel driver uses. Reuses
// DataMemoryBRAM.v's own established `if (XLEN >= 64)` idiom for this
// width-conditional logic rather than a runtime-width ternary (avoids a
// -Wall width-mismatch warning).
module Timer #(
    parameter XLEN = 32
)(
    input wire clk,
    input wire rst,

    input                          wire s_cyc,
    input                          wire s_stb,
    input                          wire s_we,
    input      wire [XLEN-1:0]          s_addr,
    input      wire [XLEN-1:0]          s_data_o,
    input      wire [`WB_SEL_WIDTH-1:0] s_sel,
    output reg [XLEN-1:0]          s_data_i,
    output                         wire s_ack,

    output wire pending,       // mtime >= mtimecmp -- Phase R's mip.MTIP source
    output wire msip_pending   // msip[0] -- Phase R's mip.MSIP source
);

wire bus_write = s_cyc && s_stb && s_we;
assign s_ack = s_cyc && s_stb;  // this slave always completes in the same cycle it's addressed

wire [15:0] reg_off = s_addr[15:0];
wire sel_msip      = (reg_off == `CLINT_OFF_MSIP);
wire sel_mtimecmp  = (reg_off == `CLINT_OFF_MTIMECMP);
wire sel_mtimecmph = (reg_off == (`CLINT_OFF_MTIMECMP + 16'h4));
wire sel_mtime     = (reg_off == `CLINT_OFF_MTIME);
wire sel_mtimeh    = (reg_off == (`CLINT_OFF_MTIME + 16'h4));

reg [31:0] msip;
reg [63:0] mtime;
reg [63:0] mtimecmp;

always @(posedge clk) begin
    if (~rst) begin
        msip     <= 32'b0;
        mtime    <= 64'b0;
        mtimecmp <= 64'b0;
    end else begin
        if (bus_write && sel_msip)
            msip <= s_data_o[31:0];

        if (bus_write && sel_mtimecmp) begin
            if (XLEN >= 64)
                mtimecmp <= s_data_o[63:0];
            else
                mtimecmp[31:0] <= s_data_o[31:0];
        end else if (bus_write && sel_mtimecmph && (XLEN < 64)) begin
            mtimecmp[63:32] <= s_data_o[31:0];
        end

        // mtime: any write this cycle (full 64-bit, low half, or high
        // half) suppresses this cycle's free-run increment -- same
        // "write OR increment, never both" mutual exclusivity the
        // original 32-bit design already had.
        if (bus_write && sel_mtime) begin
            if (XLEN >= 64)
                mtime <= s_data_o[63:0];
            else
                mtime[31:0] <= s_data_o[31:0];
        end else if (bus_write && sel_mtimeh && (XLEN < 64)) begin
            mtime[63:32] <= s_data_o[31:0];
        end else begin
            mtime <= mtime + 64'b1;
        end
    end
end

assign pending = (mtime >= mtimecmp);
assign msip_pending = msip[0];

always @(*) begin
    if (sel_msip)
        s_data_i = {{(XLEN-32){1'b0}}, msip};
    else if (sel_mtimecmp)
        s_data_i = (XLEN >= 64) ? mtimecmp[XLEN-1:0] : {{(XLEN-32){1'b0}}, mtimecmp[31:0]};
    else if (sel_mtimecmph && (XLEN < 64))
        s_data_i = {{(XLEN-32){1'b0}}, mtimecmp[63:32]};
    else if (sel_mtime)
        s_data_i = (XLEN >= 64) ? mtime[XLEN-1:0] : {{(XLEN-32){1'b0}}, mtime[31:0]};
    else if (sel_mtimeh && (XLEN < 64))
        s_data_i = {{(XLEN-32){1'b0}}, mtime[63:32]};
    else
        s_data_i = {XLEN{1'b0}};
end

endmodule

`default_nettype wire
