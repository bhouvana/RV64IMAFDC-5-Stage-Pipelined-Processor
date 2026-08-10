`default_nettype none
`include "riscv_defs.vh"

// No `include for design/*.v modules instantiated below -- matches this
// project's own established convention (riscvpipeline.v/OOOCore.v only
// `include their own .vh headers, never sibling design/*.v modules);
// testbenches list the full flat dependency chain themselves.

// Generation 6, Gen6-N (docs/adr/0050). Heterogeneous "big-little" SoC:
// PIPELINED (design/riscvpipeline.v, the "big" core -- full RV32/64IMAF,
// MMU, interrupts, general atomics) and OOOCore.v (the "little" core --
// dual-issue OoO, but a genuinely narrower ISA subset, see OOOCore.v's
// own header) run SIMULTANEOUSLY, each with their own private
// instruction/data memory, sharing exactly one thing: design/Mailbox.v,
// a small memory-mapped handoff surface at MAILBOX_BASE
// (riscv_defs.vh).
//
// Real, load-bearing constraint, not a placeholder: OOOCore.v cannot
// execute jal/jalr/lui/auipc/csrrX/general-AMO/interrupts (design/
// OOOCore.v's own header + docs/adr/0048's own "real bugs/findings").
// Whatever program IMEM_INIT_FILE_OOO points at must be hand-written (or
// compiler-constrained) to avoid every one of those -- large constants
// built via the same addi/slli chunked idiom sim/tools/random_gen.py's
// own `no_lui` mode already established, control flow via conditional
// branches only, no function calls. This is a real, deliberate,
// documented limitation of what "the little core" can run today, not
// hidden.
//
// Mailbox protocol (a convention this module's own wiring enforces
// nothing about beyond the address range -- the two programs loaded
// into each core are what actually implement it): each core only ever
// WRITES its own designated words, never the other's (Mailbox.v's own
// header explains why a same-cycle same-word write from both ports is a
// real, unspecified race otherwise). See docs/adr/0050's own Design
// section for the exact word layout this phase's own directed test
// uses.
module HeteroSoC #(
    parameter XLEN = 64,
    parameter INIT_FILE_PIPELINED     = "sim/programs/arith.mem",
    parameter MEM_SIZE_BYTES_PIPELINED = 512,
    parameter IMEM_INIT_FILE_OOO       = "sim/programs/arith.mem",
    parameter IMEM_SIZE_BYTES_OOO      = 512,
    parameter DMEM_SIZE_BYTES_OOO      = 512,
    // Matches `MAILBOX_SIZE (riscv_defs.vh, 256 bytes) / 4 exactly --
    // both PIPELINED's own WbDecoder hit-test and OOOCore.v's own
    // address-range split decode against the FULL `MAILBOX_SIZE window,
    // so Mailbox.v's own real storage capacity must cover it too, or a
    // word address past this parameter's own capacity silently aliases
    // (Mailbox.v's own `mem[address[WORD_BITS+1:2]]` indexing wraps,
    // not a hard error) instead of a real out-of-bounds signal.
    parameter MAILBOX_WORDS            = 64
)(
    input wire clk,
    input wire rst_ooo,   // OOOCore.v's own active-low reset (independent
                            // of PIPELINED's own `start`, below -- the two
                            // cores are genuinely independent bus masters,
                            // not lockstepped)
    input wire start_pipelined   // PIPELINED's own active-HIGH start
                                   // (riscvpipeline.v's own convention,
                                   // unrelated to rst_ooo's polarity --
                                   // preserved exactly as each core's own
                                   // module already defines it, not
                                   // homogenized)
);

wire [XLEN-1:0] mbox_a_data_i;
wire            mbox_a_ack;
wire            mbox_m_cyc, mbox_m_stb, mbox_m_we;
wire [XLEN-1:0] mbox_m_addr, mbox_m_data_o;
wire [3:0]      mbox_m_sel;

PIPELINED #(
    .INIT_FILE(INIT_FILE_PIPELINED), .MEM_SIZE_BYTES(MEM_SIZE_BYTES_PIPELINED),
    .XLEN(XLEN)
) m_PIPELINED (
    .clk(clk), .start(start_pipelined), .uart_rx(1'b1),
    .mailbox_m_cyc(mbox_m_cyc), .mailbox_m_stb(mbox_m_stb), .mailbox_m_we(mbox_m_we),
    .mailbox_m_addr(mbox_m_addr), .mailbox_m_data_o(mbox_m_data_o), .mailbox_m_sel(mbox_m_sel),
    .mailbox_s_data_i(mbox_a_data_i), .mailbox_s_ack(mbox_a_ack)
);

wire            mbox_b_memWrite, mbox_b_memRead;
wire [XLEN-1:0] mbox_b_address, mbox_b_writeData;
wire [XLEN-1:0] mbox_b_readData;

OOOCore #(
    .XLEN(XLEN), .IMEM_INIT_FILE(IMEM_INIT_FILE_OOO), .IMEM_SIZE_BYTES(IMEM_SIZE_BYTES_OOO),
    .DMEM_SIZE_BYTES(DMEM_SIZE_BYTES_OOO)
) m_OOOCore (
    .clk(clk), .rst(rst_ooo),
    .mailbox_memWrite(mbox_b_memWrite), .mailbox_memRead(mbox_b_memRead),
    .mailbox_address(mbox_b_address), .mailbox_writeData(mbox_b_writeData),
    .mailbox_readData(mbox_b_readData)
);

Mailbox #(.XLEN(XLEN), .NUM_WORDS(MAILBOX_WORDS)) m_Mailbox (
    .clk(clk), .rst(rst_ooo),   // Mailbox.v's own reset just needs to be
                                  // asserted once at power-on like any
                                  // other module here -- reusing rst_ooo
                                  // rather than adding a 3rd independent
                                  // reset input (both cores' own reset
                                  // sequences already overlap in every
                                  // real bring-up, see this module's own
                                  // test harness).
    .a_cyc(mbox_m_cyc), .a_stb(mbox_m_stb), .a_we(mbox_m_we),
    .a_addr(mbox_m_addr), .a_data_o(mbox_m_data_o),
    .a_data_i(mbox_a_data_i), .a_ack(mbox_a_ack),
    .b_memWrite(mbox_b_memWrite), .b_memRead(mbox_b_memRead),
    .b_address(mbox_b_address), .b_writeData(mbox_b_writeData),
    .b_readData(mbox_b_readData)
);

endmodule

`default_nettype wire
