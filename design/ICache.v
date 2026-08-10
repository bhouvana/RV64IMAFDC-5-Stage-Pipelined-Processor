`default_nettype none

`include "wb_defs.vh"

// docs/adr/0023-caches.md (Phase G2). Set-associative, PIPT (indexed by the
// already-translated physical address -- this core's fetch is already PIPT
// today, see the ADR), read-only instruction cache. Standalone this phase
// (G2): a private, internal InstructionMemory.v instance (unmodified port --
// nothing else ever shares fetch's own backing memory, unlike DataMemoryBRAM.v,
// which Ptw.v shares with the LSU because page tables live in data memory),
// not yet wired into the live pipeline (G3's job). No dirty state, no
// writeback, no bus port -- I$ is pure fill/read, unlike DCache.v.
//
// Query is combinational and continuous (mirrors Tlb.v's own always-live
// query shape, not Divider.v/Ptw.v's explicit `start` contract) -- `hit`
// reflects whether `readAddr` hits *this* cycle, re-evaluated every cycle.
// On a miss with no fill already in progress, an internal FSM auto-starts a
// line fill (LINE_BYTES/4 sequential single-word reads, one word per cycle,
// against the private InstructionMemory instance) -- no external `start`
// signal needed, since nothing else contends for this module's own memory
// port the way Ptw.v/the LSU contend for the shared Wishbone bus.
//
// Replacement: round-robin (one small counter per set, not true LRU) --
// # ponytail: round-robin, not LRU -- upgrade to tree-PLRU only if a real
// hit-rate counter (G8) shows it matters. Functionally correct either way,
// only relative hit-rate differs.
//
// # ponytail: a fill already in progress for an address that's since been
// abandoned (a redirect un-stalled PC before the fill finished) always runs
// to completion rather than being restarted early for the new miss -- costs
// up to LINE_BYTES/4 extra stall cycles in the rare case of a miss
// immediately followed by a misprediction to a different missing line,
// never a correctness issue (valid/tag for the abandoned fill's line only
// commit at the very end, so a query against that same slot meanwhile still
// sees whatever was validly there before, not partial/torn data). Upgrade
// only if a real benchmark shows this measurably matters.
module ICache #(
    parameter INIT_FILE = "sim/programs/arith.mem",     // threaded to the
                                                           // private InstructionMemory
    parameter IMEM_SIZE_BYTES = 128,                     // backing memory size (matches
                                                           // PIPELINED's own MEM_SIZE_BYTES)
    parameter XLEN = 32,
    parameter WAYS = 4,             // must be >= 2 (round-robin victim counter needs $clog2(WAYS) >= 1)
    parameter CACHE_SIZE_BYTES = 4096,
    parameter LINE_BYTES = 16,      // must be a multiple of 4 (word-sized fetch)
    // docs/adr/0041-cache-replacement-policy-phase-b.md (Generation 4, Phase
    // B). POLICY_ROUND_ROBIN (0, default): today's exact behavior, bit-exact.
    // POLICY_FIFO (1): identical mechanism to POLICY_ROUND_ROBIN (both select
    // the non-LRU branch below -- round-robin already IS FIFO-by-fill-order
    // at this associativity). POLICY_LRU (2): true per-way access-recency
    // tracking via the new age[] array below.
    parameter REPLACEMENT_POLICY = 0,
    // Generation 4, Phase C (docs/adr/0042-victim-cache-phase-c.md): entry
    // count for a small fully-associative victim buffer. 0 = disabled,
    // bit-exact with pre-Phase-C behavior. Not yet consumed anywhere as of
    // this commit.
    parameter VICTIM_ENTRIES = 0,
    // docs/adr/0024-variable-latency-memory.md (Phase I4). Extra wait-state
    // cycles per fill word, 0 by default (bit-exact, one word per cycle,
    // matching every phase before this one). This module is the sole
    // consumer of its own private InstructionMemory instance below -- no
    // shared bus, no other master, so a plain single-outstanding
    // start/busy/done timer (MemoryLatencyModel's own contract) is
    // sufficient here, unlike the D-side's own MEM_LATENCY_D wrapper
    // (docs/adr/0024 Phase I2), which had to account for DCache.v/Ptw.v/
    // the raw LSU all sharing one real Wishbone bus.
    parameter MEM_LATENCY = 0,
    // docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). 0 (default):
    // today's exact private-InstructionMemory-direct-fill path, byte-for-
    // byte unchanged. 1: fill words are fetched over a real Wishbone-master
    // bus port instead (below), targeting an L2Cache.v instance -- the
    // private InstructionMemory instance is not even instantiated in this
    // case (generate-gated, mirrors VICTIM_ENTRIES==0's own "don't
    // instantiate what isn't used" discipline).
    parameter L2_ENABLE = 0,
    // Generation 4, Phase G (docs/adr/0046-hardware-prefetchers-phase-g.md).
    // 0 (default, PF_OFF) = disabled, bit-exact with pre-Phase-G behavior.
    // Only meaningful when L2_ENABLE=1 -- under L2_ENABLE=0 there's no real
    // miss latency to hide (the private InstructionMemory instance is
    // always-combinational), so prefetching there would only cost FSM-busy
    // cycles for no benefit. Documented no-op otherwise, same "meaningless
    // without X" convention `--compare-l2`/`--compare-burst` already use.
    parameter PREFETCH_MODE = 0
)(
    input clk,
    input rst,

    input      [XLEN-1:0] readAddr,   // physical address (post-translation) -- PIPT
    output     [XLEN-1:0] inst,       // valid when hit
    output                hit,        // combinational: does readAddr hit this cycle
    output                busy,       // a line fill is in progress
    output                done,       // one-cycle pulse: a fill just completed

    // docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). Inclusion
    // probe responder -- same shape/precedent as DCache.v's own copy, but
    // simpler: I$ is read-only, nothing to pull back, so no probe_dirty/
    // probe_data ports exist here at all. Permanently dark when a caller
    // ties probe_req=0 (the default, every existing testbench).
    input                 probe_req,
    input      [XLEN-1:0] probe_addr,
    output                probe_ack,

    // docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). New
    // Wishbone-master bus port, only meaningful when L2_ENABLE=1 -- read-
    // only (no m_we/m_data_o at all; a caller wiring this to an L2Cache.v
    // instance's own u_* slave port ties u_we=1'b0/u_data_o={XLEN{1'b0}}
    // directly at the instantiation site, since I$ never writes).
    output                          m_cyc,
    output                          m_stb,
    output     [XLEN-1:0]           m_addr,
    output     [`WB_SEL_WIDTH-1:0]  m_sel,
    output     [2:0]                m_funct3,
    input      [XLEN-1:0]           m_data_i,
    input                           m_ack
);

localparam LINE_WORDS   = LINE_BYTES / 4;
localparam NUM_LINES    = CACHE_SIZE_BYTES / LINE_BYTES;
localparam NUM_SETS     = NUM_LINES / WAYS;
localparam SET_BITS     = $clog2(NUM_SETS);
localparam OFFSET_BITS  = $clog2(LINE_BYTES);   // covers byte-in-word(2) + word-in-line
localparam WORD_OFF_BITS = OFFSET_BITS - 2;
localparam TAG_BITS     = XLEN - SET_BITS - OFFSET_BITS;
localparam WAY_BITS     = $clog2(WAYS);

// REPLACEMENT_POLICY values -- named purely for readability at the sites
// that consume this parameter below (docs/adr/0041).
localparam POLICY_ROUND_ROBIN = 0;
localparam POLICY_FIFO        = 1;
localparam POLICY_LRU         = 2;

// PREFETCH_MODE values (docs/adr/0046) -- same enum DCache.v's own copy uses.
localparam PF_OFF       = 0;
localparam PF_NEXT_LINE = 1;
localparam PF_STRIDE    = 2;
localparam PF_STREAM    = 3;

wire [WORD_OFF_BITS-1:0] word_off = readAddr[OFFSET_BITS-1:2];
// docs/adr/0041. Fixed: a fully-associative (1-set, WAYS==NUM_LINES)
// configuration has SET_BITS==0, and readAddr[OFFSET_BITS+SET_BITS-1:
// OFFSET_BITS] then reverses to readAddr[OFFSET_BITS-1:OFFSET_BITS] -- an
// invalid (high<low) part-select. A plain `generate if` (elaboration-time,
// unlike a runtime `?:` ternary, which would still elaborate the invalid
// branch's expression) sidesteps the bad part-select entirely for that
// case, tying set_idx to its only possible value (0). Found while
// designing docs/adr/0041's own testbench; pre-existing, unrelated to
// REPLACEMENT_POLICY -- no existing test before this phase used a
// fully-associative sizing to hit it.
wire [SET_BITS-1:0]      set_idx;
generate
if (SET_BITS == 0) begin : gen_set_idx_fully_assoc
    assign set_idx = 1'b0;
end else begin : gen_set_idx_normal
    assign set_idx = readAddr[OFFSET_BITS+SET_BITS-1:OFFSET_BITS];
end
endgenerate
wire [TAG_BITS-1:0]      tag      = readAddr[XLEN-1:OFFSET_BITS+SET_BITS];

reg                 valid   [0:NUM_LINES-1];
reg [TAG_BITS-1:0]  tag_arr [0:NUM_LINES-1];
reg [XLEN-1:0]      data_arr[0:NUM_LINES*LINE_WORDS-1];
reg [WAY_BITS-1:0]  victim  [0:NUM_SETS-1];   // per-set round-robin fill pointer
// docs/adr/0041. Per-set, per-way access-recency rank: 0=most-recently-used,
// WAYS-1=least-recently-used. Only consumed under POLICY_LRU.
// ponytail: age[] update always runs regardless of REPLACEMENT_POLICY,
// never gated on ==POLICY_LRU -- cheaper than an extra generate branch, and
// harmless since nothing reads age[] under the other two policies.
reg [WAY_BITS-1:0]  age     [0:NUM_SETS-1][0:WAYS-1];

// Combinational, N-way tag compare -- same shape as Tlb.v's own
// hit = valid[index] && tag[index]==query, generalized across WAYS via
// `generate`/`assign` (MuxN.v's own convention) rather than a procedural
// `always @*` for-loop -- Icarus treats a loop that reads an *unpacked*
// array inside `always @*` as "sensitive to every word in the array" and
// warns on it (harmless in practice, since the loop bound is fixed at
// elaboration time, but this project's own verification bar requires a
// zero-warning compile). Since at most one way can ever validly hit (tags
// are unique within a set by construction), an OR-of-AND-masked reduction
// correctly selects that way's data (or 0 if none hit) with no priority
// logic needed.
genvar gw;
wire [WAYS-1:0]    way_hit;
wire [XLEN-1:0]     way_data [0:WAYS-1];
wire [XLEN-1:0]     inst_acc [0:WAYS];
// docs/adr/0041. Same accumulator-reduction shape as inst_acc above, just
// producing the winning way's own index instead of its data -- needed so
// POLICY_LRU knows WHICH way a hit touched.
wire [WAY_BITS-1:0] hit_way_acc [0:WAYS];
assign inst_acc[0]    = {XLEN{1'b0}};
assign hit_way_acc[0] = {WAY_BITS{1'b0}};
generate
    for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_way_compare
        assign way_hit[gw]  = valid[set_idx*WAYS + gw] && (tag_arr[set_idx*WAYS + gw] == tag);
        assign way_data[gw] = data_arr[(set_idx*WAYS + gw)*LINE_WORDS + word_off];
        assign inst_acc[gw+1]    = inst_acc[gw]    | (way_hit[gw] ? way_data[gw]     : {XLEN{1'b0}});
        assign hit_way_acc[gw+1] = hit_way_acc[gw] | (way_hit[gw] ? gw[WAY_BITS-1:0] : {WAY_BITS{1'b0}});
    end
endgenerate

wire hit_main = |way_hit;
wire [WAY_BITS-1:0] hit_way_idx = hit_way_acc[WAYS];

// docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). Same second,
// independent tag/set decode + N-way compare DCache.v's own copy uses --
// see its header comment for the full rationale (a probe can target a
// completely different address than whatever the main FSM is servicing).
localparam LINE_IDX_BITS = SET_BITS + WAY_BITS;
wire [SET_BITS-1:0] probe_set_idx;
generate
if (SET_BITS == 0) begin : gen_probe_set_idx_fully_assoc
    assign probe_set_idx = 1'b0;
end else begin : gen_probe_set_idx_normal
    assign probe_set_idx = probe_addr[OFFSET_BITS+SET_BITS-1:OFFSET_BITS];
end
endgenerate
wire [TAG_BITS-1:0] probe_tag = probe_addr[XLEN-1:OFFSET_BITS+SET_BITS];
wire [WAYS-1:0]          probe_way_hit;
wire [LINE_IDX_BITS-1:0] probe_lineidx_acc[0:WAYS];
assign probe_lineidx_acc[0] = {LINE_IDX_BITS{1'b0}};
generate
    for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_probe_compare
        assign probe_way_hit[gw] = valid[probe_set_idx*WAYS + gw] && (tag_arr[probe_set_idx*WAYS + gw] == probe_tag);
        assign probe_lineidx_acc[gw+1] = probe_lineidx_acc[gw] | (probe_way_hit[gw] ? (probe_set_idx*WAYS + gw) : {LINE_IDX_BITS{1'b0}});
    end
endgenerate
wire probe_found = |probe_way_hit;
wire [LINE_IDX_BITS-1:0] probe_found_line = probe_lineidx_acc[WAYS];
// Combinational, from ANY state (see the unconditional probe-service block
// above the case(state) for why -- a real deadlock, found by running,
// gating this on state==S_IDLE), unconditionally (found or not) -- mirrors
// DCache.v's own probe_ack precedent exactly.
assign probe_ack = probe_req;

// docs/adr/0046-hardware-prefetchers-phase-g.md (Generation 4, Phase G).
// Fires the predictor on every genuine backing-store miss (the S_IDLE
// `!hit_main && !vc_lookup_hit` fork below -- a real bus-triggering miss,
// not a victim-buffer promote). See Prefetcher.v's own header for why this
// is a single-global-entry predictor, not a PC-indexed table.
wire icache_pf_update_valid = (state == S_IDLE) && !hit_main && !vc_lookup_hit;
wire [XLEN-1:0] icache_pf_update_addr = {readAddr[XLEN-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
wire pf_valid_w;
wire [XLEN-1:0] pf_addr_w;
Prefetcher #(.XLEN(XLEN), .LINE_BYTES(LINE_BYTES), .MODE(PREFETCH_MODE)) m_prefetcher(
    .clk(clk), .rst(rst),
    .update_valid(icache_pf_update_valid),
    .update_addr(icache_pf_update_addr),
    .pf_valid(pf_valid_w), .pf_addr(pf_addr_w)
);

// Same second, independent tag/set decode + N-way compare the probe port
// above already establishes, mirrored against the PREDICTED address.
wire [SET_BITS-1:0] pf_set_idx;
generate
if (SET_BITS == 0) begin : gen_pf_set_idx_fully_assoc
    assign pf_set_idx = 1'b0;
end else begin : gen_pf_set_idx_normal
    assign pf_set_idx = pf_addr_w[OFFSET_BITS+SET_BITS-1:OFFSET_BITS];
end
endgenerate
wire [TAG_BITS-1:0] pf_tag = pf_addr_w[XLEN-1:OFFSET_BITS+SET_BITS];

wire [WAYS-1:0] pf_way_hit;
generate
    for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_pf_compare
        assign pf_way_hit[gw] = valid[pf_set_idx*WAYS + gw] && (tag_arr[pf_set_idx*WAYS + gw] == pf_tag);
    end
endgenerate
wire pf_found = |pf_way_hit;

// Victim-way choice for the PREDICTED set -- same POLICY_LRU/round-robin
// choice victim_target_way already makes for readAddr's own set, mirrored
// for pf_set_idx. No dirty guard needed -- I$ has no dirty bit, any
// currently-resident line is safe to evict.
wire [WAYS-1:0]     pf_is_lru_way;
wire [WAY_BITS-1:0] pf_lru_way_acc [0:WAYS];
assign pf_lru_way_acc[0] = {WAY_BITS{1'b0}};
generate
    for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_pf_lru_victim
        assign pf_is_lru_way[gw]    = (age[pf_set_idx][gw] == WAYS-1);
        assign pf_lru_way_acc[gw+1] = pf_lru_way_acc[gw] | (pf_is_lru_way[gw] ? gw[WAY_BITS-1:0] : {WAY_BITS{1'b0}});
    end
endgenerate
wire [WAY_BITS-1:0] pf_victim_way = (REPLACEMENT_POLICY == POLICY_LRU) ? pf_lru_way_acc[WAYS] : victim[pf_set_idx];

// docs/adr/0046-hardware-prefetchers-phase-g.md (Generation 4, Phase G). The
// IMEM_SIZE_BYTES bound (`pf_addr_w <= IMEM_SIZE_BYTES-LINE_BYTES`) reuses
// this module's OWN existing IMEM_SIZE_BYTES parameter -- already the real
// backing-memory size, no new parameter needed here. See DCache.v's own
// identical MEM_SIZE_BYTES bound for the real deadlock this prevents (a
// predicted line past the end of real memory gets no bus ack at all,
// hanging the whole pipeline forever -- found by running, not anticipated).
wire prefetch_fire = (PREFETCH_MODE != PF_OFF) && L2_ENABLE && pf_valid_w && !pf_found
    && (pf_addr_w <= (IMEM_SIZE_BYTES - LINE_BYTES));

// docs/adr/0042. `hit` (the module's own external port) now also reflects
// a victim-buffer promote hit -- see the victim-cache block below for
// vc_lookup_hit. `hit_main` (main-array-only) stays the name every
// pre-existing use in THIS file needs (lru_touch's own hit branch, the
// S_IDLE miss/promote fork) -- only the external port broadens.
assign hit  = hit_main | vc_lookup_hit;
assign inst = hit_main ? inst_acc[WAYS] : vc_word_at_offset;

// docs/adr/0041. POLICY_LRU's own victim choice: the way whose age[] entry
// is genuinely WAYS-1 (least-recently-used) for the set a miss is about to
// fill into. Same OR-of-AND-masked reduction shape as way_hit/inst_acc
// above -- safe because lru_touch (below) maintains age[] as a real total
// order, so exactly one way ever holds WAYS-1 at a time.
wire [WAYS-1:0]     is_lru_way;
wire [WAY_BITS-1:0] lru_way_acc [0:WAYS];
assign lru_way_acc[0] = {WAY_BITS{1'b0}};
generate
    for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_lru_victim
        assign is_lru_way[gw]    = (age[set_idx][gw] == WAYS-1);
        assign lru_way_acc[gw+1] = lru_way_acc[gw] | (is_lru_way[gw] ? gw[WAY_BITS-1:0] : {WAY_BITS{1'b0}});
    end
endgenerate
wire [WAY_BITS-1:0] lru_way_idx = lru_way_acc[WAYS];

// docs/adr/0042-victim-cache-phase-c.md (Generation 4, Phase C). A small,
// fully-associative buffer for lines just evicted from THIS cache -- see
// VictimCache.v's own header for the full design rationale. Wired as a
// same-cycle combinational extension of `hit`/`inst` (not a new FSM state):
// a victim-buffer hit needs no backing-store access at all, so it resolves
// exactly as fast as an ordinary hit (pc_stall's own icache_miss term in
// riscvpipeline.v is purely `!icache_hit`, so this costs zero extra stall
// cycles). Disabled (VICTIM_ENTRIES==0) ties vc_lookup_hit to 0, bit-exact
// with pre-Phase-C behavior -- mirrors the SET_BITS==0 generate-if guard
// above (an elaboration-time `generate if`, not a runtime ternary, since
// ENTRIES==0 would otherwise still elaborate an invalid $clog2(0)-1 width).
localparam VC_TAG_WIDTH = TAG_BITS + SET_BITS;
wire [VC_TAG_WIDTH-1:0] vc_lookup_tag = {tag, set_idx};
wire vc_lookup_hit;
wire [XLEN*LINE_WORDS-1:0] vc_lookup_data;

// The way about to be displaced by a miss OR a promote -- same choice
// either way (round-robin/LRU doesn't distinguish "displaced by a real
// fill" from "displaced by a victim-buffer promote", both are just "this
// set's own next eviction target").
wire [WAY_BITS-1:0] victim_target_way = (REPLACEMENT_POLICY == POLICY_LRU) ? lru_way_idx : victim[set_idx];

// Whatever currently occupies (set_idx, victim_target_way) -- read
// combinationally (data_arr/tag_arr are plain regs, same as way_data's own
// combinational read above) regardless of whether it's actually valid.
// Only ever pushed into the victim buffer when genuinely valid (see
// vc_do_insert below) -- a promote's own vc_do_swap is unconditional
// because a real invariant rules out the alternative: victim_target_way
// can only ever point at a still-invalid (never-filled) way during a
// set's own cold ramp-up, during which nothing could have been evicted
// FROM that set into the victim buffer yet either (round-robin/LRU both
// exhaust every way at least once before ever re-selecting one), so
// vc_lookup_hit for that set is provably impossible while
// victim_target_way is invalid. Full derivation in docs/adr/0042.
wire [TAG_BITS-1:0]     vc_outgoing_tag_bits = tag_arr[set_idx*WAYS + victim_target_way];
wire [VC_TAG_WIDTH-1:0] vc_outgoing_tag      = {vc_outgoing_tag_bits, set_idx};
wire [XLEN*LINE_WORDS-1:0] vc_outgoing_data;
generate
    for (gw = 0; gw < LINE_WORDS; gw = gw + 1) begin : gen_vc_outgoing
        assign vc_outgoing_data[gw*XLEN +: XLEN] = data_arr[(set_idx*WAYS + victim_target_way)*LINE_WORDS + gw];
    end
endgenerate

wire vc_do_swap   = (state == S_IDLE) && !hit_main && vc_lookup_hit;
wire vc_do_insert = (state == S_IDLE) && !hit_main && !vc_lookup_hit
                     && valid[set_idx*WAYS + victim_target_way];

generate
if (VICTIM_ENTRIES == 0) begin : gen_victim_disabled
    assign vc_lookup_hit  = 1'b0;
    assign vc_lookup_data = {(XLEN*LINE_WORDS){1'b0}};
end else begin : gen_victim_enabled
    VictimCache #(.ENTRIES(VICTIM_ENTRIES), .WITH_DIRTY(0), .TAG_WIDTH(VC_TAG_WIDTH),
                  .LINE_WORDS(LINE_WORDS), .XLEN(XLEN)) m_victim(
        .clk(clk), .rst(rst),
        .lookup_tag(vc_lookup_tag), .lookup_hit(vc_lookup_hit), .lookup_data(vc_lookup_data), .lookup_dirty(),
        .do_swap(vc_do_swap), .swap_in_tag(vc_outgoing_tag), .swap_in_data(vc_outgoing_data), .swap_in_dirty(1'b0),
        .do_insert(vc_do_insert), .insert_tag(vc_outgoing_tag), .insert_data(vc_outgoing_data), .insert_dirty(1'b0),
        .evict_out_valid(), .evict_out_tag(), .evict_out_data(), .evict_out_dirty()
        // I$ is read-only -- an evicted victim-buffer entry (buffer full)
        // is just discarded, no dirty data ever exists to lose.
    );
end
endgenerate

wire [XLEN-1:0] vc_word_at_offset = vc_lookup_data[word_off*XLEN +: XLEN];

// Fill engine.
localparam S_IDLE = 1'b0;
localparam S_FILL = 1'b1;

reg                        state;
reg [XLEN-1:0]             fill_base_r;   // line-aligned base address, latched once at fill-start
reg [SET_BITS-1:0]         fill_set_r;
reg [TAG_BITS-1:0]         fill_tag_r;
reg [WAY_BITS-1:0]         fill_way_r;
reg [WORD_OFF_BITS-1:0]    fill_word_r;
reg                        busy_r, done_r;

wire [XLEN-1:0] imem_addr = fill_base_r + {{(XLEN-OFFSET_BITS){1'b0}}, fill_word_r, 2'b00};
wire [XLEN-1:0] imem_data;

assign busy = busy_r;
assign done = done_r;

// docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). L2_ENABLE==0
// (default): the EXISTING private-InstructionMemory-direct-fill path,
// completely unchanged -- including the existing MEM_LATENCY wait-state
// wrapper (docs/adr/0024-variable-latency-memory.md, Phase I4), nested
// inside this same branch. The new bus-master output port is simply tied
// off/idle here.
// L2_ENABLE==1: `imem_data`/`fillword_ready` are re-sourced from a real
// Wishbone-master transaction instead -- S_FILL's own case-statement logic
// below is UNCHANGED either way, it only ever consumes these two signals by
// name. No separate FSM needed: `m_cyc` held for the whole S_FILL service
// (mirrors DCache.v/L2Cache.v's own `m_cyc = (state==S_FILL)` shape),
// `fillword_ready` IS `m_ack` directly (one pulse per word, the same
// granularity S_FILL's own fill_word_r loop already advances at).
// docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). Kept
// UNCONDITIONALLY instantiated (not inside the L2_ENABLE generate split
// below) on purpose -- mirrors riscvpipeline.v's own documented reason for
// keeping RamWishboneAdapter.v's instance name (`dut.m_DataMemory`) outside
// any generate branch: several existing testbenches (tb_icache_unit.v and
// others) poke `dut.m_imem.insts[...]` by hierarchical reference, which a
// generate-block wrapper would silently rename (e.g. to
// `dut.gen_l2_disabled.m_imem...`), breaking every one of them -- a real
// regression found by running the full suite while first implementing this
// phase, not a theoretical concern. Harmless at L2_ENABLE=1 (simply unused,
// its own small IMEM_SIZE_BYTES-sized array going untouched).
InstructionMemory #(.INIT_FILE(INIT_FILE), .SIZE_BYTES(IMEM_SIZE_BYTES), .XLEN(XLEN)) m_imem(
    .readAddr(imem_addr),
    .inst(imem_data_priv)
);
wire [XLEN-1:0] imem_data_priv;

wire fillword_ready;
generate
if (L2_ENABLE == 0) begin : gen_l2_disabled
    assign m_cyc    = 1'b0;
    assign m_stb    = 1'b0;
    assign m_addr   = {XLEN{1'b0}};
    assign m_sel    = {`WB_SEL_WIDTH{1'b0}};
    assign m_funct3 = 3'b000;
    assign imem_data = imem_data_priv;

    // docs/adr/0024-variable-latency-memory.md (Phase I4). fillword_ready
    // gates S_FILL's per-word capture/advance below -- tied 1'b1
    // combinationally at MEM_LATENCY==0 (bit-exact, one word per cycle,
    // unchanged), otherwise driven by a MemoryLatencyModel instance
    // retriggered once per word (start = (state==S_FILL) && !busy,
    // naturally re-fires the cycle after each word's own done pulse).
    // Generate-gated so MEM_LATENCY==0 callers (the overwhelming majority
    // of existing tests) never need MemoryLatencyModel.v in their own
    // include list.
    if (MEM_LATENCY == 0) begin : gen_fill_latency_none
        assign fillword_ready = 1'b1;
    end else begin : gen_fill_latency_added
        wire fillword_latency_busy;
        MemoryLatencyModel #(.LATENCY(MEM_LATENCY)) m_FillLatency(
            .clk(clk), .rst(rst),
            .start((state == S_FILL) && !fillword_latency_busy),
            .busy(fillword_latency_busy),
            .done(fillword_ready)
        );
    end
end else begin : gen_l2_enabled
    assign m_cyc    = (state == S_FILL);
    assign m_stb    = m_cyc;
    assign m_addr   = imem_addr;
    assign m_sel    = {`WB_SEL_WIDTH{1'b1}};
    assign m_funct3 = 3'b010;
    assign fillword_ready = m_ack;
    assign imem_data = m_data_i;
end
endgenerate

// docs/adr/0041. Standard LRU-stack update: the touched way becomes rank 0
// (MRU); every way that was more-recently-used than it (age < its OLD age)
// ages by one step to make room. Task calls containing non-blocking
// assignments, invoked from inside the always @(posedge clk) block below,
// are ordinary, legal Verilog.
task lru_touch;
    input [SET_BITS-1:0] t_set;
    input [WAY_BITS-1:0] t_way;
    integer k;
    begin
        for (k = 0; k < WAYS; k = k + 1) begin
            if (k[WAY_BITS-1:0] == t_way)
                age[t_set][k] <= {WAY_BITS{1'b0}};
            else if (age[t_set][k] < age[t_set][t_way])
                age[t_set][k] <= age[t_set][k] + 1'b1;
        end
    end
endtask

integer reset_i, reset_j, vcw;
always @(posedge clk) begin
    if (~rst) begin
        state  <= S_IDLE;
        busy_r <= 1'b0;
        done_r <= 1'b0;
        for (reset_i = 0; reset_i < NUM_LINES; reset_i = reset_i + 1)
            valid[reset_i] <= 1'b0;
        for (reset_i = 0; reset_i < NUM_SETS; reset_i = reset_i + 1) begin
            victim[reset_i] <= {WAY_BITS{1'b0}};
            // docs/adr/0041. Arbitrary-but-valid initial total order (any
            // deterministic starting state is fine -- only relative order
            // after real accesses matters, same convention victim[]'s own
            // reset-to-0 already established).
            for (reset_j = 0; reset_j < WAYS; reset_j = reset_j + 1)
                age[reset_i][reset_j] <= reset_j[WAY_BITS-1:0];
        end
    end
    else begin
        done_r <= 1'b0;   // default: one-cycle pulse, cleared unless set below

        // docs/adr/0041. POLICY_LRU: touch the hit way every cycle `hit`
        // holds -- idempotent once already MRU (age[touched]==0 already, so
        // nothing else has a smaller age to increment past), safe to
        // evaluate every cycle regardless of FSM state, since `hit` is
        // combinational against `readAddr` independent of any in-progress
        // fill for a different line.
        // docs/adr/0042. Split into two arms: a real main-array hit touches
        // hit_way_idx (the way way_hit[] actually matched, unchanged from
        // before this phase); a victim-buffer promote hit touches
        // victim_target_way instead -- hit_way_idx would be meaningless
        // here (way_hit[] is all-zero for a main-array miss, so the old
        // single-condition `hit` check would have silently touched way 0
        // of every set on every victim-hit, corrupting LRU state for a way
        // that was never actually accessed).
        if (REPLACEMENT_POLICY == POLICY_LRU) begin
            if (hit_main)
                lru_touch(set_idx, hit_way_idx);
            else if (vc_lookup_hit)
                lru_touch(set_idx, victim_target_way);
        end

        // docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F).
        // UNCONDITIONAL, decoupled from `state`/case(state) below entirely --
        // same real deadlock DCache.v's own copy of this comment documents
        // (found by running DCache.v's own version first): gating this on
        // state==S_IDLE meant ICache could never answer a probe while itself
        // busy (S_FILL) waiting on a request to L2 that L2's own eviction
        // pressure might need to probe THIS module for. Fixed identically.
        if (probe_req) begin
            if (probe_found)
                valid[probe_found_line] <= 1'b0;
        end

        case (state)
            S_IDLE: begin
                if (!hit_main) begin
                    if (vc_lookup_hit) begin
                        // docs/adr/0042. Promote: commit the victim
                        // buffer's own line straight into the main array
                        // THIS cycle -- no InstructionMemory access needed,
                        // so this resolves exactly as fast as an ordinary
                        // hit (state never leaves S_IDLE). vc_do_swap (a
                        // plain combinational wire, not a registered pulse)
                        // fires m_victim's own swap on this SAME edge.
                        for (vcw = 0; vcw < LINE_WORDS; vcw = vcw + 1)
                            data_arr[(set_idx*WAYS + victim_target_way)*LINE_WORDS + vcw] <= vc_lookup_data[vcw*XLEN +: XLEN];
                        tag_arr[set_idx*WAYS + victim_target_way] <= tag;
                        valid[set_idx*WAYS + victim_target_way]   <= 1'b1;
                        victim[set_idx] <= (victim_target_way == WAYS-1) ? {WAY_BITS{1'b0}} : victim_target_way + 1'b1;
                        done_r <= 1'b1;
                    end
                    else begin
                        // Genuine backing-store miss -- unchanged from
                        // pre-Phase-C behavior, except vc_do_insert (above)
                        // now also feeds this same eviction into the victim
                        // buffer whenever the outgoing line is real (valid).
                        fill_set_r  <= set_idx;
                        fill_tag_r  <= tag;
                        fill_way_r  <= victim_target_way;
                        fill_base_r <= {readAddr[XLEN-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
                        fill_word_r <= {WORD_OFF_BITS{1'b0}};
                        busy_r      <= 1'b1;
                        state       <= S_FILL;
                    end
                end
                // docs/adr/0046-hardware-prefetchers-phase-g.md (Generation
                // 4, Phase G). Only reached when hit_main is true (a real
                // hit this cycle, no promote in progress) -- a genuinely
                // idle S_IDLE cycle. Reuses the SAME S_FILL completion logic
                // below verbatim: the array-commit (data_arr/valid/tag_arr/
                // victim/age) and done_r pulse are correct and harmless for
                // a prefetch fill too (busy_r/done_r are proven-dead wires
                // externally, see docs/adr/0046's own Design section).
                else if (prefetch_fire) begin
                    fill_set_r  <= pf_set_idx;
                    fill_tag_r  <= pf_tag;
                    fill_way_r  <= pf_victim_way;
                    fill_base_r <= pf_addr_w;
                    fill_word_r <= {WORD_OFF_BITS{1'b0}};
                    busy_r      <= 1'b1;
                    state       <= S_FILL;
                end
            end

            S_FILL: begin
                if (fillword_ready) begin
                    data_arr[(fill_set_r*WAYS + fill_way_r)*LINE_WORDS + fill_word_r] <= imem_data;
                    if (fill_word_r == LINE_WORDS-1) begin
                        valid[fill_set_r*WAYS + fill_way_r]   <= 1'b1;
                        tag_arr[fill_set_r*WAYS + fill_way_r] <= fill_tag_r;
                        victim[fill_set_r] <= (fill_way_r == WAYS-1) ? {WAY_BITS{1'b0}} : fill_way_r + 1'b1;
                        if (REPLACEMENT_POLICY == POLICY_LRU)
                            lru_touch(fill_set_r, fill_way_r);
                        busy_r <= 1'b0;
                        done_r <= 1'b1;
                        state  <= S_IDLE;
                    end
                    else begin
                        fill_word_r <= fill_word_r + 1'b1;
                    end
                end
            end
        endcase
    end
end

endmodule

`default_nettype wire
