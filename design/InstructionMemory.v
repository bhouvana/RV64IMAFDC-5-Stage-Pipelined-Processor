`default_nettype none

// Instruction ROM: a flat byte array, word-read combinationally at
// `readAddr` (no synchronous retiming yet -- see docs/adr/0013's Future
// improvements, which retimed DataMemoryBRAM.v this way but left this
// module as future work). Reads past `SIZE_BYTES` return 0, which
// Control.v decodes as opcode 0000000, a real illegal-instruction trap
// (docs/adr/0011) -- every test program relies on this to catch a runaway
// PC (see the "jal x0, self" halt-loop convention documented in
// docs/ROADMAP.md).
//
// docs/adr/0037-rvc-compressed-instructions-phase-u.md: reads bytes in the
// same LSB-first order DataMemoryBRAM.v's own read already uses (`inst =
// {insts[readAddr+3], ..., insts[readAddr]}`, insts[readAddr] as the LOW
// byte) -- NOT the byte-reversed order this module used through Phase T
// (`{insts[readAddr], ..., insts[readAddr+3]}`, matched by asm.py's/
// elf2mem.py's own real byte-swap on write). That older convention only
// ever worked because every fetch before RVC was 4-byte-aligned, making a
// FIXED per-4-byte-aligned-word swap indistinguishable from a real
// per-fetch swap. RVC breaks that: a compressed instruction shifts every
// later instruction off the 4-byte grid, and a real, worked proof (this
// phase's own debugging) shows NO fixed static byte array can satisfy
// "every possible 4-byte read, at every possible alignment, reconstructs
// the correct little-endian value" simultaneously -- only a true, per-
// fetch LSB-first read (this module's new form, mirroring
// DataMemoryBRAM.v's own already-correct convention) is well-defined for
// arbitrary readAddr. asm.py's write_mem and elf2mem.py's own real ELF-
// byte-swap were updated to match (plain little-endian bytes, no swap at
// all) in the same change.
module InstructionMemory #(
    // Resolved relative to the simulator's working directory at run time
    // (Icarus resolves $readmemb paths against the invoking process's CWD,
    // not the source file's location) -- the provided Makefile always
    // invokes vvp from the repository root, so paths here are repo-root-relative.
    parameter INIT_FILE = "sim/programs/arith.mem",
    parameter SIZE_BYTES = 128,  // was a hardcoded 128 throughout; now threaded
                                   // from PIPELINED, matching DataMemory.v
                                   // (docs/ROADMAP.md Phase 6/7).
    parameter XLEN = 32,  // docs/adr/0015-xlen-and-regcount-parameterization.md.
                            // Applies to readAddr/inst too, same simplification
                            // ImmGen.v/reg1.v already made -- RV32I's fixed
                            // 32-bit instruction word happens to equal XLEN,
                            // only because both are 32 for this ISA.
    // docs/adr/0036-linux-boot-attempt-phase-t.md: 0 (default) keeps Phase
    // Q's own 64KB cap below exactly as-is (every existing test relies on
    // that cap for startup speed); a real kernel Image loaded at a multi-MB
    // offset needs more of the array actually populated from INIT_FILE than
    // that cap allows, so this build passes an explicit nonzero override
    // instead of changing the shared default.
    parameter ZERO_INIT_LIMIT_OVERRIDE = 0
) (
    input wire [XLEN-1:0] readAddr,
    output wire [XLEN-1:0] inst
);

    reg [7:0] insts [0:SIZE_BYTES-1];

    assign inst = (readAddr >= SIZE_BYTES) ? {XLEN{1'b0}} : {insts[readAddr + 3], insts[readAddr + 2], insts[readAddr + 1], insts[readAddr]};

    // Phase Q (docs/adr/0033): zero-initializing the full array at time 0 is
    // real cost proportional to SIZE_BYTES -- fine at the tens-of-KB this
    // core's programs have ever needed, prohibitive at MB scale (measured:
    // ~2m47s wall-clock for a trivial reset with the old unconditional loop
    // at SIZE_BYTES=64MB, vs. the fix below). Bounded to the same 64KB
    // window every actually-generated program (directed or constrained-
    // random) stays within, matching this project's own established "bound
    // the constant-cost operation to what the core's real work needs"
    // precedent (Ptw.v's 20-bit PPN truncation). Bit-exact at every
    // currently-used SIZE_BYTES (<=16384), all below this cap.
    localparam ZERO_INIT_LIMIT_DEFAULT = (SIZE_BYTES < 65536) ? SIZE_BYTES : 65536;
    localparam ZERO_INIT_LIMIT = (ZERO_INIT_LIMIT_OVERRIDE == 0) ? ZERO_INIT_LIMIT_DEFAULT : ZERO_INIT_LIMIT_OVERRIDE;
    integer i;
    initial begin
        for (i = 0; i < ZERO_INIT_LIMIT; i = i + 1)
            insts[i] = 8'b0;
        // Explicit start/stop avoids relying on simulator-specific default
        // behavior for which end of a descending-range array $readmemb fills
        // first (Icarus warns about exactly this ambiguity otherwise).
        // Range bounded to ZERO_INIT_LIMIT-1, not SIZE_BYTES-1 (found by
        // running Phase Q's own new large-memory test, docs/adr/0033): a
        // real program's .mem file is only ever as long as the program
        // itself, never padded out to a huge SIZE_BYTES, so requesting the
        // full range at MB scale made Icarus warn "not enough words in the
        // file" every time -- harmless (untouched words already sit at the
        // same 0 the bounded zero-init above just wrote), but a real,
        // avoidable warning this bound removes cleanly.
        if (INIT_FILE != "")
            $readmemb(INIT_FILE, insts, 0, ZERO_INIT_LIMIT-1);
    end

endmodule

`default_nettype wire
