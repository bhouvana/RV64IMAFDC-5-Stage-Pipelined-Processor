`default_nettype none

`include "wb_defs.vh"

// docs/adr/0020-soc-integration.md (Phase D4) built the original TX/RX
// serial framing engine, unchanged by this phase. docs/adr/0034-uart-clint-
// register-compat-phase-r.md (Phase R) replaced the old 4-register map with
// a real ns16550a-compatible one, so a stock Linux 8250 driver (DT
// `compatible = "ns16550a"`) works against it with no kernel patch --
// `UPF_FIXED_TYPE` from that compatible string skips the driver's legacy
// autoconfig probe entirely, so this only needs to implement the register
// *semantics* the driver's ordinary start/TX/RX/interrupt paths actually
// touch, not full 16550A hardware-detection fidelity.
//
// Native Wishbone slave (see wb_defs.vh). Word-addressed (s_addr[4:2],
// matching every other access this core makes -- this core's bus is
// exclusively full-word transactions, no real byte-enable support, so each
// ns16550a byte-register gets its own word slot rather than the literal
// byte-adjacent layout a byte-wide bus would use; describe this to a DT via
// `reg-shift=2`/`reg-io-width=4`, a real, driver-supported combination).
// DLAB (LCR bit 7) gates offsets 0x0/0x4 between their two real-spec
// meanings, exactly like a real 16550A:
//   0x00 RBR(read)/THR(write), DLAB=0: last received byte / byte to send.
//        THR write ignored (not queued) while tx_busy -- software polls
//        LSR.THRE first. RBR read clears LSR.DR (a real "consume the
//        byte" side effect, not just a peek).
//        DLL, DLAB=1 (R/W): baud-rate divisor low byte. Software-visible
//        storage, no live consumer -- CLKS_PER_BIT stays the fixed
//        elaboration-time baud divisor it always was (docs/adr/0020's own
//        "cycle-accurate ... not software-programmable" scope line still
//        holds; a real baud-rate generator is explicit future work).
//   0x04 IER (R/W), DLAB=0: bit0=ERBFI (RX-data-available interrupt
//        enable), bit1=ETBEI (THR-empty interrupt enable), bits2-7 plain
//        storage (no line-status/modem-status interrupt sources exist).
//        DLM, DLAB=1 (R/W): baud-rate divisor high byte, same inert-
//        storage note as DLL.
//   0x08 IIR (read) / FCR (write), DLAB-independent: IIR reports which
//        cause (if any) is pending, priority RX-data-available over
//        THR-empty, matching real spec priority (0001=none, 0100=RX data
//        available, 0010=THR empty; bits 7:4 always 0, no FIFO ever
//        really enables). FCR write is a no-op sink -- accepted (so a
//        driver's startup FCR write doesn't fault) but there's no real
//        FIFO to configure.
//   0x0C LCR (R/W), DLAB-independent: bit7=DLAB, the only functionally
//        consumed bit. Word-length/parity/stop-bit bits are plain
//        storage -- TX/RX framing stays fixed 8N1 regardless, a
//        documented simplification, not a new bug.
//   0x10 MCR (R/W): plain storage, no real loopback/modem-control mode.
//   0x14 LSR (read-only): bit0=DR(rx_ready), bit5=THRE(!tx_busy),
//        bit6=TEMT(!tx_busy, identical to THRE -- no separate shift-
//        register-vs-holding-register distinction without a real FIFO),
//        everything else 0 (no framing/parity/overrun/break detection).
//   0x18 MSR (read-only): hardwired 0 -- no modem control lines wired up,
//        no DT modem-control properties supported.
//   0x1C SCR (R/W): plain storage, no functional effect (real 16550A
//        scratch register, used only by autoconfig probing this core's
//        UPF_FIXED_TYPE DT binding already bypasses).
//
// `irq` (was `rx_irq` through Phase D -- renamed since it now covers both
// RX and TX causes) is level-triggered: pending_rx | pending_thr, each
// self-clearing on the same natural state transition that already cleared
// rx_ready before (RBR read; a THR write re-asserting tx_busy) -- no extra
// "IIR read clears the cause" side effect needed.
//
// RX samples at the *middle* of each bit period (half a bit after the
// detected start-bit edge, then a full bit period per subsequent bit) --
// standard UART receiver practice, not a shortcut.
//
// Deliberately no overrun/framing-error flags: if software doesn't read
// RBR before the next byte finishes, the new byte silently overwrites it
// (matching docs/adr/0020's original documented minimal scope).
module Uart #(
    parameter CLKS_PER_BIT = 4
)(
    input wire clk,
    input wire rst,

    input                          wire s_cyc,
    input                          wire s_stb,
    input                          wire s_we,
    input      wire [31:0]              s_addr,
    input      wire [31:0]              s_data_o,
    input      wire [`WB_SEL_WIDTH-1:0] s_sel,
    output reg [31:0]              s_data_i,
    output                         wire s_ack,

    output reg tx,
    input      wire rx,

    output wire irq  // pending_rx | pending_thr -- Phase R's mip.MEIP source
);

localparam CNT_WIDTH = $clog2(CLKS_PER_BIT + 1);

wire bus_write = s_cyc && s_stb && s_we;
wire bus_read  = s_cyc && s_stb && !s_we;
assign s_ack = s_cyc && s_stb;  // this slave always completes in the same cycle it's addressed

wire [2:0] reg_sel = s_addr[4:2];
localparam REG_RBR_THR_DLL = 3'd0;
localparam REG_IER_DLM     = 3'd1;
localparam REG_IIR_FCR     = 3'd2;
localparam REG_LCR         = 3'd3;
localparam REG_MCR         = 3'd4;
localparam REG_LSR         = 3'd5;
localparam REG_MSR         = 3'd6;
localparam REG_SCR         = 3'd7;

// Phase R: LCR/IER/MCR/SCR/DLL/DLM plain storage, plus LCR's own DLAB bit.
reg [7:0] ier;
reg [7:0] lcr;
reg [7:0] mcr;
reg [7:0] scr;
reg [7:0] dll;
reg [7:0] dlm;
wire dlab = lcr[7];

always @(posedge clk) begin
    if (~rst) begin
        ier <= 8'b0;
        lcr <= 8'b0;
        mcr <= 8'b0;
        scr <= 8'b0;
        dll <= 8'b0;
        dlm <= 8'b0;
    end else if (bus_write) begin
        case (reg_sel)
            REG_RBR_THR_DLL: if (dlab) dll <= s_data_o[7:0];  // else: THR, handled by the TX state machine below
            REG_IER_DLM:     if (dlab) dlm <= s_data_o[7:0]; else ier <= s_data_o[7:0];
            REG_LCR:         lcr <= s_data_o[7:0];
            REG_MCR:         mcr <= s_data_o[7:0];
            REG_SCR:         scr <= s_data_o[7:0];
            default: ; // REG_IIR_FCR write = FCR, no-op sink; REG_LSR/REG_MSR read-only, writes dropped
        endcase
    end
end

// ==========================================================================
// TX: idle-high line, start(0)-8data(LSB first)-stop(1), one bit per
// CLKS_PER_BIT cycles.
// ==========================================================================
localparam TX_IDLE = 2'd0, TX_START = 2'd1, TX_DATA = 2'd2, TX_STOP = 2'd3;
reg [1:0] tx_state;
reg [CNT_WIDTH-1:0] tx_clk_count;
reg [2:0] tx_bit_index;
reg [7:0] tx_shift_reg;
wire tx_busy = (tx_state != TX_IDLE);

always @(posedge clk) begin
    if (~rst) begin
        tx_state <= TX_IDLE;
        tx <= 1'b1;
        tx_clk_count <= 0;
        tx_bit_index <= 0;
    end else begin
        case (tx_state)
            TX_IDLE: begin
                tx <= 1'b1;
                if (bus_write && (reg_sel == REG_RBR_THR_DLL) && !dlab) begin
                    tx_shift_reg <= s_data_o[7:0];
                    tx_state <= TX_START;
                    tx_clk_count <= 0;
                end
            end
            TX_START: begin
                tx <= 1'b0;
                if (tx_clk_count == CLKS_PER_BIT - 1) begin
                    tx_clk_count <= 0;
                    tx_bit_index <= 0;
                    tx_state <= TX_DATA;
                end else begin
                    tx_clk_count <= tx_clk_count + 1'b1;
                end
            end
            TX_DATA: begin
                tx <= tx_shift_reg[tx_bit_index];
                if (tx_clk_count == CLKS_PER_BIT - 1) begin
                    tx_clk_count <= 0;
                    if (tx_bit_index == 3'd7) begin
                        tx_state <= TX_STOP;
                    end else begin
                        tx_bit_index <= tx_bit_index + 1'b1;
                    end
                end else begin
                    tx_clk_count <= tx_clk_count + 1'b1;
                end
            end
            TX_STOP: begin
                tx <= 1'b1;
                if (tx_clk_count == CLKS_PER_BIT - 1) begin
                    tx_clk_count <= 0;
                    tx_state <= TX_IDLE;
                end else begin
                    tx_clk_count <= tx_clk_count + 1'b1;
                end
            end
            default: tx_state <= TX_IDLE;
        endcase
    end
end

// ==========================================================================
// RX: detect a falling edge on an idle-high line, sample each bit at its
// midpoint.
// ==========================================================================
localparam RX_IDLE = 2'd0, RX_START = 2'd1, RX_DATA = 2'd2, RX_STOP = 2'd3;
reg [1:0] rx_state;
reg [CNT_WIDTH-1:0] rx_clk_count;
reg [2:0] rx_bit_index;
reg [7:0] rx_shift_reg;
reg [7:0] rx_data_reg;
reg rx_ready;
reg rx_prev;  // for edge detection

always @(posedge clk) begin
    if (~rst) begin
        rx_state <= RX_IDLE;
        rx_clk_count <= 0;
        rx_bit_index <= 0;
        rx_data_reg <= 8'b0;
        rx_ready <= 1'b0;
        rx_prev <= 1'b1;
    end else begin
        rx_prev <= rx;

        // A read of RBR (DLAB=0) consumes the byte (clears rx_ready)
        // regardless of what the RX state machine itself is doing this
        // same cycle -- deliberately checked independently of the case
        // statement below so a same-cycle "byte N+1 just finished" and
        // "software reads byte N" don't need special-casing against each
        // other (the new byte's own `rx_ready <= 1'b1` in RX_STOP, if it
        // fires the same cycle, is textually later and wins, which is
        // correct: the newly completed byte IS the current unread one at
        // that point).
        if (bus_read && (reg_sel == REG_RBR_THR_DLL) && !dlab)
            rx_ready <= 1'b0;

        case (rx_state)
            RX_IDLE: begin
                rx_clk_count <= 0;
                if (rx_prev && !rx) begin
                    // Falling edge: start bit begins. Wait half a bit
                    // period before confirming/sampling, so every
                    // subsequent sample lands mid-bit.
                    rx_state <= RX_START;
                    rx_clk_count <= 0;
                end
            end
            RX_START: begin
                if (rx_clk_count == (CLKS_PER_BIT / 2) - 1) begin
                    if (!rx) begin
                        // Confirmed real start bit (not a glitch) --
                        // begin sampling data bits, one full period apart.
                        rx_clk_count <= 0;
                        rx_bit_index <= 0;
                        rx_state <= RX_DATA;
                    end else begin
                        rx_state <= RX_IDLE;  // spurious edge, abort
                    end
                end else begin
                    rx_clk_count <= rx_clk_count + 1'b1;
                end
            end
            RX_DATA: begin
                if (rx_clk_count == CLKS_PER_BIT - 1) begin
                    rx_clk_count <= 0;
                    rx_shift_reg[rx_bit_index] <= rx;
                    if (rx_bit_index == 3'd7) begin
                        rx_state <= RX_STOP;
                    end else begin
                        rx_bit_index <= rx_bit_index + 1'b1;
                    end
                end else begin
                    rx_clk_count <= rx_clk_count + 1'b1;
                end
            end
            RX_STOP: begin
                if (rx_clk_count == CLKS_PER_BIT - 1) begin
                    rx_data_reg <= rx_shift_reg;
                    rx_ready <= 1'b1;
                    rx_state <= RX_IDLE;
                    rx_clk_count <= 0;
                end else begin
                    rx_clk_count <= rx_clk_count + 1'b1;
                end
            end
            default: rx_state <= RX_IDLE;
        endcase
    end
end

// ==========================================================================
// LSR/IIR (combinational -- no separate FIFO/shift-vs-hold distinction,
// so THRE and TEMT are identical here) and the single external `irq` line.
// ==========================================================================
wire [7:0] lsr = {1'b0, !tx_busy, !tx_busy, 4'b0, rx_ready};  // bit7..bit0

wire pending_rx  = ier[0] & rx_ready;
wire pending_thr = ier[1] & !tx_busy;
wire [3:0] iir4 = pending_rx ? 4'b0100 : pending_thr ? 4'b0010 : 4'b0001;

assign irq = pending_rx | pending_thr;

// ==========================================================================
// Read mux
// ==========================================================================
always @(*) begin
    case (reg_sel)
        REG_RBR_THR_DLL: s_data_i = dlab ? {24'b0, dll} : {24'b0, rx_data_reg};
        REG_IER_DLM:      s_data_i = dlab ? {24'b0, dlm} : {24'b0, ier};
        REG_IIR_FCR:      s_data_i = {24'b0, 4'b0, iir4};
        REG_LCR:          s_data_i = {24'b0, lcr};
        REG_MCR:          s_data_i = {24'b0, mcr};
        REG_LSR:          s_data_i = {24'b0, lsr};
        REG_MSR:          s_data_i = 32'b0;  // no modem lines wired -- documented simplification
        REG_SCR:          s_data_i = {24'b0, scr};
        default:          s_data_i = 32'b0;
    endcase
end

endmodule

`default_nettype wire
