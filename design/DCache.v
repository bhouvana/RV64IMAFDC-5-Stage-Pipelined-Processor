`default_nettype none

`include "wb_defs.vh"
`include "riscv_defs.vh"

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
    parameter REPLACEMENT_POLICY = 0,
    // Generation 4, Phase C (docs/adr/0042-victim-cache-phase-c.md): entry
    // count for a small fully-associative victim buffer. 0 = disabled,
    // bit-exact with pre-Phase-C behavior. Not yet consumed anywhere as of
    // this commit.
    parameter VICTIM_ENTRIES = 0,
    // Generation 4, Phase D (docs/adr/0043-memory-controller-phase-d.md):
    // 0 = disabled (bit-exact, every beat of S_FILL/S_WB drives
    // `CTI_CLASSIC, matching pre-Phase-D behavior). 1 = drive real
    // Wishbone B3 CTI signaling (`CTI_INCR_BURST/`CTI_END_OF_BURST) across
    // a line fill/writeback's own multi-word sequence. Not yet consumed
    // anywhere as of this commit.
    parameter BURST_ENABLE = 0,
    // Generation 4, Phase E (docs/adr/0044-non-blocking-dcache-mshr-phase-e.md):
    // outstanding-LOAD-miss queue depth. 1 = disabled, bit-exact with
    // pre-Phase-E behavior -- every dispatch decision below still reduces
    // to today's single-outstanding fork (a store, or a load with no free
    // MSHR slot, always falls back to the pre-existing blocking wait).
    // >1 lets a second (and further) load miss be accepted into the queue
    // while an earlier one is still filling. Not yet consumed anywhere as
    // of this commit.
    parameter MSHR_ENTRIES = 1
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
    // Generation 4, Phase E. Caller-supplied architectural destination
    // register for a LOAD -- only ever consumed if this request becomes a
    // non-blocking MSHR (mshr_accept) or an S_IDLE-fork load miss at
    // MSHR_ENTRIES>1; ignored for stores/hits.
    input      [4:0]       req_dest_reg,
    // Generation 4, Phase E. True only when THIS req_read, if it misses,
    // is a genuine plain-integer load (riscvpipeline.v wires this to
    // regWrite_regem) -- a real, serious gap found by running the
    // constrained-random harness at MSHR_ENTRIES>1, not anticipated in the
    // original design: memRead_regem is ALSO true for a floating-point
    // load (OPCODE_LOAD_FP sets memRead=1 AND fRegWrite=1, never
    // regWrite), whose real destination is FRegister.v, not Register.v --
    // req_dest_reg/mshr_complete_reg/RegisterFile.v's own port2 have no
    // way to route a result there. Without this gate, an flw miss would
    // get queued as non-blocking, retire with no valid data written
    // ANYWHERE (its result silently vanishes -- neither the normal
    // resp_ready-driven float-writeback path nor the new integer-only
    // completion path ever fires for it). Hit-under-miss is unaffected
    // (mshr_busy_dispatch_hit resolves through the ordinary resp_ready/
    // resp_rdata path every load, integer or float, already uses) --
    // only the queued/non-blocking accept path needs this gate.
    input                   req_int_load,

    // Generation 4, Phase E (docs/adr/0044-non-blocking-dcache-mshr-phase-e.md).
    // Fires the SAME cycle a load miss is accepted into the MSHR queue
    // (whether the bus was idle or already busy with an earlier entry) --
    // the caller may retire this instruction now without data; the result
    // arrives later via mshr_complete. Never fires for a store (stores
    // always use the traditional resp_ready path, see module header) or
    // when MSHR_ENTRIES==1 (bit-identical-to-today requirement).
    output                 mshr_accept,
    // Pulses exactly once when a queued MSHR's fill finishes, carrying the
    // destination register and final (already-extended) data directly --
    // decoupled from req_addr/resp_ready, since the caller that issued
    // this load is long gone by the time its fill completes.
    output                 mshr_complete,
    output     [4:0]       mshr_complete_reg,
    output     [XLEN-1:0]  mshr_complete_data,
    // Generation 4, Phase E. Fence must wait for every outstanding MSHR to
    // drain before starting its scan (a line still mid-fill has no
    // meaningful dirty/clean state to flush yet) -- riscvpipeline.v's own
    // fence_pending_r gate consumes this alongside its existing !ptw_busy
    // check.
    output                 mshr_outstanding,

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
    output     [2:0]                m_cti,   // docs/adr/0043 (Phase D): real Wishbone B3 cycle-type, only meaningful when BURST_ENABLE=1
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
    output                          access_miss,

    // docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). Inclusion
    // probe responder -- driven by an L2Cache.v instance sitting below this
    // module, ONLY when a caller actually wires it (riscvpipeline.v ties
    // probe_req=0 when L2 is disabled, the default -- this whole port stays
    // permanently dark/inert then, bit-identical to pre-Phase-F behavior).
    // L2 probes UNCONDITIONALLY before evicting any currently-valid line it
    // holds (no present_in_l1 tracking on L2's own side, see L2Cache.v's
    // header) -- this module's own job is simple: answer truthfully whether
    // probe_addr's line is resident here right now, and if so, hand over its
    // dirty bit + full data and invalidate it, same cycle.
    input                           probe_req,
    input      [XLEN-1:0]           probe_addr,
    output                          probe_ack,
    output                          probe_dirty,
    output     [XLEN*LINE_WORDS-1:0] probe_data
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
// Generation 4, Phase E. Same "$clog2(1)==0 would give a zero-width reg"
// guard this file's own SET_BITS==0 fix (docs/adr/0041) established --
// MSHR_ENTRIES==1 (the default/disabled case) needs a real 1-bit index
// even though $clog2(1)==0.
localparam MSHR_IDX_BITS = (MSHR_ENTRIES <= 1) ? 1 : $clog2(MSHR_ENTRIES);
// A count of OCCUPIED entries needs to represent MSHR_ENTRIES itself (the
// full-queue value), one more than the largest INDEX (MSHR_ENTRIES-1) --
// $clog2(MSHR_ENTRIES) alone is one bit too narrow (e.g. MSHR_ENTRIES=2
// needs 2 bits to hold the value 2, not the 1 bit $clog2(2) gives, which
// can only ever hold 0 or 1 and silently wraps 1+1 back to 0). A real bug
// found by running tb_mshr_unit.v's own case3 (queue-full-reject wrongly
// saw mshr_count_r==0 with both entries genuinely mshr_valid), not
// anticipated in the original design.
localparam MSHR_COUNT_BITS = $clog2(MSHR_ENTRIES + 1);

// REPLACEMENT_POLICY values (docs/adr/0041) -- same three values as
// ICache.v's own copy.
localparam POLICY_ROUND_ROBIN = 0;
localparam POLICY_FIFO        = 1;
localparam POLICY_LRU         = 2;

wire [WORD_OFF_BITS-1:0] word_off = req_addr[OFFSET_BITS-1:2];
wire [1:0]               byte_off = req_addr[1:0];
// Generation 4 Phase F (docs/adr/0045). `sd`'s own upper 32 bits, computed
// width-safely at every XLEN: zero-extend req_wdata up to a real 64 bits
// FIRST, then slice -- a literal `req_wdata[63:32]` is a real, in-range
// slice only at XLEN>=64; at XLEN=32 it's an out-of-bounds part-select
// (still elaborates under Icarus, silently reading 'bx with a real
// warning -- this project's own zero-warning bar catches it) even though
// every real consumer of this wire is itself gated `XLEN>=64` and never
// actually reads it there. This form is safe/warning-free at both widths
// (the `{(64-XLEN){1'b0}}` padding term itself reduces to a harmless
// zero-width nested repeat at XLEN==64, the same legal-when-nested form
// DataMemoryBRAM.v's own `{{(XLEN-32){...}}, ...}` idiom already relies on).
wire [63:0] req_wdata_ext64 = {{(64-XLEN){1'b0}}, req_wdata};
wire [31:0] req_wdata_hi32 = req_wdata_ext64[63:32];
// docs/adr/0041. Same fix as ICache.v's own set_idx -- see its comment for
// the full rationale.
wire [SET_BITS-1:0]      set_idx;
generate
if (SET_BITS == 0) begin : gen_set_idx_fully_assoc
    assign set_idx = 1'b0;
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
wire [XLEN-1:0]          hit_data     = hit_data_acc[WAYS];
wire [LINE_IDX_BITS-1:0] hit_line_idx = hit_lineidx_acc[WAYS];
// docs/adr/0042. `hit_main` is the pre-existing main-array-only signal
// (renamed from the old bare `hit` -- still what hit_data/hit_line_idx are
// built from, and what every pre-existing site that needs to distinguish
// "a real main-array hit" from "a victim-buffer promote" now uses). `hit`
// is broadened to also cover a victim-buffer hit -- every pre-existing
// consumer of the bare `hit` identifier (the S_IDLE dispatch fork below,
// access_hit/access_miss) already meant "resolvable without a bus access,"
// which a victim-buffer promote genuinely is too, so broadening it here
// fixes those three sites for free with no further edits needed there.
wire hit_main = |way_hit;

// docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). A SECOND,
// independent tag/set decode + N-way compare against probe_addr -- this is
// deliberately NOT req_addr/tag/set_idx (a probe can arrive for a
// completely different address than whatever the main FSM is currently
// servicing). Same accumulator-reduction shape way_hit/hit_data_acc already
// use above. Permanently inert (probe_found stays 0) when the caller never
// asserts probe_req.
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

// docs/adr/0042-victim-cache-phase-c.md (Generation 4, Phase C). A small,
// fully-associative buffer for lines just evicted from THIS cache -- see
// VictimCache.v's own header for the full design rationale, and ICache.v's
// own copy of this same block for the "why same-cycle, not a new FSM
// state" reasoning (identical here for a write-hit; a read-hit still goes
// through the pre-existing S_HIT_RD staging either way, see the S_IDLE
// case below). Disabled (VICTIM_ENTRIES==0) ties vc_lookup_hit to 0,
// bit-exact with pre-Phase-C behavior.
localparam VC_TAG_WIDTH = TAG_BITS + SET_BITS;
wire [VC_TAG_WIDTH-1:0] vc_lookup_tag = {tag, set_idx};
wire vc_lookup_hit;
wire [XLEN*LINE_WORDS-1:0] vc_lookup_data;
wire vc_lookup_dirty;

// The way about to be displaced by a miss OR a promote -- same choice
// either way, mirrors ICache.v's own victim_target_way exactly.
wire [WAY_BITS-1:0] victim_target_way = (REPLACEMENT_POLICY == POLICY_LRU) ? lru_way_idx : victim[set_idx];

// Whatever currently occupies (set_idx, victim_target_way) -- read
// combinationally regardless of validity. do_swap is unconditional on
// vc_lookup_hit (same provable "victim_target_way can't be invalid while
// vc_lookup_hit is true for this set" invariant ICache.v's own copy of
// this comment derives in full -- identical reasoning, round-robin/LRU
// mechanics are shared). do_insert is explicitly gated on `valid` below,
// since an ordinary cold-start miss (the common case) legitimately targets
// a still-invalid way with nothing worth preserving.
wire [TAG_BITS-1:0]     vc_outgoing_tag_bits = tag_arr[set_idx*WAYS + victim_target_way];
wire [VC_TAG_WIDTH-1:0] vc_outgoing_tag      = {vc_outgoing_tag_bits, set_idx};
wire                    vc_outgoing_dirty    = dirty[set_idx*WAYS + victim_target_way];
wire [XLEN*LINE_WORDS-1:0] vc_outgoing_data;
generate
    for (gw = 0; gw < LINE_WORDS; gw = gw + 1) begin : gen_vc_outgoing
        assign vc_outgoing_data[gw*XLEN +: XLEN] = data_arr[(set_idx*WAYS + victim_target_way)*LINE_WORDS + gw];
    end
endgenerate

wire vc_do_swap   = (state == S_IDLE) && !hit_main && vc_lookup_hit;
// Inserted regardless of dirty state -- a clean evicted line still gets a
// real shot at fast recovery, same as a dirty one; insert_dirty (below)
// carries the real bit through either way.
wire vc_do_insert = (state == S_IDLE) && !hit_main && !vc_lookup_hit
                     && valid[set_idx*WAYS + victim_target_way];

wire                       evict_out_valid;
wire [VC_TAG_WIDTH-1:0]    evict_out_tag;
wire [XLEN*LINE_WORDS-1:0] evict_out_data;
wire                       evict_out_dirty;

generate
if (VICTIM_ENTRIES == 0) begin : gen_victim_disabled
    assign vc_lookup_hit   = 1'b0;
    assign vc_lookup_data  = {(XLEN*LINE_WORDS){1'b0}};
    assign vc_lookup_dirty = 1'b0;
    assign evict_out_valid = 1'b0;
    assign evict_out_tag   = {VC_TAG_WIDTH{1'b0}};
    assign evict_out_data  = {(XLEN*LINE_WORDS){1'b0}};
    assign evict_out_dirty = 1'b0;
end else begin : gen_victim_enabled
    VictimCache #(.ENTRIES(VICTIM_ENTRIES), .WITH_DIRTY(1), .TAG_WIDTH(VC_TAG_WIDTH),
                  .LINE_WORDS(LINE_WORDS), .XLEN(XLEN)) m_victim(
        .clk(clk), .rst(rst),
        .lookup_tag(vc_lookup_tag), .lookup_hit(vc_lookup_hit), .lookup_data(vc_lookup_data), .lookup_dirty(vc_lookup_dirty),
        .do_swap(vc_do_swap), .swap_in_tag(vc_outgoing_tag), .swap_in_data(vc_outgoing_data), .swap_in_dirty(vc_outgoing_dirty),
        .do_insert(vc_do_insert), .insert_tag(vc_outgoing_tag), .insert_data(vc_outgoing_data), .insert_dirty(vc_outgoing_dirty),
        .evict_out_valid(evict_out_valid), .evict_out_tag(evict_out_tag),
        .evict_out_data(evict_out_data), .evict_out_dirty(evict_out_dirty)
    );
end
endgenerate

wire hit = hit_main | vc_lookup_hit;

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
// Generation 4, Phase E. access_miss also counts a busy-dispatch miss
// (mshr_busy_dispatch_miss, a real new miss just accepted into the queue)
// -- correctness improvement, at MSHR_ENTRIES==1 this term is permanently
// false (mshr_busy_dispatch_miss requires mshr_room, which requires
// MSHR_ENTRIES>1), preserving bit-identical behavior at the default.
// access_hit deliberately does NOT gain a hu_pending_r term -- hit-under-
// miss stays invisible to the hit/miss perf counter and POLICY_LRU's own
// recency touch, a narrow, documented gap (docs/adr/0044's own Future
// improvements), not a correctness issue (the data served is still right).
assign access_hit  = (state == S_IDLE && req_write && hit) ||
                      (state == S_HIT_RD && req_read && req_addr == served_addr_r);
assign access_miss = ((state == S_IDLE) && (req_read || req_write) && !hit) ||
                      mshr_busy_dispatch_miss;

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

// Generation 4, Phase E (docs/adr/0044-non-blocking-dcache-mshr-phase-e.md).
// The single-outstanding "which miss is being serviced" bookkeeping this
// block used to hold directly (miss_set_r/miss_way_r/...) now lives in the
// mshr_*[] arrays declared further down, indexed by mshr_head_r (the entry
// S_WB/S_FILL are CURRENTLY servicing) -- see mshr_alloc's own header
// comment for why. wb_line_r/wb_base_r below still name the ACTIVE
// writeback target directly (both a miss's own primary-line eviction AND a
// plain flush scan use them identically to before) -- refreshed from
// mshr_wb_line[]/mshr_wb_base[] only at the moment bus-service advances to
// a newly-current head (S_FILL's own completion logic, below).

// One entry per outstanding LOAD miss (a store-miss reuses the same array
// too, always alone -- see mshr_alloc's own header comment below). No
// separate flat miss_*_r registers anymore -- S_WB/S_FILL read whichever
// entry mshr_head_r currently points at.
reg                     mshr_valid    [0:MSHR_ENTRIES-1];
reg [SET_BITS-1:0]      mshr_set      [0:MSHR_ENTRIES-1];
reg [WAY_BITS-1:0]      mshr_way      [0:MSHR_ENTRIES-1];
reg [TAG_BITS-1:0]      mshr_tag      [0:MSHR_ENTRIES-1];
reg [XLEN-1:0]          mshr_base     [0:MSHR_ENTRIES-1];
reg [WORD_OFF_BITS-1:0] mshr_word_off [0:MSHR_ENTRIES-1];
reg [1:0]               mshr_byteoff  [0:MSHR_ENTRIES-1];
reg [2:0]               mshr_funct3   [0:MSHR_ENTRIES-1];
reg [4:0]               mshr_dest_reg [0:MSHR_ENTRIES-1];
reg [XLEN-1:0]          mshr_orig_addr[0:MSHR_ENTRIES-1];
reg                     mshr_is_write     [0:MSHR_ENTRIES-1];
reg [XLEN-1:0]          mshr_wdata        [0:MSHR_ENTRIES-1];
// True iff this entry's own caller already retired without waiting --
// gates whether S_FILL's completion pulses mshr_complete (side-channel)
// or the traditional address-matched resp_ready (caller still holding).
reg                     mshr_early_retired[0:MSHR_ENTRIES-1];
// This entry's own primary-line eviction bookkeeping -- captured at
// allocation time so a QUEUED (not immediately serviced) entry's own
// writeback-before-fill need isn't lost while it waits its turn.
reg                     mshr_need_wb  [0:MSHR_ENTRIES-1];
reg [LINE_IDX_BITS-1:0] mshr_wb_line  [0:MSHR_ENTRIES-1];
reg [XLEN-1:0]          mshr_wb_base  [0:MSHR_ENTRIES-1];
reg [MSHR_COUNT_BITS-1:0] mshr_count_r;            // 0..MSHR_ENTRIES, occupancy
reg [MSHR_IDX_BITS-1:0] mshr_head_r, mshr_tail_r;  // FIFO service order
// Hit-under-miss: a read that resolves as a genuine main-array hit while
// state != S_IDLE (bus busy servicing an earlier MSHR). Decoupled from
// `state` entirely (state stays whatever it is, servicing the earlier
// entry) -- resolves 1 cycle later via resp_ready/resp_rdata (OR'd in
// below), matching the existing S_HIT_RD read-hit's own 1-cycle latency.
// Victim-buffer hits are NOT served this way (deliberate scope cut, see
// docs/adr/0044) -- only hit_main qualifies.
reg                     hu_pending_r;
reg [XLEN-1:0]          hu_data_r;

reg [WORD_OFF_BITS-1:0] fill_word_r;   // shared progress counter: fill AND writeback (mirrors Ptw.v's own pte_r reuse-across-levels precedent)
reg [LINE_IDX_BITS-1:0] wb_line_r;
reg [XLEN-1:0]          wb_base_r;
reg                     wb_return_to_flush_r;

// docs/adr/0042-victim-cache-phase-c.md. The victim buffer's own FIFO
// eviction (on a genuine miss's do_insert) needs writing back too, if it
// was dirty -- or that data is silently lost. Latched in S_IDLE (the
// combinational evict_out_* signals from m_victim are only valid the
// exact cycle do_insert fires -- by the time S_WB could get around to
// this, possibly after the PRIMARY line's own writeback, fifo_next_r has
// already moved on). vwb_active_r tells S_WB's own completion logic (and
// the m_data_o mux) which line -- the primary miss's own, or the victim
// buffer's own -- the CURRENT S_WB pass is actually writing back.
reg                        vwb_pending_r;
reg                        vwb_active_r;
reg [VC_TAG_WIDTH-1:0]     vwb_tag_r;
reg [XLEN*LINE_WORDS-1:0]  vwb_data_r;

reg [LINE_IDX_BITS-1:0] flush_scan_r;
reg                     flush_active_r;
reg                     flush_done_r;

// docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). Same
// SET_BITS==0 guard access_hit_set's own copy uses above -- flush's own
// address reconstruction below needs the identical fix (a THIRD previously-
// latent instance of docs/adr/0041's own bug, this one in the flush/fence
// path specifically -- no existing fence/flush test before this phase ever
// ran against a fully-associative D$ sizing either).
wire [SET_BITS-1:0] flush_scan_set;
generate
if (SET_BITS == 0) begin : gen_flush_scan_set_fully_assoc
    assign flush_scan_set = 1'b0;
end else begin : gen_flush_scan_set_normal
    assign flush_scan_set = flush_scan_r[LINE_IDX_BITS-1:WAY_BITS];
end
endgenerate

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
// Generation 4 Phase F (docs/adr/0045). `ld`'s own upper 32 bits -- see the
// S_IDLE write-hit arm's own comment above for the full rationale (a real,
// pre-existing RV64+cache integration gap this phase's own constrained-
// random sweep found, unrelated to L2 itself). Only meaningful/read when
// hit_funct3_r==`F3_LOAD_LD; harmless (an extra combinational read) at
// every other funct3.
wire [31:0] hit_rd_word_hi = data_arr[hit_line_r*LINE_WORDS + hit_word_r + 1];

// docs/adr/0041. The way/set access_hit (declared above) touched: at
// S_IDLE (the write-hit case, resp_ready fires the SAME cycle) it's
// hit_line_idx, still live combinationally; at S_HIT_RD (the read-hit
// case, completing one cycle later) it's hit_line_r, latched back at
// S_IDLE detection time and still valid through S_HIT_RD.
// docs/adr/0042. The S_IDLE arm now also covers a victim-buffer
// write-promote (resolves same-cycle, exactly like a real write-hit) --
// hit_line_idx is all-zero when hit_main is 0 (no way_hit bit set), so
// without this split, a write-promote would have silently touched way 0
// of every set's own LRU state instead of victim_target_way (the same bug
// class ICache.v's own copy of this fix closes). The S_HIT_RD arm needs no
// change: hit_line_r is already correctly latched to victim_target_way by
// the read-promote branch below by the time S_HIT_RD evaluates this.
wire [WAY_BITS-1:0] access_hit_way = (state == S_IDLE)
    ? (hit_main ? hit_line_idx[WAY_BITS-1:0] : victim_target_way)
    : hit_line_r[WAY_BITS-1:0];
// docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). A SECOND,
// previously-latent instance of docs/adr/0041's own SET_BITS==0 part-select
// bug (see set_idx's own comment above) -- never caught before because no
// existing test used a fully-associative D$ sizing (tb_icache_unit.v's own
// dut3 comment explicitly documents routing around this exact gap for I$;
// this phase's own tb_cache_l2_f1.v is the first test to genuinely need a
// fully-associative-shaped D$/L2, and found the D$-side twin of the same
// bug by running). [LINE_IDX_BITS-1:WAY_BITS] reverses to a high<low slice
// when SET_BITS==0 (LINE_IDX_BITS==WAY_BITS there) -- guarded the same way.
wire [SET_BITS-1:0] access_hit_set;
generate
if (SET_BITS == 0) begin : gen_access_hit_set_fully_assoc
    assign access_hit_set = 1'b0;
end else begin : gen_access_hit_set_normal
    assign access_hit_set = (state == S_IDLE)
        ? (hit_main ? hit_line_idx[LINE_IDX_BITS-1:WAY_BITS] : set_idx)
        : hit_line_r[LINE_IDX_BITS-1:WAY_BITS];
end
endgenerate

wire fill_is_last_word = (fill_word_r == LINE_WORDS-1);
wire fill_do_merge = mshr_is_write[mshr_head_r] && (fill_word_r == mshr_word_off[mshr_head_r]);
// Generation 4 Phase F (docs/adr/0045). `sd`'s own upper-32-bit fill-time
// merge -- a write-allocate miss for an 8-byte store needs its SECOND
// (high) word written too, one fill cycle later, using the upper half of
// the MSHR's own already-XLEN-wide mshr_wdata (which dcache_merge_write's
// own 32-bit `wdata` port truncates automatically when passed the raw
// value directly, same as the S_IDLE write-hit arm's own comment already
// explains). A full 64-bit replace, always -- `sd` never partial-merges,
// same as `sw` never does.
wire fill_do_merge_hi = (XLEN >= 64) && mshr_is_write[mshr_head_r]
    && (mshr_funct3[mshr_head_r] == `F3_STORE_SD) && (fill_word_r == mshr_word_off[mshr_head_r] + 1'b1);
// Width-safe at every XLEN -- see req_wdata_hi32's own comment above for why
// a literal `mshr_wdata[mshr_head_r][63:32]` isn't (a real, warning-flagged
// out-of-range slice at XLEN=32, found by running the zero-warning check).
wire [63:0] mshr_wdata_ext64 = {{(64-XLEN){1'b0}}, mshr_wdata[mshr_head_r]};
wire [31:0] mshr_wdata_hi32 = mshr_wdata_ext64[63:32];
wire [31:0] fill_value = fill_do_merge
    ? dcache_merge_write(m_data_i, mshr_funct3[mshr_head_r][1:0], mshr_byteoff[mshr_head_r], mshr_wdata[mshr_head_r])
    : fill_do_merge_hi
        ? mshr_wdata_hi32
        : m_data_i;

// Generation 4, Phase E (docs/adr/0044-non-blocking-dcache-mshr-phase-e.md).
// Does req_addr's own line already have an outstanding MSHR (queued or
// actively being serviced)? Same N-way-compare shape way_hit already uses.
genvar gm;
wire [MSHR_ENTRIES-1:0] mshr_line_match;
generate
    for (gm = 0; gm < MSHR_ENTRIES; gm = gm + 1) begin : gen_mshr_conflict
        assign mshr_line_match[gm] = mshr_valid[gm] && (mshr_tag[gm] == tag) && (mshr_set[gm] == set_idx);
    end
endgenerate
wire mshr_addr_line_conflict = |mshr_line_match;

// A fresh dispatch (state==S_IDLE, i.e. mshr_count_r==0 by construction --
// state never returns to S_IDLE while any MSHR is outstanding, see S_FILL's
// own completion logic below) mirrors the pre-existing flush/hit/miss
// if/else-if ordering in the S_IDLE case exactly, so this wire agrees with
// whichever fork that case block actually takes.
wire fresh_dispatch_ok    = (state == S_IDLE) && !(flush_all && !flush_active_r);
// A load miss dispatched fresh: MSHR_ENTRIES==1 keeps this permanently
// false (falls through to the pre-existing blocking S_FILL fork below,
// bit-identical to pre-Phase-E behavior -- the Global Constraint this
// whole phase is built around).
wire mshr_fresh_load_miss = fresh_dispatch_ok && req_read && !req_write && !hit && req_int_load && (MSHR_ENTRIES > 1);

// A NEW request landing while the bus is genuinely busy servicing an
// earlier MSHR's own writeback/fill (state==S_WB or S_FILL specifically --
// NOT `state != S_IDLE`, which would wrongly also include S_HIT_RD, the
// ordinary 1-cycle delay EVERY existing hit-read already uses regardless
// of MSHR_ENTRIES; a real bug caught by tb_cache_lru_b1's own regression
// run -- a plain hit-read was spuriously double-served the cycle after,
// once via its own S_HIT_RD/served_addr_r completion and once more via a
// falsely-armed hu_pending_r). Only possible at all once some earlier load
// already used mshr_accept to retire early, so MSHR_ENTRIES==1 (which never
// grants mshr_accept) never reaches req_addr actually changing here either;
// still written unconditionally, safe/inert dead logic at MSHR_ENTRIES==1.
wire mshr_busy = (state == S_WB) || (state == S_FILL);
wire mshr_busy_dispatch_hit  = mshr_busy && req_read && !req_write && hit_main;
wire mshr_room               = (MSHR_ENTRIES > 1) && (mshr_count_r < MSHR_ENTRIES) && !mshr_addr_line_conflict;
wire mshr_busy_dispatch_miss = mshr_busy && req_read && !req_write && !hit && req_int_load && mshr_room;

wire mshr_accept = mshr_fresh_load_miss || mshr_busy_dispatch_miss;

// Generation 4, Phase E. Unified per-cycle MSHR occupancy bookkeeping --
// see the two `if`-chains inside the always block below (before and inside
// case(state)) for why these are computed once, combinationally, rather
// than left to two independent non-blocking-assignment sites.
wire mshr_complete_now = (state == S_FILL) && m_ack && fill_is_last_word;
wire mshr_alloc_now    = mshr_busy_dispatch_miss;
wire [MSHR_IDX_BITS-1:0] mshr_head_next = (mshr_head_r == MSHR_ENTRIES-1) ? {MSHR_IDX_BITS{1'b0}} : mshr_head_r + 1'b1;
wire [MSHR_IDX_BITS-1:0] mshr_tail_next = (mshr_tail_r == MSHR_ENTRIES-1) ? {MSHR_IDX_BITS{1'b0}} : mshr_tail_r + 1'b1;
// How many entries remain queued after this cycle's completion (if any) --
// MUST also add back a same-cycle busy-dispatch allocation. A real bug
// found by running the constrained-random harness (a permanent hang, the
// scoreboard's own pending bit for the stuck entry's destination register
// then deadlocks pc_stall forever): the original version of this wire
// argued a new allocation "lands at the TAIL and never affects whether the
// just-advanced HEAD has more work" -- true in general, but wrong in the
// specific case this comment failed to consider: when completion drains
// the queue to exactly 0 and a new entry arrives the SAME cycle, that new
// entry's own tail-slot IS the just-advanced head's own new position (the
// queue was empty, so head and tail coincide) -- S_FILL's own completion
// logic below needs to know there IS more work, or it sends state to
// S_IDLE while the just-allocated entry sits valid but never serviced,
// permanently stuck (mshr_count_r itself stays consistent, at 1, because
// the unified head/tail/count writer above already correctly nets this
// exact case to "unchanged" -- only THIS wire's own separate, narrower
// "is there more work for S_FILL to continue with" question was wrong).
wire [MSHR_COUNT_BITS-1:0] mshr_count_after_complete =
    (mshr_complete_now ? (mshr_count_r - 1'b1) : mshr_count_r) + (mshr_alloc_now ? 1'b1 : 1'b0);
// When a same-cycle allocation lands exactly at the just-advanced head's
// own new position (queue was down to its last entry, refilled the same
// cycle it drained), that entry's own mshr_need_wb/mshr_wb_line/
// mshr_wb_base aren't in the array yet -- mshr_alloc's own writes are
// non-blocking, still in flight this same edge. S_FILL's completion arm
// below must use the SAME live combinational wires mshr_alloc_now's own
// busy-dispatch call already computes them from, not read the array back
// stale. A real bug found by running (same session as mshr_count_after_
// complete's own fix above, discovered investigating the same hang).
wire mshr_new_head_is_fresh_alloc = mshr_alloc_now && (mshr_head_next == mshr_tail_r);
wire mshr_new_head_need_wb = mshr_new_head_is_fresh_alloc
    ? (valid[set_idx*WAYS + victim_target_way] && dirty[set_idx*WAYS + victim_target_way])
    : mshr_need_wb[mshr_head_next];
wire [LINE_IDX_BITS-1:0] mshr_new_head_wb_line = mshr_new_head_is_fresh_alloc
    ? (set_idx*WAYS + victim_target_way)
    : mshr_wb_line[mshr_head_next];
wire [XLEN-1:0] mshr_new_head_wb_base = mshr_new_head_is_fresh_alloc
    ? {tag_arr[set_idx*WAYS + victim_target_way], set_idx, {OFFSET_BITS{1'b0}}}
    : mshr_wb_base[mshr_head_next];

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

// Generation 4, Phase E. Shared field-writer for a new MSHR entry, called
// from both the fresh-S_IDLE-dispatch fork and the busy-dispatch fork below
// -- avoids duplicating this ~15-field assignment list at two call sites.
// a_early_retired is passed EXPLICITLY by each call site, computed from the
// SAME condition that actually granted mshr_accept for this allocation --
// NOT re-derived from a_is_write alone. A real bug found by running the
// constrained-random harness at MSHR_ENTRIES>1 (not anticipated in the
// original design): a re-derived "(MSHR_ENTRIES>1) && !a_is_write" is TRUE
// for ANY read, including a float load (flw) that req_int_load correctly
// blocked from ever getting mshr_accept -- its own MSHR entry got wrongly
// marked early-retired anyway, so its completion fired mshr_complete
// instead of the traditional resp_ready the caller was actually still
// holding out for, and mshr_complete_reg (driven from req_dest_reg, an
// F-register encoding for that instruction) silently corrupted whichever
// INTEGER register happened to share that same 5-bit encoding.
task mshr_alloc;
    input [MSHR_IDX_BITS-1:0] slot;
    input [SET_BITS-1:0]      a_set;
    input [WAY_BITS-1:0]      a_way;
    input [TAG_BITS-1:0]      a_tag;
    input [XLEN-1:0]          a_base;
    input [WORD_OFF_BITS-1:0] a_word_off;
    input [1:0]                a_byteoff;
    input [2:0]                a_funct3;
    input [4:0]                a_dest_reg;
    input [XLEN-1:0]           a_orig_addr;
    input                      a_is_write;
    input [XLEN-1:0]           a_wdata;
    input                      a_need_wb;
    input [LINE_IDX_BITS-1:0]  a_wb_line;
    input [XLEN-1:0]           a_wb_base;
    input                      a_early_retired;
    begin
        mshr_valid[slot]        <= 1'b1;
        mshr_set[slot]          <= a_set;
        mshr_way[slot]          <= a_way;
        mshr_tag[slot]          <= a_tag;
        mshr_base[slot]         <= a_base;
        mshr_word_off[slot]     <= a_word_off;
        mshr_byteoff[slot]      <= a_byteoff;
        mshr_funct3[slot]       <= a_funct3;
        mshr_dest_reg[slot]     <= a_dest_reg;
        mshr_orig_addr[slot]    <= a_orig_addr;
        mshr_is_write[slot]     <= a_is_write;
        mshr_wdata[slot]        <= a_wdata;
        mshr_early_retired[slot]<= a_early_retired;
        mshr_need_wb[slot]      <= a_need_wb;
        mshr_wb_line[slot]      <= a_wb_line;
        mshr_wb_base[slot]      <= a_wb_base;
    end
endtask

integer reset_i, reset_j, reset_m, vcw;
always @(posedge clk) begin
    if (~rst) begin
        state <= S_IDLE;
        flush_active_r <= 1'b0;
        flush_done_r   <= 1'b0;
        vwb_pending_r  <= 1'b0;
        vwb_active_r   <= 1'b0;
        for (reset_i = 0; reset_i < NUM_LINES; reset_i = reset_i + 1) begin
            valid[reset_i] <= 1'b0;
            dirty[reset_i] <= 1'b0;
        end
        for (reset_i = 0; reset_i < NUM_SETS; reset_i = reset_i + 1) begin
            victim[reset_i] <= {WAY_BITS{1'b0}};
            for (reset_j = 0; reset_j < WAYS; reset_j = reset_j + 1)
                age[reset_i][reset_j] <= reset_j[WAY_BITS-1:0];
        end
        // Generation 4, Phase E.
        mshr_count_r <= {MSHR_COUNT_BITS{1'b0}};
        mshr_head_r  <= {MSHR_IDX_BITS{1'b0}};
        mshr_tail_r  <= {MSHR_IDX_BITS{1'b0}};
        hu_pending_r <= 1'b0;
        for (reset_m = 0; reset_m < MSHR_ENTRIES; reset_m = reset_m + 1)
            mshr_valid[reset_m] <= 1'b0;
    end
    else begin
        flush_done_r <= 1'b0;   // default: one-cycle pulse, cleared unless set below

        // docs/adr/0041. POLICY_LRU: touch on every real access-hit (reuses
        // the existing J5 access_hit signal, already exactly-once-per-real-
        // access -- see its own header comment) and on every fill
        // completion (below, inside S_FILL).
        if (REPLACEMENT_POLICY == POLICY_LRU && access_hit)
            lru_touch(access_hit_set, access_hit_way);

        // Generation 4, Phase E (docs/adr/0044). Hit-under-miss: decoupled
        // from `state`/case(state) below entirely -- see hu_pending_r's own
        // header comment. Defaults to 0 unless mshr_busy_dispatch_hit fires
        // this cycle (a pure 1-cycle pulse, no queue -- at most one
        // hit-under-miss can be "in flight" at a time by construction, the
        // caller holds this exact request for its one committed stall
        // cycle same as an ordinary S_HIT_RD read-hit).
        if (mshr_busy_dispatch_hit) begin
            hu_pending_r <= 1'b1;
            hu_data_r    <= dcache_extend_read(hit_data, req_funct3, byte_off);
        end
        else begin
            hu_pending_r <= 1'b0;
        end

        // Generation 4, Phase E. Single writer for mshr_count_r/mshr_head_r/
        // mshr_tail_r covering BOTH a same-cycle bus-service completion
        // (mshr_complete_now, the current head's fill just finished) and a
        // same-cycle busy-dispatch allocation (mshr_alloc_now, a new load
        // miss queued while busy) -- kept as one if/else-if chain
        // specifically so neither can silently clobber the other's write
        // to the SAME registers in the same always-block invocation (two
        // separate top-level `if`s both non-blocking-assigning mshr_count_r
        // this same cycle would only keep the textually-later one). The
        // fresh-S_IDLE-dispatch allocation's own count_r/tail_r writes stay
        // inside the S_IDLE case arm below -- mutually exclusive with both
        // conditions here by construction (state can't be S_IDLE and also
        // != S_IDLE/== S_FILL at once).
        if (mshr_complete_now && mshr_alloc_now) begin
            mshr_head_r <= mshr_head_next;
            mshr_tail_r <= mshr_tail_next;
            // count net-unchanged (one entry leaves, one arrives) -- no
            // assignment needed, non-blocking "no write" keeps the old value.
        end
        else if (mshr_complete_now) begin
            mshr_head_r  <= mshr_head_next;
            mshr_count_r <= mshr_count_r - 1'b1;
        end
        else if (mshr_alloc_now) begin
            mshr_tail_r  <= mshr_tail_next;
            mshr_count_r <= mshr_count_r + 1'b1;
        end

        if (mshr_complete_now)
            mshr_valid[mshr_head_r] <= 1'b0;

        if (mshr_alloc_now)
            mshr_alloc(mshr_tail_r, set_idx, victim_target_way, tag,
                       {req_addr[XLEN-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}},
                       word_off, byte_off, req_funct3, req_dest_reg, req_addr,
                       1'b0, {XLEN{1'b0}},   // never a store -- see module header
                       valid[set_idx*WAYS + victim_target_way] && dirty[set_idx*WAYS + victim_target_way],
                       set_idx*WAYS + victim_target_way,
                       {tag_arr[set_idx*WAYS + victim_target_way], set_idx, {OFFSET_BITS{1'b0}}},
                       1'b1);   // always early-retired -- mshr_alloc_now (mshr_busy_dispatch_miss) already requires req_int_load
                       // No victim-cache interaction for a queued-while-busy
                       // entry (vc_do_swap/vc_do_insert stay gated
                       // state==S_IDLE, unchanged) -- deliberate scope cut,
                       // docs/adr/0044.

        // docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F).
        // UNCONDITIONAL, decoupled from `state`/case(state) below entirely --
        // a real deadlock found by running (not anticipated in the original
        // design, which gated this on state==S_IDLE): while THIS module is
        // itself busy (S_WB/S_FILL) waiting on a request to L2, L2Cache.v may
        // need to evict and probe THIS module for a DIFFERENT line (the
        // eviction pressure L2's own miss servicing for the in-flight request
        // creates) -- gating the probe response on S_IDLE meant DCache could
        // never leave its busy state to answer, while L2 could never finish
        // servicing that busy request until the probe was answered. A
        // genuine circular wait, not just a missed corner case -- confirmed
        // by tb_cache_l2_f1.v's own "correctness" scenario hanging
        // completely (never reaching its halt loop) before this fix. Safe to
        // answer from ANY state: the probe reads/invalidates a line chosen
        // by probe_addr's own independent decode (probe_found_line), never
        // the same array slot the main FSM's own in-flight S_WB/S_FILL is
        // concurrently writing (inclusion means a line mid-fill here, not
        // yet valid, can never simultaneously be a line L2 already knows
        // about and wants evicted).
        if (probe_req) begin
            if (probe_found)
                valid[probe_found_line] <= 1'b0;
        end

        case (state)
            S_IDLE: begin
                if (flush_all && !flush_active_r) begin
                    flush_active_r <= 1'b1;
                    flush_scan_r   <= {LINE_IDX_BITS{1'b0}};
                    state <= S_FLUSH_SCAN;
                end
                else if (req_read || req_write) begin
                    if (hit) begin
                        if (hit_main) begin
                            if (req_write) begin
                                data_arr[hit_line_idx*LINE_WORDS + word_off] <=
                                    dcache_merge_write(hit_data, req_funct3[1:0], byte_off, req_wdata);
                                // Generation 2 (RV64) + Generation 4 Phase F
                                // integration gap, found by running the
                                // constrained-random harness at --xlen 64
                                // --cache-mode 1 combined (never exercised
                                // together by any prior phase's own sweep --
                                // confirmed pre-existing, unrelated to L2,
                                // by reproducing identically with L2
                                // disabled). data_arr's own LINE_WORDS
                                // granularity is a fixed 4 bytes regardless
                                // of XLEN (word_off = req_addr[OFFSET_BITS-1:2]),
                                // so an 8-byte `sd` (`F3_STORE_SD`) needs a
                                // SECOND write, one slot higher, for its own
                                // upper 32 bits -- dcache_merge_write itself
                                // stays untouched (32-bit, one-slot,
                                // unchanged) since req_wdata's own low 32
                                // bits already flow through its existing
                                // default/sw-shaped arm correctly (funct3_lo
                                // 2'b11 falls to the same "full replace"
                                // case 2'b10/sw already uses). Naturally-
                                // aligned 8-byte access assumed (same
                                // alignment convention this file's own
                                // header already documents) -- word_off+1
                                // is always the correct, in-line adjacent
                                // slot, never crossing a line boundary.
                                if (XLEN >= 64 && req_funct3 == `F3_STORE_SD)
                                    data_arr[hit_line_idx*LINE_WORDS + word_off + 1] <= req_wdata_hi32;
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
                            // docs/adr/0042. Victim-buffer promote: commit
                            // the buffer's own line into the main array
                            // THIS cycle -- no bus access needed.
                            if (req_write) begin
                                // Same-cycle, mirrors the hit_main write
                                // arm above exactly (resp_ready's own
                                // existing S_IDLE&&hit&&req_write arm
                                // already fires, `hit` having been
                                // broadened to include vc_lookup_hit).
                                // Generation 4 Phase F (docs/adr/0045). Same
                                // sd-upper-32-bits gap the hit_main write
                                // arm above documents in full -- the
                                // victim-buffer promote path needs the
                                // identical second-word handling.
                                for (vcw = 0; vcw < LINE_WORDS; vcw = vcw + 1)
                                    data_arr[(set_idx*WAYS + victim_target_way)*LINE_WORDS + vcw] <=
                                        (vcw == word_off)
                                            ? dcache_merge_write(vc_lookup_data[vcw*XLEN +: XLEN], req_funct3[1:0], byte_off, req_wdata)
                                            : (XLEN >= 64 && req_funct3 == `F3_STORE_SD && vcw == word_off + 1)
                                                ? req_wdata_hi32
                                                : vc_lookup_data[vcw*XLEN +: XLEN];
                                tag_arr[set_idx*WAYS + victim_target_way] <= tag;
                                valid[set_idx*WAYS + victim_target_way]   <= 1'b1;
                                dirty[set_idx*WAYS + victim_target_way]   <= 1'b1; // a write always dirties it, regardless of the promoted line's own prior dirtiness
                                victim[set_idx] <= (victim_target_way == WAYS-1) ? {WAY_BITS{1'b0}} : victim_target_way + 1'b1;
                            end
                            else begin
                                // Read-promote: commit now, but the actual
                                // read still goes through S_HIT_RD next
                                // cycle -- same 1-cycle shape as a real
                                // main-array read-hit (hit_rd_word reads
                                // data_arr combinationally there, and by
                                // then this commit has already landed).
                                for (vcw = 0; vcw < LINE_WORDS; vcw = vcw + 1)
                                    data_arr[(set_idx*WAYS + victim_target_way)*LINE_WORDS + vcw] <= vc_lookup_data[vcw*XLEN +: XLEN];
                                tag_arr[set_idx*WAYS + victim_target_way] <= tag;
                                valid[set_idx*WAYS + victim_target_way]   <= 1'b1;
                                dirty[set_idx*WAYS + victim_target_way]   <= vc_lookup_dirty; // carried through, unchanged by a plain read
                                victim[set_idx] <= (victim_target_way == WAYS-1) ? {WAY_BITS{1'b0}} : victim_target_way + 1'b1;
                                hit_line_r    <= set_idx*WAYS + victim_target_way;
                                hit_word_r    <= word_off;
                                hit_funct3_r  <= req_funct3;
                                hit_byteoff_r <= byte_off;
                                state <= S_HIT_RD;
                                served_addr_r <= req_addr;
                            end
                        end
                    end
                    else begin
                        // Generation 4, Phase E. Was a flat miss_*_r write;
                        // now allocates into the MSHR array at mshr_tail_r
                        // (== mshr_head_r here, queue is empty -- state
                        // can't be S_IDLE otherwise, see mshr_room's own
                        // header comment) via the shared mshr_alloc task.
                        // Bus-service kickoff below (wb_line_r/wb_base_r/
                        // vwb_active_r/state) is UNCHANGED from pre-Phase-E
                        // -- still driven by the live combinational wires,
                        // not the array (mshr_alloc's own writes aren't
                        // visible until next cycle, by which point state
                        // already left S_IDLE).
                        mshr_alloc(mshr_tail_r, set_idx, victim_target_way, tag,
                                   {req_addr[XLEN-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}},
                                   word_off, byte_off, req_funct3, req_dest_reg, req_addr,
                                   req_write, req_wdata,
                                   valid[set_idx*WAYS + victim_target_way] && dirty[set_idx*WAYS + victim_target_way],
                                   set_idx*WAYS + victim_target_way,
                                   {tag_arr[set_idx*WAYS + victim_target_way], set_idx, {OFFSET_BITS{1'b0}}},
                                   mshr_fresh_load_miss);   // the SAME condition that actually granted mshr_accept for this allocation -- see mshr_alloc's own header comment for the bug this closes
                        mshr_count_r <= mshr_count_r + 1'b1;
                        mshr_tail_r  <= (mshr_tail_r == MSHR_ENTRIES-1) ? {MSHR_IDX_BITS{1'b0}} : mshr_tail_r + 1'b1;
                        // docs/adr/0042. The victim buffer's own eviction
                        // (if do_insert's target FIFO slot was valid+dirty)
                        // needs writing back too -- latched here regardless
                        // of which fork below is taken (see S_WB's own
                        // completion logic for how it's chained in). Only
                        // ever set from THIS fork (a fresh S_IDLE dispatch)
                        // -- see mshr_busy_dispatch_miss's own header
                        // comment for why a queued-while-busy entry never
                        // gets victim-buffer interaction (a deliberate,
                        // documented scope cut, docs/adr/0044).
                        vwb_pending_r <= evict_out_valid && evict_out_dirty;
                        vwb_tag_r     <= evict_out_tag;
                        vwb_data_r    <= evict_out_data;
                        if (valid[set_idx*WAYS + victim_target_way] && dirty[set_idx*WAYS + victim_target_way]) begin
                            wb_line_r <= set_idx*WAYS + victim_target_way;
                            wb_base_r <= {tag_arr[set_idx*WAYS + victim_target_way], set_idx, {OFFSET_BITS{1'b0}}};
                            wb_return_to_flush_r <= 1'b0;
                            vwb_active_r <= 1'b0;
                            fill_word_r <= {WORD_OFF_BITS{1'b0}};
                            state <= S_WB;
                        end
                        else if (evict_out_valid && evict_out_dirty) begin
                            // The primary miss's own outgoing line is clean
                            // (or invalid -- no S_WB needed for IT), but the
                            // victim buffer's own FIFO eviction still needs
                            // writing back -- go straight to S_WB configured
                            // for THAT line instead.
                            vwb_active_r <= 1'b1;
                            wb_base_r <= {evict_out_tag, {OFFSET_BITS{1'b0}}};
                            fill_word_r <= {WORD_OFF_BITS{1'b0}};
                            state <= S_WB;
                        end
                        else begin
                            vwb_active_r <= 1'b0;
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
                        // docs/adr/0042. If THIS pass was already the
                        // victim buffer's own chained writeback, nothing
                        // else pending -- fall through to the real fill.
                        if (vwb_active_r) begin
                            vwb_active_r  <= 1'b0;
                            vwb_pending_r <= 1'b0;
                            fill_word_r <= {WORD_OFF_BITS{1'b0}};
                            state <= S_FILL;
                        end
                        else begin
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
                            else if (vwb_pending_r) begin
                                // The PRIMARY line's own writeback just
                                // finished, and the victim buffer's own
                                // eviction (latched back in S_IDLE) is
                                // still pending -- chain a second S_WB pass
                                // for it before falling into S_FILL
                                // (implicitly stays in S_WB -- state isn't
                                // reassigned this branch).
                                vwb_active_r <= 1'b1;
                                wb_base_r <= {vwb_tag_r, {OFFSET_BITS{1'b0}}};
                                fill_word_r <= {WORD_OFF_BITS{1'b0}};
                            end
                            else begin
                                fill_word_r <= {WORD_OFF_BITS{1'b0}};
                                state <= S_FILL;
                            end
                        end
                    end
                    else begin
                        fill_word_r <= fill_word_r + 1'b1;
                    end
                end
            end

            S_FILL: begin
                if (m_ack) begin
                    data_arr[(mshr_set[mshr_head_r]*WAYS + mshr_way[mshr_head_r])*LINE_WORDS + fill_word_r] <= fill_value;
                    if (fill_is_last_word) begin
                        valid[mshr_set[mshr_head_r]*WAYS + mshr_way[mshr_head_r]]   <= 1'b1;
                        tag_arr[mshr_set[mshr_head_r]*WAYS + mshr_way[mshr_head_r]] <= mshr_tag[mshr_head_r];
                        dirty[mshr_set[mshr_head_r]*WAYS + mshr_way[mshr_head_r]]   <= mshr_is_write[mshr_head_r];   // a read-miss fill is clean; a write-allocate fill is dirty
                        victim[mshr_set[mshr_head_r]] <= (mshr_way[mshr_head_r] == WAYS-1) ? {WAY_BITS{1'b0}} : mshr_way[mshr_head_r] + 1'b1;
                        if (REPLACEMENT_POLICY == POLICY_LRU)
                            lru_touch(mshr_set[mshr_head_r], mshr_way[mshr_head_r]);
                        // Generation 4, Phase E. mshr_valid[mshr_head_r]/
                        // mshr_count_r/mshr_head_r themselves are written by
                        // the unified block above (mshr_complete_now) -- not
                        // here, to stay the single writer. Only the NEXT
                        // `state` (and, if continuing to a new head that
                        // itself needs a primary-line writeback first,
                        // wb_line_r/wb_base_r) is this arm's own job.
                        if (mshr_count_after_complete == {MSHR_COUNT_BITS{1'b0}}) begin
                            state <= S_IDLE;
                        end
                        else begin
                            fill_word_r <= {WORD_OFF_BITS{1'b0}};
                            if (mshr_new_head_need_wb) begin
                                wb_line_r     <= mshr_new_head_wb_line;
                                wb_base_r     <= mshr_new_head_wb_base;
                                wb_return_to_flush_r <= 1'b0;
                                vwb_active_r  <= 1'b0;   // a queued entry never has victim-chain business, see mshr_alloc_now's own comment above
                                state <= S_WB;
                            end
                            else begin
                                state <= S_FILL;   // stays S_FILL; mshr_head_r already advancing via the unified block above
                            end
                        end
                    end
                    else begin
                        fill_word_r <= fill_word_r + 1'b1;
                    end
                end
            end

            S_FLUSH_SCAN: begin
                if (valid[flush_scan_r] && dirty[flush_scan_r]) begin
                    wb_line_r <= flush_scan_r;
                    wb_base_r <= {tag_arr[flush_scan_r], flush_scan_set, {OFFSET_BITS{1'b0}}};
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
// Generation 4, Phase E. The S_FILL arm below now also excludes an
// early-retired entry (mshr_early_retired[mshr_head_r]) -- that caller is
// long gone by the time this fires, so req_addr==mshr_orig_addr[mshr_head_r]
// could otherwise spuriously match a genuinely NEW, unrelated request that
// happens to reuse the same address; its own completion is delivered via
// mshr_complete instead (below). hu_pending_r (hit-under-miss) OR's in
// directly -- decoupled from `state`/req_addr matching by construction (see
// its own header comment), and at MSHR_ENTRIES==1 it's permanently 0.
assign resp_ready =
    (state == S_IDLE && hit && req_write && (req_read || req_write)) ||
    (state == S_HIT_RD && req_read && req_addr == served_addr_r) ||
    (state == S_FILL && m_ack && fill_is_last_word && !mshr_early_retired[mshr_head_r]
        && (req_read || req_write) && req_addr == mshr_orig_addr[mshr_head_r]) ||
    hu_pending_r;

// docs/adr/0043-memory-controller-phase-d.md (Generation 4, Phase D). A
// second, real, pre-existing bug found while chasing the RamWishboneAdapter.v
// ack fix above -- previously masked BY that same bug, not caused by fixing
// it. miss_base_r always aligns to word0 of the line (a fill always starts
// there, regardless of which word within the line was actually requested),
// so the LAST word fetched (fill_word_r==LINE_WORDS-1) is only the SAME
// word as the one actually requested (miss_word_off_r) when a line happens
// to be exactly 1 word, or the request happened to target the line's own
// last word. Before this fix, resp_rdata's S_FILL arm always returned
// fill_value -- correct only in that coincidental case. With
// RamWishboneAdapter's ack bug fixed (each word's own raw_word_r now
// genuinely reflects that word's real data instead of staying stuck on
// word0's), this became visible: a miss requesting word0 of a >1-word line
// returned the LAST word's own value instead. Fixed by reading the
// SPECIFICALLY-requested word (miss_word_off_r) from data_arr instead of
// trusting whichever word happened to be fetched last -- data_arr[...] for
// any word OTHER than the one committing THIS cycle was already written on
// an earlier cycle, safely readable now. The one exception: if the
// REQUESTED word IS the one committing this exact cycle, data_arr's own
// write for it is still in-flight (a non-blocking assignment scheduled for
// this same edge) -- reading it combinationally right now would see the
// stale pre-write value, so that specific case still uses fill_value
// directly (the fresh, about-to-be-written value).
wire [31:0] resp_fill_word = (mshr_word_off[mshr_head_r] == fill_word_r)
    ? fill_value
    : data_arr[(mshr_set[mshr_head_r]*WAYS + mshr_way[mshr_head_r])*LINE_WORDS + mshr_word_off[mshr_head_r]];
// Generation 4 Phase F (docs/adr/0045). `ld`'s own upper 32 bits -- same
// "use fill_value if it's the exact word committing THIS cycle, else read
// the already-committed data_arr slot" logic resp_fill_word's own comment
// above derives, mirrored one slot higher. Only meaningful when
// mshr_funct3[mshr_head_r]==`F3_LOAD_LD.
wire [31:0] resp_fill_word_hi = (mshr_word_off[mshr_head_r] + 1'b1 == fill_word_r)
    ? fill_value
    : data_arr[(mshr_set[mshr_head_r]*WAYS + mshr_way[mshr_head_r])*LINE_WORDS + mshr_word_off[mshr_head_r] + 1];

assign resp_rdata =
    (state == S_HIT_RD && req_read && req_addr == served_addr_r)
        ? ((XLEN >= 64 && hit_funct3_r == `F3_LOAD_LD)
            ? {hit_rd_word_hi, hit_rd_word}
            : dcache_extend_read(hit_rd_word, hit_funct3_r, hit_byteoff_r)) :
    (state == S_FILL && m_ack && fill_is_last_word && !mshr_early_retired[mshr_head_r]
        && (req_read || req_write) && req_addr == mshr_orig_addr[mshr_head_r])
        ? ((XLEN >= 64 && mshr_funct3[mshr_head_r] == `F3_LOAD_LD)
            ? {resp_fill_word_hi, resp_fill_word}
            : dcache_extend_read(resp_fill_word, mshr_funct3[mshr_head_r], mshr_byteoff[mshr_head_r])) :
    hu_pending_r ? hu_data_r :
                                                        {XLEN{1'b0}};

// Generation 4, Phase E (docs/adr/0044-non-blocking-dcache-mshr-phase-e.md).
// mshr_accept was already declared combinationally above (dispatch section).
// mshr_complete fires the SAME cycle resp_ready's own S_FILL condition
// would have fired for a non-early-retired entry, but for the OPPOSITE case
// -- an early-retired load whose own caller already left.
assign mshr_complete      = (state == S_FILL) && m_ack && fill_is_last_word && mshr_early_retired[mshr_head_r];
assign mshr_complete_reg  = mshr_dest_reg[mshr_head_r];
// Generation 4 Phase F (docs/adr/0045). Same ld-combining special case
// resp_rdata's own S_FILL arm uses -- a non-blocking (early-retired) ld
// miss needs its own upper 32 bits here too.
assign mshr_complete_data = (XLEN >= 64 && mshr_funct3[mshr_head_r] == `F3_LOAD_LD)
    ? {resp_fill_word_hi, resp_fill_word}
    : dcache_extend_read(resp_fill_word, mshr_funct3[mshr_head_r], mshr_byteoff[mshr_head_r]);
assign mshr_outstanding   = (mshr_count_r != {MSHR_COUNT_BITS{1'b0}});

assign flush_busy = flush_active_r;
assign flush_done = flush_done_r;

// docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). probe_ack fires
// combinationally the same cycle probe_req is seen, from ANY state (see the
// unconditional probe-service block above the case(state) for why -- gating
// this on state==S_IDLE was a real deadlock, found by running), whether or
// not a matching line was actually found -- "wasn't here" is itself a
// complete, valid answer (L2Cache.v's own header covers why an over-eager
// probe is harmless). probe_dirty/probe_data are don't-care when
// !probe_found; L2's own probe response handling never inspects them then.
assign probe_ack   = probe_req;
assign probe_dirty = probe_found && dirty[probe_found_line];
generate
    for (gw = 0; gw < LINE_WORDS; gw = gw + 1) begin : gen_probe_data
        assign probe_data[gw*XLEN +: XLEN] = data_arr[probe_found_line*LINE_WORDS + gw];
    end
endgenerate

assign m_cyc    = (state == S_WB) || (state == S_FILL);
assign m_stb    = m_cyc;
assign m_we     = (state == S_WB);
assign m_addr   = (state == S_WB) ? (wb_base_r + {{(XLEN-OFFSET_BITS){1'b0}}, fill_word_r, 2'b00})
                                   : (mshr_base[mshr_head_r] + {{(XLEN-OFFSET_BITS){1'b0}}, fill_word_r, 2'b00});
// docs/adr/0042. vwb_active_r selects the victim buffer's own latched
// evicted line (vwb_data_r, a flat XLEN*LINE_WORDS-wide register, not a
// data_arr index) instead of the primary miss's own real main-array line.
assign m_data_o = (state == S_WB)
    ? (vwb_active_r ? vwb_data_r[fill_word_r*XLEN +: XLEN] : data_arr[wb_line_r*LINE_WORDS + fill_word_r])
    : {XLEN{1'b0}};
assign m_sel    = {`WB_SEL_WIDTH{1'b1}};
assign m_funct3 = 3'b010;   // fill/writeback are always full-word transfers

// docs/adr/0043-memory-controller-phase-d.md (Generation 4, Phase D).
// BURST_ENABLE=0: always CTI_CLASSIC, bit-exact with pre-Phase-D behavior.
// BURST_ENABLE=1: S_WB and S_FILL (and a chained vwb writeback, which
// reuses fill_word_r the same way) are each their own independent burst --
// fill_is_last_word already identifies "the last word of whichever
// transfer is currently active" regardless of which state that is, so no
// separate burst-boundary tracking is needed here.
assign m_cti = (!BURST_ENABLE || !m_cyc) ? `CTI_CLASSIC
             : (fill_is_last_word ? `CTI_END_OF_BURST : `CTI_INCR_BURST);

endmodule

`default_nettype wire
