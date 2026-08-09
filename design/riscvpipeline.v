`default_nettype none

`include "riscv_defs.vh"

// Top-level integration for the 5-stage (or, under PROFILE_6STAGE_SPLIT_FETCH,
// 6-stage) RV32I+M pipeline: IF -> ID -> EX -> MEM -> WB, connected by
// reg1/reg2/reg3/reg4 (plus reg1a under the split-fetch profile). Forwarding
// (Forward.v) and load-use hazard detection (Hazard.v, or HazardNoForward.v
// under the alternate strategy) resolve RAW hazards; EX-stage branch/jump
// resolution, CSR/exception traps, and mret all redirect through the same
// `unconditional_redirect`/`branch_taken` squash machinery. See
// docs/ARCHITECTURE.md sec 1 for the block diagram this module implements,
// and the module inventory table (sec 2) for what each instantiated module
// below does.
module PIPELINED #(
    parameter INIT_FILE = "sim/programs/arith.mem",
    parameter MEM_SIZE_BYTES = 128,  // threaded to both memories (docs/ROADMAP.md
                                       // Phase 6/7) -- default matches every
                                       // existing test program's assumptions,
                                       // so this is a no-op unless overridden.
    parameter DATA_INIT_FILE = "",   // docs/ROADMAP.md Phase 10 -- optional
                                       // pre-load for DataMemoryBRAM.v, e.g. a
                                       // compiled-C program's .data section.
                                       // Empty (default): every existing test's
                                       // assumption, data memory just resets to
                                       // zero as it always has.
    // docs/adr/0036-linux-boot-attempt-phase-t.md -- threaded to both
    // InstructionMemory.v and DataMemoryBRAM.v's identical ZERO_INIT_LIMIT
    // cap. 0 (default): Phase Q's own 64KB cap, bit-exact for every
    // existing test.
    parameter ZERO_INIT_LIMIT_OVERRIDE = 0,
    // docs/adr/0015-xlen-and-regcount-parameterization.md -- named, not truly
    // variable at other values: this core is RV32I+M only, and RV32I's own
    // instruction encoding hardwires a 32-bit instruction word and 5-bit
    // rs1/rs2/rd fields, so XLEN=32/NUM_REGS=32 are the only ISA-compliant
    // combination today. Threaded through as a single source of truth
    // (matching CQ-1's riscv_defs.vh spirit and docs/adr/0012's memory-size
    // precedent) and as groundwork for a possible future RV64I variant
    // (same instruction encoding, wider XLEN), not to claim arbitrary-width
    // support exists now.
    parameter XLEN = 32,
    parameter NUM_REGS = 32,
    // docs/adr/0016-swappable-hazard-strategy.md (docs/ROADMAP.md Phase 6:
    // "compare hazard strategies"). 0 (default): Hazard.v + Forward.v, this
    // core's original, fully-verified stall-on-load-use-only + forward-
    // everything-else strategy. 1: HazardNoForward.v, a conservative
    // alternate that stalls on *every* RAW hazard instead of forwarding
    // around any of them (Forward.v's muxes are forced to "no forward" in
    // this mode). Both are independently verified (see the ADR); 0 is what
    // every pre-existing test/ADR/benchmark result in this repo assumes.
    parameter HAZARD_STRATEGY = 0,
    // docs/adr/0018-variable-pipeline-depth.md (docs/ROADMAP.md Phase 6:
    // "compare pipeline depths") -- a closed, named enum, not a free integer
    // implying arbitrary stage counts (same honesty convention as
    // docs/adr/0015's XLEN/NUM_REGS). PROFILE_5STAGE (0, default): today's
    // exact IF/ID/EX/MEM/WB structure, bit-exact, what every existing test/
    // ADR/benchmark in this repo assumes. PROFILE_6STAGE_SPLIT_FETCH (1):
    // adds a second fetch-stage relay register (reg1a) ahead of today's IF/ID
    // boundary -- deliberately the structurally cheap alternate depth
    // (Forward.v/Hazard.v/reg2/reg3/reg4/the divider and MEM-stage interlocks
    // all anchor at ID/EX/MEM/WB, none of which a fetch-side split touches).
    // Splitting EX/MEM (branch-resolve-early, cache-miss stalls) remains
    // explicitly out of scope -- the genuinely larger redesign docs/adr/0016
    // already deferred, not attempted here either.
    parameter PIPELINE_PROFILE = 0,
    // docs/adr/0020-soc-integration.md (Phase D5). Uart.v's bit-shift-timing
    // divisor -- small by default so every existing/simulation test stays
    // fast (the framing logic itself doesn't care about the actual value,
    // only that it counts correctly, so a small divisor is just as valid a
    // correctness test as a realistic one). A real FPGA target instantiation
    // would override this to match a real baud rate against a real clock
    // frequency (e.g. 115200 baud at 50MHz needs 434).
    parameter UART_CLKS_PER_BIT = 4,
    // docs/adr/0021-branch-prediction.md (Phase E). A closed, named enum
    // (same docs/adr/0015 honesty convention as PIPELINE_PROFILE/
    // HAZARD_STRATEGY above -- never a free integer). PREDICTOR_STATIC (0,
    // default): today's exact behavior, unchanged and bit-exact forever --
    // fetch always guesses "not taken," every taken branch/jal/jalr/trap/
    // mret costs a fixed 2-bubble squash, discovered only once EX resolves
    // it. PREDICTOR_DYNAMIC_BHT_BTB (1): a per-PC 2-bit-saturating-counter
    // branch-history table (Bht.v) plus a branch-target buffer (Btb.v) let
    // fetch speculatively redirect *before* EX resolves anything; a correct
    // prediction costs zero bubbles, a misprediction still costs the same
    // 2-bubble squash as today, now discovered by comparing EX's ground-
    // truth outcome against the prediction that traveled alongside the
    // instruction, not by fetch simply never having guessed in the first
    // place. Not yet consumed anywhere as of this commit (E1).
    parameter BRANCH_PREDICTOR = 0,
    // docs/adr/0021-branch-prediction.md. Bht.v/Btb.v table size, only
    // meaningful under PREDICTOR_DYNAMIC_BHT_BTB. Must be a power of 2 (see
    // Bht.v/Btb.v's own indexing). Small by default -- this core's test
    // programs are tiny (32-instruction budget per sim/run_tests.sh), so a
    // bigger table buys nothing measurable without a benchmark large enough
    // to exercise it; a real FPGA target running larger programs could
    // override this.
    parameter BHT_BTB_ENTRIES = 32,
    // docs/adr/0023-caches.md (Phase G). A closed, named enum (same honesty
    // convention as HAZARD_STRATEGY/PIPELINE_PROFILE/BRANCH_PREDICTOR above).
    // CACHE_NONE (0, default): today's exact direct-InstructionMemory/
    // DataMemoryBRAM behavior, bit-exact, what every existing test/ADR/
    // benchmark in this repo assumes. CACHE_WRITEBACK_SETASSOC (1): a 4-way
    // set-associative write-back I$/D$ pair (ICache.v/DCache.v) sit in front
    // of the same backing memories, PIPT-indexed (this core's fetch and
    // load/store are already PIPT today -- translation resolves
    // combinationally before the memory array is indexed, see the ADR).
    // Not yet consumed anywhere as of this commit (G1) -- declared before
    // any consumer, same staging every prior swappable parameter used.
    parameter CACHE_MODE = 0,
    // docs/adr/0023-caches.md (Phase G). I$/D$ sizing, only meaningful
    // under CACHE_WRITEBACK_SETASSOC -- independently parameterized per
    // cache (not one shared enum) since a future --compare-cache sweep may
    // want to vary them independently, same granularity precedent as
    // HAZARD_STRATEGY/PIPELINE_PROFILE being separate parameters rather
    // than one combined one. Defaults: 4-way, 4KB, 16B lines (256 lines /
    // 4 ways = 64 sets) -- the more-ambitious sizing option confirmed with
    // the user over a smaller 2-way/1KB first pass.
    parameter ICACHE_WAYS = 4,
    parameter ICACHE_SIZE_BYTES = 4096,
    parameter ICACHE_LINE_BYTES = 16,
    parameter DCACHE_WAYS = 4,
    parameter DCACHE_SIZE_BYTES = 4096,
    parameter DCACHE_LINE_BYTES = 16,
    // docs/adr/0024-variable-latency-memory.md (Phase I). Additional
    // wait-state cycles beyond each side's own existing baseline timing --
    // independently configurable (a real system's I-side and D-side memory
    // can have genuinely different timing behind them), both 0 by default
    // (bit-exact with every phase before this one, same convention every
    // other swappable axis in this file already follows).
    parameter MEM_LATENCY_I = 0,
    parameter MEM_LATENCY_D = 0,
    // docs/adr/0041-cache-replacement-policy-phase-b.md (Generation 4, Phase
    // B). A closed, named enum (same honesty convention as HAZARD_STRATEGY/
    // PIPELINE_PROFILE/BRANCH_PREDICTOR/CACHE_MODE above). POLICY_ROUND_ROBIN
    // (0, default): today's exact per-set fill-order pointer, bit-exact,
    // what every existing test/ADR/benchmark in this repo assumes.
    // POLICY_FIFO (1): the SAME underlying mechanism as POLICY_ROUND_ROBIN --
    // round-robin already IS fill-order/FIFO eviction at this associativity;
    // a separately-implemented FIFO would be redundant RTL with zero
    // behavioral difference, so both select the identical non-LRU branch in
    // ICache.v/DCache.v. POLICY_LRU (2): true per-way access-recency
    // tracking, updated on every real hit AND every fill completion, not
    // just fills. Only meaningful under CACHE_WRITEBACK_SETASSOC. Not yet
    // consumed anywhere as of this commit.
    parameter REPLACEMENT_POLICY = 0,
    // Generation 4, Phase C (docs/adr/0042-victim-cache-phase-c.md): entry
    // count for a small fully-associative victim buffer sitting alongside
    // ICache.v/DCache.v, absorbing recently-evicted lines. 0 = disabled,
    // bit-exact with pre-Phase-C behavior. Not yet consumed anywhere as of
    // this commit.
    parameter VICTIM_ENTRIES = 0
)(
    input clk,
    input start,
    output [XLEN-1:0] debug_x10,   // read-only tap on x10/a0 (docs/adr/0012-fpga-
                                // readiness.md) -- a bare-metal test program's
                                // natural "write your result here" register
                                // under the standard RISC-V calling
                                // convention. Unused by every existing
                                // testbench (an unconnected output changes
                                // nothing about existing behavior); fpga/top.v
                                // is the first consumer.
    // docs/adr/0020-soc-integration.md (Phase D5). Real UART serial pins,
    // the same "tap for external use, unconnected changes nothing" shape
    // as debug_x10 above -- every existing testbench that doesn't
    // instantiate its own external UART peer simply leaves rx idle-high
    // (matching a real disconnected serial line) and ignores tx.
    output uart_tx,
    input  uart_rx,

    // docs/adr/0027-formal-verification.md (Phase L4). Formal-observability
    // taps only, same "unconnected changes nothing" shape as debug_x10
    // above -- the whole-pipeline formal property (a committing register
    // write is always from a real, non-squashed instruction) needs to
    // observe these two WB-stage signals from outside this module, and
    // Yosys's read_verilog can't resolve a hierarchical peek the way
    // iverilog's simulator can (confirmed by running in Phase L1/L3).
    output debug_regwrite_commit,  // regWrite_regwb
    output debug_valid_commit,     // valid_regwb

    // docs/adr/0036-linux-boot-attempt-phase-t.md: same "unconnected
    // changes nothing" tap shape as debug_x10 above -- the Verilator boot
    // harness has no other way to observe whether real forward progress is
    // happening (fetch-stage PC) or which privilege mode is live, short of
    // a full waveform dump.
    output [XLEN-1:0] debug_pc,        // pc_o, fetch-stage PC
    output [1:0] debug_priv_mode,      // priv_mode_w
    output [XLEN-1:0] debug_mcause,    // m_CSR.mcause, same hierarchical-tap idiom debug_x10 uses on m_Register
    // docs/adr/0037: temporary RVC-debug taps -- same "unconnected changes
    // nothing" shape as debug_x10.
    output debug_jump_regde,
    output [XLEN-1:0] debug_imm_sum,
    output [XLEN-1:0] debug_inst_regfd,
    output [XLEN-1:0] debug_inst_raw,
    output debug_is_compressed,
    output [XLEN-1:0] debug_inst_final,
    output debug_illegal_regde,
    output [XLEN-1:0] debug_inst_regde,
    output [XLEN-1:0] debug_pc_o_regde,
    output [7:0] debug_trap_src,
    output debug_exception_taken,
    output [XLEN-1:0] debug_trap_cause_raw,
    output [XLEN-1:0] debug_x1,
    output debug_amo_active,
    output debug_amo_write_phase,
    output debug_amo_write_done,
    output debug_amo_stall,
    output [XLEN-1:0] debug_amo_captured_read,
    // Phase W (sp/tp polling-loop investigation, docs/adr/0036's own parked-
    // loop gap): same "unconnected changes nothing" tap shape as debug_x10 --
    // a1/a2/a3/sp/tp are the exact registers the kernel's own hart-lottery
    // amoadd + secondary-hart wait_for_cpu_up loop reads.
    output [XLEN-1:0] debug_x2,
    output [XLEN-1:0] debug_x4,
    output [XLEN-1:0] debug_x11,
    output [XLEN-1:0] debug_x12,
    output [XLEN-1:0] debug_x13,
    // Phase X (Sv39 instruction-page-fault investigation, the new frontier
    // docs/adr/0039 found past the sp/tp fix): same "unconnected changes
    // nothing" tap shape as debug_x10.
    output [XLEN-1:0] debug_mtval,
    output [XLEN-1:0] debug_satp,
    output debug_translate_enable,
    output debug_itlb_hit,
    output debug_itlb_hit_fault,
    output debug_ptw_busy,
    output debug_ptw_done,
    output debug_ptw_fault,
    output [XLEN-1:0] debug_ptw_vaddr,
    output [XLEN-1:0] debug_ptw_m_addr
);
// Register-address field width, derived once and reused on every
// pipeline-register/Register.v/Forward.v/Hazard.v instantiation below.
localparam REG_ADDR_WIDTH = $clog2(NUM_REGS);

// PIPELINE_PROFILE values (docs/adr/0018-variable-pipeline-depth.md) -- named
// constants purely for readability at the generate/if sites that consume
// this parameter; not yet consumed anywhere as of this commit.
localparam PROFILE_5STAGE = 0;
localparam PROFILE_6STAGE_SPLIT_FETCH = 1;

// BRANCH_PREDICTOR values (docs/adr/0021-branch-prediction.md) -- named
// constants purely for readability at the generate/if sites that consume
// this parameter; not yet consumed anywhere as of this commit.
localparam PREDICTOR_STATIC = 0;
localparam PREDICTOR_DYNAMIC_BHT_BTB = 1;
localparam PREDICTOR_GSHARE = 2;       // Generation 4, Phase A (docs/adr/0040)
localparam PREDICTOR_TOURNAMENT = 3;   // Generation 4, Phase A (docs/adr/0040)

// CACHE_MODE values (docs/adr/0023-caches.md) -- named constants purely for
// readability at the generate/if sites that consume this parameter; not yet
// consumed anywhere as of this commit.
localparam CACHE_NONE = 0;
localparam CACHE_WRITEBACK_SETASSOC = 1;

// REPLACEMENT_POLICY values (docs/adr/0041-cache-replacement-policy-phase-b.md)
// -- named constants purely for readability at the instantiation sites that
// consume this parameter; not yet consumed anywhere as of this commit.
localparam POLICY_ROUND_ROBIN = 0;
localparam POLICY_FIFO        = 1;
localparam POLICY_LRU         = 2;

wire branch;
wire memRead;
wire memtoReg;
wire [1:0] ALUOp;
wire memWrite;
wire ALUSrc;
wire regWrite;
wire fRegWrite;    // docs/adr/0019-f-extension.md: writes FRegister.v instead of Register.v
wire [REG_ADDR_WIDTH-1:0] readReg1;
wire [REG_ADDR_WIDTH-1:0] readReg2;
wire [REG_ADDR_WIDTH-1:0] writeReg;
wire [XLEN-1:0] writeData;
wire [XLEN-1:0] readData1;
wire [XLEN-1:0] readData2;
wire [XLEN-1:0] pc_final;
wire [XLEN-1:0] imm_reg_val;
wire zero;
wire [4:0] ALUCtl;
wire [XLEN-1:0] imm;
wire [XLEN-1:0] ALUOut;
wire [XLEN-1:0] imm_sum;
wire [XLEN-1:0] imm_s;
wire [XLEN-1:0] inst;
wire [XLEN-1:0] pc_o;
wire [XLEN-1:0] pc_new;
wire [XLEN-1:0] pc_speculative;  // docs/adr/0021-branch-prediction.md: pc_new, or the predictor's guessed target
wire predict_taken_if;           // live query result for whatever pc_o is fetching THIS cycle
wire [XLEN-1:0] predict_target_if;
wire [XLEN-1:0] readData;
wire jump;
wire jalr;
wire lui;
wire auipc;
wire stall;         // load-use hazard (Hazard.v); freezes PC/IF-ID
wire flush;         // load-use hazard (Hazard.v); bubbles ID/EX
wire branch_zero;   // ALU's raw branch-condition output, registered into `zero`
wire pc_stall;      // stall | div_stall (docs/adr/0009) | mem_stall (docs/adr/0013) -- what PC/reg1 actually freeze on
wire isCsr;         // CSR/exceptions (docs/adr/0011-csr-and-exceptions.md)
wire isEcall;
wire isEbreak;
wire isMret;
wire isSret;         // docs/adr/00NN-mmu-sv32.md (Phase F2) -- no live consumer yet (F3)
wire isSfenceVma;    // docs/adr/00NN-mmu-sv32.md (Phase F2) -- no live consumer yet (F5)
wire isFence;        // docs/adr/0023-caches.md (Phase G1) -- no live consumer yet (G6)
wire isAmo;          // docs/adr/0038-a-extension-phase-v.md
wire illegalOpcode;
wire [XLEN-1:0] redirect_target;  // imm_sum (branch/jal/jalr), or mtvec/mepc on a trap/mret

// rst is active-low and synchronous: while low, every pipeline register
// and the architectural register file hold their reset values; once
// driven high the pipeline runs. (Named "start" for historical reasons --
// this file began as a single-cycle CPU template.)


 // ==========================================================================
 // IF -- Instruction Fetch
 // ==========================================================================

    // Under PROFILE_6STAGE_SPLIT_FETCH (docs/adr/0018-variable-pipeline-
    // depth.md), instruction memory reads reg1a's registered PC instead of
    // PC.v's combinational output directly -- one extra cycle of fetch
    // latency, decoupling PC generation from instruction-memory access.
    // PIPELINE_PROFILE is a parameter (elaboration-time constant), so this
    // ternary collapses to a direct wire connection with no runtime mux --
    // no generate/if needed here, unlike reg1a's own module-instantiation
    // choice, since this is a plain wire select, not a choice between
    // instantiating different modules.
    wire [XLEN-1:0] imem_read_addr = (PIPELINE_PROFILE == PROFILE_5STAGE) ? pc_o : pc_o_reg1a;

    // docs/adr/00NN-mmu-sv32.md (Phase F5): imem_phys_addr (defined in the
    // MMU translation block near the MEM section below) substitutes the
    // translated physical address when translation is active, bit-exact
    // with raw imem_read_addr otherwise -- forward-referenced here, same
    // pattern as pc_stall/priv_mode_w elsewhere in this file.
    //
    // docs/adr/0023-caches.md (Phase G3). CACHE_NONE (default): unchanged
    // direct InstructionMemory.v instantiation, bit-exact with every prior
    // phase. CACHE_WRITEBACK_SETASSOC: ICache.v sits at this exact same
    // feed point instead -- fetch is already PIPT today (translation
    // resolves combinationally before this address is formed), so the
    // cache is naturally PIPT too, no VIPT alias-handling needed (see the
    // ADR). icache_hit is tied to 1 under CACHE_NONE so icache_miss (its
    // own definition, in the MMU translation block below, alongside
    // itlb_miss) is always 0 there -- bit-exact with pre-G3 behavior.
    wire icache_hit;
    // docs/adr/0024-variable-latency-memory.md (Phase I3). imem_wait: a new
    // I-side interlock, CACHE_NONE only (CACHE_WRITEBACK_SETASSOC's own
    // I-side latency is I4's job instead, inside ICache.v's own fill
    // engine -- a cache hit never touches memory at all). InstructionMemory.v
    // has no ack/handshake of any kind (a flat combinational array read), so
    // this is genuinely new machinery, not a rewire of an existing ack --
    // detects a fresh fetch address (imem_phys_addr changed since the last
    // one this wait mechanism finished serving; PC/imem_phys_addr are
    // frozen by pc_stall throughout a wait, so no repeat-while-waiting
    // ambiguity is possible), gated on translation having resolved
    // (!translate_enable || itlb_hit, mirrors icache_miss's own gate --
    // don't start counting against a still-resolving, not-yet-final
    // physical address) and on !branch_taken && !redirect_squash_extend_r
    // -- the stall-vs-redirect priority bug this project has now hit three
    // times (docs/adr/0016, 0022 Finding 1, 0023 G3) -- applied proactively
    // here from the start instead of discovering it a fourth time by
    // running.
    wire imem_wait;
    generate
    if (CACHE_MODE == CACHE_NONE) begin : gen_icache_none
        assign icache_hit = 1'b1;
        InstructionMemory #(.INIT_FILE(INIT_FILE), .SIZE_BYTES(MEM_SIZE_BYTES), .XLEN(XLEN), .ZERO_INIT_LIMIT_OVERRIDE(ZERO_INIT_LIMIT_OVERRIDE)) m_InstMem(
            .readAddr(imem_phys_addr),
            .inst(inst)
        );

        if (MEM_LATENCY_I == 0) begin : gen_imem_latency_none
            assign imem_wait = 1'b0;
        end else begin : gen_imem_latency_added
            reg [XLEN-1:0] imem_served_addr_r;
            reg            imem_served_valid_r;
            wire imem_new_addr = !imem_served_valid_r || (imem_phys_addr != imem_served_addr_r);
            wire imem_latency_busy, imem_latency_done;
            // A real bug found by running (Phase I3, 3rd finding): without
            // excluding busy/done here, imem_served_addr_r (a REGISTERED
            // update, only visible starting the cycle AFTER done) hasn't
            // caught up yet on the exact cycle `done` fires -- MemoryLatencyModel's
            // OWN busy_r has ALREADY cleared that same cycle (its "start &&
            // !busy" guard evaluates busy_r's just-updated value), so
            // imem_new_addr is STILL true (stale served_addr_r) while busy
            // is ALSO already false -- imem_latency_start fires again on
            // that exact cycle and restarts the whole wait for an address
            // that's already served, silently doubling every wait's real
            // duration. Excluding busy/done here closes the one-cycle gap
            // the same way MemoryLatencyModel's own internal "start &&
            // !busy" guard already protects itself -- this wire needs the
            // identical protection against its OWN downstream bookkeeping's
            // one-cycle registered lag.
            wire imem_latency_start = imem_new_addr && !imem_latency_busy && !imem_latency_done
                && (!translate_enable || itlb_hit) && !branch_taken && !redirect_squash_extend_r;
            MemoryLatencyModel #(.LATENCY(MEM_LATENCY_I)) m_ImemLatency(
                .clk(clk), .rst(start),
                .start(imem_latency_start),
                .busy(imem_latency_busy),
                .done(imem_latency_done)
            );
            // A real bug found by running (Phase I3, 2nd finding): gating
            // pc_stall through a REGISTERED imem_wait_r (as an earlier
            // version of this block did) leaves a one-cycle gap between
            // imem_latency_start firing (combinational) and pc_stall
            // actually freezing reg1 (one cycle later, once imem_wait_r
            // catches up). InstructionMemory.v is purely combinational (no
            // real handshake at all), so `inst` is ALREADY valid the exact
            // cycle a new address appears -- during that one free cycle,
            // reg1 (not yet stalled) legitimately latches the real
            // instruction and it advances into reg2 completely normally.
            // Only THEN does the artificial wait catch up and start
            // masking pc_stall for an address that's already been
            // correctly fetched -- reg2 spends the whole (now-pointless)
            // wait being bubbled, discarding an instruction that was never
            // actually stale (unlike itlb_miss/icache_miss, which are
            // purely combinational with no such lag, so reg1 genuinely
            // never latches anything during their own stalls). Observed
            // directly only under BRANCH_PREDICTOR=1: a correctly-predicted
            // self-looping `jal` got bubbled away one cycle after being
            // correctly decoded, then re-fetched with a stale BTB
            // prediction, corrupting its own redirect target and running
            // the CPU off the end of the program. Fixed by gating on the
            // combinational start/busy pair directly instead of the
            // registered imem_wait_r -- MemoryLatencyModel's own busy
            // output already covers every cycle from the one after start
            // through the done cycle itself, so ORing it with
            // imem_latency_start (which covers exactly the one cycle busy
            // hasn't caught up to yet) leaves no gap.
            wire imem_wait_active = imem_latency_start || imem_latency_busy;
            // imem_abandoned_r (mirrors docs/adr/0022 Finding 3's
            // ptw_abandoned_r): once a wait is abandoned mid-flight (a
            // redirect fires while busy), its eventual `done` must NOT
            // mark imem_served_addr_r against imem_phys_addr, which has
            // since moved on to the redirect target -- would otherwise
            // wrongly mark the NEW address "already served" before its own
            // wait ever ran.
            // # ponytail: an abandoned wait still runs to completion
            // rather than being cancelled early, delaying the redirected
            // target's own real wait by however many cycles were left --
            // same accepted simplification ICache.v's own fill engine
            // already documents; never a correctness issue, only ever
            // extra (rare) stall cycles.
            reg imem_abandoned_r;
            always @(posedge clk) begin
                if (~start) imem_abandoned_r <= 1'b0;
                else if (imem_latency_busy && branch_taken) imem_abandoned_r <= 1'b1;
                else if (imem_latency_done) imem_abandoned_r <= 1'b0;
            end
            always @(posedge clk) begin
                if (~start) imem_served_valid_r <= 1'b0;
                else if (imem_latency_done && !imem_abandoned_r) begin
                    imem_served_addr_r  <= imem_phys_addr;
                    imem_served_valid_r <= 1'b1;
                end
            end
            assign imem_wait = imem_wait_active && !branch_taken && !redirect_squash_extend_r;
        end
    end else begin : gen_icache_writeback
        assign imem_wait = 1'b0;
        wire icache_busy, icache_done;
        ICache #(.INIT_FILE(INIT_FILE), .IMEM_SIZE_BYTES(MEM_SIZE_BYTES), .XLEN(XLEN),
                 .WAYS(ICACHE_WAYS), .CACHE_SIZE_BYTES(ICACHE_SIZE_BYTES), .LINE_BYTES(ICACHE_LINE_BYTES),
                 .MEM_LATENCY(MEM_LATENCY_I), .REPLACEMENT_POLICY(REPLACEMENT_POLICY),
                 .VICTIM_ENTRIES(VICTIM_ENTRIES)) m_ICache(
            .clk(clk), .rst(start),
            .readAddr(imem_phys_addr),
            .inst(inst),
            .hit(icache_hit),
            .busy(icache_busy),
            .done(icache_done)
        );
    end
    endgenerate
    //
    // docs/adr/0021-branch-prediction.md (Phase E4). Speculative arm: if the
    // predictor guesses this cycle's fetch is a taken branch/jump, override
    // the default sequential `pc_new` with its guessed target -- a second
    // Mux2to1 chained in front of the pre-existing redirect mux below,
    // which keeps top priority (an authoritative EX-stage
    // redirect/misprediction-correction always wins over a stale guess).
    // Under PREDICTOR_STATIC, predict_taken_if is tied to 0 (see
    // gen_predictor/gen_no_predictor below), so this mux always selects
    // s0=pc_new -- a pure no-op, bit-exact with today's single-mux fetch.
    Mux2to1 #(.size(XLEN)) m_Mux_PC_Speculative(
        .sel(predict_taken_if),
        .s0(pc_new),
        .s1(predict_target_if),
        .out(pc_speculative)
    );
    //
    Mux2to1 #(.size(XLEN)) m_Mux_PC(
        .sel(branch_taken),   // fires on a misprediction, a trap, or mret -- all resolved in EX
                               // (PREDICTOR_STATIC: fires on any taken branch/jal/jalr instead,
                               // exactly as before this phase -- see branch_or_jump_redirect below)
        .s0(pc_speculative),
        .s1(redirect_target),
        .out(pc_final)

    );
    //
    PC #(.XLEN(XLEN)) m_PC(
        .clk(clk),
        .rst(start),
        .stall(pc_stall),   // Hazard.v's load-use stall, the multi-cycle divide interlock (docs/adr/0009),
                            // or the MEM-stage interlock (docs/adr/0013)
        .pc_i(pc_final),
        .pc_o(pc_o)
    );

    // docs/adr/0037-rvc-compressed-instructions-phase-u.md. `inst` (the raw
    // fetch) is a real standard 32-bit instruction only when its own low
    // two bits are 11 -- otherwise the low half-word alone is a real,
    // complete 16-bit compressed instruction (the high half-word, whatever
    // it holds, belongs to a DIFFERENT, not-yet-fetched instruction and is
    // irrelevant here). InstructionMemory.v's own byte-array read already
    // tolerates any byte-aligned readAddr for free (not just 4-byte-
    // aligned), so a 2-byte-aligned compressed-instruction PC needs no new
    // memory-side plumbing -- only this expansion tap and the PC-increment/
    // link-address fixes below.
    wire is_compressed = (inst[1:0] != 2'b11);
    wire [31:0] inst_compressed_exp;
    CompressedExpander m_CompressedExpander(
        .c(inst[15:0]),
        .exp(inst_compressed_exp)
    );
    wire [XLEN-1:0] inst_final = is_compressed ? {{(XLEN-32){1'b0}}, inst_compressed_exp} : inst;

    Adder #(.XLEN(XLEN)) m_Adder_1(
        .a(pc_o),
        .b(is_compressed ? {{(XLEN-3){1'b0}}, 3'd2} : {{(XLEN-3){1'b0}}, 3'd4}),
        .sum(pc_new)
    );

wire [XLEN-1:0] inst_regfd;
wire [XLEN-1:0] pc_o_regfd;
wire predict_taken_regfd;               // docs/adr/0021-branch-prediction.md
wire [XLEN-1:0] predict_target_regfd;
wire ifetch_fault_regfd;                // docs/adr/00NN-mmu-sv32.md (Phase F5)
wire is_compressed_regfd;               // docs/adr/0037-rvc-compressed-instructions-phase-u.md

reg1 #(.XLEN(XLEN)) m_reg1(
    .clk(clk),
    .rst(start),
    .stall(pc_stall),
    .inst(inst_final),
    // Must be the PC that was actually used to fetch `inst` this cycle
    // (imem_read_addr), not PC.v's live pc_o -- under PROFILE_5STAGE these
    // are the same wire, but under PROFILE_6STAGE_SPLIT_FETCH pc_o has
    // already advanced to the *next* PC by the time inst (fetched via
    // reg1a's one-cycle-delayed address) comes back. Pairing inst with the
    // wrong PC here silently corrupts every PC-relative computation
    // downstream (branch/jal targets, auipc, jal's link address) --
    // caught by constrained-random cross-checking at profile 1 before this
    // fix, not assumed correct from the design alone.
    .pc_o(imem_read_addr),
    // docs/adr/0021-branch-prediction.md (Phase E4). Tied to 0 rather than
    // fed the real branch_regde/zero wires: unconditional_redirect below
    // now fully covers the branch/jump redirect condition on its own
    // (branch_or_jump_redirect, folded in below) for BOTH BRANCH_PREDICTOR
    // values -- under PREDICTOR_STATIC branch_or_jump_redirect reduces to
    // exactly (branch_regde&zero)|jump_regde, the same condition this
    // module would otherwise recompute itself, so tying these off and
    // routing everything through `jump` instead is bit-exact, not just
    // convenient. Under PREDICTOR_DYNAMIC_BHT_BTB it's essential, not just
    // tidy: feeding the raw (unfiltered-by-prediction) branch_regde/zero
    // here would squash every actually-taken branch regardless of whether
    // it was correctly predicted, defeating the entire feature.
    .branch_regde(1'b0),
    .zero(1'b0),
    // Fires on a misprediction, a trap, or mret (PREDICTOR_DYNAMIC_BHT_BTB)
    // or on any taken branch/jal/jalr/trap/mret (PREDICTOR_STATIC, bit-
    // exact with pre-Phase-E behavior) -- see unconditional_redirect's own
    // definition below. ORed with redirect_squash_extend_r (docs/adr/0018),
    // which is always 0 under PROFILE_5STAGE, so this term is a genuine
    // no-op at the default profile.
    .jump(unconditional_redirect | redirect_squash_extend_r),
    // docs/adr/0021-branch-prediction.md (Phase E4). The prediction made
    // for THIS fetch (query_pc == imem_read_addr, the same address `inst`
    // came from), latched alongside it -- see predict_taken_fetch/
    // predict_target_fetch's own definitions below for the
    // PIPELINE_PROFILE-aware selection (mirrors imem_read_addr's own
    // pc_o-vs-pc_o_reg1a pattern exactly, for the same reason: under
    // PROFILE_6STAGE_SPLIT_FETCH, the prediction that mattered for this
    // specific instruction was made one cycle earlier, when reg1a's own PC
    // was live, not whatever pc_o/predict_taken_if currently is).
    .predict_taken(predict_taken_fetch),
    .predict_target(predict_target_fetch),
    // docs/adr/00NN-mmu-sv32.md (Phase F5). See the MMU translation block
    // (near the MEM section below) for ifetch_fault_if's own definition --
    // referenced here as a forward reference, the same pattern this file
    // already relies on for pc_stall/priv_mode_w/etc.
    .ifetch_fault(ifetch_fault_if),
    .is_compressed(is_compressed),
    .inst_regfd(inst_regfd),
    .pc_o_regfd(pc_o_regfd),
    .predict_taken_regfd(predict_taken_regfd),
    .predict_target_regfd(predict_target_regfd),
    .ifetch_fault_regfd(ifetch_fault_regfd),
    .is_compressed_regfd(is_compressed_regfd)
);

// IF1/IF2 relay register (docs/adr/0018-variable-pipeline-depth.md). Only
// instantiated (and only meaningful) under PROFILE_6STAGE_SPLIT_FETCH --
// same elaboration-time generate/if template docs/adr/0016 established for
// HAZARD_STRATEGY, so PROFILE_5STAGE's branch costs nothing and isn't even
// instantiated. A plain, unconditional relay -- no squash notion of its
// own; see reg1a.v's header comment for the two rejected designs (an
// infinite loop, then a duplicated fetch) and redirect_squash_extend_r
// below for where the actual fix lives.
wire [XLEN-1:0] pc_o_reg1a;
wire predict_taken_reg1a;               // docs/adr/0021-branch-prediction.md
wire [XLEN-1:0] predict_target_reg1a;
generate
if (PIPELINE_PROFILE == PROFILE_5STAGE) begin : gen_fetch_5stage
    assign pc_o_reg1a = pc_o;  // unused under this profile; tied off for cleanliness, not read anywhere
    assign predict_taken_reg1a = 1'b0;
    assign predict_target_reg1a = {XLEN{1'b0}};
end else begin : gen_fetch_6stage_split_fetch
    reg1a #(.XLEN(XLEN)) m_reg1a(
        .clk(clk),
        .rst(start),
        .stall(pc_stall),
        .pc_o(pc_o),
        .pc_o_reg1a(pc_o_reg1a),
        .predict_taken(predict_taken_if),
        .predict_target(predict_target_if),
        .predict_taken_reg1a(predict_taken_reg1a),
        .predict_target_reg1a(predict_target_reg1a)
    );
end
endgenerate

// docs/adr/0021-branch-prediction.md (Phase E4). Which prediction pairs
// correctly with imem_read_addr's own PIPELINE_PROFILE-aware selection
// just above -- same reasoning, same pattern: under PROFILE_5STAGE the
// live combinational query (predict_taken_if, queried this cycle at pc_o)
// is exactly the prediction that was made for whatever imem_read_addr==
// pc_o just fetched; under PROFILE_6STAGE_SPLIT_FETCH, imem_read_addr is
// reg1a's one-cycle-delayed relay of a PAST pc_o, so the prediction that
// matters is reg1a's own equally-delayed relay of that past query
// (predict_taken_reg1a), not today's live one.
wire predict_taken_fetch = (PIPELINE_PROFILE == PROFILE_5STAGE) ? predict_taken_if : predict_taken_reg1a;
wire [XLEN-1:0] predict_target_fetch = (PIPELINE_PROFILE == PROFILE_5STAGE) ? predict_target_if : predict_target_reg1a;

// docs/adr/0021-branch-prediction.md (Phase E4). The predictor itself:
// only instantiated under PREDICTOR_DYNAMIC_BHT_BTB (the unselected branch
// isn't even elaborated, same convention as HAZARD_STRATEGY/
// PIPELINE_PROFILE above) -- queried combinationally every cycle at pc_o
// (the same live PC pc_new's own Adder_1 uses, not imem_read_addr -- the
// "what should fetch do next" decision always operates on PC.v's current
// live output regardless of profile, exactly like pc_new already does;
// only the value LATCHED for later comparison needs the profile-aware
// relay above). A hit requires BOTH tables to agree there's something
// useful here: Bht.v's own direction counter predicting taken, AND
// Btb.v actually having a target on file for this PC -- a direction-only
// "taken" with no known target has nowhere useful to speculatively
// redirect to. bp_update_valid/bp_update_pc/bp_update_taken/
// bp_update_target (trained from EX's real resolution) are declared where
// desired_taken/desired_target themselves are, further below.
wire bp_update_valid;
wire [XLEN-1:0] bp_update_pc;
wire bp_update_taken;
wire [XLEN-1:0] bp_update_target;
// Generation 4, Phase A (docs/adr/0040): restructured to share Btb.v (pure
// target prediction, identical regardless of which direction scheme is
// active) across every dynamic scheme, and to nest direction-scheme
// selection inside -- avoids duplicating the Btb.v instantiation three
// times. predict_taken_if/predict_target_if stay the exact same two wires
// every downstream consumer (reg1/reg1a/reg2 latching, the EX-stage
// mispredict comparison) already expects -- zero changes needed anywhere
// else in the pipeline beyond the branch_or_jump_redirect/target fix above.
generate
if (BRANCH_PREDICTOR != PREDICTOR_STATIC) begin : gen_btb
    wire btb_hit_q;
    wire [XLEN-1:0] btb_target_q;
    Btb #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Btb(
        .clk(clk), .rst(start),
        .query_pc(pc_o), .hit(btb_hit_q), .target(btb_target_q),
        .update_valid(bp_update_valid & bp_update_taken), .update_pc(bp_update_pc), .update_target(bp_update_target)
    );

    wire direction_predict_taken_q;

    if (BRANCH_PREDICTOR == PREDICTOR_DYNAMIC_BHT_BTB) begin : gen_direction_bht
        Bht #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Bht(
            .clk(clk), .rst(start),
            .query_pc(pc_o), .predict_taken(direction_predict_taken_q),
            .train_pc({XLEN{1'b0}}), .train_predict_taken(),
            .update_valid(bp_update_valid), .update_pc(bp_update_pc), .update_taken(bp_update_taken)
        );
    end else if (BRANCH_PREDICTOR == PREDICTOR_GSHARE) begin : gen_direction_gshare
        Gshare #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Gshare(
            .clk(clk), .rst(start),
            .query_pc(pc_o), .predict_taken(direction_predict_taken_q),
            .train_pc({XLEN{1'b0}}), .train_predict_taken(),
            .update_valid(bp_update_valid), .update_pc(bp_update_pc), .update_taken(bp_update_taken)
        );
    end else begin : gen_direction_tournament
        wire bht_predict_taken_q, bht_train_predict_taken_q;
        wire gshare_predict_taken_q, gshare_train_predict_taken_q;
        wire chooser_prefer_gshare_q;
        Bht #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Bht(
            .clk(clk), .rst(start),
            .query_pc(pc_o), .predict_taken(bht_predict_taken_q),
            .train_pc(bp_update_pc), .train_predict_taken(bht_train_predict_taken_q),
            .update_valid(bp_update_valid), .update_pc(bp_update_pc), .update_taken(bp_update_taken)
        );
        Gshare #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Gshare(
            .clk(clk), .rst(start),
            .query_pc(pc_o), .predict_taken(gshare_predict_taken_q),
            .train_pc(bp_update_pc), .train_predict_taken(gshare_train_predict_taken_q),
            .update_valid(bp_update_valid), .update_pc(bp_update_pc), .update_taken(bp_update_taken)
        );
        // a_correct/b_correct: re-query Bht's/Gshare's own opinion AT
        // bp_update_pc (the PC actually being trained this cycle) via the
        // second read port, compare each against the real resolved
        // outcome -- this is what avoids needing either sub-predictor's
        // original at-fetch-time guess threaded through the pipeline as a
        // new latched signal (docs/adr/0040's Design section). A real,
        // documented approximation for a re-trained (looping) PC between
        // fetch and resolution, same class as Bht.v's own "no same-cycle
        // bypass" aliasing note.
        Chooser #(.XLEN(XLEN), .NUM_ENTRIES(BHT_BTB_ENTRIES)) m_Chooser(
            .clk(clk), .rst(start),
            .query_pc(pc_o), .prefer_b(chooser_prefer_gshare_q),
            .update_valid(bp_update_valid), .update_pc(bp_update_pc),
            .a_correct(bht_train_predict_taken_q == bp_update_taken),
            .b_correct(gshare_train_predict_taken_q == bp_update_taken)
        );
        assign direction_predict_taken_q = chooser_prefer_gshare_q ? gshare_predict_taken_q : bht_predict_taken_q;
    end

    assign predict_taken_if = direction_predict_taken_q & btb_hit_q;
    assign predict_target_if = btb_target_q;
end else begin : gen_no_predictor
    assign predict_taken_if = 1'b0;
    assign predict_target_if = {XLEN{1'b0}};
end
endgenerate

// Under PROFILE_6STAGE_SPLIT_FETCH, a redirect needs reg1 (IF2/ID) to
// squash for one EXTRA cycle beyond what PROFILE_5STAGE needs -- an
// honest architectural cost, not a workaround: the extra fetch stage
// (reg1a) means one additional instruction is already "in flight," fetched
// using a now-stale address reg1a held before the redirect corrected it,
// by the time the redirect is discovered. Registers `branch_taken` one
// cycle so reg1's squash condition (fed via its `jump` port below) can OR
// it in; always 0 under PROFILE_5STAGE (the condition that sets it is
// itself gated on the split-fetch profile), so this is a genuine no-op at
// the default profile, not just a harmless-in-practice one. A real bug
// found by running constrained-random programs at this profile, not
// reasoned out in advance: without this, a redirect immediately followed
// by another instruction that depends on the redirect target's own
// results computes wrong values, because the duplicate/stale fetch this
// extra squash cycle discards would otherwise flow into reg2 and (for a
// CSR instruction specifically) apply its side effect an extra, spurious
// time.
reg redirect_squash_extend_r;
always @(posedge clk) begin
    if (~start)
        redirect_squash_extend_r <= 1'b0;
    else
        redirect_squash_extend_r <= (PIPELINE_PROFILE == PROFILE_6STAGE_SPLIT_FETCH) ? branch_taken : 1'b0;
end

wire [2:0] funct3_control;
wire [6:0] funct7_control;


 // ==========================================================================
 // ID -- Instruction Decode
 // ==========================================================================
    Control #(.XLEN(XLEN)) m_Control(
        .opcode(inst_regfd[6:0]),
        .funt7(inst_regfd[31:25]),
        .funt3(inst_regfd[14:12]),
        .csr_imm12(inst_regfd[31:20]),
        .branch(branch),
        .memRead(memRead),
        .memtoReg(memtoReg),
        .ALUOp(ALUOp),
        .memWrite(memWrite),
        .ALUSrc(ALUSrc),
        .regWrite(regWrite),
        .funct3(funct3_control),
        .funct7(funct7_control),
        .jump(jump),
        .jalr(jalr),
        .lui(lui),
        .auipc(auipc),
        .isCsr(isCsr),
        .isEcall(isEcall),
        .isEbreak(isEbreak),
        .isMret(isMret),
        .isSret(isSret),
        .isSfenceVma(isSfenceVma),
        .isFence(isFence),
        .isAmo(isAmo),
        .illegalOpcode(illegalOpcode),
        .fRegWrite(fRegWrite)
    );
//
    ImmGen #(.Width(XLEN)) m_ImmGen(
        .inst(inst_regfd),
        .imm(imm)
    );
//
    Register #(.XLEN(XLEN), .NUM_REGS(NUM_REGS), .SP_INIT(MEM_SIZE_BYTES)) m_Register(
        .clk(clk),
        .rst(start),
        .regWrite(regWrite_regwb),
        .readReg1(inst_regfd[19:15]),
        .readReg2(inst_regfd[24:20]),
        .writeReg(write_to_Reg_regwb),
        .writeData(writeData_regwb),
        .readData1(readData1),
        .readData2(readData2)
    );

    // docs/adr/0019-f-extension.md (Phase C6): parallel float register file.
    // Always instantiated and always reading rs1/rs2/rs3's bit positions
    // regardless of instruction type -- harmless when unused, the same
    // convention Register.v's own readReg1/readReg2 already follow.
    // writeReg/writeData are shared verbatim with Register.v above: the two
    // files' own regWrite/fRegWrite enables are mutually exclusive by
    // construction (Control.v never sets both for the same instruction), so
    // sharing the destination-index and write-value wires is safe, not a
    // race -- exactly one of the two actually commits a write each cycle.
    wire [XLEN-1:0] freadData1, freadData2, freadData3;
    FRegister #(.XLEN(XLEN), .NUM_REGS(NUM_REGS)) m_FRegister(
        .clk(clk),
        .rst(start),
        .regWrite(fRegWrite_regwb),
        .readReg1(inst_regfd[19:15]),
        .readReg2(inst_regfd[24:20]),
        .readReg3(inst_regfd[31:27]),
        .writeReg(write_to_Reg_regwb),
        .writeData(writeData_regwb),
        .readData1(freadData1),
        .readData2(freadData2),
        .readData3(freadData3)
    );

    // Opcode/funct5 classification, ID stage (inst_regfd) -- computed
    // directly from the raw instruction bits rather than as new Control.v
    // output ports, since these are needed in more than one place (register-
    // read routing here, the conservative float-hazard stall below) and are
    // cheap, pure combinational functions of bits Control.v already receives
    // anyway. A second, one-cycle-later copy exists at the EX stage
    // (inst_regde-based, see below) for actual execution dispatch -- the
    // same "decode the same thing twice, one cycle apart" shape
    // Control.v/ALUCtrl.v already use.
    wire [6:0] opcode_fd = inst_regfd[6:0];
    wire isOpFp_fd = (opcode_fd == `OPCODE_FP);
    wire isStoreFp_fd = (opcode_fd == `OPCODE_STORE_FP);
    wire isFma_fd = (opcode_fd == `OPCODE_MADD) || (opcode_fd == `OPCODE_MSUB) ||
                    (opcode_fd == `OPCODE_NMSUB) || (opcode_fd == `OPCODE_NMADD);
    // docs/adr/0019-f-extension.md (Phase C7): which of this ID-stage
    // instruction's rs1/rs2/rs3 *positions* are float reads -- same
    // "always read, harmless when unused" convention FRegister.v's own
    // read ports already follow, so this doesn't need to sub-decode which
    // specific OP-FP sub-op actually consumes which operand. rs1 is the one
    // position that's sometimes INTEGER despite an OP-FP opcode
    // (fcvt.s.w/fcvt.s.wu/fmv.w.x) -- mirrors rs1_is_float_regde's EX-stage
    // twin below exactly, one cycle earlier.
    wire [4:0] funct5_fd = inst_regfd[31:27];
    wire rs1_is_float_fd = isOpFp_fd &&
        !(funct5_fd == `FUNCT5_FCVT_S_W || funct5_fd == `FUNCT5_FMV_W_X);
    wire rs2_is_float_fd = isOpFp_fd || isStoreFp_fd || isFma_fd;
    wire rs3_is_float_fd = isFma_fd;
    // Real, register-indexed load-use hazard for flw -- the one float
    // hazard forwarding genuinely cannot resolve (flw's loaded value isn't
    // available until MEM completes, one cycle after FForward.v's EX/MEM
    // source could supply it), exactly mirroring Hazard.v's own lw
    // load-use check one cycle upstream (isLoadFp_regde is the EX-stage,
    // inst_regde-based twin of isOpFp_fd/isStoreFp_fd/isFma_fd -- see its
    // own declaration below). Replaces C6's placeholder maximally-
    // conservative "any float write anywhere in flight" stall now that
    // FForward.v resolves every other float RAW hazard by forwarding.
    wire float_load_use_hazard = isLoadFp_regde &&
        ((rs1_is_float_fd && (write_to_Reg_regde == inst_regfd[19:15])) ||
         (rs2_is_float_fd && (write_to_Reg_regde == inst_regfd[24:20])) ||
         (rs3_is_float_fd && (write_to_Reg_regde == inst_regfd[31:27])));

    // Hazard strategy select (docs/adr/0016-swappable-hazard-strategy.md) --
    // elaboration-time choice between the two hazard units; whichever one
    // is NOT selected isn't even instantiated, so this costs nothing in the
    // default (HAZARD_STRATEGY=0) build.
    generate
    if (HAZARD_STRATEGY == 0) begin : gen_hazard_forwarding
        Hazard #(.NUM_REGS(NUM_REGS)) m_Hazard(
            .readReg1_fd(inst_regfd[19:15]),
            .readReg2_fd(inst_regfd[24:20]),
            // Phase W (real kernel-boot bug, docs/adr/0038's own hart-lottery
            // amoadd.w): Control.v deliberately leaves memRead_regde=0 for
            // OPCODE_AMO (isAmo's own MEM-stage interlock drives the real
            // bus instead) -- but that same 0 also blinded THIS, separate,
            // earlier-staged load-use detector to an AMO's own multi-cycle
            // rd latency. An immediately-following instruction reading an
            // AMO's rd (the pre-modification value) advanced into EX one
            // cycle before amo_stall/reg2_hold could catch it, capturing
            // the stale pre-AMO register-file value instead -- real,
            // reproduced by the actual kernel's own aliased `amoadd.w
            // a3,a2,(a3)` / `bnez a3,...` hart-lottery pair (rd==rs1, the
            // very next instruction depends on rd). Same fix shape as an
            // ordinary load-use hazard: treat an AMO in "regde" as a hazard
            // source too, not just a real load.
            .la_memRead(memRead_regde | isAmo_regde),
            .la_dest(write_to_Reg_regde),
            .flush(flush),
            .stall(stall)
        );
    end else begin : gen_hazard_no_forward
        HazardNoForward #(.NUM_REGS(NUM_REGS)) m_HazardNoForward(
            .readReg1_fd(inst_regfd[19:15]),
            .readReg2_fd(inst_regfd[24:20]),
            .regWrite_regde(regWrite_regde),
            .write_to_Reg_regde(write_to_Reg_regde),
            .regWrite_regem(regWrite_regem),
            .write_to_Reg_regem(write_to_Reg_regem),
            .branch_taken(branch_taken),
            .flush(flush),
            .stall(stall)
        );
    end
    endgenerate
//
    wire valid_regde;  // docs/adr/0025-hpc-performance-csrs.md (Phase J3)
    wire branch_regde;
    wire memRead_regde;
    wire memtoReg_regde;
    wire memWrite_regde;
    wire ALUSrc_regde;
    wire regWrite_regde;
    wire fRegWrite_regde;
    wire [1:0] ALUOp_regde;
    wire [REG_ADDR_WIDTH-1:0] writeReg_regde;
    wire [XLEN-1:0] pc_o_regde;
    wire [XLEN-1:0] readData1_regde;
    wire [XLEN-1:0] readData2_regde;
    wire [XLEN-1:0] freadData1_regde;
    wire [XLEN-1:0] freadData2_regde;
    wire [XLEN-1:0] freadData3_regde;
    wire [XLEN-1:0] imm_regde;
    wire [XLEN-1:0] inst_regde;
    wire [REG_ADDR_WIDTH-1:0] readReg1_regde;
    wire [REG_ADDR_WIDTH-1:0] readReg2_regde;
    wire [REG_ADDR_WIDTH-1:0] readReg3_regde;
    wire predict_taken_regde;               // docs/adr/0021-branch-prediction.md
    wire [XLEN-1:0] predict_target_regde;
    wire ifetch_fault_regde;                // docs/adr/00NN-mmu-sv32.md (Phase F5)
    wire is_compressed_regde;               // docs/adr/0037-rvc-compressed-instructions-phase-u.md
    wire [1:0] forwardA;
    wire [1:0] forwardB;
    wire [1:0] fforwardA;
    wire [1:0] fforwardB;
    wire [1:0] fforwardC;
    wire jump_regde;
    wire jalr_regde;
    wire lui_regde;
    wire auipc_regde;
    wire isCsr_regde;
    wire isEcall_regde;
    wire isEbreak_regde;
    wire isMret_regde;
    wire isSret_regde;
    wire isSfenceVma_regde;
    wire isFence_regde;
    wire illegalOpcode_regde;
    //
reg2 #(.XLEN(XLEN), .NUM_REGS(NUM_REGS)) m_reg2(
    .clk(clk),
    .rst(start),
    .branch(branch),
    .memRead(memRead),
    .memtoReg(memtoReg),
    .memWrite(memWrite),
    .ALUSrc(ALUSrc),
    .regWrite(regWrite),
    .fRegWrite(fRegWrite),
    .writeReg(inst_regfd[11:7]),
    .funct7(funct7_control),
    .funct3(funct3_control),
    .ALUOp(ALUOp),
    .pc_o_regfd(pc_o_regfd),
    .readData1(readData1),
    .readData2(readData2),
    .freadData1(freadData1),
    .freadData2(freadData2),
    .freadData3(freadData3),
    .imm(imm),
    .inst_regfd(inst_regfd),
    // docs/adr/00NN-mmu-sv32.md (Phase F5): itlb_miss joins float_load_use_hazard
    // here -- same front-end-only-interlock category as Hazard.v's own
    // stall (reg1 held via pc_stall, so whatever's flowing into reg2 is
    // unchanged cycle to cycle; without also bubbling reg2 here, the
    // instruction already in ID before the miss began would be re-latched
    // into EX every stall cycle instead of exactly once -- the same bug
    // class docs/adr/0016 found for HazardNoForward.v's own stall).
    .flush(flush | float_load_use_hazard | itlb_miss | icache_miss | imem_wait),  // docs/adr/0024 (Phase I3): imem_wait joins the same I-side group. docs/adr/0019 (Phase C7): bubble reg2 while an flw
                                          // load-use hazard clears, same "insert a nop, real
                                          // instruction retries from IF/ID" shape as Hazard.v's own
    .branch_taken(branch_taken),
    // docs/adr/0025-hpc-performance-csrs.md (Phase J3). id_bubble_r
    // (declared below, near interrupt_taken) already tracks exactly this;
    // `id_bubble_r` is itself declared later in this file but Verilog
    // doesn't require declare-before-use ordering within a module.
    .valid(!id_bubble_r),
    .hold(reg2_hold),   // multi-cycle divide interlock (docs/adr/0009) OR MEM-stage
                         // interlock (docs/adr/0013) -- either way, ID/EX must not
                         // advance past the instruction reg3 isn't ready to accept yet.
    .readReg1(inst_regfd[19:15]),
    .readReg2(inst_regfd[24:20]),
    .readReg3(inst_regfd[31:27]),
    // docs/adr/0021-branch-prediction.md (Phase E4). The prediction reg1
    // already latched for this instruction, carried one more stage to EX.
    .predict_taken(predict_taken_regfd),
    .predict_target(predict_target_regfd),
    // docs/adr/00NN-mmu-sv32.md (Phase F5). reg1's own ifetch_fault_regfd,
    // carried one more stage to EX.
    .ifetch_fault(ifetch_fault_regfd),
    // docs/adr/0037-rvc-compressed-instructions-phase-u.md.
    .is_compressed(is_compressed_regfd),
    .jump(jump),
    .jalr(jalr),
    .lui(lui),
    .auipc(auipc),
    .isCsr(isCsr),
    .isEcall(isEcall),
    .isEbreak(isEbreak),
    .isMret(isMret),
    .isSret(isSret),
    .isSfenceVma(isSfenceVma),
    .isFence(isFence),
    .isAmo(isAmo),
    .illegalOpcode(illegalOpcode),

    .valid_regde(valid_regde),
    .branch_regde(branch_regde),
    .memRead_regde(memRead_regde),
    .memtoReg_regde(memtoReg_regde),
    .memWrite_regde(memWrite_regde),
    .ALUSrc_regde(ALUSrc_regde),
    .regWrite_regde(regWrite_regde),
    .fRegWrite_regde(fRegWrite_regde),
    .ALUOp_regde(ALUOp_regde),
    .write_to_Reg_regde(write_to_Reg_regde),
    .pc_o_regde(pc_o_regde),
    .readData1_regde(readData1_regde),
    .readData2_regde(readData2_regde),
    .freadData1_regde(freadData1_regde),
    .freadData2_regde(freadData2_regde),
    .freadData3_regde(freadData3_regde),
    .imm_regde(imm_regde),
    .inst_regde(inst_regde),
    .funct7_regde(funct7_regde),
    .funct3_regde(funct3_regde),
    .readReg1_regde(readReg1_regde),
    .readReg2_regde(readReg2_regde),
    .readReg3_regde(readReg3_regde),
    .predict_taken_regde(predict_taken_regde),
    .predict_target_regde(predict_target_regde),
    .ifetch_fault_regde(ifetch_fault_regde),
    .is_compressed_regde(is_compressed_regde),
    .jump_regde(jump_regde),
    .jalr_regde(jalr_regde),
    .lui_regde(lui_regde),
    .auipc_regde(auipc_regde),
    .isCsr_regde(isCsr_regde),
    .isEcall_regde(isEcall_regde),
    .isEbreak_regde(isEbreak_regde),
    .isMret_regde(isMret_regde),
    .isSret_regde(isSret_regde),
    .isSfenceVma_regde(isSfenceVma_regde),
    .isFence_regde(isFence_regde),
    .isAmo_regde(isAmo_regde),
    .illegalOpcode_regde(illegalOpcode_regde)
);

wire [6:0] funct7_regde;
wire [2:0] funct3_regde;
wire isAmo_regde;  // docs/adr/0038-a-extension-phase-v.md
wire [XLEN-1:0] readData1_final;
wire [XLEN-1:0] readData2_final;
wire branch_taken;
wire unconditional_redirect;  // branch/jal/jalr (mispredict-gated under docs/adr/0021) | trap | mret
// Fires on a taken branch, an unconditional jal/jalr, a synchronous
// exception, or mret -- all resolved here in EX, all squash the two
// younger in-flight instructions (see reg1.jump / reg2.branch_taken).
// docs/adr/0021-branch-prediction.md (Phase E4): unconditional_redirect's
// own definition (below, near desired_taken/mispredict) now folds the
// branch/jal/jalr condition in directly (branch_or_jump_redirect) rather
// than this wire adding (branch_regde&zero) back on top of a narrower
// unconditional_redirect the way it did before this phase -- the two
// wires are therefore now always numerically identical; kept as two names
// because every existing consumer of either already has its own settled
// meaning and comment trail, not because they differ.
assign branch_taken = unconditional_redirect;

// forwarding unit (docs/adr/0016-swappable-hazard-strategy.md: only
// instantiated under the default forwarding strategy -- the alternate
// HazardNoForward.v strategy ties forwardA/B to "no forward" directly,
// relying entirely on stalling plus Register.v's existing write-first
// bypass instead).
generate
if (HAZARD_STRATEGY == 0) begin : gen_forward
    // fwd_valid/fwd_dest are farthest-producer-first (index 0 = MEM/WB,
    // index 1 = EX/MEM), matching Forward.v's NUM_FWD_SRC=2 default -- see
    // its own comment for why that order makes the nearest producer win
    // ties.
    Forward #(.NUM_REGS(NUM_REGS)) m_Forward(
        .readReg1_regde(readReg1_regde),
        .readReg2_regde(readReg2_regde),
        .fwd_valid({regWrite_regem, regWrite_regwb}),
        .fwd_dest({write_to_Reg_regem, write_to_Reg_regwb}),
        .forwardA(forwardA),
        .forwardB(forwardB)
    );
end else begin : gen_no_forward
    assign forwardA = 2'b00;
    assign forwardB = 2'b00;
end
endgenerate

// ==========================================================================
// EX -- Execute
// ==========================================================================
    ShiftLeftOne #(.Width(XLEN)) m_ShiftLeftOne(
    .i(imm_regde),
    .o(imm_s)
    );
//
    // Target-address base/offset: branch/jal use PC + (shifted immediate);
    // jalr uses rs1 + (plain, unshifted immediate) with bit0 cleared per
    // spec. Same adder, muxed inputs -- avoids a second dedicated adder for
    // what is otherwise identical redirect-target-computation plumbing.
    wire [XLEN-1:0] target_base = jalr_regde ? readData1_final : pc_o_regde;
    wire [XLEN-1:0] target_off  = jalr_regde ? imm_regde : imm_s;
    wire [XLEN-1:0] imm_sum_raw;
    Adder #(.XLEN(XLEN)) m_Adder_2(
    .a(target_base),
    .b(target_off),
    .sum(imm_sum_raw)
    );
    assign imm_sum = {imm_sum_raw[XLEN-1:1], 1'b0};  // clear bit0 (only jalr needs this; branch/jal sums are already even)

    // Link value for jal/jalr (rd = PC+2 or PC+4) and the branch predictor's
    // fallthrough-PC comparison -- docs/adr/0037: a compressed instruction's
    // real "next sequential PC" is only 2 bytes past its own address, not 4
    // (e.g. c.jalr's own real link value is PC+2, not PC+4 -- getting this
    // wrong would corrupt the return address of every compressed call).
    // Reuses the generic Adder the same way Adder_1 (fetch, PC+len) and
    // Adder_2 (branch/jump target) already do.
    wire [XLEN-1:0] pc_plus4_regde;
    Adder #(.XLEN(XLEN)) m_Adder_3(
    .a(pc_o_regde),
    .b(is_compressed_regde ? {{(XLEN-3){1'b0}}, 3'd2} : {{(XLEN-3){1'b0}}, 3'd4}),
    .sum(pc_plus4_regde)
    );

    // EX/MEM forwarding must hand out the *architectural* result of the EX/MEM
    // instruction, not the raw ALU output -- for jal those differ (ALUOut is
    // unused/meaningless for jal; the real result is PC+4). Forwarded from
    // MEM/WB (writeData_regwb, s1 below) is unaffected: that value is formed
    // by the WB-stage jal-override mux and is already correct.
    wire [XLEN-1:0] exmem_fwd_val;
    assign exmem_fwd_val = jump_regem ? pc_plus4_regem : ALUOut_regem;

    // docs/adr/0019-f-extension.md (Phase C7): float forwarding, replacing
    // C6's maximally-conservative placeholder stall. Mirrors the integer
    // network immediately above almost exactly -- same fwd_valid/fwd_dest
    // ordering (index 0 = MEM/WB, index 1 = EX/MEM), same EX/MEM-forwarded
    // value (exmem_fwd_val is already correct for float ops unmodified:
    // jump_regem is always 0 for an F-extension instruction, so it reduces
    // to plain ALUOut_regem, which already carries fp_result via ex_result
    // -- see reg3's own instantiation below), same MEM/WB-forwarded value
    // (writeData_regwb, already generic over which register file the
    // result is destined for). Not gated by HAZARD_STRATEGY: that
    // parameter is specifically the *integer* Hazard.v/HazardNoForward.v
    // research-platform toggle (docs/adr/0016) and doesn't apply here --
    // float forwarding is unconditional, additive infrastructure per the
    // plan's own explicitly-out-of-scope note.
    FForward #(.NUM_REGS(NUM_REGS)) m_FForward(
        .readReg1_regde(readReg1_regde),
        .readReg2_regde(readReg2_regde),
        .readReg3_regde(readReg3_regde),
        .fwd_valid({fRegWrite_regem, fRegWrite_regwb}),
        .fwd_dest({write_to_Reg_regem, write_to_Reg_regwb}),
        .forwardA(fforwardA),
        .forwardB(fforwardB),
        .forwardC(fforwardC)
    );

    wire [XLEN-1:0] freadData1_final;
    wire [XLEN-1:0] freadData2_final;
    wire [XLEN-1:0] freadData3_final;
    MuxN #(.size(XLEN)) m_Mux_FPU_A(
    .sel(fforwardA),
    .s0(freadData1_regde),
    .src({exmem_fwd_val, writeData_regwb}),
    .out(freadData1_final)
    );

    MuxN #(.size(XLEN)) m_Mux_FPU_B(
    .sel(fforwardB),
    .s0(freadData2_regde),
    .src({exmem_fwd_val, writeData_regwb}),
    .out(freadData2_final)
    );

    MuxN #(.size(XLEN)) m_Mux_FPU_C(
    .sel(fforwardC),
    .s0(freadData3_regde),
    .src({exmem_fwd_val, writeData_regwb}),
    .out(freadData3_final)
    );

    // src bus must match Forward.v's fwd_dest ordering above (index 0 =
    // MEM/WB, index 1 = EX/MEM) so forwardA/B's encoding selects the right
    // value.
    MuxN #(.size(XLEN)) m_Mux_ALU_A(
    .sel(forwardA),
    .s0(readData1_regde),
    .src({exmem_fwd_val, writeData_regwb}),
    .out(readData1_final)
    );

    MuxN #(.size(XLEN)) m_Mux_ALU_B(
    .sel(forwardB),
    .s0(readData2_regde),
    .src({exmem_fwd_val, writeData_regwb}),
    .out(readData2_final)
    );




//
    Mux2to1 #(.size(XLEN)) m_Mux_ALU(
    .sel(ALUSrc_regde),
    .s0(readData2_final),
    .s1(imm_regde),
    .out(imm_reg_val)
    );
//



    ALUCtrl m_ALUCtrl(
    .ALUOp(ALUOp_regde),
    //.functi(inst_regde)
    .funct7_c(funct7_regde),
    .funct3_c(funct3_regde),
    .ALUCtl(ALUCtl)
    );
//
    // lui/auipc have no real rs1 (those instruction bits are part of the
    // U-type immediate) -- they reuse the ALU's ADD by overriding its A
    // operand: 0 for lui (result = imm), PC for auipc (result = PC+imm).
    // This is why lui/auipc need no writeback-mux override or forwarding
    // correction the way jal/jalr did: ALUOut is already the right value,
    // so it flows through the existing EX/MEM path untouched.
    wire [XLEN-1:0] aluA;
    Mux4to1 #(.size(XLEN)) m_Mux_ALU_A_Src(
    .sel({auipc_regde, lui_regde}),
    .s0(readData1_final),
    .s1({XLEN{1'b0}}),
    .s2(pc_o_regde),
    .out(aluA)
    );

    ALU #(.XLEN(XLEN)) m_ALU(
    .ALUCtl(ALUCtl),
    .A(aluA),
    .B(imm_reg_val),
    .wordOp(wordOp_regde),
    .ALUOut(ALUOut),
    .zero(zero),
    .branch_zero(branch_zero)
    );

    // Multi-cycle division interlock (docs/adr/0009-multicycle-divider.md).
    // Unlike mul (single-cycle via the ALU above), div/rem route through a
    // dedicated iterative unit and are NOT ready the same cycle they enter
    // EX. `start` is tied to `isDivRem` at the *level* (not a pulse) --
    // Divider.v's own `start && !busy` guard means it only actually latches
    // new operands once, on the first cycle, and naturally ignores `start`
    // staying asserted for the rest of the (many-cycle) computation.
    wire isDivRem = (ALUCtl == `ALUCTL_DIV) || (ALUCtl == `ALUCTL_DIVU) ||
                    (ALUCtl == `ALUCTL_REM) || (ALUCtl == `ALUCTL_REMU);
    // divw/divuw/remw/remuw share these SAME ALUCtl codes as their plain
    // div/divu/rem/remu counterparts (OP-32 reuses OP's funct7/funct3
    // byte-for-byte, see wordOp_regde's own comment above) -- isDivRem/
    // isDivSigned/div_stall correctly cover both without any change here.
    wire isDivSigned = (ALUCtl == `ALUCTL_DIV) || (ALUCtl == `ALUCTL_REM);
    wire div_busy, div_done;
    wire [XLEN-1:0] div_quotient, div_remainder;

    // Generation 2 (Phase M): divw/divuw/remw/remuw reuse Divider.v
    // completely unmodified -- truncate the low 32 bits of each operand and
    // extend back to XLEN (sign-extend if isDivSigned, matching div/rem's
    // own signedness; zero-extend otherwise, matching divu/remu's) before
    // this same divider runs on them at full XLEN width. Mathematically
    // equivalent to a true 32-bit division, including the INT32_MIN/-1
    // overflow edge case (verified by hand: two's-complement truncation of
    // the true 64-bit quotient 2^31 reproduces exactly the spec-mandated
    // overflow result, dividend itself, without needing a separate special
    // case here). `# ponytail: costs a full XLEN-cycle (64-cycle) divide
    // for what's architecturally a 32-bit divide; a genuine 32-cycle fast
    // path for *w divides is a separable future optimization, not
    // attempted here.`
    wire [XLEN-1:0] div_dividend_in = wordOp_regde ?
        (isDivSigned ? {{(XLEN-32){aluA[31]}}, aluA[31:0]} : {{(XLEN-32){1'b0}}, aluA[31:0]}) :
        aluA;
    wire [XLEN-1:0] div_divisor_in = wordOp_regde ?
        (isDivSigned ? {{(XLEN-32){imm_reg_val[31]}}, imm_reg_val[31:0]} : {{(XLEN-32){1'b0}}, imm_reg_val[31:0]}) :
        imm_reg_val;

    Divider #(.XLEN(XLEN)) m_Divider(
    .clk(clk),
    .rst(start),
    .start(isDivRem),
    .isSigned(isDivSigned),
    .dividend(div_dividend_in),
    .divisor(div_divisor_in),
    .busy(div_busy),
    .done(div_done),
    .quotient(div_quotient),
    .remainder(div_remainder)
    );

    // True from the cycle a div/rem enters EX until (not including) the
    // cycle its result becomes valid -- freezes PC/IF-ID (via pc_stall) and
    // holds ID/EX (reg2.hold) for exactly that span. False the rest of the
    // time, including every cycle occupied by a non-div/rem instruction, so
    // it never affects normal single-cycle execution.
    wire div_stall = isDivRem && !div_done;

    // ==========================================================================
    // F-extension execute (docs/adr/0019-f-extension.md, Phase C6). Opcode/
    // funct5 classification, EX stage (inst_regde) -- see the ID-stage
    // (inst_regfd-based) copy above for why this is computed twice, one
    // cycle apart, rather than threaded as a dedicated Control.v output.
    // ==========================================================================
    wire [6:0] opcode_regde = inst_regde[6:0];

    // Generation 2 (Phase M, docs/adr/0028-rv64-migration-phase-m.md).
    // Recomputed from inst_regde, same pattern as isOpFp_regde/etc. below --
    // no new reg2/reg3 field needed. OPCODE_OP_32/OPCODE_OP_IMM_32 reuse
    // OP/OP-IMM's own funct7/funct3 encodings byte-for-byte (ALUCtrl.v), so
    // ALUCtl alone can't distinguish e.g. divw from div -- wordOp_regde is
    // what actually does, telling ALU.v (m_ALU below) and the Divider
    // operand wrapper to truncate-and-sign-extend.
    wire isOp32_regde    = (opcode_regde == `OPCODE_OP_32);
    wire isOpImm32_regde = (opcode_regde == `OPCODE_OP_IMM_32);
    wire wordOp_regde    = isOp32_regde || isOpImm32_regde;

    wire isOpFp_regde = (opcode_regde == `OPCODE_FP);
    wire isLoadFp_regde = (opcode_regde == `OPCODE_LOAD_FP);
    wire isStoreFp_regde = (opcode_regde == `OPCODE_STORE_FP);
    wire isFma_regde = (opcode_regde == `OPCODE_MADD) || (opcode_regde == `OPCODE_MSUB) ||
                       (opcode_regde == `OPCODE_NMSUB) || (opcode_regde == `OPCODE_NMADD);
    // OP-FP's funct5 (inst[31:27]) occupies the exact bits R-type's funct7
    // does, so it's already sitting in funct7_regde's top 5 bits -- no new
    // reg2 field needed to carry it. rm (rounding mode) is likewise already
    // funct3_regde; RM_DYN (rm==111) resolution against fcsr's live frm
    // happens right below (docs/adr/0019 Phase C8) -- FALU.v/FMADDUnit.v/
    // FDivider.v/FSqrt.v all expect an already-resolved rm, by design (see
    // FALU.v's own header comment).
    wire [4:0] funct5_regde = funct7_regde[6:2];
    // docs/adr/0019-f-extension.md (Phase C9 bugfix): MADD/MSUB/NMSUB/NMADD
    // (7'b1000011/1000111/1001011/1001111) are distinguished by bits[3:2],
    // NOT bits[4:3] -- bit4 is 0 for all four, so the original [4:3] slice
    // silently aliased fmadd.s with fmsub.s (both decoded as op=00) and
    // fnmsub.s with fnmadd.s (both decoded as op=01), each pair collapsing
    // to whichever op the *lower* opcode of the pair actually meant. Found
    // building sim/tools/iss.py's independent float model (C9) -- none of
    // C6/C7/C8's directed tests happened to exercise fmsub.s/fnmsub.s/
    // fnmadd.s, only fmadd.s, which has op=00 either way and so never
    // surfaced the bug.
    wire [1:0] fma_op_regde = opcode_regde[3:2];  // negate-product/negate-addend -- see FMADDUnit.v's header comment
    // docs/adr/0019-f-extension.md (Phase C8). frm_live comes from CSR.v
    // (instantiated below); resolving RM_DYN here, once, before any FPU
    // unit sees it, is what lets every one of those modules stay ignorant
    // of `fcsr`/CSR.v entirely. Safe to apply this substitution
    // unconditionally to funct3_regde even though that same field doubles
    // as a sub-op selector for FSGNJ/FMINMAX/FCMP/FMV_X_W_FCLASS (funct3
    // values 000/001/010 there): those families never legitimately encode
    // funct3==111 (RM_DYN's own encoding) at all -- it's a reserved
    // encoding for them -- so the substitution only ever fires for
    // instructions where funct3 genuinely means "rounding mode".
    wire [2:0] fpu_rm = (funct3_regde == `RM_DYN) ? frm_live : funct3_regde;
    // rs1 is the one operand that's sometimes INTEGER despite an OP-FP
    // opcode (fcvt.s.w/fcvt.s.wu/fmv.w.x) -- rs2/rs3 are float whenever
    // they're real operands at all for this core's op set.
    wire rs1_is_float_regde = isOpFp_regde &&
        !(funct5_regde == `FUNCT5_FCVT_S_W || funct5_regde == `FUNCT5_FMV_W_X);
    wire fpu_uses_a_regde = rs1_is_float_regde || isFma_regde;
    // docs/adr/0019-f-extension.md (Phase C7): *_final (forwarded), not
    // *_regde (raw ID-latched) -- same "forwarding sits between the
    // pipeline register and the execute unit" shape readData1_final/
    // readData2_final already established for the integer file.
    wire [XLEN-1:0] fpu_operand_a = fpu_uses_a_regde ? freadData1_final : readData1_final;

    wire [31:0] falu_result;
    wire [4:0] falu_flags;
    // Generation 2 (Phase M): FALU.v/FMADDUnit.v/FDivider.v/FSqrt.v are
    // deliberately fixed FLEN=32 (RV64F still keeps single-precision float
    // registers 32 bits wide, unlike the integer file -- this core
    // implements F only, never D). freadData*_final/fpu_operand_a are
    // XLEN-wide pipeline-register carrier wires (their real content is
    // always in the low 32 bits, upper bits provably 0 -- FRegister.v never
    // writes anything else into them); explicit [31:0] here makes that
    // truncation visible instead of relying on implicit Verilog port-width
    // auto-pruning, which is correct but -Wall-noisy once anything actually
    // instantiates PIPELINED at XLEN=64.
    FALU m_FALU(
        .funct5(funct5_regde),
        .funct3(fpu_rm),
        .rs2_sel(readReg2_regde),   // inst[24:20] doubles as a real rs2 index or an op-selector, same bits either way
        .a(fpu_operand_a[31:0]),
        .b(freadData2_final[31:0]),
        .result(falu_result),
        .flags(falu_flags)
    );

    wire [31:0] fmadd_result;
    wire [4:0] fmadd_flags;
    FMADDUnit m_FMADDUnit(
        .op(fma_op_regde),
        .rm(fpu_rm),
        .a(freadData1_final[31:0]),
        .b(freadData2_final[31:0]),
        .c(freadData3_final[31:0]),
        .result(fmadd_result),
        .flags(fmadd_flags)
    );

    // Multi-cycle fdiv.s/fsqrt.s (docs/adr/0019 Phase C4), wired in with the
    // exact same busy/done interlock shape div_stall already established
    // above -- `start` tied to the level condition, not a pulse, relying on
    // each unit's own internal `start && !busy && !done` guard the same way
    // Divider.v's does.
    wire isFpDiv_regde = isOpFp_regde && (funct5_regde == `FUNCT5_FDIV);
    wire isFpSqrt_regde = isOpFp_regde && (funct5_regde == `FUNCT5_FSQRT);
    wire fdiv_busy, fdiv_done;
    wire [31:0] fdiv_result;
    wire [4:0] fdiv_flags;
    FDivider m_FDivider(
        .clk(clk),
        .rst(start),
        .start(isFpDiv_regde),
        .rm(fpu_rm),
        .a(fpu_operand_a[31:0]),
        .b(freadData2_final[31:0]),
        .busy(fdiv_busy),
        .done(fdiv_done),
        .result(fdiv_result),
        .flags(fdiv_flags)
    );
    wire fsqrt_busy, fsqrt_done;
    wire [31:0] fsqrt_result;
    wire [4:0] fsqrt_flags;
    FSqrt m_FSqrt(
        .clk(clk),
        .rst(start),
        .start(isFpSqrt_regde),
        .rm(fpu_rm),
        .a(fpu_operand_a[31:0]),
        .busy(fsqrt_busy),
        .done(fsqrt_done),
        .result(fsqrt_result),
        .flags(fsqrt_flags)
    );

    // True from the cycle an fdiv.s/fsqrt.s enters EX until (not including)
    // the cycle its result becomes valid -- mirrors div_stall exactly, one
    // more OR term alongside it wherever the pipeline freezes/holds for a
    // still-computing multi-cycle EX operation.
    wire fp_stall = (isFpDiv_regde && !fdiv_done) || (isFpSqrt_regde && !fsqrt_done);

    // What the F-extension's own execute step produced this cycle,
    // regardless of which of the four units actually computed it -- muxed
    // into ex_result below alongside the existing CSR/div/ALU sources.
    // flw/fsw deliberately do NOT go through this mux: their address is
    // computed by the existing ALU path exactly like lw/sw (Control.v sets
    // ALUSrc/ALUOp for them the same way), so ALUOut already holds the right
    // value for those two ops without any change here.
    wire [31:0] fp_result = isFma_regde   ? fmadd_result :
                            isFpDiv_regde ? fdiv_result   :
                            isFpSqrt_regde? fsqrt_result  :
                                            falu_result;    // every other OP-FP op

    // docs/adr/0019-f-extension.md (Phase C8): same shape as fp_result,
    // for the exception flags each unit computed alongside its result --
    // ORed into CSR.v's sticky fflags on the exact cycle this instruction
    // actually commits (see fp_flags_we below), not before.
    wire [4:0] fp_flags = isFma_regde    ? fmadd_flags :
                          isFpDiv_regde  ? fdiv_flags   :
                          isFpSqrt_regde ? fsqrt_flags  :
                                           falu_flags;
    // isOpFp_regde covers feq.s/flt.s/fle.s/fcvt.w.s/fcvt.wu.s too (they
    // still route through FALU.v and can still raise NV/NX despite writing
    // the *integer* file) -- fmv.x.w/fmv.w.x/fclass.s also pass through
    // here but FALU.v always reports 5'b0 flags for those (pure bit
    // manipulation, nothing to flag). Gated by !reg2_hold for exactly the
    // same reason CSR.v's own csr_write_en/trap_taken/mret_taken are
    // (see m_CSR's instantiation comment below): an instruction held in EX
    // across multiple cycles (e.g. mem_stall from an unrelated older load)
    // must only commit its flags once, not once per held cycle.
    wire fp_flags_we = (isOpFp_regde || isFma_regde) && !reg2_hold;

    // MEM-stage interlock (docs/adr/0013-mem-stage-retiming.md). DataMemoryBRAM's
    // read is registered: a load's `readData` isn't valid until the cycle
    // *after* its address/memRead are presented, one cycle later than the old
    // combinational DataMemory.v. `mem_stall` is true for exactly that one
    // extra cycle a fresh load spends in reg3 (EX/MEM) -- mirrors div_stall's
    // shape one stage later: freezes PC/reg1/reg2 (via pc_stall/reg2.hold) and
    // now also reg3 AND reg4 themselves (each a new `hold` input, same
    // empty-branch idiom docs/adr/0009 used for reg2 -- NOT a bubble for
    // reg4, see its port comment for why that first attempt was wrong)
    // instead of either latching not-yet-valid readData or evicting a value
    // still needed for forwarding.
    //
    // mem_stall_done_r tracks "has the load currently latched in reg3 already
    // had its one stall cycle." A first attempt derived this from
    // DataMemoryBRAM's own registered "read happened last cycle" signal
    // instead of tracking it here -- that failed on back-to-back loads
    // (verified by running mem_bytes.s, not just reasoned about): a load
    // held in reg3 for its stall cycle keeps memRead asserted for 2 cycles,
    // so by the time the *next* load freshly arrives, the memory's own
    // signal is still reporting the *previous* load's read as having just
    // completed -- exactly the busy/done "re-triggering on the done cycle"
    // ambiguity docs/adr/0009 hit with the divider, and for the same
    // underlying reason: a bare level signal can't distinguish "still the
    // same request" from "a new request that happens to look the same."
    // Tracking readiness against reg3's own occupancy here (reset to 0
    // whenever mem_stall was 0 last cycle, which is exactly when reg3 is
    // about to accept a new occupant) sidesteps that ambiguity entirely.
    //
    // docs/adr/0023-caches.md (Phase G5). Generalized from a fixed one-cycle
    // delay to an externally-driven `mem_access_ready` pulse -- a D$ miss
    // (G6) needs a variable number of cycles, not always exactly one.
    // mem_access_ready is tied constant 1 here (no cache logic drives it
    // yet, CACHE_MODE isn't even consumed by this wire) -- with a constant-1
    // ready signal, `mem_stall_done_r <= mem_access_ready` whenever
    // mem_stall is asserted is bit-for-bit equivalent to the original
    // `mem_stall_done_r <= mem_stall` every cycle (the two differ only in
    // the mem_stall==0 case, where both branches produce 0 either way) --
    // this step changes the MECHANISM, not the TIMING, and must stay
    // bit-identical under CACHE_NONE (docs/adr/0020 D3's own "prove the
    // plumbing is inert before anything uses it" discipline). G6 replaces
    // this tie-off with a real CACHE_MODE-selected mux to DCache.v's own
    // resp_ready; mem_stall's own trigger condition (memRead_regem alone,
    // never memWrite_regem) is deliberately UNCHANGED here too -- teaching
    // a plain store to stall is a real behavior change (write-allocate
    // misses, G6's own job), not something this pure-refactor step may do
    // even under CACHE_WRITEBACK_SETASSOC.
    //
    // docs/adr/0023-caches.md (Phase G6). mem_access_ready now genuinely
    // varies: DCache.v's own resp_ready for a load/store, or its flush_done
    // for a retiring fence -- whichever this reg3 occupant is actually
    // waiting on (dcache_resp_ready/dcache_flush_done/fence_pending_r are
    // forward-referenced to the MEM-stage bus-master block below, same
    // pattern this file already relies on for pc_stall/priv_mode_w).
    // mem_trigger generalizes what USED to be a bare `memRead_regem`:
    // still exactly that (alone) under CACHE_NONE -- writes never stall,
    // bit-identical to every existing test's assumption. Under
    // CACHE_WRITEBACK_SETASSOC: memRead_regem unchanged (a hit-read still
    // costs its one real registered cycle, same as today); memWrite_regem
    // ONLY when DCache doesn't already show combinational readiness -- a
    // hit-write's genuinely zero-stall commit (mirrors RamWishboneAdapter's
    // own "writes never stall" precedent) must not gain a spurious cycle
    // just because the trigger technically matched; fence_pending_r for a
    // retiring flush's own (possibly multi-cycle) duration.
    // docs/adr/0024-variable-latency-memory.md (Phase I2). CACHE_NONE's
    // branch used to be a hardcoded 1'b1 here -- harmless only because
    // RamWishboneAdapter's real timing happened to always be exactly 1
    // cycle, which the constant was silently calibrated to match (lsu_ack
    // itself, declared above, was reserved but deliberately unconsumed for
    // exactly this reason). Now genuinely tracks lsu_ack, so MEM_LATENCY_D
    // actually has an effect under CACHE_NONE too. At MEM_LATENCY_D==0,
    // lsu_ack pulses on the exact same cycle the old constant already
    // matched -- bit-exact by construction, not coincidence, this time.
    // mem_trigger's write clause mirrors CACHE_WRITEBACK_SETASSOC's own
    // existing write-miss shape (memWrite_regem && !dcache_resp_ready): a
    // write only ever stalls once MEM_LATENCY_D>0 makes !lsu_ack true on
    // its own first cycle; at the default 0, RamWishboneAdapter still acks
    // writes combinationally same-cycle, so this OR arm is always false --
    // "writes never stall under CACHE_NONE" stays true at the default.
    wire mem_access_ready = (CACHE_MODE == CACHE_NONE) ? lsu_ack :
        (fence_pending_r ? dcache_flush_done : dcache_resp_ready);
    wire mem_trigger = (CACHE_MODE == CACHE_NONE) ? (memRead_regem || (memWrite_regem && !lsu_ack)) :
        (memRead_regem || (memWrite_regem && !dcache_resp_ready) || fence_pending_r);
    reg mem_stall_done_r;
    wire mem_stall = mem_trigger && !mem_stall_done_r;
    always @(posedge clk) begin
        if (~start) mem_stall_done_r <= 1'b0;
        else if (!mem_stall) mem_stall_done_r <= 1'b0;
        else mem_stall_done_r <= mem_access_ready;
    end

    // docs/adr/0038-a-extension-phase-v.md. lr/sc/amo* need a genuine
    // read-THEN-write sequence -- not just mem_stall's own single extra
    // wait cycle -- so this is a real, separate 2-phase interlock, not an
    // extension of mem_stall's own single-access machinery (isAmo_regem is
    // never also memRead_regem/memWrite_regem -- Control.v deliberately
    // leaves those 0 for OPCODE_AMO -- so mem_trigger/mem_stall above never
    // fire for an AMO at all, by construction, zero interaction risk with
    // every existing load/store/fence path).
    //
    // CACHE_NONE only (matching this phase's own real target -- the kernel
    // boot attempt never runs under CACHE_WRITEBACK_SETASSOC): phase 0
    // issues a read (mirrors an ordinary load's own address/memRead), phase
    // 1 (entered once phase 0's lsu_ack fires and the read value is
    // captured) issues a write of the funct5-combined result. Both phases
    // reuse the exact same address (ALUOut_regem = rs1+0, Control.v's own
    // ALUSrc=1/ImmGen.v's imm=0 for OPCODE_AMO) and funct3 (funct3_regem,
    // already the AMO instruction's own real .W/.D width tag -- no new
    // wiring needed, wb_m_funct3 already reads it unconditionally).
    reg amo_write_phase_r;
    reg amo_write_done_r;
    reg [XLEN-1:0] amo_captured_read_r;
    wire amo_active = isAmo_regem;
    // LR.W/D is real spec read-only -- it must never issue a write phase at
    // all (a plain load with a trivial-on-single-hart reservation, see
    // riscv_defs.vh's own AMO_F5_LR comment), so it's the one funct5 that
    // finishes after just phase 0.
    wire amo_is_lr = (funct7_regem[6:2] == `AMO_F5_LR);
    wire amo_stall = amo_active && !amo_write_done_r;
    always @(posedge clk) begin
        if (~start || !amo_active) begin
            amo_write_phase_r <= 1'b0;
            amo_write_done_r  <= 1'b0;
        end else if (!amo_write_phase_r) begin
            if (lsu_ack) begin
                amo_captured_read_r <= readData;
                if (amo_is_lr) amo_write_done_r <= 1'b1;
                else amo_write_phase_r <= 1'b1;
            end
        end else if (lsu_ack) begin
            amo_write_done_r <= 1'b1;
        end
    end
    // docs/adr/0038: funct5 = funct7_regem[6:2] (the real spec field --
    // inst[26:25], funct7_regem's own low 2 bits, are the aq/rl ordering
    // bits this genuinely single-hart core has no real use for, see
    // riscv_defs.vh's own AMO_F5_* comment). SC.W/D and every unrecognized
    // funct5 fall through to the same "just store rs2" arm -- correct for
    // SC specifically (this core's own single-hart SC always succeeds, see
    // the ADR), and a safe/inert default for anything else (Control.v's
    // own illegalOpcode never gates on funct5, so a genuinely malformed
    // funct5 here still executes as SOME real memory write rather than X --
    // acceptable: real hardware behavior for a reserved encoding is
    // implementation-defined UNSPECIFIED anyway, not a spec violation).
    wire [4:0] amo_funct5 = funct7_regem[6:2];
    wire signed [XLEN-1:0] amo_old_s = amo_captured_read_r;
    wire signed [XLEN-1:0] amo_rs2_s = readData2_regem;
    wire [XLEN-1:0] amo_combined =
        (amo_funct5 == `AMO_F5_ADD)  ? (amo_captured_read_r + readData2_regem) :
        (amo_funct5 == `AMO_F5_XOR)  ? (amo_captured_read_r ^ readData2_regem) :
        (amo_funct5 == `AMO_F5_AND)  ? (amo_captured_read_r & readData2_regem) :
        (amo_funct5 == `AMO_F5_OR)   ? (amo_captured_read_r | readData2_regem) :
        (amo_funct5 == `AMO_F5_MIN)  ? ((amo_old_s < amo_rs2_s) ? amo_captured_read_r : readData2_regem) :
        (amo_funct5 == `AMO_F5_MAX)  ? ((amo_old_s > amo_rs2_s) ? amo_captured_read_r : readData2_regem) :
        (amo_funct5 == `AMO_F5_MINU) ? ((amo_captured_read_r < readData2_regem) ? amo_captured_read_r : readData2_regem) :
        (amo_funct5 == `AMO_F5_MAXU) ? ((amo_captured_read_r > readData2_regem) ? amo_captured_read_r : readData2_regem) :
        readData2_regem;  // AMOSWAP, LR (never reaches phase 1 in practice -- see below), SC, default

    // docs/adr/00NN-mmu-sv32.md (Phase F5): itlb_miss/dtlb_miss are defined
    // in the MMU translation block below (forward-referenced here).
    // docs/adr/0023-caches.md (Phase G3): icache_miss joins them, same
    // forward-reference pattern, always 0 under CACHE_NONE.
    // docs/adr/0024-variable-latency-memory.md (Phase I3): imem_wait joins
    // them, always 0 under CACHE_WRITEBACK_SETASSOC and at MEM_LATENCY_I=0.
    assign pc_stall = stall | div_stall | mem_stall | fp_stall | float_load_use_hazard | itlb_miss | dtlb_miss | icache_miss | imem_wait | amo_stall;

    // reg2's own hold condition, factored out for reuse below (CSR.v's write
    // gating needs to know exactly the same thing reg2 does: "is this
    // instruction's stay in EX not over yet". fp_stall joins div_stall/
    // mem_stall here the same way it joins them in pc_stall above --
    // float_load_use_hazard deliberately does NOT: that stall's cause (a
    // hazard against an *older* in-flight instruction) is resolved in ID,
    // not EX, so it has no business holding reg2's own occupant in place --
    // exactly the same reasoning Hazard.v's own load-use flush/stall
    // already follows for the integer file's lw case.
    // docs/adr/00NN-mmu-sv32.md (Phase F5): dtlb_miss joins the existing
    // multi-cycle-EX-interlock set -- the load/store itself is held in EX
    // (not bubbled) while the D-side walk resolves, exactly mirroring
    // div_stall/fp_stall/mem_stall's own shape. itlb_miss deliberately
    // does NOT join here -- it's a front-end-only interlock (nothing in
    // EX/MEM is its cause), same category as Hazard.v's own stall, see
    // reg2's flush input below instead.
    wire reg2_hold = div_stall | mem_stall | fp_stall | dtlb_miss | amo_stall;

    wire [XLEN-1:0] div_result_raw = (ALUCtl == `ALUCTL_DIV || ALUCtl == `ALUCTL_DIVU) ? div_quotient : div_remainder;
    // divw/divuw/remw/remuw: per spec, the 32-bit result is ALWAYS
    // sign-extended regardless of the operation's own signedness (the same
    // "word instructions always sign-extend their result" rule ALU.v's
    // wordOp arms already follow for addw/sllw/etc.) -- not conditioned on
    // isDivSigned.
    wire [XLEN-1:0] div_result = wordOp_regde ?
        {{(XLEN-32){div_result_raw[31]}}, div_result_raw[31:0]} : div_result_raw;

    // CSR / synchronous exceptions (docs/adr/0011-csr-and-exceptions.md).
    // M-mode only -- illegal instruction, ecall, ebreak, and the
    // csrrw/csrrs/csrrc(+i) instructions plus mret to act on them. (Real
    // asynchronous interrupts -- timer and UART RX -- are a separate
    // detection point below, docs/adr/0020-soc-integration.md Phase D9.)
    // Both exception sources resolve in EX, same stage as branch/jal/jalr:
    // illegalOpcode_regde came from Control.v at decode time (an
    // unrecognized opcode, or SYSTEM/funct3=0 with an unrecognized
    // funct12), while ALUCtl==ILLEGAL is only known now, after ALUCtrl has
    // decoded a *recognized* opcode's funct7/funct3 and found no valid op.
    // docs/adr/00NN-mmu-sv32.md (Phase F3). priv_mode_w is CSR.v's own
    // live priv_mode_val output (declared as a port since F1, unconnected
    // until now). Three new privilege-violation sources, each a real
    // illegal-instruction exception, not a separate cause of its own:
    // (1) any CSR access below that CSR address's own required privilege
    // (bits[9:8] of the CSR address, per spec -- 00=U/01=S/11=M, already
    // numerically ordered so a plain `<` compare works); (2) mret executed
    // anywhere but M; (3) sret executed from U (S and M may both execute
    // it -- M-mode using sret is unusual but not spec-illegal). Without
    // these, U-mode/S-mode would not actually be a protection boundary --
    // any program could read/write mstatus/satp/mideleg/etc, or return to
    // an arbitrary privilege via mret, regardless of its own current level.
    wire csr_priv_violation = isCsr_regde & (priv_mode_w < imm_regde[9:8]);
    wire mret_priv_violation = isMret_regde & (priv_mode_w != `PRIV_M);
    wire sret_priv_violation = isSret_regde & (priv_mode_w == `PRIV_U);
    // The real mret/sret behavior (redirect via mepc/sepc, restore
    // priv_mode/mstatus) only ever applies when NOT a privilege violation
    // -- a violating mret/sret instead becomes a plain illegal-instruction
    // exception (via exception_taken below), redirecting through the
    // ordinary trap path instead of actually returning anywhere.
    wire mret_real = isMret_regde & !mret_priv_violation;
    wire sret_real = isSret_regde & !sret_priv_violation;

    // docs/adr/00NN-mmu-sv32.md (Phase F5). ifetch_fault_regde/
    // dtlb_page_fault/sfence_priv_violation are all defined in the MMU
    // translation block near the MEM section below -- forward-referenced
    // here, the same pattern this file already relies on for
    // priv_mode_w/stvec_val/etc (all defined at m_CSR's own instantiation,
    // referenced earlier throughout this section).
    wire exception_taken = illegalOpcode_regde | (ALUCtl == `ALUCTL_ILLEGAL) | isEcall_regde | isEbreak_regde |
                            csr_priv_violation | mret_priv_violation | sret_priv_violation |
                            sfence_priv_violation | ifetch_fault_regde | dtlb_page_fault;
    // docs/adr/00NN-mmu-sv32.md (Phase F3): ecall's cause is now
    // privilege-dependent (it was unconditionally MCAUSE_ECALL_FROM_M
    // through Phase E, since M was the only privilege that existed) --
    // every existing test still boots and stays in M throughout, so this
    // is bit-exact for all of them. The three new violation sources all
    // map to the same illegal-instruction cause an ordinary illegal
    // opcode does.
    // docs/adr/00NN-mmu-sv32.md (Phase F5): ifetch_fault_regde/
    // dtlb_page_fault get their own real causes, checked first -- an
    // ifetch-fault "instruction" carries garbage bits that could
    // themselves coincidentally decode as illegal/ecall/etc, and the page
    // fault cause must win regardless of what the garbage happened to
    // look like. dtlb_page_fault implies a real load/store opcode, never
    // simultaneously illegal/ecall/csr/mret/sret/sfence, so its ordering
    // relative to those is not itself load-bearing, but it's placed early
    // for the same clarity.
    wire [XLEN-1:0] trap_cause = ifetch_fault_regde ? `MCAUSE_INSTRUCTION_PAGE_FAULT :
                              dtlb_page_fault ? (memWrite_regde ? `MCAUSE_STORE_PAGE_FAULT : `MCAUSE_LOAD_PAGE_FAULT) :
                              (illegalOpcode_regde | (ALUCtl == `ALUCTL_ILLEGAL) |
                                   csr_priv_violation | mret_priv_violation | sret_priv_violation | sfence_priv_violation)
                                      ? `MCAUSE_ILLEGAL_INSTRUCTION :
                              isEbreak_regde ? `MCAUSE_BREAKPOINT :
                              isEcall_regde  ? ((priv_mode_w == `PRIV_M) ? `MCAUSE_ECALL_FROM_M :
                                                 (priv_mode_w == `PRIV_S) ? `MCAUSE_ECALL_FROM_S :
                                                                             `MCAUSE_ECALL_FROM_U) :
                              {XLEN{1'b0}};

    // docs/adr/0021-branch-prediction.md (Phase E4). Ground truth for
    // whatever branch/jal/jalr instruction is now in EX -- desired_taken/
    // desired_target are the exact same expressions this file always used
    // ((branch_regde&zero)|jump_regde, and imm_sum) before this phase,
    // simply given names so they can be compared against a prediction
    // instead of consumed directly. fallthrough reuses pc_plus4_regde
    // (already computed above for jal's own link value -- pc_o_regde+4 is
    // pc_o_regde+4 regardless of why it's needed) rather than a second,
    // redundant adder.
    wire desired_taken = (branch_regde & zero) | jump_regde;
    wire [XLEN-1:0] desired_target = imm_sum;
    wire [XLEN-1:0] fallthrough_pc_regde = pc_plus4_regde;

    // Did fetch's earlier guess (predict_taken_regde/predict_target_regde,
    // latched alongside this instruction all the way from IF, two cycles
    // ago) disagree with what actually happened? Three ways to disagree:
    // predicted taken but really wasn't (or this was never a branch/jump
    // at all -- predict_taken_regde=1 for an ordinary instruction, e.g.
    // from an aliased Bht.v/Btb.v hit, is exactly as wrong as mispredicting
    // a real branch, and this XOR catches both identically); predicted
    // not-taken but it really was; predicted taken *and* it really was, but
    // to a different target than a stale Btb.v entry guessed. Under
    // PREDICTOR_STATIC, predict_taken_regde is always 0 (riscvpipeline.v
    // never feeds reg1 anything else -- see predict_taken_fetch/
    // gen_no_predictor above), so `mispredict` collapses to exactly
    // `desired_taken` -- today's exact "squash on every taken branch/jump"
    // behavior, bit-exact. `branch_or_jump_redirect`/`branch_or_jump_target`
    // are the two values every existing consumer below actually needs;
    // `mispredict` itself is unused (harmlessly, just dead logic) under
    // PREDICTOR_STATIC.
    wire mispredict = (predict_taken_regde != desired_taken) |
                       (desired_taken & (predict_target_regde != desired_target));
    // Generation 4, Phase A (docs/adr/0040): was hardcoded to
    // "== PREDICTOR_DYNAMIC_BHT_BTB" specifically -- silently correct for
    // BRANCH_PREDICTOR in {0,1} (nothing else existed), but would have
    // silently fallen through to PREDICTOR_STATIC's own "squash on every
    // taken branch" behavior for GShare/Tournament (architecturally still
    // safe, since squashing a correctly-predicted branch too is always
    // safe -- just silently defeating the entire point of adding a new
    // predictor scheme, with mispredict_pulse/branch_retired_pulse below
    // still reporting misleading "always mispredicted" stats). Generalized
    // to "any dynamic scheme" -- bit-exact for BRANCH_PREDICTOR in {0,1}
    // (0 != 0 is false either way; 1 != 0 is true either way).
    wire branch_or_jump_redirect = (BRANCH_PREDICTOR != PREDICTOR_STATIC) ? mispredict : desired_taken;
    wire [XLEN-1:0] branch_or_jump_target =
        (BRANCH_PREDICTOR != PREDICTOR_STATIC && !desired_taken) ? fallthrough_pc_regde : desired_target;

    // Bht.v/Btb.v training, from this same ground truth -- gated !reg2_hold
    // for exactly the same reason csr_write_en/trap_taken/mret_taken/
    // fp_flags_we already are (docs/adr/0011/0019 D9's own comment below):
    // an instruction held in EX across multiple cycles (e.g. mem_stall from
    // an unrelated older load still in MEM) must train the tables exactly
    // once, on its real resolution, not once per held cycle -- desired_taken
    // would otherwise be (harmlessly) recomputed identically each held
    // cycle, but a write-side effect like this genuinely needs the gate, the
    // same distinction CSR.v's own write logic already draws. Btb.v is
    // trained only when desired_taken (no target to record for a not-taken
    // resolution); Bht.v trains on every resolution, taken or not, so the
    // direction counter actually learns both directions.
    assign bp_update_valid = (branch_regde | jump_regde) & !reg2_hold;
    assign bp_update_pc = pc_o_regde;
    assign bp_update_taken = desired_taken;
    assign bp_update_target = desired_target;

    // docs/adr/0020-soc-integration.md (Phase D9) built machine-external/
    // machine-timer interrupt detection, independent of whatever
    // instruction (if any) currently sits in EX, unlike the synchronous
    // exceptions above. docs/adr/0034 (Phase R) adds a third source,
    // machine-software (mip.MSIP, driven by Timer.v's own new CLINT `msip`
    // register). mip's three real bits are exactly Uart.v's irq / Timer.v's
    // msip_pending/pending (uart_irq/msip_pending_w/timer_pending_w, wired
    // below at the bus instantiation); mie's enable bits and mstatus.MIE
    // are CSR.v's own live outputs. Spec-mandated priority when more than
    // one is pending and enabled: machine-external > machine-software >
    // machine-timer.
    wire mei_pending = mie_meie & uart_irq;
    wire msi_pending = mie_msie & msip_pending_w;
    wire mti_pending = mie_mtie & timer_pending_w;

    // docs/adr/0035-minimal-sbi-firmware-phase-s.md (Phase S). A real gap
    // this phase's own SBI-firmware design found: mip_sw's SSIP/STIP bits
    // (real, software-writable storage since Phase F -- e.g. an M-mode
    // trap handler synthesizing a "virtual" supervisor timer interrupt,
    // since mtimecmp is M-mode-only CLINT state S-mode cannot touch
    // directly) had NO path into interrupt_taken at all -- setting them
    // was pure bookkeeping, no interrupt would ever actually retrap.
    // Deliberately NOT gated by mstatus_mie (M's own global enable) --
    // real spec precedence: a supervisor-targeted interrupt is gated by
    // sstatus.SIE (S's own enable) and only valid while executing AT S
    // (mstatus_mie has no bearing on whether an S-level interrupt is
    // recognized at all, only on M-level ones).
    wire ssi_pending = mstatus_sie & mie_ssie & mip_ssip & (priv_mode_w == `PRIV_S);
    wire sti_pending = mstatus_sie & mie_stie & mip_stip & (priv_mode_w == `PRIV_S);

    // Does EX's current occupant already want to redirect PC for its own
    // reasons this cycle (a taken branch, jal/jalr, a synchronous
    // exception, or mret)? If so, defer the interrupt one cycle rather
    // than contest the same redirect_target mux this same cycle -- mip is
    // level-pending (it doesn't clear itself), so nothing is lost, only
    // recognized one cycle later once whatever's already redirecting
    // finishes. Deliberately the *pre*-interrupt value of what becomes
    // branch_taken/unconditional_redirect below, built from their raw
    // constituent signals rather than those wires themselves (referencing
    // them here would be a combinational self-reference). docs/adr/0021
    // (Phase E4): branch_or_jump_redirect replaces the old raw
    // (branch_regde&zero)|jump_regde term -- itself built from
    // predict_taken_regde/desired_taken, not interrupt_taken, so no
    // circularity is introduced.
    // docs/adr/00NN-mmu-sv32.md (Phase F3): mret_real replaces the raw
    // isMret_regde -- a privilege-violating mret doesn't itself redirect
    // via mepc (it's folded into exception_taken instead, above), so it
    // must not double-count here either. sret_real (a new redirect source
    // this phase adds) joins the same list.
    wire other_redirect_taken = branch_or_jump_redirect | exception_taken | mret_real | sret_real;

    // Gated on !pc_stall, not just !reg2_hold (docs/adr/0009/0013's
    // multi-cycle div/mem/fp interlock) -- reg1.v's own squash-on-jump
    // takes priority over its *own* stall input (see reg1.v: the
    // branch_regde&zero|jump check is tested before stall), so asserting
    // an interrupt's `jump` into reg1 during an ordinary Hazard.v load-use
    // stall (`stall`, folded into pc_stall but NOT into reg2_hold) would
    // incorrectly discard the very instruction that stall exists to hold
    // in place -- not just a multi-cycle EX operation. Found by tracing
    // reg1.v's own priority ordering before implementing this (the same
    // "found by careful tracing, not assumed" standard docs/adr/0009/0013
    // set), not by hitting the bug at runtime.
    // ssi_pending/sti_pending join the OR list, deliberately outside the
    // mstatus_mie gate (see their own declarations above for why) --
    // interrupt_taken itself stays a single, unified redirect-request wire
    // regardless of which of the now-five sources actually fired.
    wire interrupt_taken = ((mstatus_mie & (mei_pending | msi_pending | mti_pending)) | ssi_pending | sti_pending)
                            & !pc_stall & !other_redirect_taken;
    // Priority when more than one source is simultaneously pending+enabled:
    // real spec ordering, machine before supervisor, external > software >
    // timer within each level (MEI > MSI > MTI > SSI > STI). sti_pending
    // is the final `else` since interrupt_taken already guarantees at
    // least one of the five is true whenever this mux is actually live.
    wire [XLEN-1:0] interrupt_cause =
        mei_pending ? `MCAUSE_INT_MACHINE_EXTERNAL :
        msi_pending ? `MCAUSE_INT_MACHINE_SOFTWARE :
        mti_pending ? `MCAUSE_INT_MACHINE_TIMER :
        ssi_pending ? `MCAUSE_INT_SUPERVISOR_SOFTWARE :
                      `MCAUSE_INT_SUPERVISOR_TIMER;

    // Tracks "is reg1's current output (pc_o_regfd/inst_regfd) a real
    // fetched instruction, or a squash-produced bubble" -- mirrors reg1.v's
    // own priority ordering exactly (squash > stall-hold > fresh latch) so
    // it always agrees with what reg1 itself actually did last edge.
    // redirect_squash_extend_r joins branch_taken here for the same reason
    // reg1's own `jump` port does (docs/adr/0018): under
    // PROFILE_6STAGE_SPLIT_FETCH the squash window is one cycle longer.
    reg id_bubble_r;
    always @(posedge clk) begin
        if (~start)
            id_bubble_r <= 1'b1;  // reg1 resets to a bubble too
        else if (branch_taken | redirect_squash_extend_r)
            id_bubble_r <= 1'b1;
        else if (pc_stall)
            id_bubble_r <= id_bubble_r;  // holds, same as reg1 itself
        else
            id_bubble_r <= 1'b0;
    end

    // mepc for an interrupt is the PC of the instruction that *would have
    // executed next* -- normally reg1's current output (pc_o_regfd, the
    // ID-stage instruction about to enter EX), which this same redirect
    // squashes via reg2's own branch_taken port exactly like any other
    // redirect -- deliberately NOT pc_o_regde (EX's *current* occupant,
    // used by the exception path above): unlike a synchronous exception,
    // this instruction did nothing wrong and is left to retire normally
    // this same cycle; only what comes *after* it is deferred. Exception:
    // if reg1's current output is itself a squash-produced bubble
    // (id_bubble_r, above) rather than a real fetched instruction -- e.g.
    // the cycle right after any other taken redirect -- pc_o_regfd is a
    // meaningless 0 (reg1.v's own squash value), and the real "next
    // instruction" is instead whatever pc_o (IF's own live PC) currently
    // is, since that's exactly the address the redirect that produced the
    // bubble already retargeted fetch to. Found by tracing the bubble
    // timing through reg1.v before implementing this, the same way the
    // !pc_stall gating above was -- not something any directed test
    // happened to hit first.
    wire [XLEN-1:0] interrupt_mepc = id_bubble_r ? pc_o : pc_o_regfd;

    // csrrwi/csrrsi/csrrci (funct3[2]=1) source their write data from a
    // zero-extended 5-bit immediate sitting in rs1's *field position*
    // (inst[19:15]) rather than a real register read; csrrw/csrrs/csrrc
    // (funct3[2]=0) use the actual (forwarded) rs1 value.
    wire [XLEN-1:0] csr_wdata = funct3_regde[2] ? {{(XLEN-5){1'b0}}, inst_regde[19:15]} : readData1_final;
    wire [XLEN-1:0] csr_old_val;
    wire [XLEN-1:0] mtvec_val, mepc_val;
    wire [2:0] frm_live;  // docs/adr/0019 Phase C8 -- CSR.v's live frm, for RM_DYN resolution above

    // csr_write_en/trap_taken/mret_taken must NOT simply be isCsr_regde/
    // exception_taken/isMret_regde directly: those are combinational, live
    // off reg2's *current* output, which stays constant across every cycle
    // reg2 is held (docs/adr/0013's mem_stall, e.g. an unrelated load
    // immediately preceding this instruction) -- unlike jal/branch (whose
    // redirect is naturally protected by reg2's hold-priority over its own
    // branch_taken squash, plus reg3 only ever capturing pre-edge values),
    // CSR.v is an external stateful module with no notion of "already
    // applied this instruction's effect." Left ungated, a held CSR/trap/mret
    // instruction would write on *every* held cycle, not just its last one:
    // csr_rdata (the value handed to rd) would reflect an already-applied
    // write instead of the true old value, and mstatus's MIE/MPIE swap
    // (self-referencing: mstatus[7]<=mstatus[3]) would corrupt itself on the
    // second application. Found by constrained-random cross-checking after
    // extending random_gen.py to generate CSR instructions -- not by any
    // directed test, none of which happen to put a CSR/trap/mret instruction
    // immediately after a load. Gating by !reg2_hold suppresses the write on
    // every held cycle and lets it fire exactly once, on the same cycle
    // reg3 finally accepts this instruction's other outputs.
    CSR #(.XLEN(XLEN)) m_CSR(
    .clk(clk),
    .rst(start),
    // docs/adr/00NN-mmu-sv32.md (Phase F3): a privilege-violating CSR
    // access must not actually commit its write (the read side needs no
    // extra gating -- exception_taken already squashes this instruction
    // before its rd write could ever retire, see riscvpipeline.v's own
    // csr_priv_violation comment).
    .csr_write_en(isCsr_regde && !reg2_hold && !csr_priv_violation),
    .csr_addr(imm_regde[11:0]),   // ImmGen.v zero-extends inst[31:20] into imm for OPCODE_SYSTEM
    .csr_op(funct3_regde[1:0]),
    .csr_wdata(csr_wdata),
    .csr_rdata(csr_old_val),
    // docs/adr/0020-soc-integration.md (Phase D9). exception_taken and
    // interrupt_taken are mutually exclusive by construction
    // (other_redirect_taken, folded into interrupt_taken's own gating,
    // already excludes exception_taken) -- the OR below is safe, exactly
    // one of the two (or neither) is ever true on a given cycle.
    // trap_pc/trap_cause mux the same way: pc_o_regde/trap_cause for a
    // synchronous exception, interrupt_mepc/interrupt_cause for an
    // interrupt (see their own definitions above for why these two
    // deliberately differ from the exception path's values).
    .trap_taken((exception_taken && !reg2_hold) || interrupt_taken),
    .trap_pc(interrupt_taken ? interrupt_mepc : pc_o_regde),
    .trap_cause(interrupt_taken ? interrupt_cause : trap_cause),
    .trap_is_interrupt(interrupt_taken),
    // docs/adr/00NN-mmu-sv32.md (Phase F5). Replaces F3's tie-off, exactly
    // as anticipated: the faulting virtual address for mtval/stval --
    // pc_o_regde for an ifetch fault (the VA that failed translation,
    // already correctly carried this far via reg1/reg2's normal PC
    // threading), ALUOut for a D-side fault (the VA the load/store was
    // about to use, computed combinationally at EX -- see the MMU
    // translation block below), 0 for every other cause exactly as before.
    .trap_value(ifetch_fault_regde ? pc_o_regde : dtlb_page_fault ? dtlb_vaddr : {XLEN{1'b0}}),
    .mret_taken(mret_real && !reg2_hold),
    .sret_taken(sret_real && !reg2_hold),
    .fp_flags_we(fp_flags_we),
    .fp_flags_in(fp_flags),
    .frm_val(frm_live),
    // docs/adr/0020-soc-integration.md (Phase D8, D9) wired timer_pending/
    // ext_pending to the real Timer.v/Uart.v (PLIC-lite) live signals
    // declared below; docs/adr/0034 (Phase R) adds msip_pending
    // (Timer.v's new CLINT `msip` register). mstatus_mie/mie_msie/
    // mie_mtie/mie_meie feed interrupt_taken's own condition above.
    .msip_pending(msip_pending_w),
    .timer_pending(timer_pending_w),
    .ext_pending(uart_irq),
    .mstatus_mie(mstatus_mie),
    .mie_msie(mie_msie),
    .mie_mtie(mie_mtie),
    .mie_meie(mie_meie),
    // docs/adr/0035-minimal-sbi-firmware-phase-s.md (Phase S). Real
    // consumers for ssi_pending/sti_pending's own gating above.
    .mstatus_sie(mstatus_sie),
    .mie_ssie(mie_ssie),
    .mie_stie(mie_stie),
    .mip_ssip(mip_ssip),
    .mip_stip(mip_stip),
    .mtvec_val(mtvec_val),
    .mepc_val(mepc_val),
    // docs/adr/00NN-mmu-sv32.md (Phase F3).
    .priv_mode_val(priv_mode_w),
    .stvec_val(stvec_val),
    .sepc_val(sepc_val),
    .trap_target_is_s(trap_target_is_s),
    // docs/adr/00NN-mmu-sv32.md (Phase F5).
    .satp_mode_val(satp_mode_w),
    .satp_ppn_val(satp_ppn_w),
    // docs/adr/0025-hpc-performance-csrs.md (Phase J3). instret_pulse is
    // exactly-once-per-real-retiring-instruction: `valid_regem` (survived
    // every squash from reg1 through reg3 -- see reg2.v/reg3.v's own
    // `valid` threading) gated on `!mem_stall`, the same "gate on the
    // producer's own hold signal at the point of transition, not the
    // consumer's already-latched level" shape as the existing
    // `bp_update_valid` below. Using `mem_stall`-held reg4 output instead
    // would double-count every instruction riding out a multi-cycle
    // mem_stall (the docs/adr/0009/0013/0014 "a held level can't tell a
    // repeat from a new one" bug class) -- see docs/adr/0025's Design
    // section for the full hand-trace.
    .instret_pulse(valid_regem && !mem_stall),
    // docs/adr/0025-hpc-performance-csrs.md (Phase J4). `bp_update_valid`
    // (riscvpipeline.v:1504) is already exactly-once-per-real-branch/jump
    // reaching EX, gated on `!reg2_hold` -- reused verbatim, no new
    // gating needed. `mispredict` gets the identical `!reg2_hold` gate,
    // applied consistently for the same "count exactly once, not once per
    // held cycle" reason.
    .branch_retired_pulse(bp_update_valid),
    .mispredict_pulse(mispredict & !reg2_hold),
    // Remaining event pulses tied to 0 until J5-J6 wire each one live,
    // same "declare state before consumers" staging every prior phase's
    // own step 1/2 has used (F1, G1, I1).
    // docs/adr/0025-hpc-performance-csrs.md (Phase J5).
    .icache_hit_pulse(icache_hit_pulse_w),
    .icache_miss_pulse(icache_miss_pulse_w),
    .dcache_hit_pulse(dcache_hit_pulse_w),
    .dcache_miss_pulse(dcache_miss_pulse_w),
    // docs/adr/0025-hpc-performance-csrs.md (Phase J6). `pc_stall` is
    // already the aggregate "a cycle lost to any stall source" signal --
    // counted every cycle it's 1, the one event that measures duration
    // rather than discrete occurrences (deliberate, matches how "cycles
    // lost to stalling" is normally reported). `interrupt_taken` is
    // already `!pc_stall`-gated (riscvpipeline.v:1545), no extra gating
    // needed. `exception_taken` reuses the same `!reg2_hold` pattern
    // CSR.v's own `trap_taken` already relies on for exactly-once firing.
    .stall_cycle_pulse(pc_stall),
    .interrupt_pulse(interrupt_taken),
    .exception_pulse(exception_taken & !reg2_hold),
    // docs/adr/0026-performance-profiler.md (Phase K1). The 9 raw per-cause
    // wires whose OR already forms `pc_stall` above (riscvpipeline.v:1365),
    // exposed individually so the profiler can select one onto a counter.
    // No new detection logic -- these wires already exist for `pc_stall`'s
    // own sake.
    .stall_hazard_pulse(stall),
    .stall_div_pulse(div_stall),
    .stall_mem_pulse(mem_stall),
    .stall_fp_pulse(fp_stall),
    .stall_float_lu_pulse(float_load_use_hazard),
    .stall_itlb_pulse(itlb_miss),
    .stall_dtlb_pulse(dtlb_miss),
    .stall_icache_pulse(icache_miss),
    .stall_imem_wait_pulse(imem_wait)
    );
    wire mstatus_mie, mie_msie, mie_mtie, mie_meie;
    wire mstatus_sie, mie_ssie, mie_stie, mip_ssip, mip_stip;
    wire [1:0] priv_mode_w;
    wire [XLEN-1:0] stvec_val, sepc_val;
    wire trap_target_is_s;
    wire satp_mode_w;
    // docs/adr/00NN-sv39-mmu-phase-p.md (Phase P3): widened 22->44 bits to
    // carry Sv39's real PPN width (CSR.v's own satp_ppn_val widening).
    wire [43:0] satp_ppn_w;

    // What EX "produces" this cycle: an F-extension result (docs/adr/0019)
    // on any OP-FP/FMA op -- checked first since isOpFp_regde/isFma_regde
    // are mutually exclusive with isCsr_regde/isDivRem by construction (an
    // instruction is never both) -- the CSR's old value on a real csrrX op,
    // the divider's result on div/rem (valid only when div_done, but only
    // consumed downstream on that exact cycle -- see reg3_bubble below),
    // the ALU's result otherwise (this last case is also what flw/fsw use,
    // since their address is computed by the ordinary ALU path, not routed
    // through fp_result -- see fp_result's own comment above). No
    // forwarding correction needed for CSR reads either (same reasoning as
    // lui/auipc, docs/adr/0009): ex_result is already correct by the time
    // reg3 latches it.
    // docs/adr/00NN-mmu-sv32.md (Phase F5): a load/store's address becomes
    // the translated physical address (mem_paddr, defined in the MMU
    // translation block below) instead of the raw ALU output -- bit-exact
    // at translate_enable=0 (mem_paddr reduces to exactly ALUOut there),
    // matching this file's own existing behavior for every other case.
    wire [XLEN-1:0] ex_result = (isOpFp_regde || isFma_regde) ? fp_result :
                                 isCsr_regde ? csr_old_val : (isDivRem ? div_result :
                                 ((memRead_regde | memWrite_regde) ? mem_paddr : ALUOut));

    // docs/adr/0020-soc-integration.md (Phase D9). interrupt_taken joins
    // the same squash machinery jal/jalr/exception/mret already use --
    // reg1.jump/reg2.branch_taken don't need to know or care *why*
    // unconditional_redirect fired, only that it did (see reg1.v/reg2.v).
    // mtvec is a single, non-vectored trap target either way (this core
    // has no vectored-interrupt mode), so interrupt_taken shares
    // exception_taken's redirect_target arm. docs/adr/0021 (Phase E4):
    // branch_or_jump_redirect/branch_or_jump_target replace the old raw
    // jump_regde / imm_sum terms -- under PREDICTOR_STATIC these reduce to
    // exactly (branch_regde&zero)|jump_regde / imm_sum, bit-exact with
    // this file's behavior before this phase; under
    // PREDICTOR_DYNAMIC_BHT_BTB, a redirect only fires on an actual
    // misprediction, to whichever of the real target or the real
    // fall-through address the misprediction needs.
    // docs/adr/00NN-mmu-sv32.md (Phase F3): mret_real/sret_real replace
    // the raw isMret_regde (a privilege-violating mret/sret redirects via
    // exception_taken's own mtvec/stvec arm instead, never mepc/sepc --
    // see mret_real/sret_real's own definitions above). redirect_target's
    // trap arm now also picks between M's and S's vector/return-address
    // pair using CSR.v's own trap_target_is_s decision (mideleg/medeleg-
    // aware, computed there since it already owns that state) --
    // interrupt_taken shares this same delegation-aware selection, unlike
    // before this phase when it always meant mtvec unconditionally (this
    // core has no vectored-interrupt mode either way, M or S).
    assign unconditional_redirect = branch_or_jump_redirect | exception_taken | mret_real | sret_real | interrupt_taken;
    assign redirect_target = (exception_taken | interrupt_taken) ? (trap_target_is_s ? stvec_val : mtvec_val) :
                              mret_real                           ? mepc_val :
                              sret_real                           ? sepc_val :
                                                                     branch_or_jump_target;

    // Compiled in only with -DCOVERAGE (see sim/tools/coverage_report.py,
    // docs/ROADMAP.md V-5). Not a real statement/branch coverage tool (none
    // was available in this environment) -- functional coverage: how many
    // times each ALUCtl operation and each hazard/stall/branch-outcome class
    // was actually exercised, dumped to a fixed file per run and aggregated
    // across the whole suite by the Python driver. Zero synthesis/simulation
    // impact when the macro isn't defined.
    `ifdef COVERAGE
    integer cov_alu_ctl [0:31];
    integer cov_branch_taken [0:7];
    integer cov_branch_not_taken [0:7];
    integer cov_stall_cycles;
    integer cov_flush_cycles;
    integer cov_div_cycles;
    integer cov_jump_cycles;
    integer cov_i;
    integer cov_fd;
    initial begin
        for (cov_i = 0; cov_i < 32; cov_i = cov_i + 1) cov_alu_ctl[cov_i] = 0;
        for (cov_i = 0; cov_i < 8; cov_i = cov_i + 1) begin
            cov_branch_taken[cov_i] = 0;
            cov_branch_not_taken[cov_i] = 0;
        end
        cov_stall_cycles = 0;
        cov_flush_cycles = 0;
        cov_div_cycles = 0;
        cov_jump_cycles = 0;
    end
    always @(posedge clk) begin
        if (start) begin
            cov_alu_ctl[ALUCtl] = cov_alu_ctl[ALUCtl] + 1;
            if (stall) cov_stall_cycles = cov_stall_cycles + 1;
            if (flush) cov_flush_cycles = cov_flush_cycles + 1;
            if (div_stall) cov_div_cycles = cov_div_cycles + 1;
            if (jump_regde) cov_jump_cycles = cov_jump_cycles + 1;
            if (ALUOp_regde == `ALUOP_BRANCH) begin
                if (branch_zero) cov_branch_taken[funct3_regde] = cov_branch_taken[funct3_regde] + 1;
                else cov_branch_not_taken[funct3_regde] = cov_branch_not_taken[funct3_regde] + 1;
            end
        end
    end
    // Verilog-2005 (this project's language mode, see docs/ROADMAP.md CQ-5)
    // has no `final` block -- that's SystemVerilog. Exposed as a task
    // instead; each testbench calls `dut.dump_coverage;` immediately before
    // its own $finish (sim/run_tests.sh passes -DCOVERAGE and every tb_*.v
    // was updated to include the call, guarded the same way).
    task dump_coverage;
        begin
            cov_fd = $fopen("coverage.txt", "w");
            for (cov_i = 0; cov_i < 32; cov_i = cov_i + 1)
                $fdisplay(cov_fd, "alu_ctl %0d %0d", cov_i, cov_alu_ctl[cov_i]);
            for (cov_i = 0; cov_i < 8; cov_i = cov_i + 1) begin
                $fdisplay(cov_fd, "branch_taken %0d %0d", cov_i, cov_branch_taken[cov_i]);
                $fdisplay(cov_fd, "branch_not_taken %0d %0d", cov_i, cov_branch_not_taken[cov_i]);
            end
            $fdisplay(cov_fd, "stall_cycles %0d", cov_stall_cycles);
            $fdisplay(cov_fd, "flush_cycles %0d", cov_flush_cycles);
            $fdisplay(cov_fd, "div_cycles %0d", cov_div_cycles);
            $fdisplay(cov_fd, "jump_cycles %0d", cov_jump_cycles);
            $fclose(cov_fd);
        end
    endtask
    `endif

//
wire [REG_ADDR_WIDTH-1:0] write_to_Reg_regde;
wire valid_regem;  // docs/adr/0025-hpc-performance-csrs.md (Phase J3)
wire memtoReg_regem;
wire regWrite_regem;
wire fRegWrite_regem;
wire memRead_regem;
wire memWrite_regem;
wire [XLEN-1:0] ALUOut_regem;
wire [XLEN-1:0] readData2_regem;
wire [REG_ADDR_WIDTH-1:0] write_to_Reg_regem;
wire jump_regem;
wire [XLEN-1:0] pc_plus4_regem;
wire [2:0] funct3_regem;
wire isAmo_regem;         // docs/adr/0038-a-extension-phase-v.md
wire [6:0] funct7_regem;  // docs/adr/0038-a-extension-phase-v.md
//
    // While a div/rem is still computing (div_stall), reg2/EX keeps
    // presenting the *same* div/rem instruction cycle after cycle (that's
    // the whole point of `hold`) -- without this mux, reg3 would latch that
    // instruction's control signals (regWrite=1 for any R-type op) every
    // one of those cycles, i.e. ~32 spurious register-file writes of a
    // not-yet-valid result before the real one. Bubbling the control
    // signals (not the data signals -- harmless once their gating control
    // bit is 0) makes this show up correctly everywhere downstream expects
    // "one instruction, one completion": the register file, forwarding,
    // and the pipeline viewer's trace. See docs/adr/0009-multicycle-divider.md.
    // fp_stall joins div_stall here for the exact same reason: while an
    // fdiv.s/fsqrt.s is still computing, reg2/EX keeps presenting that same
    // instruction cycle after cycle, and without bubbling, reg3 would latch
    // its (fRegWrite=1) control signals on every one of those cycles too.
    // docs/adr/00NN-mmu-sv32.md (Phase F5): dtlb_miss joins div_stall/
    // fp_stall (same reasoning -- while a D-side walk is in progress, reg3
    // must not see any version of the not-yet-translated access).
    // exception_taken also joins here now, fixing a real gap found by this
    // same hand-trace: csr_priv_violation (Phase F3) is a genuine csrrX
    // instruction with regWrite=1, and without this, a privilege-violating
    // CSR read would still let reg3 latch regWrite_regde=1 and the CSR's
    // real old value one cycle before the trap redirect became visible
    // anywhere else -- a real leak, not just this phase's own new fault
    // sources (an ifetch-fault "instruction" carries garbage bits that
    // could themselves coincidentally decode as an ordinary regWrite=1 op,
    // which is what actually surfaced this while designing that case). Safe
    // to add unconditionally: every pre-existing exception_taken source
    // (illegalOpcode/ALUCTL_ILLEGAL/ecall/ebreak/mret/sret violations)
    // already has regWrite=0 from Control.v, so this is a no-op for all of
    // them -- confirmed by inspection, not just assumed. No !reg2_hold
    // qualifier needed (unlike csr_write_en/trap_taken's "fire exactly
    // once" requirement): bubbling reg3 is safe and correct to repeat
    // every cycle the condition holds, the same multi-cycle-bubble shape
    // div_stall/fp_stall already have.
    wire reg3_bubble = div_stall | fp_stall | dtlb_miss | exception_taken;
    // docs/adr/0025-hpc-performance-csrs.md (Phase J3). Same treatment as
    // every other `_to_reg3` wire here -- a bubbled instruction (for any
    // reg3_bubble reason) must never count toward minstret.
    wire valid_to_reg3         = reg3_bubble ? 1'b0 : valid_regde;
    wire memtoReg_to_reg3      = reg3_bubble ? 1'b0 : memtoReg_regde;
    wire regWrite_to_reg3      = reg3_bubble ? 1'b0 : regWrite_regde;
    wire fRegWrite_to_reg3     = reg3_bubble ? 1'b0 : fRegWrite_regde;
    wire memRead_to_reg3       = reg3_bubble ? 1'b0 : memRead_regde;
    wire memWrite_to_reg3      = reg3_bubble ? 1'b0 : memWrite_regde;
    wire jump_to_reg3          = reg3_bubble ? 1'b0 : jump_regde;
    wire [REG_ADDR_WIDTH-1:0] destReg_to_reg3 = reg3_bubble ? {REG_ADDR_WIDTH{1'b0}}  : write_to_Reg_regde;
    // docs/adr/0038-a-extension-phase-v.md: a squashed/bubbled lr/sc/amo*
    // must never reach the real 2-phase interlock below -- same reasoning
    // as every other control field bubbled here.
    wire isAmo_to_reg3        = reg3_bubble ? 1'b0 : isAmo_regde;

reg3 #(.XLEN(XLEN), .NUM_REGS(NUM_REGS)) m_reg3(
    .clk(clk),
    .rst(start),
    .valid_regde(valid_to_reg3),
    .memtoReg_regde(memtoReg_to_reg3),
    .regWrite_regde(regWrite_to_reg3),
    .fRegWrite_regde(fRegWrite_to_reg3),
    .memRead_regde(memRead_to_reg3),
    .memWrite_regde(memWrite_to_reg3),
    .ALUOut(ex_result),
    // Store data must come from the forwarded value for both sw
    // (readData2_final) and fsw (freadData2_final, forwarded by FForward.v
    // since Phase C7) -- docs/adr/0003's lesson (store data is a separate
    // path to reg3/DataMemory, easy to silently leave on the raw/stale
    // decode-stage value) applies to the float case just as much as the
    // original integer one it was found for. docs/adr/00NN-mmu-sv32.md
    // (Phase F5): dtlb_store_data (forward-referenced, defined below near
    // dtlb_needed) instead of the raw expression -- see dtlb_vaddr_r's own
    // comment for the forwarding-drift bug a long D-side stall can hit.
    .readData2_regde(dtlb_store_data),
    .write_to_Reg_regde(destReg_to_reg3),
    .jump_regde(jump_to_reg3),
    .pc_plus4_regde(pc_plus4_regde),
    .funct3_regde(funct3_regde),
    .isAmo_regde(isAmo_to_reg3),
    .funct7_regde(funct7_regde),
    .hold(mem_stall | amo_stall),   // MEM-stage interlock (docs/adr/0013): freeze reg3 while
                        // the load it's currently holding hasn't come back from
                        // DataMemoryBRAM yet -- reg2 must not be allowed to push
                        // the next instruction in on top of it. docs/adr/0038:
                        // amo_stall joins it for the identical reason, across
                        // an lr/sc/amo*'s own real 2-phase occupancy.

    .valid_regem(valid_regem),
    .memtoReg_regem(memtoReg_regem),
    .regWrite_regem(regWrite_regem),
    .fRegWrite_regem(fRegWrite_regem),
    .memRead_regem(memRead_regem),
    .memWrite_regem(memWrite_regem),
    .ALUOut_regem(ALUOut_regem),
    .readData2_regem(readData2_regem),
    .write_to_Reg_regem(write_to_Reg_regem),
    .jump_regem(jump_regem),
    .pc_plus4_regem(pc_plus4_regem),
    .funct3_regem(funct3_regem),
    .isAmo_regem(isAmo_regem),
    .funct7_regem(funct7_regem)
);

// Compiled in only with -DASSERT_ON (see sim/run_tests.sh). reg3 latches
// unconditionally every cycle for a store (its docs/adr/0013 `hold` input
// only ever fires on a load, mem_stall being gated on memRead_regem, which
// is mutually exclusive with memWrite_regem), so readData2_regem this cycle
// must equal (readData2_final, or fsw's freadData2_final -- see reg3's own
// instantiation above) as it was one cycle ago. This is exactly the
// property docs/adr/0003-store-data-forwarding.md's bug violated (reg3 was
// wired to the raw readData2_regde instead of the forwarded value) --
// this assertion would have caught that wiring mistake immediately instead
// of needing a directed test (store_load.s) to stumble into it.
`ifdef ASSERT_ON
reg [XLEN-1:0] expected_store_data;
// docs/adr/0023-caches.md (Phase G6). A second gap in this same assertion,
// found by running: it re-checked EVERY cycle memWrite_regem stayed high,
// an assumption that only ever held because writes never used to stall
// (mem_stall was gated on memRead_regem alone). A write-allocate MISS can
// now hold reg3's store for multiple cycles -- readData2_regem correctly
// stays frozen throughout (reg3's own `hold` does exactly its job), but
// expected_store_data kept sampling the LIVE dtlb_store_data wire every
// cycle regardless, which drifts to whatever's now transiently in reg2/
// Forward.v for the NEXT (unrelated) instruction once the store has
// already moved past EX -- a spurious failure, not a real RTL bug (caught
// directly: tb_fence_flush_g7.v's first-ever write-allocate miss). Fixed
// the same "distinguish fresh from repeat" way mem_stall_done_r itself
// already does: only compare on the cycle memWrite_regem is FIRST seen,
// not on every held-repeat cycle after it.
reg store_already_checked_r;
always @(posedge clk) begin
    // docs/adr/00NN-mmu-sv32.md (Phase F5): tracks dtlb_store_data, not
    // the raw expression -- reg3 now legitimately latches the frozen
    // snapshot (dtlb_store_data_r) instead of the live, possibly-drifted
    // forwarding result once a D-side stall has been in progress a while
    // (see dtlb_vaddr_r's own comment); this assertion must track the
    // same value reg3 actually receives, or it would spuriously fire.
    expected_store_data <= dtlb_store_data;
    if (~start || !memWrite_regem)
        store_already_checked_r <= 1'b0;
    else if (!store_already_checked_r) begin
        store_already_checked_r <= 1'b1;
        if (readData2_regem !== expected_store_data)
            begin
                $display("ASSERTION FAILED @t=%0t: reg3 store-data mismatch: readData2_regem=%0d, expected (last cycle's forwarded readData2_final)=%0d",
                          $time, readData2_regem, expected_store_data);
                $finish;
            end
    end
end
`endif

// ==========================================================================
// MEM -- Memory Access
// ==========================================================================
    // docs/adr/0020-soc-integration.md (Phase D3). The LSU-to-bus
    // translation ("WbMaster") is plain combinational wiring here rather
    // than its own module -- it's a direct level-based re-expression of
    // signals riscvpipeline.v already has (memRead_regem/memWrite_regem/
    // ALUOut_regem/readData2_regem/funct3_regem), and this project avoids
    // introducing a module for a passthrough nothing else will ever reuse
    // (Phase B's own "avoid the premature abstraction trap" convention).
    // `lsu_sel` is derived from funct3_regem's width bits for any future
    // slave that cares about byte lanes (today's sole slave, RamWishbone-
    // Adapter, doesn't -- see its own header comment for why it takes
    // `funct3` as a side-band tag instead).
    // docs/adr/0038-a-extension-phase-v.md: an active lr/sc/amo* drives this
    // shared bus request through its own 2-phase eff_memRead/eff_memWrite
    // instead of the raw memRead_regem/memWrite_regem (which Control.v
    // deliberately leaves 0 for OPCODE_AMO) -- amo_active/amo_write_phase_r/
    // amo_write_done_r are defined above, alongside mem_stall.
    wire eff_memRead  = amo_active ? (!amo_write_phase_r && !amo_write_done_r) : memRead_regem;
    wire eff_memWrite = amo_active ? (amo_write_phase_r && !amo_write_done_r)  : memWrite_regem;
    wire lsu_cyc = eff_memRead | eff_memWrite;
    wire lsu_stb = lsu_cyc;
    wire lsu_we  = eff_memWrite;
    wire [3:0] lsu_sel = (funct3_regem[1:0] == 2'b00) ? (4'b0001 << ALUOut_regem[1:0]) :  // byte
                          (funct3_regem[1:0] == 2'b01) ? (4'b0011 << ALUOut_regem[1:0]) :  // halfword
                                                          4'b1111;                          // word
    wire lsu_ack;  // docs/adr/0024-variable-latency-memory.md (Phase I2): now genuinely
                    // consumed by mem_access_ready/mem_trigger's own CACHE_NONE branch below,
                    // closing the gap this comment used to flag.

    // ==========================================================================
    // MMU translation (docs/adr/00NN-mmu-sv32.md, Phase F5). Wires Tlb.v/
    // Ptw.v (Phase F4, standalone until now) live into fetch and load/
    // store. Translation is gated on satp.MODE==Sv32 && priv_mode != M --
    // M-mode always executes physical addresses (mstatus.MPRV, which
    // would let M opt in too, is out of scope this phase). Deliberately a
    // real, always-instantiated feature (unlike HAZARD_STRATEGY/
    // BRANCH_PREDICTOR's elaboration-time swappable-subsystem parameters)
    // -- gated at runtime by translate_enable, not a research-platform
    // comparison axis. Placed here (rather than up near the IF section
    // that most immediately consumes itlb_miss/imem_phys_addr) because
    // this is where it most naturally reads the EX/MEM-stage signals it
    // needs (ALUOut, memRead_regde/memWrite_regde, lsu_cyc); every
    // upstream consumer (pc_stall, reg1/reg2's instantiations,
    // exception_taken, ex_result) forward-references these wires, the
    // same pattern this file already relies on for pc_stall/priv_mode_w.
    // ==========================================================================
    // docs/adr/00NN-sv39-mmu-phase-p.md (Phase P3): the MMU now covers both
    // supported XLENs -- Sv32 (Tlb.v/Ptw.v, 2-level/32-bit-PTE) at XLEN=32,
    // Sv39 (Tlb39.v/Ptw39.v, 3-level/64-bit-PTE, Phase P1-P2) at XLEN=64,
    // selected below via `generate` (elaboration-time, XLEN is a module
    // parameter -- exactly one of the two ever exists in a given build,
    // mirroring CACHE_MODE's own "unselected branch costs nothing"
    // convention). Every downstream consumer of itlb_hit/itlb_ppn/ls_hit/
    // ls_ppn/ptw_busy/ptw_done/... below is written purely in terms of
    // these plain wire names and needs ZERO changes for either XLEN -- the
    // miss/fault/permission logic, the dtlb_vaddr_r/dtlb_store_data_r
    // latches, ptw_abandoned_r, and the shared-bus mux are all already
    // XLEN-agnostic by construction (docs/ROADMAP.md's own research pass
    // confirmed this before any RTL changed).
    wire translate_enable = ((XLEN == 32) || (XLEN == 64)) && satp_mode_w && (priv_mode_w != `PRIV_M);
    wire priv_is_u = (priv_mode_w == `PRIV_U);

    // -- Tlb.v/Tlb39.v: unified, tagged, two independent combinational read
    // ports (identical port shape in both modules by design -- Tlb39.v was
    // built as a deliberate structural mirror of Tlb.v, only the VPN tag
    // width differs internally).
    wire itlb_hit, ls_hit;
    wire [XLEN-1:0] itlb_ppn, ls_ppn;
    wire itlb_perm_r, itlb_perm_w, itlb_perm_x, itlb_perm_u;
    wire ls_perm_r, ls_perm_w, ls_perm_x, ls_perm_u;
    wire ptw_fill_valid;
    wire [XLEN-1:0] ptw_fill_vaddr, ptw_fill_ppn;
    wire ptw_fill_perm_r, ptw_fill_perm_w, ptw_fill_perm_x, ptw_fill_perm_u;

    // Named generate branches (gen_mmu_tlb_sv32/gen_mmu_tlb_sv39) -- Icarus
    // inserts a hierarchical scope for a generate-if body regardless of an
    // explicit label (an unnamed one just gets an implicit genblk# name),
    // so existing `dut.m_Ptw.*`-style debug-tap hierarchical references in
    // testbenches (e.g. tb_mmu_translate_f5.v) need the scope name added
    // to their path -- an explicit, stable name is easier to reference
    // correctly than relying on an implicit genblk# numbering.
    generate
    if (XLEN == 32) begin : gen_mmu_tlb_sv32
        Tlb #(.XLEN(XLEN)) m_Tlb(
            .clk(clk), .rst(start),
            .fetch_vaddr(imem_read_addr),
            .fetch_hit(itlb_hit), .fetch_ppn(itlb_ppn),
            .fetch_perm_r(itlb_perm_r), .fetch_perm_w(itlb_perm_w),
            .fetch_perm_x(itlb_perm_x), .fetch_perm_u(itlb_perm_u),
            // docs/adr/00NN-mmu-sv32.md (Phase F5): dtlb_vaddr (forward-
            // referenced, defined below near dtlb_needed), not raw ALUOut --
            // see its own comment for the forwarding-drift bug this avoids.
            .ls_vaddr(dtlb_vaddr),
            .ls_hit(ls_hit), .ls_ppn(ls_ppn),
            .ls_perm_r(ls_perm_r), .ls_perm_w(ls_perm_w),
            .ls_perm_x(ls_perm_x), .ls_perm_u(ls_perm_u),
            .fill_valid(ptw_fill_valid), .fill_vaddr(ptw_fill_vaddr), .fill_ppn(ptw_fill_ppn),
            .fill_perm_r(ptw_fill_perm_r), .fill_perm_w(ptw_fill_perm_w),
            .fill_perm_x(ptw_fill_perm_x), .fill_perm_u(ptw_fill_perm_u),
            .flush_all(sfence_real && !reg2_hold)
        );
    end else begin : gen_mmu_tlb_sv39
        Tlb39 #(.XLEN(XLEN)) m_Tlb(
            .clk(clk), .rst(start),
            .fetch_vaddr(imem_read_addr),
            .fetch_hit(itlb_hit), .fetch_ppn(itlb_ppn),
            .fetch_perm_r(itlb_perm_r), .fetch_perm_w(itlb_perm_w),
            .fetch_perm_x(itlb_perm_x), .fetch_perm_u(itlb_perm_u),
            .ls_vaddr(dtlb_vaddr),
            .ls_hit(ls_hit), .ls_ppn(ls_ppn),
            .ls_perm_r(ls_perm_r), .ls_perm_w(ls_perm_w),
            .ls_perm_x(ls_perm_x), .ls_perm_u(ls_perm_u),
            .fill_valid(ptw_fill_valid), .fill_vaddr(ptw_fill_vaddr), .fill_ppn(ptw_fill_ppn),
            .fill_perm_r(ptw_fill_perm_r), .fill_perm_w(ptw_fill_perm_w),
            .fill_perm_x(ptw_fill_perm_x), .fill_perm_u(ptw_fill_perm_u),
            .flush_all(sfence_real && !reg2_hold)
        );
    end
    endgenerate

    // -- I-side (fetch): front-end-only interlock, same category as
    // Hazard.v's own load-use stall (freeze PC/reg1, bubble reg2) -- see
    // pc_stall's and reg2's own instantiation comments above for the fold-
    // in, and ptw_done_i's own definition below for why itlb_miss excludes
    // the exact cycle a walk just concluded with a fault (so the stall
    // doesn't re-trigger a pointless re-walk of a known-faulting address).
    wire itlb_hit_fault = translate_enable && itlb_hit &&
        !(itlb_perm_x && (priv_is_u ? itlb_perm_u : !itlb_perm_u));
    // A real bug found by running, not anticipated in the design write-up
    // -- the same bug class docs/adr/0016 already found for
    // HazardNoForward.v's own stall: PC.v prioritizes `stall` over
    // accepting a new `pc_i` UNCONDITIONALLY, regardless of what's causing
    // either one. Once an OLDER instruction's ifetch_fault_regde reaches
    // EX and fires exception_taken (branch_taken=1, wanting to redirect to
    // mtvec), a YOUNGER instruction's own itlb_miss for the (about to be
    // abandoned) current PC would otherwise keep pc_stall=1 that same
    // cycle, and PC.v's stall silently swallows the redirect entirely --
    // observed directly via a debug testbench tapping branch_taken/pc_o
    // (the same diagnostic technique D8's mip_live race and D11's CSR bug
    // were both found with), not reasoned out in advance. Fixed the same
    // way docs/adr/0016 fixed it: gate the whole stall condition on
    // !branch_taken, not just the specific path that motivated finding it.
    //
    // docs/adr/0023-caches.md (Phase G3). A SECOND, related bug in this same
    // gating, found by running CACHE_MODE=1 constrained-random programs
    // under PIPELINE_PROFILE=1 (6-stage split-fetch) -- !branch_taken alone
    // isn't sufficient there. reg1a.v (docs/adr/0018) relays pc_o one cycle
    // behind by construction, EXCEPT for exactly one cycle immediately after
    // a redirect, where it catches up to equal pc_o (the "one instruction
    // already in flight" gap momentarily collapses to zero) -- that's the
    // same cycle redirect_squash_extend_r squashes reg1's fetch to a nop
    // regardless of what was actually fetched there. If a NEW pc_stall
    // source (itlb_miss here, icache_miss below) asserts on that exact
    // collapsed-gap cycle, PC.v and reg1a freeze TOGETHER at the now-equal
    // value; when the stall later clears, reg1a's next relay redundantly
    // re-samples pc_o's still-unchanged value one extra time, silently
    // duplicating the fetch of the redirect target -- a new trigger for the
    // exact "duplicate fetch" bug shape docs/adr/0018's own A3 step first
    // found and fixed for the plain (non-stalled) redirect case. Since that
    // cycle's fetch result is discarded unconditionally either way, there's
    // nothing to stall for -- fixed by also gating on
    // !redirect_squash_extend_r, mirroring the !branch_taken gate immediately
    // above it structurally, not by touching reg1a/redirect_squash_extend_r
    // themselves (this project's "an object entering a store must trust the
    // store" convention elsewhere: the new stall source is what must respect
    // an existing invariant, not the other way around).
    wire itlb_miss = translate_enable && !itlb_hit && !(ptw_done_i && ptw_fault)
        && !branch_taken && !redirect_squash_extend_r;
    // docs/adr/0023-caches.md (Phase G3). Joins itlb_miss's own front-end-
    // only interlock category (freeze PC/reg1 via pc_stall, bubble reg2 --
    // see both instantiations below). Gated on (!translate_enable ||
    // itlb_hit), not just itlb_hit alone: icache_hit/imem_phys_addr aren't
    // meaningful until translation resolves (this core's fetch is PIPT),
    // but when translation is disabled entirely (Bare mode/M-mode) the
    // physical address is available immediately and the cache shouldn't
    // wait on a TLB hit that will never come from a query it was never
    // asked to perform. Gated on !branch_taken and !redirect_squash_extend_r
    // for the same reasons itlb_miss just above is (both the original
    // docs/adr/0016/0022 lesson and this phase's own collapsed-gap finding).
    // Always 0 under CACHE_NONE (icache_hit tied to 1 above), bit-exact with
    // pre-G3 behavior.
    wire icache_miss = (!translate_enable || itlb_hit) && !icache_hit
        && !branch_taken && !redirect_squash_extend_r;

    // docs/adr/0025-hpc-performance-csrs.md (Phase J5). `icache_hit`/
    // `icache_miss` are LEVELS held for as long as PC stays frozen on the
    // same address (icache_miss for the whole fill; icache_hit trivially,
    // every cycle an unrelated stall re-presents an already-cached line to
    // a PC that hasn't moved) -- bench_template.v needs an edge-detector
    // to count icache_miss once for exactly this reason. A one-cycle pulse
    // pair needs a genuinely NEW gate: `pc_stall_r` (was fetch already
    // stalled last cycle) -- when 0, PC.v advanced to a fresh address this
    // cycle, so THIS is the one cycle a real access is being made, not a
    // repeat of the same address. Reuses icache_miss's own qualifying
    // conditions (translation-resolved, not itself a stale squashed fetch)
    // so hit/miss are exact complements whenever `icache_access_new` fires.
    reg pc_stall_r;
    always @(posedge clk) begin
        if (~start) pc_stall_r <= 1'b0;
        else pc_stall_r <= pc_stall;
    end
    wire icache_access_new = !pc_stall_r && (!translate_enable || itlb_hit)
        && !branch_taken && !redirect_squash_extend_r;
    wire icache_hit_pulse_w  = icache_access_new && icache_hit;
    wire icache_miss_pulse_w = icache_access_new && !icache_hit;
    // ptw_abandoned_r (defined below, near ptw_done_i/ptw_done_d) excludes
    // a stale, already-abandoned walk's fault result -- see its own
    // comment for the real bug this closes.
    wire ifetch_fault_if = itlb_hit_fault | (ptw_done_i && ptw_fault && !ptw_abandoned_r);
    // Gated on itlb_hit, not just translate_enable: Tlb.v only resets its
    // `valid` array, not `ppn_r` (see Tlb.v's own header -- a stale/never-
    // filled entry's data fields are X until first filled, by design, the
    // same way a BTB/BHT-style table's payload is meaningless without a
    // qualifying hit). Using itlb_ppn unconditionally on a MISS let X
    // propagate into `inst`/Control.v's decode and, from there, into
    // completely unrelated combinational signals (Hazard.v's own stall,
    // observed directly corrupting pc_stall to X via a debug testbench) --
    // even though the architectural effect was already safely squashed via
    // ifetch_fault_regde/reg3_bubble, the X itself still needed to not
    // exist in the first place. On a miss/disabled/fault cycle the actual
    // fetched bits don't matter (the whole point of itlb_miss stalling or
    // ifetch_fault_if tagging), so falling back to the untranslated VA here
    // is harmless and, critically, always a defined value.
    wire [XLEN-1:0] imem_phys_addr = (translate_enable && itlb_hit) ?
        {itlb_ppn[19:0], imem_read_addr[11:0]} : imem_read_addr;

    // -- D-side (load/store): EX-anchored interlock, same category as
    // div_stall/fp_stall (hold reg2, bubble reg3) -- anchored at EX
    // (ALUOut) rather than MEM (ALUOut_regem) so a D-side page fault can
    // reuse the existing exception_taken/unconditional_redirect machinery
    // directly instead of a third, MEM-anchored redirect category.
    wire dtlb_needed = translate_enable && (memRead_regde | memWrite_regde);
    // A real bug found by running: ALUOut's own value, for an instruction
    // held in EX, depends on Forward.v's mux -- which only has a bounded
    // ~2-cycle window (EX/MEM, MEM/WB) after its producer retires. Once a
    // load/store is held by dtlb_miss for LONGER than that (which a multi-
    // cycle Ptw.v walk easily does), the producer fully drains past MEM/WB,
    // Forward.v correctly reports "no forward" from then on, and
    // readData1_final falls back to reg2's own STALE, pre-forward operand
    // (captured at the ORIGINAL decode cycle, before the producer had even
    // committed) -- silently corrupting ALUOut mid-hold (observed directly:
    // a store's own address drifted from a correct 0x1004 down to 0x1000,
    // losing an immediate-offset instruction's contribution entirely, once
    // its result aged out of the forwarding window). Divider.v/FDivider.v/
    // FSqrt.v/Ptw.v itself all avoid this class of bug by latching their
    // own inputs ONCE, internally, at the moment they start (the same
    // start&&!busy&&!done guard) -- nothing else in riscvpipeline.v
    // previously needed to snapshot ALUOut for a held instruction, since no
    // other reg2_hold source ever depended on it past the first cycle.
    // Same drift hits the STORE's own data operand (readData2_final,
    // forwarded x11 in the case that found this): once its producer ages
    // out of Forward.v's window, readData2_final reverts to reg3's stale
    // pre-forward operand too -- latched alongside the VA for the same
    // reason, using the exact same timing.
    reg [XLEN-1:0] dtlb_vaddr_r;
    reg [XLEN-1:0] dtlb_store_data_r;
    reg dtlb_miss_r;
    always @(posedge clk) begin
        if (~start) begin
            dtlb_vaddr_r <= {XLEN{1'b0}};
            dtlb_store_data_r <= {XLEN{1'b0}};
            dtlb_miss_r  <= 1'b0;
        end else begin
            if (dtlb_needed && !dtlb_miss_r) begin
                dtlb_vaddr_r <= ALUOut;
                dtlb_store_data_r <= isStoreFp_regde ? freadData2_final : readData2_final;
            end
            dtlb_miss_r <= dtlb_miss;
        end
    end
    // The stable VA to use for D-side translation. Gated on dtlb_miss_r
    // (the ONE-CYCLE-DELAYED copy), not live dtlb_miss: on the very first
    // cycle dtlb_miss goes high, dtlb_vaddr_r hasn't been written with
    // THIS cycle's ALUOut yet (that capture only lands on the upcoming
    // edge) -- gating on live dtlb_miss would read the stale, pre-capture
    // register (e.g. still 0 from reset, on an instruction's first-ever
    // D-side access) instead of the still-fresh, correct ALUOut. A real
    // bug found by running: vpn0_r inside Ptw.v latched 0 instead of the
    // real VPN0, because ptw_vaddr (fed from this same mux) sampled that
    // exact stale value on the walk's own first cycle.
    wire [XLEN-1:0] dtlb_vaddr = dtlb_miss_r ? dtlb_vaddr_r : ALUOut;
    wire [XLEN-1:0] dtlb_store_data = dtlb_miss_r ? dtlb_store_data_r :
        (isStoreFp_regde ? freadData2_final : readData2_final);
    wire ls_perm_ok = (memWrite_regde ? ls_perm_w : ls_perm_r) &&
        (priv_is_u ? ls_perm_u : !ls_perm_u);
    wire dtlb_hit_fault = dtlb_needed && ls_hit && !ls_perm_ok;
    // Same !branch_taken gate as itlb_miss above, same reason -- see its
    // own comment.
    wire dtlb_miss = dtlb_needed && !ls_hit && !(ptw_done_d && ptw_fault) && !branch_taken;
    // ptw_abandoned_r: see ifetch_fault_if's own comment (defined below,
    // near ptw_done_i/ptw_done_d) for the real bug this closes.
    wire dtlb_page_fault = dtlb_hit_fault | (ptw_done_d && ptw_fault && !ptw_abandoned_r);
    // Gated on ls_hit, not just translate_enable -- same X-propagation
    // reasoning as imem_phys_addr above. Uses dtlb_vaddr (not raw ALUOut)
    // for the same drift reasoning as dtlb_vaddr_r's own comment.
    wire [XLEN-1:0] mem_paddr = (translate_enable && ls_hit) ?
        {ls_ppn[19:0], dtlb_vaddr[11:0]} : dtlb_vaddr;

    // -- sfence.vma (F2 decoded it; still inert until now). Requires S or
    // M -- a real, necessary privilege check the phase plan left as an
    // open question, decided here since F5 is when it needs an answer;
    // folds into exception_taken above like mret/sret's own violation
    // checks.
    wire sfence_priv_violation = isSfenceVma_regde & (priv_mode_w == `PRIV_U);
    wire sfence_real = isSfenceVma_regde & !sfence_priv_violation;

    // docs/adr/0023-caches.md (Phase G6). `fence` has no privilege
    // restriction in the base ISA (unlike sfence.vma) -- isFence_regde
    // alone is the real condition, no violation check needed.
    //
    // fence_pending_r is a LEVEL (not a one-shot pulse like sfence_real's
    // own use): set the cycle fence first lands in reg3 (mirrors
    // memRead_regem/memWrite_regem's own EX->reg3 latch timing), held for
    // the flush's entire (possibly multi-cycle) duration, cleared only once
    // DCache.v's own flush_done pulses. This is what mem_trigger (above)
    // and DCache's own .flush_all input (below) both key off, the same
    // "front the multi-cycle operation with a held level, let the unit's
    // own internal guard prevent re-triggering" shape mem_stall's own
    // generalization (G5) already established.
    //
    // Also gated on !ptw_busy: a walk started earlier (e.g. an itlb_miss
    // for a LATER instruction, detected before fence itself even reached
    // EX -- Ptw walking doesn't freeze EX/MEM/WB, only the front end) can
    // still be busy by the time fence reaches reg3. DCache.v has no
    // visibility into Ptw.v at all (a fully standalone module, F4/G4-style)
    // -- gating the flush_all LEVEL itself here, externally, is what makes
    // "wait your turn for the shared bus" apply to fence's flush the same
    // way it already applies to Ptw.v vs. the plain LSU (ptw_start's own
    // !lsu_cyc gate below). Bit-exact under CACHE_NONE regardless (see
    // mem_trigger's own CACHE_NONE branch, which never references this).
    wire fence_real = isFence_regde;
    reg fence_pending_r;
    always @(posedge clk) begin
        if (~start) fence_pending_r <= 1'b0;
        else if (dcache_flush_done) fence_pending_r <= 1'b0;
        else if (CACHE_MODE != CACHE_NONE && fence_real && !reg2_hold) fence_pending_r <= 1'b1;
    end
    // docs/adr/0023-caches.md (Phase G7). A real bug found by running MMU+
    // cache constrained-random programs: fence_pending_r (above) and
    // DCache.v's own internal flush_active_r clear ONE CYCLE APART --
    // flush_active_r drops the same edge flush_done_r first pulses, but
    // fence_pending_r (driven combinationally into DCache's own flush_all
    // input) doesn't drop until the FOLLOWING cycle (it samples
    // dcache_flush_done, itself a registered one-cycle pulse). For that one
    // in-between cycle, DCache's own S_IDLE re-evaluates
    // `flush_all && !flush_active_r` with flush_all STILL 1 (fence_pending_r
    // hasn't cleared yet) and flush_active_r ALREADY 0 (just cleared) --
    // spuriously re-triggering a second, fully redundant ~256-line scan
    // pass. Harmless on its own (nothing left dirty to write back), but it
    // silently doubles the flush's real latency, and mem_stall/reg3 had
    // ALREADY released by then (fence_pending_r's own one-cycle-late clear
    // means the pipeline moves on before the spurious second pass
    // finishes) -- the fixed simulation time budget run_random_tests.py
    // computes per program doesn't know to wait for this unplanned extra
    // ~256 cycles, so the post-halt memory dump can sample WHILE the
    // spurious pass is still draining. Same "distinguish fresh from
    // repeat" shape this project uses everywhere for this bug class
    // (mem_stall_done_r, the docs/adr/0003 store-data assertion fix
    // earlier this same phase): latch "a flush has already been started
    // for this fence" the cycle DCache.v's own flush_busy first goes high,
    // and gate flush_all on NOT having started one yet -- closes the
    // one-cycle window regardless of exactly how fence_pending_r/
    // flush_active_r end up interleaved.
    reg fence_flush_started_r;
    always @(posedge clk) begin
        if (~start || !fence_pending_r) fence_flush_started_r <= 1'b0;
        else if (dcache_flush_busy) fence_flush_started_r <= 1'b1;
    end

    // -- Shared Ptw.v: exactly one instance, arbitrated between the two
    // requesters above. D-side always wins when both are pending (older
    // instruction, program-order priority) -- this only needs to be
    // correct at the moment Ptw.v is idle (its own start&&!busy&&!done
    // guard, mirroring Divider.v, latches inputs once at walk start and
    // ignores this mux entirely while busy), so simultaneous itlb_miss+
    // dtlb_miss (possible: an older load stalled in EX and a newer fetch
    // missing, genuinely independent conditions) resolves correctly by
    // construction -- I-side's own pc_stall keeps the front end frozen
    // regardless of which side the walker is currently servicing, so it
    // simply waits its turn.
    //
    // A real, genuine bus conflict found during this implementation (not
    // anticipated in the original design write-up): an OLDER, unrelated
    // instruction's own mem_stall (docs/adr/0013) can be genuinely,
    // actively using the shared Wishbone master port (cyc/stb held high
    // for its own registered-read latency) at the exact same cycle a
    // YOUNGER instruction's dtlb_miss/itlb_miss becomes true -- the two
    // conditions are checked at different pipeline stages with
    // independent trigger conditions, so "a walk only ever happens while
    // the pipeline is already stalled" does not, by itself, guarantee no
    // OTHER real bus traffic is in flight. Fixed by gating ptw_start on
    // !lsu_cyc (the plain, pre-mux "does the real LSU currently want the
    // bus" signal, unchanged) -- the walker simply waits its turn; the
    // pipeline stays correctly frozen via dtlb_miss/itlb_miss regardless
    // of exactly when the walk itself is allowed to start.
    wire ptw_req_d = dtlb_miss;
    wire ptw_req_i = itlb_miss && !dtlb_miss;
    // docs/adr/0023-caches.md (Phase G6): !dcache_flush_busy joins !lsu_cyc
    // -- a retiring fence's own flush (no memRead_regem/memWrite_regem at
    // all, so lsu_cyc alone wouldn't see it) can genuinely be using the
    // shared bus too; tied 0 under CACHE_NONE, so this term is a no-op
    // there (see the DCache instantiation block below).
    wire ptw_start = (ptw_req_d || ptw_req_i) && !lsu_cyc && !dcache_flush_busy;
    // dtlb_vaddr (not raw ALUOut): if ptw_start is itself delayed past the
    // first dtlb_miss cycle (the !lsu_cyc gate below can do that), ALUOut
    // may have already drifted by the time the walk actually latches it --
    // see dtlb_vaddr_r's own comment.
    wire [XLEN-1:0] ptw_vaddr = ptw_req_d ? dtlb_vaddr : imem_read_addr;
    wire ptw_is_fetch = ptw_req_i;
    wire ptw_is_store = ptw_req_d && memWrite_regde;

    wire ptw_busy, ptw_done, ptw_fault;
    wire [XLEN-1:0] ptw_result_ppn;
    wire ptw_result_perm_r, ptw_result_perm_w, ptw_result_perm_x, ptw_result_perm_u;
    wire ptw_m_cyc, ptw_m_stb, ptw_m_we;
    wire [XLEN-1:0] ptw_m_addr, ptw_m_data_o;
    wire [3:0] ptw_m_sel;

    // docs/adr/00NN-sv39-mmu-phase-p.md (Phase P3): same XLEN-selected,
    // named generate as the Tlb/Tlb39 pair above (gen_mmu_ptw_sv32/
    // gen_mmu_ptw_sv39 -- see that pair's own comment on Icarus always
    // inserting a scope for a generate-if body; existing `dut.m_Ptw.*`-
    // style hierarchical debug taps, e.g. tb_mmu_translate_f5.v, now need
    // the branch's scope name prefixed). The instance keeps the name
    // `m_Ptw` in both branches so only the scope prefix differs, not the
    // leaf name. satp_ppn is the one port whose width genuinely differs
    // (Ptw.v: 22 bits, Ptw39.v: 44) -- satp_ppn_w itself is now 44 bits
    // wide (CSR.v's own widened satp_ppn_val), sliced down to Ptw.v's real
    // 22-bit port at XLEN=32. Every other port name/width is identical
    // between the two modules by design.
    generate
    if (XLEN == 32) begin : gen_mmu_ptw_sv32
        Ptw #(.XLEN(XLEN)) m_Ptw(
            .clk(clk), .rst(start),
            .start(ptw_start), .vaddr(ptw_vaddr), .satp_ppn(satp_ppn_w[21:0]),
            .is_fetch(ptw_is_fetch), .is_store(ptw_is_store), .priv_is_u(priv_is_u),
            .busy(ptw_busy), .done(ptw_done), .fault(ptw_fault),
            .result_ppn(ptw_result_ppn),
            .result_perm_r(ptw_result_perm_r), .result_perm_w(ptw_result_perm_w),
            .result_perm_x(ptw_result_perm_x), .result_perm_u(ptw_result_perm_u),
            .m_cyc(ptw_m_cyc), .m_stb(ptw_m_stb), .m_we(ptw_m_we),
            .m_addr(ptw_m_addr), .m_data_o(ptw_m_data_o), .m_sel(ptw_m_sel),
            .m_data_i(readData), .m_ack(lsu_ack)
        );
    end else begin : gen_mmu_ptw_sv39
        Ptw39 #(.XLEN(XLEN)) m_Ptw(
            .clk(clk), .rst(start),
            .start(ptw_start), .vaddr(ptw_vaddr), .satp_ppn(satp_ppn_w),
            .is_fetch(ptw_is_fetch), .is_store(ptw_is_store), .priv_is_u(priv_is_u),
            .busy(ptw_busy), .done(ptw_done), .fault(ptw_fault),
            .result_ppn(ptw_result_ppn),
            .result_perm_r(ptw_result_perm_r), .result_perm_w(ptw_result_perm_w),
            .result_perm_x(ptw_result_perm_x), .result_perm_u(ptw_result_perm_u),
            .m_cyc(ptw_m_cyc), .m_stb(ptw_m_stb), .m_we(ptw_m_we),
            .m_addr(ptw_m_addr), .m_data_o(ptw_m_data_o), .m_sel(ptw_m_sel),
            .m_data_i(readData), .m_ack(lsu_ack)
        );
    end
    endgenerate

    // Which side a walk currently in progress (or just concluded) was for
    // -- needed because Ptw.v itself doesn't report this (mirrors
    // Divider.v's own precedent of the caller owning any such
    // bookkeeping, not the multi-cycle unit itself).
    reg ptw_servicing_d_r;
    always @(posedge clk) begin
        if (~start) ptw_servicing_d_r <= 1'b0;
        else if (ptw_start && !ptw_busy) ptw_servicing_d_r <= ptw_req_d;
    end
    wire ptw_done_i = ptw_done && !ptw_servicing_d_r;
    wire ptw_done_d = ptw_done && ptw_servicing_d_r;

    // A second real bug found by running (the !branch_taken fix above
    // addresses a DIFFERENT cycle of the same underlying scenario): a walk
    // already in flight when a redirect fires is NOT itself cancelled --
    // Ptw.v has no notion of "never mind" once busy, it just keeps
    // running to completion. Observed directly: a walk started for one
    // fetch attempt (VA X) outlives a redirect that abandons X entirely
    // (e.g. that same cycle's exception_taken firing for a DIFFERENT,
    // OLDER reason), then concludes several cycles later -- by which point
    // the pipeline has moved on to completely unrelated code (even a
    // DIFFERENT privilege level) -- and its now-stale fault/success result
    // was still being trusted, corrupting whatever was actually executing.
    // Fixed by latching "the requestor of the walk currently in flight was
    // abandoned" the cycle a redirect coincides with ptw_busy, and
    // suppressing ifetch_fault_if/dtlb_page_fault (but not ptw_fill_valid
    // -- caching a stale walk's SUCCESSFUL translation is harmless and
    // still useful for whoever asks next) for that walk's own conclusion.
    reg ptw_abandoned_r;
    always @(posedge clk) begin
        if (~start) ptw_abandoned_r <= 1'b0;
        else if (ptw_busy && branch_taken) ptw_abandoned_r <= 1'b1;
        else if (ptw_done) ptw_abandoned_r <= 1'b0;
    end

    assign ptw_fill_valid = (ptw_done_i || ptw_done_d) && !ptw_fault;
    assign ptw_fill_vaddr = ptw_servicing_d_r ? dtlb_vaddr : imem_read_addr;
    assign ptw_fill_ppn = ptw_result_ppn;
    assign ptw_fill_perm_r = ptw_result_perm_r;
    assign ptw_fill_perm_w = ptw_result_perm_w;
    assign ptw_fill_perm_x = ptw_result_perm_x;
    assign ptw_fill_perm_u = ptw_result_perm_u;

    // docs/adr/0023-caches.md (Phase G6). DCache.v sits between the LSU's
    // MEM-stage request and the shared bus -- CACHE_NONE: not instantiated
    // at all (bit-exact, same "unselected generate branch costs nothing"
    // convention every prior swappable parameter used); CACHE_WRITEBACK_
    // SETASSOC: a real Wishbone-master-shaped fill/writeback engine (G4,
    // standalone-verified) now wired live. req_addr is ALUOut_regem, NOT a
    // separately-translated address -- ex_result (EX stage) already
    // substitutes mem_paddr for a load/store (see its own comment, Phase
    // F5), so ALUOut_regem is already the post-translation physical
    // address by the time it reaches MEM -- PIPT, no extra translation
    // needed here. req_wdata is readData2_regem, reg3's own already-
    // forwarded/frozen store value (docs/adr/0003, Phase F5's own
    // dtlb_store_data_r).
    //
    // dcache_req_read/write are gated on !ptw_busy: a walk started earlier
    // for a completely unrelated (younger fetch's) itlb_miss can still be
    // busy by the time THIS instruction reaches reg3 and wants its own
    // cache access -- DCache.v has no visibility into Ptw.v at all, so
    // masking its request here is what makes it wait its turn for the
    // shared bus, the same "D-side always wins... this only needs to be
    // correct at the moment Ptw.v is idle" discipline already governing
    // itlb_miss vs. dtlb_miss above, now extended to a THIRD requester.
    // mem_trigger (above) stays 1 throughout this masked wait (dcache_resp_
    // ready can't pulse while its own request is masked), correctly
    // holding reg3 until Ptw.v frees the bus.
    wire dcache_resp_ready, dcache_flush_busy, dcache_flush_done;
    wire [XLEN-1:0] dcache_resp_rdata;
    wire dcache_m_cyc, dcache_m_stb, dcache_m_we;
    wire [XLEN-1:0] dcache_m_addr, dcache_m_data_o;
    wire [3:0] dcache_m_sel;
    wire [2:0] dcache_m_funct3;
    // docs/adr/0025-hpc-performance-csrs.md (Phase J5). access_hit/
    // access_miss are already exactly-once-per-real-access by
    // construction -- see DCache.v's own updated header comment on
    // access_hit for the real read-hit double-counting bug found (and
    // fixed, inside DCache.v itself) while calibrating this phase's own
    // directed test.
    wire dcache_access_hit, dcache_access_miss;
    wire dcache_hit_pulse_w  = dcache_access_hit;
    wire dcache_miss_pulse_w = dcache_access_miss;
    generate
    if (CACHE_MODE == CACHE_NONE) begin : gen_dcache_none
        assign dcache_resp_ready = 1'b0;
        assign dcache_resp_rdata = {XLEN{1'b0}};
        assign dcache_flush_busy = 1'b0;
        assign dcache_flush_done = 1'b0;
        assign dcache_m_cyc = 1'b0;
        assign dcache_m_stb = 1'b0;
        assign dcache_m_we = 1'b0;
        assign dcache_m_addr = {XLEN{1'b0}};
        assign dcache_m_data_o = {XLEN{1'b0}};
        assign dcache_m_sel = 4'b0000;
        assign dcache_m_funct3 = 3'b000;
        assign dcache_access_hit = 1'b0;
        assign dcache_access_miss = 1'b0;
    end else begin : gen_dcache_writeback
        DCache #(.XLEN(XLEN), .WAYS(DCACHE_WAYS), .CACHE_SIZE_BYTES(DCACHE_SIZE_BYTES),
                 .LINE_BYTES(DCACHE_LINE_BYTES), .REPLACEMENT_POLICY(REPLACEMENT_POLICY),
                 .VICTIM_ENTRIES(VICTIM_ENTRIES)) m_DCache(
            .clk(clk), .rst(start),
            .req_read(memRead_regem && !ptw_busy),
            .req_write(memWrite_regem && !ptw_busy),
            .req_addr(ALUOut_regem), .req_wdata(readData2_regem), .req_funct3(funct3_regem),
            .resp_rdata(dcache_resp_rdata), .resp_ready(dcache_resp_ready),
            .flush_all(fence_pending_r && !ptw_busy && !fence_flush_started_r),
            .flush_busy(dcache_flush_busy), .flush_done(dcache_flush_done),
            .m_cyc(dcache_m_cyc), .m_stb(dcache_m_stb), .m_we(dcache_m_we),
            .m_addr(dcache_m_addr), .m_data_o(dcache_m_data_o), .m_sel(dcache_m_sel),
            .m_funct3(dcache_m_funct3),
            .m_data_i(readData), .m_ack(lsu_ack),
            .access_hit(dcache_access_hit), .access_miss(dcache_access_miss)
        );
    end
    endgenerate

    // dcache_resp_rdata is combinational and TRANSIENT (valid for exactly
    // the one cycle DCache.v's own state produces it -- a hit-read's single
    // S_HIT_RD cycle, or a miss's own last fill cycle), but reg4 doesn't
    // actually sample it until mem_stall_done_r's own one-cycle-LATER
    // release (the same lag DataMemoryBRAM.v's persistent registered output
    // already tolerates for free under CACHE_NONE, since that value simply
    // doesn't change again before reg4 gets to it). Captured here into a
    // real register so reg4 sees a stable value at the cycle it actually
    // samples, mirroring how this file already captures other transient,
    // done-pulse-only results (Ptw.v's own result_ppn) at their one valid
    // cycle rather than assuming a later consumer can read them live.
    reg [XLEN-1:0] dcache_rdata_captured_r;
    always @(posedge clk) begin
        if (dcache_resp_ready) dcache_rdata_captured_r <= dcache_resp_rdata;
    end

    // -- Bus mux: both Ptw.v's own master port and (now) DCache.v's own
    // fill/writeback engine share the LSU's existing single master port on
    // WbDecoder, per the phase's own "a walk/fill only ever happens while
    // the pipeline is already stalled, so a plain mux suffices, no real
    // arbiter needed" reasoning, now extended from two requesters to three.
    // CACHE_NONE keeps the original two-way mux verbatim (dcache_m_cyc is
    // tied 0 there, so its own arm is dead code, but the generate split
    // below keeps the *meaning* honest -- under CACHE_WRITEBACK_SETASSOC,
    // raw LSU signals no longer touch the real bus AT ALL, every real
    // access is mediated by DCache.v; keeping a live-but-never-selected
    // lsu_* arm there would be misleading, not just redundant).
    wire wb_m_cyc, wb_m_stb, wb_m_we;
    wire [XLEN-1:0] wb_m_addr, wb_m_data_o;
    wire [3:0] wb_m_sel;
    wire [2:0] wb_m_funct3;
    generate
    if (CACHE_MODE == CACHE_NONE) begin : gen_bus_mux_none
        assign wb_m_cyc  = ptw_busy ? ptw_m_cyc  : lsu_cyc;
        assign wb_m_stb  = ptw_busy ? ptw_m_stb  : lsu_stb;
        assign wb_m_we   = ptw_busy ? ptw_m_we   : lsu_we;
        assign wb_m_addr   = ptw_busy ? ptw_m_addr   : ALUOut_regem;
        // docs/adr/0038: an AMO's own write phase stores amo_combined (the
        // funct5-combined result), not the raw rs2 -- ordinary stores
        // (isAmo_regem=0) are bit-exact unaffected, and AMO's own read
        // phase never asserts eff_memWrite in the first place (lsu_we=0
        // gates s_we, so this value is simply unused/don't-care then).
        assign wb_m_data_o = ptw_busy ? ptw_m_data_o : (amo_active ? amo_combined : readData2_regem);
        assign wb_m_sel = ptw_busy ? ptw_m_sel : lsu_sel;
        // A real bug found by running: RamWishboneAdapter.v's `funct3` port
        // is a side-band tag (docs/adr/0020 D2 -- not part of the standard
        // Wishbone signal set, needed because DataMemoryBRAM.v bakes load
        // width/signedness into funct3 rather than a pure byte-enable
        // mask). Left wired to the real LSU's own funct3_regem
        // unconditionally, a Ptw.v word read during a walk was silently
        // reinterpreted as whatever width/signedness the real LSU's last
        // (unrelated, possibly stale-reset-value) funct3 happened to be --
        // observed directly: a real PTE word (0x401) came back as 0x1, its
        // own low byte, sign-extension irrelevant since bit7 was already 0.
        // Every PTE read is always a plain full-word-of-the-PTE-size read
        // -- Sv32's Ptw.v reads a 4-byte PTE (funct3=3'b010, lw's own
        // encoding); Sv39's Ptw39.v reads an 8-byte PTE (funct3=3'b011,
        // `F3_LOAD_LD`, ld's own encoding -- docs/adr/00NN-sv39-mmu-phase-p.md
        // Phase P3, the analogous fix for the wider PTE this walker reads).
        // XLEN is an elaboration-time constant, so this constant-folds
        // cleanly at either XLEN, same idiom DataMemoryBRAM.v's own
        // `if (XLEN >= 64)` already uses.
        assign wb_m_funct3 = ptw_busy ? ((XLEN == 64) ? `F3_LOAD_LD : 3'b010) : funct3_regem;
    end else begin : gen_bus_mux_cached
        // docs/adr/0023-caches.md (Phase G6). DCache.v's own fill/writeback
        // traffic takes priority (it's the newest, most granular requester
        // -- a single line-fill/writeback transaction, vs. Ptw.v's own
        // multi-transaction walk); the two are mutually exclusive by
        // construction (ptw_start's own !dcache_flush_busy/!lsu_cyc gates,
        // and dcache_req_read/write's own !ptw_busy gate above, prevent
        // either from starting while the other is genuinely using the
        // bus). No raw lsu_* arm here at all -- see this block's own header
        // comment for why keeping one would be misleading under this mode.
        assign wb_m_cyc  = dcache_m_cyc ? 1'b1            : (ptw_busy ? ptw_m_cyc  : 1'b0);
        assign wb_m_stb  = dcache_m_cyc ? dcache_m_stb    : (ptw_busy ? ptw_m_stb  : 1'b0);
        assign wb_m_we   = dcache_m_cyc ? dcache_m_we     : (ptw_busy ? ptw_m_we   : 1'b0);
        assign wb_m_addr   = dcache_m_cyc ? dcache_m_addr   : (ptw_busy ? ptw_m_addr   : {XLEN{1'b0}});
        assign wb_m_data_o = dcache_m_cyc ? dcache_m_data_o : (ptw_busy ? ptw_m_data_o : {XLEN{1'b0}});
        assign wb_m_sel = dcache_m_cyc ? dcache_m_sel : (ptw_busy ? ptw_m_sel : 4'b0000);
        assign wb_m_funct3 = dcache_m_cyc ? dcache_m_funct3 :
            (ptw_busy ? ((XLEN == 64) ? `F3_LOAD_LD : 3'b010) : 3'b000);
    end
    endgenerate

    // docs/adr/0020-soc-integration.md (Phase D8). NUM_SLAVES=3: slave 0
    // is RAM, slave 1 is Uart.v, slave 2 is Timer.v -- indices/BASE/SIZE
    // must stay in lockstep across the three flattened buses below (the
    // same convention WbDecoder.v's own header comment documents).
    wire [2:0] wb_s_cyc, wb_s_stb, wb_s_ack;
    wire wb_s_we;
    wire [XLEN-1:0] wb_s_addr, wb_s_data_o;
    wire [3:0] wb_s_sel;
    wire [3*XLEN-1:0] wb_s_data_i;

    // Generation 2 (Phase M, docs/adr/0028-rv64-migration-phase-m.md): a
    // real bug found by running, not anticipated in the plan -- WbDecoder's
    // BASE/SIZE parameters are flattened NUM_SLAVES*XLEN-wide arrays
    // (WbDecoder.v's own [g*XLEN +: XLEN] per-slot slicing), but every
    // field below (`TIMER_BASE`/`UART_BASE`/`TIMER_SIZE`/`UART_SIZE`,
    // riscv_defs.vh) is a plain 32-bit-sized literal and MEM_SIZE_BYTES/
    // 32'd0 are likewise 32 bits -- fine (and bit-exact) at XLEN=32, where
    // 32 bits *is* one whole slot, but at XLEN=64 the concatenation is only
    // half the width WbDecoder expects per slot, corrupting the address
    // map entirely (every load/store hung forever, mem_stall stuck, no
    // slave ever ack'd -- found via a debug trace after a plain sw/lw
    // sequence never completed at XLEN=64, the same "run first, don't
    // trust the read" discipline this project has needed before). Each
    // field is explicitly zero-extended to a full XLEN-wide slot here;
    // reduces to exactly the original concatenation at XLEN=32 (the
    // padding replication count is 0 there).
    WbDecoder #(.XLEN(XLEN), .NUM_SLAVES(3),
                .BASE({ {(XLEN-32){1'b0}}, `TIMER_BASE,
                        {(XLEN-32){1'b0}}, `UART_BASE,
                        {XLEN{1'b0}} }),
                .SIZE({ {(XLEN-32){1'b0}}, `TIMER_SIZE,
                        {(XLEN-32){1'b0}}, `UART_SIZE,
                        {(XLEN-32){1'b0}}, MEM_SIZE_BYTES[31:0] })) m_WbDecoder(
        // docs/adr/00NN-mmu-sv32.md (Phase F5): wb_m_* mux Ptw.v's own bus
        // traffic onto this shared master port while a walk is in
        // progress -- see the MMU translation block above.
        .m_cyc(wb_m_cyc), .m_stb(wb_m_stb), .m_we(wb_m_we),
        .m_addr(wb_m_addr), .m_data_o(wb_m_data_o), .m_sel(wb_m_sel),
        .m_data_i(readData), .m_ack(lsu_ack),
        .s_cyc(wb_s_cyc), .s_stb(wb_s_stb), .s_we(wb_s_we),
        .s_addr(wb_s_addr), .s_data_o(wb_s_data_o), .s_sel(wb_s_sel),
        .s_data_i(wb_s_data_i), .s_ack(wb_s_ack)
    );

    // docs/adr/0024-variable-latency-memory.md (Phase I2). The request
    // reaches RamWishboneAdapter UNDELAYED -- its own already-correct ack
    // generation runs at its natural timing, same as every phase before
    // this one. What gets delayed is EXPOSING that result to the real
    // master by MEM_LATENCY_D cycles. RamWishboneAdapter's own instance
    // name (dut.m_DataMemory) stays outside any generate block on purpose
    // -- check_tasks.vh and every dump template's memory-dump loop depend
    // on that exact hierarchical path; nesting it per-branch would rename
    // it and break dozens of existing tests.
    //
    // Two real bugs found by running ruled out simpler designs:
    // 1. Delaying the ack/data pair alone (a plain N-deep shift register)
    //    breaks Ptw.v: it holds m_stb continuously across TWO separate,
    //    different-address reads (level1 then level0) without ever
    //    dropping it between them, and RamWishboneAdapter's own ack is a
    //    LEVEL tied to however long stb stays asserted -- once a delayed
    //    ack makes the real master wait longer, that level, echoed through
    //    a plain shift register, produces a stale tail from the FIRST
    //    read bleeding into where the SECOND read's real ack belongs.
    //    Observed directly: a real page fault, RTL reading the first
    //    level's stale PDE where the second level's real PTE should have
    //    been.
    // 2. Delaying the REQUEST into RamWishboneAdapter instead (time-shift
    //    the whole cyc/stb/addr waveform) has the identical problem one
    //    level removed: the real master's own stb is ALSO held for the
    //    entire round trip now (however long that takes), so replaying
    //    that whole held duration through the delay still produces
    //    multiple acks for what both DCache.v and Ptw.v treat as one
    //    logical, m_ack-gated request (confirmed by reading DCache.v's own
    //    S_FILL/S_WB: `if (m_ack) ... else fill_word_r <= fill_word_r+1`
    //    -- it does NOT free-run one word per cycle, it waits for m_ack
    //    exactly like Ptw.v does between its two levels).
    //
    // The actual distinguishing signal between "still the same outstanding
    // request" and "a genuinely new one" is neither ack nor stb -- both
    // DCache.v and Ptw.v hold cyc/stb continuously across sub-requests and
    // only change ADDRESS when starting a new one. So: track the (addr, we)
    // of whatever request is currently being serviced; a live cyc&&stb
    // whose (addr, we) differs from that (or arrives with nothing currently
    // tracked) is a genuinely new request -- latch it, capture the FIRST
    // real ack/data RamWishboneAdapter produces for it (ram_ack_raw can
    // itself still be a multi-cycle level while the real master waits;
    // captured_this_req_r is the same "distinguish fresh from repeat"
    // one-shot-per-occupant discipline this project uses everywhere --
    // mem_stall_done_r, the docs/adr/0003 store-data assertion, DCache.v's
    // own served_addr_r), and delay EXPOSING that capture to the real
    // master by MEM_LATENCY_D cycles via MemoryLatencyModel's own
    // start/busy/done contract, retriggered by the same new-request pulse.
    // MEM_LATENCY_D==0: the mux below selects the live ack/data directly,
    // bit-exact with every phase before this one. UART/Timer slaves are
    // untouched -- this models memory latency specifically, not peripheral
    // latency.
    wire [XLEN-1:0] ram_data_raw;
    wire            ram_ack_raw;
    RamWishboneAdapter #(.SIZE_BYTES(MEM_SIZE_BYTES), .XLEN(XLEN), .DATA_INIT_FILE(DATA_INIT_FILE), .ZERO_INIT_LIMIT_OVERRIDE(ZERO_INIT_LIMIT_OVERRIDE)) m_DataMemory(
        .clk(clk), .rst(start),
        .s_cyc(wb_s_cyc[0]), .s_stb(wb_s_stb[0]), .s_we(wb_s_we),
        .s_addr(wb_s_addr), .s_data_o(wb_s_data_o), .s_sel(wb_s_sel),
        // docs/adr/00NN-mmu-sv32.md (Phase F5): wb_m_funct3 muxes in a
        // fixed word-width tag during a Ptw.v walk -- see the MMU
        // translation block above.
        .funct3(wb_m_funct3),
        .s_data_i(ram_data_raw), .s_ack(ram_ack_raw)
    );

    generate
    if (MEM_LATENCY_D == 0) begin : gen_dmem_latency_none
        assign wb_s_data_i[0*XLEN +: XLEN] = ram_data_raw;
        assign wb_s_ack[0] = ram_ack_raw;
    end else begin : gen_dmem_latency_added
        reg            req_active_r;
        reg [XLEN-1:0] req_addr_r;
        reg            req_we_r;
        wire is_new_request = wb_s_cyc[0] && wb_s_stb[0] &&
            (!req_active_r || wb_s_addr != req_addr_r || wb_s_we != req_we_r);

        wire delay_busy, delay_done;
        MemoryLatencyModel #(.LATENCY(MEM_LATENCY_D)) m_DMemLatency(
            .clk(clk), .rst(start),
            .start(is_new_request),
            .busy(delay_busy),
            .done(delay_done)
        );

        always @(posedge clk) begin
            if (~start) req_active_r <= 1'b0;
            else if (is_new_request) begin
                req_active_r <= 1'b1;
                req_addr_r   <= wb_s_addr;
                req_we_r     <= wb_s_we;
            end
            else if (delay_done) req_active_r <= 1'b0;
        end

        reg            captured_this_req_r;
        reg [XLEN-1:0] captured_data_r;
        always @(posedge clk) begin
            if (~start || is_new_request) captured_this_req_r <= 1'b0;
            else if (ram_ack_raw && !captured_this_req_r) begin
                captured_this_req_r <= 1'b1;
                captured_data_r     <= ram_data_raw;
            end
        end

        assign wb_s_data_i[0*XLEN +: XLEN] = captured_data_r;
        assign wb_s_ack[0] = delay_done;
    end
    endgenerate

    wire uart_irq;  // docs/adr/0034 Phase R: the PLIC-lite's sole external source -> mip.MEIP
    // Generation 2 (Phase M): Uart.v is deliberately fixed 32-bit (a tiny
    // MMIO peripheral has no reason to scale with XLEN) -- an intermediate
    // 32-bit wire plus an explicit zero-extending `assign` replaces what
    // used to be a direct (implicitly padded/pruned, and at XLEN=64
    // -Wall-noisy) port connection straight into the XLEN-wide
    // wb_s_addr/wb_s_data_o/wb_s_data_i bus wires. MMIO_BASE and every
    // UART register offset fit easily within 32 bits at any XLEN, so the
    // address truncation is exact, not lossy.
    wire [31:0] uart_s_data_i;
    Uart #(.CLKS_PER_BIT(UART_CLKS_PER_BIT)) m_Uart(
        .clk(clk), .rst(start),
        .s_cyc(wb_s_cyc[1]), .s_stb(wb_s_stb[1]), .s_we(wb_s_we),
        .s_addr(wb_s_addr[31:0]), .s_data_o(wb_s_data_o[31:0]), .s_sel(wb_s_sel),
        .s_data_i(uart_s_data_i), .s_ack(wb_s_ack[1]),
        .tx(uart_tx), .rx(uart_rx), .irq(uart_irq)
    );
    assign wb_s_data_i[1*XLEN +: XLEN] = {{(XLEN-32){1'b0}}, uart_s_data_i};

    wire timer_pending_w;   // docs/adr/0020 Phase D8: -> mip.MTIP
    wire msip_pending_w;    // docs/adr/0034 Phase R: -> mip.MSIP
    Timer #(.XLEN(XLEN)) m_Timer(
        .clk(clk), .rst(start),
        .s_cyc(wb_s_cyc[2]), .s_stb(wb_s_stb[2]), .s_we(wb_s_we),
        .s_addr(wb_s_addr), .s_data_o(wb_s_data_o), .s_sel(wb_s_sel),
        .s_data_i(wb_s_data_i[2*XLEN +: XLEN]), .s_ack(wb_s_ack[2]),
        .pending(timer_pending_w), .msip_pending(msip_pending_w)
    );
//
wire memtoReg_regwb;
wire regWrite_regwb;
wire fRegWrite_regwb;
wire valid_regwb;  // docs/adr/0027-formal-verification.md (Phase L2)
wire [XLEN-1:0] readData_regwb;
wire [XLEN-1:0] ALUOut_regwb;
wire [XLEN-1:0] readData_regem;
wire [REG_ADDR_WIDTH-1:0] write_to_Reg_regwb;
wire [XLEN-1:0] writeData_regwb;
wire jump_regwb;
wire [XLEN-1:0] pc_plus4_regwb;

//
reg4 #(.XLEN(XLEN), .NUM_REGS(NUM_REGS)) m_reg4(
    .clk(clk),
    .rst(start),
    .memtoReg_regem(memtoReg_regem),
    .regWrite_regem(regWrite_regem),
    .fRegWrite_regem(fRegWrite_regem),
    .valid_regem(valid_regem),  // docs/adr/0027-formal-verification.md (Phase L2)
    // docs/adr/0023-caches.md (Phase G6): under CACHE_WRITEBACK_SETASSOC,
    // the architectural WB-stage value comes from DCache.v's own captured
    // response (dcache_rdata_captured_r, defined in the MEM section above)
    // instead of the raw bus response -- see that register's own comment
    // for why a captured value, not DCache's live/transient resp_rdata, is
    // what reg4 must sample here.
    .readData((CACHE_MODE == CACHE_NONE) ? readData : dcache_rdata_captured_r),
    .ALUOut_regem(ALUOut_regem),
    .write_to_Reg_regem(write_to_Reg_regem),
    .jump_regem(jump_regem),
    .pc_plus4_regem(pc_plus4_regem),
    .isAmo_regem(isAmo_regem),
    .hold(mem_stall | amo_stall),   // MEM-stage interlock (docs/adr/0013): freeze reg4 while
                        // the load reg3 is holding hasn't come back from
                        // DataMemoryBRAM yet. A hold, not a bubble -- reg4 may
                        // currently hold an unrelated, already-complete
                        // instruction still within its MEM/WB forwarding
                        // window (needed by whatever's parked in reg2 during
                        // the stall), which must stay visible rather than
                        // being evicted a cycle early. See the ADR: an
                        // earlier bubble-based attempt broke exactly this
                        // case, caught by random cross-checking. docs/adr/0038:
                        // amo_stall joins it, same reasoning as reg3's own.
    .memtoReg_regwb(memtoReg_regwb),
    .regWrite_regwb(regWrite_regwb),
    .fRegWrite_regwb(fRegWrite_regwb),
    .valid_regwb(valid_regwb),
    .readData_regwb(readData_regwb),
    .ALUOut_regwb(ALUOut_regwb),
    .write_to_Reg_regwb(write_to_Reg_regwb),
    .jump_regwb(jump_regwb),
    .pc_plus4_regwb(pc_plus4_regwb),
    .isAmo_regwb(isAmo_regwb)
);
wire isAmo_regwb;  // docs/adr/0038-a-extension-phase-v.md

// ==========================================================================
// WB -- Writeback
// ==========================================================================
    wire [XLEN-1:0] writeData_regwb_mem_alu;
    Mux2to1 #(.size(XLEN)) m_Mux_WriteData(
    .sel(memtoReg_regwb),
    .s0(ALUOut_regwb),
    .s1(readData_regwb),
    .out(writeData_regwb_mem_alu)
    );

    // jal's result (PC+4) overrides the normal ALU/memory writeback value.
    wire [XLEN-1:0] writeData_regwb_mem_alu_jump;
    Mux2to1 #(.size(XLEN)) m_Mux_WriteData_Jump(
    .sel(jump_regwb),
    .s0(writeData_regwb_mem_alu),
    .s1(pc_plus4_regwb),
    .out(writeData_regwb_mem_alu_jump)
    );

    // docs/adr/0038-a-extension-phase-v.md: lr/sc/amo*'s own rd value is
    // the PRE-modification value the 2-phase MEM-stage interlock captured
    // during its own read phase (amo_captured_read_r), not readData_regwb
    // (that register's own ordinary load-capture timing doesn't line up
    // with an AMO's real 2-cycle-later retirement) or ALUOut_regwb (the
    // ALU only ever computed this instruction's own address, rs1+0).
    // Mutually exclusive with jump_regwb (isAmo/jump are never both set --
    // Control.v's own OPCODE_AMO/OPCODE_JAL arms are disjoint), so ordering
    // against the jal override above doesn't matter.
    assign writeData_regwb = isAmo_regwb ? amo_captured_read_r : writeData_regwb_mem_alu_jump;

    assign debug_x10 = m_Register.regs[10];
    assign debug_regwrite_commit = regWrite_regwb;
    assign debug_valid_commit = valid_regwb;
    assign debug_pc = pc_o;
    assign debug_priv_mode = priv_mode_w;
    assign debug_mcause = m_CSR.mcause;
    assign debug_jump_regde = jump_regde;
    assign debug_imm_sum = imm_sum;
    assign debug_inst_regfd = inst_regfd;
    assign debug_inst_raw = inst;
    assign debug_is_compressed = is_compressed;
    assign debug_inst_final = inst_final;
    assign debug_illegal_regde = illegalOpcode_regde;
    assign debug_inst_regde = inst_regde;
    assign debug_pc_o_regde = pc_o_regde;
    // docs/adr/0038: temporary debug -- one-hot-ish encoding of trap_cause's
    // own real source list, to distinguish which of the six real illegal-
    // instruction-cause conditions actually fired without adding six
    // separate taps.
    assign debug_trap_src = {2'b0, sfence_priv_violation, sret_priv_violation,
                              mret_priv_violation, csr_priv_violation,
                              (ALUCtl == `ALUCTL_ILLEGAL), dtlb_page_fault};
    assign debug_exception_taken = exception_taken;
    assign debug_trap_cause_raw = trap_cause;
    assign debug_x1 = m_Register.regs[1];
    assign debug_amo_active = amo_active;
    assign debug_amo_write_phase = amo_write_phase_r;
    assign debug_amo_write_done = amo_write_done_r;
    assign debug_amo_stall = amo_stall;
    assign debug_amo_captured_read = amo_captured_read_r;
    assign debug_x2 = m_Register.regs[2];
    assign debug_x4 = m_Register.regs[4];
    assign debug_x11 = m_Register.regs[11];
    assign debug_x12 = m_Register.regs[12];
    assign debug_x13 = m_Register.regs[13];
    assign debug_mtval = m_CSR.mtval;
    assign debug_satp = m_CSR.satp;
    assign debug_translate_enable = translate_enable;
    assign debug_itlb_hit = itlb_hit;
    assign debug_itlb_hit_fault = itlb_hit_fault;
    assign debug_ptw_busy = ptw_busy;
    assign debug_ptw_done = ptw_done;
    assign debug_ptw_fault = ptw_fault;
    assign debug_ptw_vaddr = ptw_vaddr;
    assign debug_ptw_m_addr = ptw_m_addr;

endmodule

`default_nettype wire
