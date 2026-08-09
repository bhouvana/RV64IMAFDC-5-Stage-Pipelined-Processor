`default_nettype none

// docs/adr/0042-victim-cache-phase-c.md (Generation 4, Phase C). A small,
// fully-associative buffer absorbing lines just evicted from ICache.v/
// DCache.v's own set-associative main array, so a thrashed line comes back
// in one cycle (a register-to-register copy) instead of a full backing-
// store miss. Deliberately its own standalone module (mirrors Tlb.v/Bht.v's
// own "small associative array, combinational read port" shape) rather than
// inlined into each cache -- one implementation shared by both ICache.v
// (WITH_DIRTY=0, no dirty state at all -- read-only) and DCache.v
// (WITH_DIRTY=1).
//
// Internal replacement is plain FIFO (a single wrapping pointer) -- with
// only a handful of entries, this mirrors REPLACEMENT_POLICY's own
// documented POLICY_ROUND_ROBIN/POLICY_FIFO equivalence at this scale
// (docs/adr/0041): a separate LRU-among-victim-entries scheme would be
// real extra RTL for a benefit no benchmark this project has run has ever
// shown round-robin/FIFO measurably losing at this associativity.
//
// # ponytail: FIFO-only internal replacement, not LRU-among-victim-entries.
// Upgrade only if a real forced-thrash benchmark shows FIFO evicting a
// still-hot line while a colder one sits idle in another slot.
//
// Naming note: every internal signal is prefixed vc_/fifo_ -- NEVER a bare
// `victim` identifier -- because ICache.v/DCache.v already have a live
// signal literally named `victim[]` (their own per-set round-robin fill
// pointer, unrelated to this module). Confirmed deliberate, not an
// oversight.
//
// Interface shape: a passive combinational lookup port (mirrors Tlb.v's
// own always-live query), plus two one-cycle-pulsed update ports.
// `do_swap` is used on a promote-hit -- the caller already knows (from
// `lookup_hit`) that an entry matches `lookup_tag` this same cycle, so it
// doesn't need to tell this module WHICH slot; this module recomputes that
// combinationally every cycle already. `do_insert` is used on a genuine
// backing-store miss eviction, and surfaces whatever it's about to
// overwrite (if anything) combinationally the SAME cycle, before the
// clock edge -- so the caller can write that back if it's dirty, rather
// than silently losing it.
module VictimCache #(
    parameter ENTRIES    = 4,   // number of buffer slots. 0 disables (see
                                  // ICache.v/DCache.v's own generate-if guard
                                  // at the instantiation site -- this module
                                  // is never actually instantiated at
                                  // ENTRIES==0). Must be >= 2 if instantiated
                                  // (mirrors WAYS's own ">= 2" requirement,
                                  // ICache.v:41) -- $clog2(1)-1 underflows.
    parameter WITH_DIRTY = 1,   // 0 for I$ (no dirty tracking at all, every
                                  // dirty output reads 0), 1 for D$.
    parameter TAG_WIDTH  = 32,  // width of the combined set+tag address bits
                                  // identifying a line (a buffer entry can
                                  // come from any set, so there's no separate
                                  // set index -- the full set+tag together is
                                  // this module's own tag).
    parameter LINE_WORDS = 4,   // XLEN-wide words per line.
    parameter XLEN       = 32
)(
    input  wire clk,
    input  wire rst,   // active-low, matches every other module in this project

    // Lookup port: passive, combinational, always reflects lookup_tag.
    input  wire [TAG_WIDTH-1:0]         lookup_tag,
    output wire                         lookup_hit,
    output wire [XLEN*LINE_WORDS-1:0]   lookup_data,   // valid only if lookup_hit
    output wire                         lookup_dirty,  // valid only if lookup_hit && WITH_DIRTY

    // Swap port: one-cycle pulse on a promote-hit. Replaces whichever entry
    // lookup_tag currently hits with the line being pushed out of the main
    // cache to make room. Precondition: lookup_hit must be 1 the same cycle
    // do_swap is asserted (never asserted alongside do_insert).
    input  wire                         do_swap,
    input  wire [TAG_WIDTH-1:0]         swap_in_tag,
    input  wire [XLEN*LINE_WORDS-1:0]   swap_in_data,
    input  wire                         swap_in_dirty,

    // Insert port: one-cycle pulse on a genuine backing-store miss eviction
    // (lookup_hit was 0 this same cycle). Picks the next FIFO slot. If that
    // slot already holds a valid entry, it's surfaced combinationally THIS
    // SAME CYCLE, before being overwritten on the clock edge.
    input  wire                         do_insert,
    input  wire [TAG_WIDTH-1:0]         insert_tag,
    input  wire [XLEN*LINE_WORDS-1:0]   insert_data,
    input  wire                         insert_dirty,
    output wire                         evict_out_valid,
    output wire [TAG_WIDTH-1:0]         evict_out_tag,
    output wire [XLEN*LINE_WORDS-1:0]   evict_out_data,
    output wire                         evict_out_dirty
);

localparam WAY_BITS = $clog2(ENTRIES);

reg                 vc_valid[0:ENTRIES-1];
reg [TAG_WIDTH-1:0] vc_tag  [0:ENTRIES-1];
reg [XLEN-1:0]      vc_data [0:ENTRIES*LINE_WORDS-1];
reg                 vc_dirty[0:ENTRIES-1];   // only meaningful if WITH_DIRTY -- see gen_vc_compare
reg [WAY_BITS-1:0]  fifo_next_r;             // next slot a do_insert will use

// Same OR-of-AND-masked reduction shape as ICache.v's own way_hit/inst_acc
// (docs/adr/0041's header comment covers why: at most one entry can ever
// validly hit -- tags are unique within this buffer by construction, since
// do_swap replaces in place and do_insert only ever targets the FIFO's own
// next slot -- so no priority logic is needed, just an OR of masked reads).
genvar ge, gw;
wire [ENTRIES-1:0]         vc_hit;
wire [XLEN*LINE_WORDS-1:0] vc_way_data[0:ENTRIES-1];
wire [XLEN*LINE_WORDS-1:0] vc_data_acc [0:ENTRIES];
wire                       vc_dirty_acc[0:ENTRIES];
assign vc_data_acc[0]  = {(XLEN*LINE_WORDS){1'b0}};
assign vc_dirty_acc[0] = 1'b0;
generate
    for (ge = 0; ge < ENTRIES; ge = ge + 1) begin : gen_vc_compare
        assign vc_hit[ge] = vc_valid[ge] && (vc_tag[ge] == lookup_tag);
        for (gw = 0; gw < LINE_WORDS; gw = gw + 1) begin : gen_vc_word
            assign vc_way_data[ge][gw*XLEN +: XLEN] = vc_data[ge*LINE_WORDS + gw];
        end
        assign vc_data_acc[ge+1]  = vc_data_acc[ge]  | (vc_hit[ge] ? vc_way_data[ge] : {(XLEN*LINE_WORDS){1'b0}});
        assign vc_dirty_acc[ge+1] = vc_dirty_acc[ge] | (vc_hit[ge] && WITH_DIRTY && vc_dirty[ge]);
    end
endgenerate

wire [WAY_BITS-1:0] vc_hit_way_acc_final; // computed below via the same accumulator idiom, kept separate since it indexes WAY_BITS not data width
wire [WAY_BITS-1:0] vc_hit_way_acc[0:ENTRIES];
assign vc_hit_way_acc[0] = {WAY_BITS{1'b0}};
generate
    for (ge = 0; ge < ENTRIES; ge = ge + 1) begin : gen_vc_hitway
        assign vc_hit_way_acc[ge+1] = vc_hit_way_acc[ge] | (vc_hit[ge] ? ge[WAY_BITS-1:0] : {WAY_BITS{1'b0}});
    end
endgenerate
assign vc_hit_way_acc_final = vc_hit_way_acc[ENTRIES];

assign lookup_hit   = |vc_hit;
assign lookup_data  = vc_data_acc[ENTRIES];
assign lookup_dirty = vc_dirty_acc[ENTRIES];

assign evict_out_valid = do_insert && vc_valid[fifo_next_r];
assign evict_out_tag   = vc_tag[fifo_next_r];
assign evict_out_dirty = do_insert && vc_valid[fifo_next_r] && WITH_DIRTY && vc_dirty[fifo_next_r];
generate
    for (gw = 0; gw < LINE_WORDS; gw = gw + 1) begin : gen_evict_word
        assign evict_out_data[gw*XLEN +: XLEN] = vc_data[fifo_next_r*LINE_WORDS + gw];
    end
endgenerate

integer vreset_i, wi;
always @(posedge clk) begin
    if (~rst) begin
        fifo_next_r <= {WAY_BITS{1'b0}};
        for (vreset_i = 0; vreset_i < ENTRIES; vreset_i = vreset_i + 1) begin
            vc_valid[vreset_i] <= 1'b0;
            vc_dirty[vreset_i] <= 1'b0;
        end
    end
    else begin
        // Preconditions (see port comments above): do_swap only ever
        // asserted when lookup_hit==1 this same cycle; do_swap and
        // do_insert are never both asserted the same cycle.
        if (do_swap) begin
            vc_tag[vc_hit_way_acc_final]   <= swap_in_tag;
            vc_dirty[vc_hit_way_acc_final] <= swap_in_dirty;
            for (wi = 0; wi < LINE_WORDS; wi = wi + 1)
                vc_data[vc_hit_way_acc_final*LINE_WORDS + wi] <= swap_in_data[wi*XLEN +: XLEN];
            // vc_valid[vc_hit_way_acc_final] stays 1 -- this is a replace, not an invalidate.
        end
        if (do_insert) begin
            vc_valid[fifo_next_r] <= 1'b1;
            vc_tag[fifo_next_r]   <= insert_tag;
            vc_dirty[fifo_next_r] <= insert_dirty;
            for (wi = 0; wi < LINE_WORDS; wi = wi + 1)
                vc_data[fifo_next_r*LINE_WORDS + wi] <= insert_data[wi*XLEN +: XLEN];
            fifo_next_r <= (fifo_next_r == ENTRIES-1) ? {WAY_BITS{1'b0}} : fifo_next_r + 1'b1;
        end
    end
end

endmodule

`default_nettype wire
