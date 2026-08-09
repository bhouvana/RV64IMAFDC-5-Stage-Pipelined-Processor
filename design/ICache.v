`default_nettype none

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
    // docs/adr/0024-variable-latency-memory.md (Phase I4). Extra wait-state
    // cycles per fill word, 0 by default (bit-exact, one word per cycle,
    // matching every phase before this one). This module is the sole
    // consumer of its own private InstructionMemory instance below -- no
    // shared bus, no other master, so a plain single-outstanding
    // start/busy/done timer (MemoryLatencyModel's own contract) is
    // sufficient here, unlike the D-side's own MEM_LATENCY_D wrapper
    // (docs/adr/0024 Phase I2), which had to account for DCache.v/Ptw.v/
    // the raw LSU all sharing one real Wishbone bus.
    parameter MEM_LATENCY = 0
)(
    input clk,
    input rst,

    input      [XLEN-1:0] readAddr,   // physical address (post-translation) -- PIPT
    output     [XLEN-1:0] inst,       // valid when hit
    output                hit,        // combinational: does readAddr hit this cycle
    output                busy,       // a line fill is in progress
    output                done        // one-cycle pulse: a fill just completed
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
    assign set_idx = {SET_BITS{1'b0}};
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

assign hit  = |way_hit;
assign inst = inst_acc[WAYS];
wire [WAY_BITS-1:0] hit_way_idx = hit_way_acc[WAYS];

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

InstructionMemory #(.INIT_FILE(INIT_FILE), .SIZE_BYTES(IMEM_SIZE_BYTES), .XLEN(XLEN)) m_imem(
    .readAddr(imem_addr),
    .inst(imem_data)
);

assign busy = busy_r;
assign done = done_r;

// docs/adr/0024-variable-latency-memory.md (Phase I4). fillword_ready
// gates S_FILL's per-word capture/advance below -- tied 1'b1 combinationally
// at MEM_LATENCY==0 (bit-exact, one word per cycle, unchanged), otherwise
// driven by a MemoryLatencyModel instance retriggered once per word
// (start = (state==S_FILL) && !busy, naturally re-fires the cycle after
// each word's own done pulse). Generate-gated so MEM_LATENCY==0 callers
// (the overwhelming majority of existing tests) never need
// MemoryLatencyModel.v in their own include list.
wire fillword_ready;
generate
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

integer reset_i, reset_j;
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
        if (REPLACEMENT_POLICY == POLICY_LRU && hit)
            lru_touch(set_idx, hit_way_idx);

        case (state)
            S_IDLE: begin
                if (!hit) begin
                    fill_set_r  <= set_idx;
                    fill_tag_r  <= tag;
                    fill_way_r  <= (REPLACEMENT_POLICY == POLICY_LRU) ? lru_way_idx : victim[set_idx];
                    fill_base_r <= {readAddr[XLEN-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
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
