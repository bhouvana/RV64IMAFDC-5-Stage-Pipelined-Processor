`default_nettype none

// Generation 6, Gen6-N (docs/adr/0050). Small shared memory-mapped
// mailbox -- the real inter-core handoff surface for a heterogeneous
// PIPELINED+OOOCore.v SoC (design/HeteroSoC.v). Word-only access (no
// byte/halfword granularity -- a control-protocol mailbox never needs
// sub-word stores, and skipping that logic keeps this module small and
// obviously correct). NUM_WORDS words of storage, two fully independent
// ports:
//
// - Port A: a real classic (non-pipelined) Wishbone SLAVE interface,
//   matching every other slave WbDecoder.v already routes to inside
//   design/riscvpipeline.v (Uart.v/Timer.v/RamWishboneAdapter.v's own
//   shape) -- PIPELINED reaches this port through its own WbDecoder, a
//   real, additive 4th slave slot (docs/adr/0050), never through any
//   change to PIPELINED's own execution/decode logic.
// - Port B: the SAME simple, always-1-cycle-latency direct interface
//   DataMemoryBRAM.v already exposes (memRead/memWrite/address/
//   writeData/readData, no funct3 -- word-only, same reasoning as
//   above) -- design/OOOCore.v's own LoadStoreQueue.v assumes exactly
//   this fixed timing (Gen6-E's own no-wait-state scope), so this port
//   needs zero LSQ changes to use.
//
// Both ports can read/write the SAME cycle without stalling either core
// (a real dual-port memory, not an arbitrated/contended one) -- but if
// BOTH ports target the SAME word the SAME cycle, which write wins is
// unspecified (last-write-wins in simulation, a real race in hardware).
// This is the CALLER's own protocol responsibility to avoid, same
// "caller enforces the contract" discipline FreeList.v/DCache.v's own
// MSHR array already establish: the real mailbox protocol
// (docs/adr/0050's own Design section) partitions words so each core
// only ever WRITES its own designated words, never the other's.
module Mailbox #(
    parameter XLEN      = 32,
    parameter NUM_WORDS = 16,
    parameter WORD_BITS = $clog2(NUM_WORDS)
)(
    input  wire                  clk,
    input  wire                  rst,

    // Port A: Wishbone slave (PIPELINED side, via WbDecoder.v)
    input  wire                  a_cyc,
    input  wire                  a_stb,
    input  wire                  a_we,
    input  wire [XLEN-1:0]       a_addr,
    input  wire [XLEN-1:0]       a_data_o,
    output wire [XLEN-1:0]       a_data_i,
    output wire                  a_ack,

    // Port B: simple direct interface (OOOCore.v side, matching
    // DataMemoryBRAM.v's own memRead/memWrite/address/writeData/
    // readData shape minus funct3 -- word-only, see this module's own
    // header). readData is REGISTERED, 1-cycle latency, bit-for-bit
    // matching DataMemoryBRAM.v's own raw_word_r timing (confirmed by
    // direct read of that module before writing this one) -- Gen6-E's
    // own LoadStoreQueue.v assumes exactly this fixed latency (no real
    // wait-state model), so this port needs to present it identically
    // to be a true drop-in address-range peer, not just a same-shaped
    // port.
    input  wire                  b_memWrite,
    input  wire                  b_memRead,
    input  wire [XLEN-1:0]       b_address,
    input  wire [XLEN-1:0]       b_writeData,
    output reg  [XLEN-1:0]       b_readData
);

reg [XLEN-1:0] mem [0:NUM_WORDS-1];

integer reset_i;
always @(posedge clk) begin
    if (~rst) begin
        for (reset_i = 0; reset_i < NUM_WORDS; reset_i = reset_i + 1)
            mem[reset_i] <= {XLEN{1'b0}};
        b_readData <= {XLEN{1'b0}};
    end
    else begin
        // Port A: classic Wishbone, word-addressed (a_addr's own byte
        // offset within the mailbox's [BASE, BASE+SIZE) range, divided
        // by 4 -- the caller (WbDecoder.v) already strips the BASE
        // offset by construction, since s_addr passes m_addr through
        // unmodified and every slave decodes its OWN relative index the
        // same way RamWishboneAdapter.v/Uart.v/Timer.v already do).
        if (a_cyc && a_stb && a_we)
            mem[a_addr[WORD_BITS+1:2]] <= a_data_o;

        // Port B: direct, same word-addressing convention. Registered
        // read -- see this module's own header for why this must match
        // DataMemoryBRAM.v's own raw_word_r timing exactly.
        if (b_memWrite)
            mem[b_address[WORD_BITS+1:2]] <= b_writeData;
        if (b_memRead)
            b_readData <= mem[b_address[WORD_BITS+1:2]];
    end
end

// Port A ack: classic-cycle, combinational same-cycle ack (matching
// Uart.v's own identical "this slave always completes in the same cycle
// it's addressed" convention for a plain register-file-style memory this
// small). Plain `assign`, not an `always @(*)` block, to avoid Icarus's
// own "sensitive to all N words in array" warning a variable-indexed
// array read inside a procedural always block triggers.
assign a_ack    = a_cyc && a_stb;
assign a_data_i = mem[a_addr[WORD_BITS+1:2]];

endmodule

`default_nettype wire
