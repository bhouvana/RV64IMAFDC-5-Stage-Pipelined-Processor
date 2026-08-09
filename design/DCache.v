`default_nettype none

`include "wb_defs.vh"

// docs/adr/0023-caches.md (Phase G4). Set-associative, PIPT, write-back +
// write-allocate data cache. Standalone this phase (G4): its own Wishbone-
// master-shaped fill/writeback port, built to match RamWishboneAdapter.v's
// real ack timing (same discipline Ptw.v's own standalone phase, F4, used),
// not yet wired into the live pipeline or muxed onto the shared bus (G6's
// job). Two separate modules, not one unified Cache.v with ICache.v --
// unlike Tlb.v's single-array-two-ports unification (I-side/D-side
// translation do the *identical* thing to the *identical* storage), I$ and
// D$ diverge on the axis that mattered there: write policy. I$ is pure
// fill/read; D$ needs dirty bits, byte-merge-on-store, and an eviction/
// flush writeback engine ICache.v has no use for at all.
//
// Replacement: round-robin (one small counter per set, not true LRU) --
// # ponytail: round-robin, not LRU -- same rationale as ICache.v's own
// comment. WAYS must be a power of 2 (same table-sizing convention this
// project already uses for Bht.v/Btb.v/Tlb.v) -- line_idx = set*WAYS+way
// is reconstructed by plain bit-slicing (flush's own address
// reconstruction below), which only works exactly if WAYS divides evenly
// on a power-of-2 boundary.
//
// Sub-word access (sb/sh/lb/lh/lbu/lhu) assumes natural alignment (a
// halfword access's byte offset is 0 or 2, never crossing a word
// boundary) -- matches sim/tools/random_gen.py's own "width-appropriate-
// aligned offset" generation convention and every existing test program;
// this project's DataMemoryBRAM.v coincidentally tolerates a misaligned
// halfword (its flat byte array reads 4 bytes starting at the exact byte
// address, crossing a word boundary if unaligned) but nothing here has
// ever relied on that, and a real cache's per-word storage has no
// equivalent affordance to build without real complexity for a case
// nothing exercises.
//
// CPU-side request/response mirrors DataMemoryBRAM.v's own shape
// (req_read/req_write held by the caller for the whole access, same as
// memRead/memWrite): a hit-write acks combinationally, same cycle, same as
// RamWishboneAdapter.v's own real "writes never stall" precedent; a
// hit-read takes exactly 1 registered cycle, bit-identical to
// DataMemoryBRAM.v's own real read latency; a miss (read OR write, since
// write-allocate means a store can miss too) takes a full line fill
// (LINE_BYTES/4 cycles), plus a full line writeback first if the victim
// way is dirty.
module DCache #(
    parameter XLEN = 32,
    parameter WAYS = 4,
    parameter CACHE_SIZE_BYTES = 4096,
    parameter LINE_BYTES = 16,
    // docs/adr/0041-cache-replacement-policy-phase-b.md (Generation 4, Phase
    // B). Same closed enum ICache.v's own REPLACEMENT_POLICY uses (see its
    // header comment for the full POLICY_ROUND_ROBIN/FIFO/LRU rationale --
    // not repeated here to avoid drift between two independently-maintained
    // copies of the same explanation).
    parameter REPLACEMENT_POLICY = 0
)(
    input clk,
    input rst,

    // CPU-side request (level-held by the caller until resp_ready pulses).
    input                  req_read,
    input                  req_write,
    input      [XLEN-1:0]  req_addr,    // physical address (PIPT)
    input      [XLEN-1:0]  req_wdata,
    input      [2:0]       req_funct3,  // DataMemoryBRAM.v's own encoding: 000=lb 001=lh 010=lw 100=lbu 101=lhu (stores use [1:0]: 00=sb 01=sh else=sw)
    output     [XLEN-1:0]  resp_rdata,
    output                 resp_ready,

    // fence -- unconditional whole-cache writeback of every dirty line
    // (lines stay valid/cached, just become clean -- not an invalidation).
    input                  flush_all,
    output                 flush_busy,
    output                 flush_done,

    // Wishbone master (own port; muxed onto the shared bus in G6, mirroring
    // Ptw.v's own F4-standalone-then-F5-wired staging).
    output                          m_cyc,
    output                          m_stb,
    output                          m_we,
    output     [XLEN-1:0]           m_addr,
    output     [XLEN-1:0]           m_data_o,
    output     [`WB_SEL_WIDTH-1:0]  m_sel,
    output     [2:0]                m_funct3,
    input      [XLEN-1:0]           m_data_i,
    input                           m_ack,

    // docs/adr/0025-hpc-performance-csrs.md (Phase J5). One-cycle pulses,
    // exactly once per genuine new access (not per stall/fill cycle): the
    // `state==S_IDLE && (req_read||req_write)` guard below is the FSM's
    // own pre-existing "is this a real new request, not idle" condition
    // (already load-bearing for the FSM itself), so no separate run-length
    // tracking is needed the way the testbench's own indirect mem_stall-
    // duration heuristic (bench_template.v) needs -- `state` leaves
    // S_IDLE the same cycle a miss is recognized, so `access_miss` can
    // never re-fire during the multi-cycle S_WB/S_FILL service that
    // follows.
    output                          access_hit,
    output                          access_miss
);

localparam LINE_WORDS    = LINE_BYTES / 4;
localparam NUM_LINES     = CACHE_SIZE_BYTES / LINE_BYTES;
localparam NUM_SETS      = NUM_LINES / WAYS;
localparam SET_BITS      = $clog2(NUM_SETS);
localparam OFFSET_BITS   = $clog2(LINE_BYTES);
localparam WORD_OFF_BITS = OFFSET_BITS - 2;
localparam TAG_BITS      = XLEN - SET_BITS - OFFSET_BITS;
localparam WAY_BITS      = $clog2(WAYS);
localparam LINE_IDX_BITS = SET_BITS + WAY_BITS;

// REPLACEMENT_POLICY values (docs/adr/0041) -- same three values as
// ICache.v's own copy.
localparam POLICY_ROUND_ROBIN = 0;
localparam POLICY_FIFO        = 1;
localparam POLICY_LRU         = 2;

wire [WORD_OFF_BITS-1:0] word_off = req_addr[OFFSET_BITS-1:2];
wire [1:0]               byte_off = req_addr[1:0];
// docs/adr/0041. Same fix as ICache.v's own set_idx -- see its comment for
// the full rationale.
wire [SET_BITS-1:0]      set_idx;
generate
if (SET_BITS == 0) begin : gen_set_idx_fully_assoc
    assign set_idx = {SET_BITS{1'b0}};
end else begin : gen_set_idx_normal
    assign set_idx = req_addr[OFFSET_BITS+SET_BITS-1:OFFSET_BITS];
end
endgenerate
wire [TAG_BITS-1:0]      tag      = req_addr[XLEN-1:OFFSET_BITS+SET_BITS];

reg                 valid   [0:NUM_LINES-1];
reg                 dirty   [0:NUM_LINES-1];
reg [TAG_BITS-1:0]  tag_arr [0:NUM_LINES-1];
reg [XLEN-1:0]      data_arr[0:NUM_LINES*LINE_WORDS-1];
reg [WAY_BITS-1:0]  victim  [0:NUM_SETS-1];
// docs/adr/0041. Same per-set/per-way access-recency rank ICache.v's own
// age[] tracks -- see its header comment for the full rationale.
// ponytail: always-maintained regardless of REPLACEMENT_POLICY, same
// rationale as ICache.v's own copy.
reg [WAY_BITS-1:0]  age     [0:NUM_SETS-1][0:WAYS-1];

// N-way tag compare, same generate/assign shape ICache.v uses (avoids the
// Icarus "always @* sensitive to all N words" warning a procedural for-loop
// over these unpacked arrays would trigger) -- extended here to also
// accumulate the winning way's own flat line index (needed for the
// hit-write commit and has no ICache.v analog, since a read-only cache
// never needs to identify a line to write into).
genvar gw;
wire [WAYS-1:0]          way_hit;
wire [XLEN-1:0]          way_data   [0:WAYS-1];
wire [LINE_IDX_BITS-1:0] way_lineidx[0:WAYS-1];
wire [XLEN-1:0]          hit_data_acc   [0:WAYS];
wire [LINE_IDX_BITS-1:0] hit_lineidx_acc[0:WAYS];
assign hit_data_acc[0]    = {XLEN{1'b0}};
assign hit_lineidx_acc[0] = {LINE_IDX_BITS{1'b0}};
generate
    for (gw = 0; gw < WAYS; gw = gw + 1) begin : gen_way_compare
        assign way_hit[gw]     = valid[set_idx*WAYS + gw] && (tag_arr[set_idx*WAYS + gw] == tag);
        assign way_data[gw]    = data_arr[(set_idx*WAYS + gw)*LINE_WORDS + word_off];
        assign way_lineidx[gw] = set_idx*WAYS + gw;
        assign hit_data_acc[gw+1]    = hit_data_acc[gw]    | (way_hit[gw] ? way_data[gw]    : {XLEN{1'b0}});
        assign hit_lineidx_acc[gw+1] = hit_lineidx_acc[gw] | (way_hit[gw] ? way_lineidx[gw] : {LINE_IDX_BITS{1'b0}});
    end
endgenerate
wire hit = |way_hit;
wire [XLEN-1:0]          hit_data     = hit_data_acc[WAYS];
wire [LINE_IDX_BITS-1:0] hit_line_idx = hit_lineidx_acc[WAYS];

// docs/adr/0041. POLICY_LRU's own victim choice -- same shape as
// ICache.v's own gen_lru_victim block. (hit_line_idx already gives a
// hit's own way via its low WAY_BITS bits -- line_idx = set*WAYS+way with
// WAYS a power of 2, per this file's own header comment -- so no separate
// hit-way accumulator is needed here the way ICache.v's is.)
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

// docs/adr/0025-hpc-performance-csrs.md (Phase J5). `access_miss` fires
// exactly once at the S_IDLE cycle a miss is recognized (state leaves
// S_IDLE for S_WB/S_FILL immediately after and doesn't return until the
// whole fill completes, by which point the caller has long since
// advanced -- confirmed clean by a calibration trace, no repeat risk).
// `access_hit` is NOT simply the write-hit/read-hit mirror of that same
// S_IDLE condition -- a real bug found by running, not anticipated in the
// original hand-trace: a write-hit resolves combinationally in the SAME
// S_IDLE cycle (safe, matches resp_ready's own S_IDLE&&req_write arm
// below), but a read-hit transitions to S_HIT_RD and only comes BACK to
// S_IDLE one cycle later -- at which point the caller (riscvpipeline.v)
// may not have advanced reg3 yet (mem_stall's own drop lags one cycle
// behind resp_ready), so the SAME still-stale req_read/req_addr looks
// like a second genuine S_IDLE request and would double-count the
// identical access. Fixed by counting a read-hit at its own S_HIT_RD
// completion cycle instead (mirroring resp_ready's own read arm exactly,
// `state==S_HIT_RD && req_read && req_addr==served_addr_r` -- gated on
// the same latched-address-match docs/adr/0023's own G7 bugfix
// established, for the identical "a bare level/state can't distinguish
// still-the-same-request from a new one" reason), which fires exactly
// once per read-hit since state can't re-enter S_HIT_RD without a fresh
// S_IDLE request first.
assign access_hit  = (state == S_IDLE && req_write && hit) ||
                      (state == S_HIT_RD && req_read && req_addr == served_addr_r);
assign access_miss = (state == S_IDLE) && (req_read || req_write) && !hit;

// Width/sign extension for a load, mirroring DataMemoryBRAM.v's own
// funct3-keyed case exactly, generalized with a byte_off since this
// cache's storage is one register per WORD (not a flat byte array) --
// natural-alignment assumption, see module header.
function [31:0] dcache_extend_read;
    input [31:0] word;
    input [2:0]  funct3;
    input [1:0]  byte_off_f;
    reg [7:0]  b;
    reg [15:0] h;
    begin
        case (funct3)
            3'b000: begin // lb
                case (byte_off_f)
                    2'd0: b = word[7:0];
                    2'd1: b = word[15:8];
                    2'd2: b = word[23:16];
                    default: b = word[31:24];
                endcase
                dcache_extend_read = {{24{b[7]}}, b};
            end
            3'b100: begin // lbu
                case (byte_off_f)
                    2'd0: b = word[7:0];
                    2'd1: b = word[15:8];
                    2'd2: b = word[23:16];
                    default: b = word[31:24];
                endcase
                dcache_extend_read = {24'b0, b};
            end
            3'b001: begin // lh
                h = byte_off_f[1] ? word[31:16] : word[15:0];
                dcache_extend_read = {{16{h[15]}}, h};
            end
            3'b101: begin // lhu
                h = byte_off_f[1] ? word[31:16] : word[15:0];
                dcache_extend_read = {16'b0, h};
            end
            default: dcache_extend_read = word; // lw
        endcase
    end
endfunction

// Byte/halfword/word merge for a store, the write-side mirror of
// dcache_extend_read above (DataMemoryBRAM.v's own sb/sh/sw case,
// generalized the same way).
function [31:0] dcache_merge_write;
    input [31:0] old_word;
    input [1:0]  funct3_lo;   // req_funct3[1:0]: 00=sb 01=sh else=sw
    input [1:0]  byte_off_f;
    input [31:0] wdata;
    begin
        case (funct3_lo)
            2'b00: begin // sb
                case (byte_off_f)
                    2'd0: dcache_merge_write = {old_word[31:8],  wdata[7:0]};
                    2'd1: dcache_merge_write = {old_word[31:16], wdata[7:0], old_word[7:0]};
                    2'd2: dcache_merge_write = {old_word[31:24], wdata[7:0], old_word[15:0]};
                    default: dcache_merge_write = {wdata[7:0], old_word[23:0]};
                endcase
            end
            2'b01: // sh
                dcache_merge_write = byte_off_f[1] ? {wdata[15:0], old_word[15:0]} : {old_word[31:16], wdata[15:0]};
            default: // sw
                dcache_merge_write = wdata;
        endcase
    end
endfunction

// -- Fill/writeback engine --
localparam S_IDLE       = 3'd0;
localparam S_HIT_RD     = 3'd1;
localparam S_WB         = 3'd2;
localparam S_FILL       = 3'd3;
localparam S_FLUSH_SCAN = 3'd4;

reg [2:0] state;

reg [LINE_IDX_BITS-1:0] hit_line_r;
reg [WORD_OFF_BITS-1:0] hit_word_r;
reg [2:0]               hit_funct3_r;
reg [1:0]               hit_byteoff_r;

reg [SET_BITS-1:0]      miss_set_r;
reg [WAY_BITS-1:0]      miss_way_r;
reg [TAG_BITS-1:0]      miss_tag_r;
reg [XLEN-1:0]          miss_base_r;
reg [WORD_OFF_BITS-1:0] miss_word_off_r;
reg [1:0]               miss_byteoff_r;
reg [2:0]               miss_funct3_r;
reg                     miss_is_write_r;
reg [XLEN-1:0]          miss_wdata_r;
reg [XLEN-1:0]          miss_orig_addr_r;   // full req_addr at miss-detection, for resp_ready's own address-match gate (see served_addr_r's header comment)

reg [WORD_OFF_BITS-1:0] fill_word_r;   // shared progress counter: fill AND writeback (mirrors Ptw.v's own pte_r reuse-across-levels precedent)
reg [LINE_IDX_BITS-1:0] wb_line_r;
reg [XLEN-1:0]          wb_base_r;
reg                     wb_return_to_flush_r;

reg [LINE_IDX_BITS-1:0] flush_scan_r;
reg                     flush_active_r;
reg                     flush_done_r;

// docs/adr/0023-caches.md (Phase G7). A real bug found by running MMU+cache
// constrained-random programs: resp_ready's own S_HIT_RD/S_FILL branches
// (below) originally trusted `state` alone to mean "the CURRENT req_read/
// req_write/req_addr is what this pulse answers." That's false around a
// state-transition boundary: this module's own internal S_IDLE/S_HIT_RD/
// S_FILL case logic re-evaluates state one edge later than resp_ready's own
// combinational value can already reflect (fill_word_r/m_ack settling
// mid-cycle), and separately, the CALLER (riscvpipeline.v's mem_stall_
// done_r) releases a served occupant using resp_ready's live value the
// SAME cycle it first goes high -- letting a completely different, genuinely
// new request (e.g. the very next instruction, already latched into reg3)
// land on the exact cycle a stale S_HIT_RD/S_FILL pulse (meant for the
// PREVIOUS request) is still combinationally asserted. Observed directly: a
// store immediately following a load lost its data entirely (never
// written, never marked dirty), invisible until a later fence's own flush
// found nothing there to write back. Same "a bare level/state can't
// distinguish still-the-same-request from a new one" lesson this project
// has hit repeatedly (docs/adr/0009, 0013, 0016, 0022, and this same
// phase's own mem_stall/store-data-assertion fixes) -- fixed by latching
// the exact address each pulse answers and gating resp_ready/resp_rdata on
// it matching the CURRENT req_addr (see their own `assign` below): a
// mismatch means the state happens to still show S_HIT_RD/S_FILL-completing
// but for a DIFFERENT request than what's live right now, so nothing that
// address doesn't ask for gets served by it.
reg [XLEN-1:0]     served_addr_r;   // latched at S_HIT_RD entry -- the address that read is for

wire [31:0] hit_rd_word = data_arr[hit_line_r*LINE_WORDS + hit_word_r];

// docs/adr/0041. The way/set access_hit (declared above) touched: at
// S_IDLE (the write-hit case, resp_ready fires the SAME cycle) it's
// hit_line_idx, still live combinationally; at S_HIT_RD (the read-hit
// case, completing one cycle later) it's hit_line_r, latched back at
// S_IDLE detection time and still valid through S_HIT_RD.
wire [WAY_BITS-1:0] access_hit_way = (state == S_IDLE) ? hit_line_idx[WAY_BITS-1:0]
                                                        : hit_line_r[WAY_BITS-1:0];
wire [SET_BITS-1:0] access_hit_set = (state == S_IDLE) ? hit_line_idx[LINE_IDX_BITS-1:WAY_BITS]
                                                        : hit_line_r[LINE_IDX_BITS-1:WAY_BITS];

wire fill_is_last_word = (fill_word_r == LINE_WORDS-1);
wire fill_do_merge = miss_is_write_r && (fill_word_r == miss_word_off_r);
wire [31:0] fill_value = fill_do_merge
    ? dcache_merge_write(m_data_i, miss_funct3_r[1:0], miss_byteoff_r, miss_wdata_r)
    : m_data_i;

// docs/adr/0041. Same LRU-stack update ICache.v's own lru_touch performs.
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
        state <= S_IDLE;
        flush_active_r <= 1'b0;
        flush_done_r   <= 1'b0;
        for (reset_i = 0; reset_i < NUM_LINES; reset_i = reset_i + 1) begin
            valid[reset_i] <= 1'b0;
            dirty[reset_i] <= 1'b0;
        end
        for (reset_i = 0; reset_i < NUM_SETS; reset_i = reset_i + 1) begin
            victim[reset_i] <= {WAY_BITS{1'b0}};
            for (reset_j = 0; reset_j < WAYS; reset_j = reset_j + 1)
                age[reset_i][reset_j] <= reset_j[WAY_BITS-1:0];
        end
    end
    else begin
        flush_done_r <= 1'b0;   // default: one-cycle pulse, cleared unless set below

        // docs/adr/0041. POLICY_LRU: touch on every real access-hit (reuses
        // the existing J5 access_hit signal, already exactly-once-per-real-
        // access -- see its own header comment) and on every fill
        // completion (below, inside S_FILL).
        if (REPLACEMENT_POLICY == POLICY_LRU && access_hit)
            lru_touch(access_hit_set, access_hit_way);

        case (state)
            S_IDLE: begin
                if (flush_all && !flush_active_r) begin
                    flush_active_r <= 1'b1;
                    flush_scan_r   <= {LINE_IDX_BITS{1'b0}};
                    state <= S_FLUSH_SCAN;
                end
                else if (req_read || req_write) begin
                    if (hit) begin
                        if (req_write) begin
                            data_arr[hit_line_idx*LINE_WORDS + word_off] <=
                                dcache_merge_write(hit_data, req_funct3[1:0], byte_off, req_wdata);
                            dirty[hit_line_idx] <= 1'b1;
                            // resp_ready combinational this cycle (see assign below), stays in S_IDLE
                        end
                        else begin
                            hit_line_r    <= hit_line_idx;
                            hit_word_r    <= word_off;
                            hit_funct3_r  <= req_funct3;
                            hit_byteoff_r <= byte_off;
                            state <= S_HIT_RD;
                            served_addr_r <= req_addr;
                        end
                    end
                    else begin
                        miss_set_r      <= set_idx;
                        miss_tag_r      <= tag;
                        miss_way_r      <= (REPLACEMENT_POLICY == POLICY_LRU) ? lru_way_idx : victim[set_idx];
                        miss_base_r     <= {req_addr[XLEN-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
                        miss_word_off_r <= word_off;
                        miss_byteoff_r  <= byte_off;
                        miss_funct3_r   <= req_funct3;
                        miss_is_write_r <= req_write;
                        miss_wdata_r    <= req_wdata;
                        miss_orig_addr_r <= req_addr;
                        if (valid[set_idx*WAYS + victim[set_idx]] && dirty[set_idx*WAYS + victim[set_idx]]) begin
                            wb_line_r <= set_idx*WAYS + victim[set_idx];
                            wb_base_r <= {tag_arr[set_idx*WAYS + victim[set_idx]], set_idx, {OFFSET_BITS{1'b0}}};
                            wb_return_to_flush_r <= 1'b0;
                            fill_word_r <= {WORD_OFF_BITS{1'b0}};
                            state <= S_WB;
                        end
                        else begin
                            fill_word_r <= {WORD_OFF_BITS{1'b0}};
                            state <= S_FILL;
                        end
                    end
                end
            end

            S_HIT_RD: begin
                state <= S_IDLE;
            end

            S_WB: begin
                if (m_ack) begin
                    if (fill_is_last_word) begin
                        dirty[wb_line_r] <= 1'b0;
                        if (wb_return_to_flush_r) begin
                            if (flush_scan_r == NUM_LINES-1) begin
                                flush_active_r <= 1'b0;
                                flush_done_r   <= 1'b1;
                                state <= S_IDLE;
                            end
                            else begin
                                flush_scan_r <= flush_scan_r + 1'b1;
                                state <= S_FLUSH_SCAN;
                            end
                        end
                        else begin
                            fill_word_r <= {WORD_OFF_BITS{1'b0}};
                            state <= S_FILL;
                        end
                    end
                    else begin
                        fill_word_r <= fill_word_r + 1'b1;
                    end
                end
            end

            S_FILL: begin
                if (m_ack) begin
                    data_arr[(miss_set_r*WAYS + miss_way_r)*LINE_WORDS + fill_word_r] <= fill_value;
                    if (fill_is_last_word) begin
                        valid[miss_set_r*WAYS + miss_way_r]   <= 1'b1;
                        tag_arr[miss_set_r*WAYS + miss_way_r] <= miss_tag_r;
                        dirty[miss_set_r*WAYS + miss_way_r]   <= miss_is_write_r;   // a read-miss fill is clean; a write-allocate fill is dirty
                        victim[miss_set_r] <= (miss_way_r == WAYS-1) ? {WAY_BITS{1'b0}} : miss_way_r + 1'b1;
                        if (REPLACEMENT_POLICY == POLICY_LRU)
                            lru_touch(miss_set_r, miss_way_r);
                        state <= S_IDLE;
                    end
                    else begin
                        fill_word_r <= fill_word_r + 1'b1;
                    end
                end
            end

            S_FLUSH_SCAN: begin
                if (valid[flush_scan_r] && dirty[flush_scan_r]) begin
                    wb_line_r <= flush_scan_r;
                    wb_base_r <= {tag_arr[flush_scan_r], flush_scan_r[LINE_IDX_BITS-1:WAY_BITS], {OFFSET_BITS{1'b0}}};
                    wb_return_to_flush_r <= 1'b1;
                    fill_word_r <= {WORD_OFF_BITS{1'b0}};
                    state <= S_WB;
                end
                else if (flush_scan_r == NUM_LINES-1) begin
                    flush_active_r <= 1'b0;
                    flush_done_r   <= 1'b1;
                    state <= S_IDLE;
                end
                else begin
                    flush_scan_r <= flush_scan_r + 1'b1;
                end
            end

            default: state <= S_IDLE;
        endcase
    end
end

// See served_addr_r's own header comment above for the bug this closes.
// `state==S_HIT_RD`/`state==S_FILL&&...` alone isn't enough to mean "the
// CURRENT req_read/req_write/req_addr is what this pulse answers" -- gating
// on the latched address (served_addr_r for a hit-read, miss_orig_addr_r
// for a fill) matching req_addr means a genuinely new, different request
// landing on the same cycle a stale pulse would otherwise fire sees a
// mismatch and correctly gets nothing (its OWN S_IDLE evaluation serves it
// fresh, on its own timing) -- while a real repeat of the SAME address
// (e.g. the caller hasn't advanced yet) still correctly matches and
// harmlessly re-confirms the same answer.
assign resp_ready =
    (state == S_IDLE && hit && req_write && (req_read || req_write)) ||
    (state == S_HIT_RD && req_read && req_addr == served_addr_r) ||
    (state == S_FILL && m_ack && fill_is_last_word
        && (req_read || req_write) && req_addr == miss_orig_addr_r);

assign resp_rdata =
    (state == S_HIT_RD && req_read && req_addr == served_addr_r)
        ? dcache_extend_read(hit_rd_word, hit_funct3_r, hit_byteoff_r) :
    (state == S_FILL && m_ack && fill_is_last_word
        && (req_read || req_write) && req_addr == miss_orig_addr_r)
        ? dcache_extend_read(fill_value, miss_funct3_r, miss_byteoff_r) :
                                                        {XLEN{1'b0}};

assign flush_busy = flush_active_r;
assign flush_done = flush_done_r;

assign m_cyc    = (state == S_WB) || (state == S_FILL);
assign m_stb    = m_cyc;
assign m_we     = (state == S_WB);
assign m_addr   = (state == S_WB) ? (wb_base_r + {{(XLEN-OFFSET_BITS){1'b0}}, fill_word_r, 2'b00})
                                   : (miss_base_r + {{(XLEN-OFFSET_BITS){1'b0}}, fill_word_r, 2'b00});
assign m_data_o = (state == S_WB) ? data_arr[wb_line_r*LINE_WORDS + fill_word_r] : {XLEN{1'b0}};
assign m_sel    = {`WB_SEL_WIDTH{1'b1}};
assign m_funct3 = 3'b010;   // fill/writeback are always full-word transfers

endmodule

`default_nettype wire
