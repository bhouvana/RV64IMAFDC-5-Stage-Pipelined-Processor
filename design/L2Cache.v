`default_nettype none

`include "wb_defs.vh"

// docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). A shared L2 cache
// module -- ONE implementation, instantiated twice (I-side, D-side) by
// riscvpipeline.v, same "one implementation shared by both caches" precedent
// VictimCache.v already established (docs/adr/0042). This project's I$/D$
// backing stores are physically separate arrays (Harvard-style) -- "shared"
// means code reuse via one parameterized module, never a literally-unified
// address space.
//
// Wishbone-slave-in / Wishbone-master-out: the upstream `u_*` port presents
// the identical shape DCache.v's own `m_*` port already drives (so DCache.v
// needs ZERO FSM changes to gain an L2 -- it already just talks Wishbone to
// whatever is below it). The downstream `m_*` port presents the identical
// shape MemoryController.v's `dcache_*` arm already expects.
//
// Internal FSM closely mirrors DCache.v's own proven S_IDLE/S_HIT_RD/S_WB/
// S_FILL shape -- deliberately WITHOUT DCache.v's own MSHR array, victim-
// buffer instantiation, or burst-CTI generation (blocking, single-
// outstanding, always presents `` `CTI_CLASSIC `` downstream if a caller
// wires cti at all -- this module doesn't even expose a cti port, see the
// ADR's own Future improvements). Same incremental-phase discipline every
// prior Gen4 axis (victim cache, memory controller, MSHR, burst) followed --
// each arrived as its own phase, not bundled for free into this one.
//
// Inclusion: this module unconditionally probes the owning L1 before
// evicting ANY currently-valid line (not just ones it believes are still
// L1-resident) -- there is no `present_in_l1` tracking bit anywhere in this
// module. L1's own probe response is the sole source of truth for whether a
// line is really present and really dirty; an unnecessary probe (the line
// was already gone from L1) costs one handshake round-trip and nothing else.
// This removes an entire bookkeeping mechanism (a bit that would otherwise
// need updating correctly at three separate event sites) for a bounded,
// honest, documented performance-only cost -- the same `# ponytail`-style
// tradeoff VictimCache.v's own FIFO-only replacement comment already
// establishes precedent for in this codebase.
module L2Cache #(
    parameter XLEN = 32,
    parameter WAYS = 4,
    parameter CACHE_SIZE_BYTES = 8192,
    parameter LINE_BYTES = 16,        // must match the serving L1's own LINE_BYTES -- documented, not enforced (same convention as WAYS>=2 in ICache.v/DCache.v)
    // Same closed POLICY_ROUND_ROBIN(0)/POLICY_FIFO(1)/POLICY_LRU(2) enum
    // DCache.v/ICache.v already use -- independent of whichever L1 policy
    // this instance's own caller happens to be running (confirmed via
    // AskUserQuestion: L2_REPLACEMENT_POLICY is its own top-level knob).
    parameter REPLACEMENT_POLICY = 0,
    // 0 for the I-side instance (read-only -- no writeback ever, dirty[] and
    // the probe's own dirty/data path stay permanently inert), 1 for the
    // D-side instance. Mirrors VictimCache.v's own WITH_DIRTY convention.
    parameter WITH_DIRTY = 1
)(
    input clk,
    input rst,

    // Upstream slave port -- Wishbone-shaped, facing the L1 cache's own
    // existing Wishbone-master output (DCache.v's `m_*` shape exactly; for
    // the I-side instance, ICache.v's new L2_ENABLE-gated bus-master port,
    // Generation 4 Phase F6). Held continuously across a whole line's worth
    // of words by the caller (mirrors DCache.v's own `m_cyc =
    // (state==S_WB)||(state==S_FILL)`), one `u_ack` per word.
    input                          u_cyc,
    input                          u_stb,
    input                          u_we,
    input      [XLEN-1:0]          u_addr,
    input      [XLEN-1:0]          u_data_o,
    input      [`WB_SEL_WIDTH-1:0] u_sel,
    input      [2:0]               u_funct3,
    output     [XLEN-1:0]          u_data_i,
    output                         u_ack,

    // Downstream master port -- Wishbone-shaped, facing MemoryController.v
    // (D-side instance) or InstructionMemoryWishboneAdapter.v (I-side
    // instance, point-to-point, no shared bus involved). Always presents a
    // plain classic (non-burst) transaction shape -- no cti port at all,
    // see module header.
    output                         m_cyc,
    output                         m_stb,
    output                         m_we,
    output     [XLEN-1:0]          m_addr,
    output     [XLEN-1:0]          m_data_o,
    output     [`WB_SEL_WIDTH-1:0] m_sel,
    output     [2:0]               m_funct3,
    input      [XLEN-1:0]          m_data_i,
    input                          m_ack,

    // Inclusion probe port -- into whichever L1 this instance serves
    // (DCache.v Generation 4 Phase F3 / ICache.v Phase F4). Asserted before
    // ANY eviction of a currently-valid line (unconditional, see module
    // header) -- held until probe_ack pulses back.
    output                         probe_req,
    output     [XLEN-1:0]          probe_addr,
    input                          probe_ack,
    input                          probe_dirty,   // only meaningful if WITH_DIRTY; the I-side L1 (ICache.v) exposes no such output, tied 0 at the instantiation site
    input      [XLEN*(LINE_BYTES/4)-1:0] probe_data,   // only meaningful if probe_dirty

    // docs/adr/0025-hpc-performance-csrs.md-style perf taps (testbench-tap
    // only this phase, see the ADR's own Future improvements -- no HPM/CSR
    // event wiring yet). Exactly-once-per-real-access, same discipline
    // DCache.v's own access_hit/access_miss already established.
    output                         access_hit,
    output                         access_miss
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

localparam POLICY_ROUND_ROBIN = 0;
localparam POLICY_FIFO        = 1;
localparam POLICY_LRU         = 2;

wire [WORD_OFF_BITS-1:0] word_off = u_addr[OFFSET_BITS-1:2];
wire [1:0]               byte_off = u_addr[1:0];
// docs/adr/0041's own SET_BITS==0 fix, same rationale (a fully-associative
// L2 sizing -- WAYS==NUM_LINES -- would otherwise produce an invalid
// high<low part-select).
wire [SET_BITS-1:0]      set_idx;
generate
if (SET_BITS == 0) begin : gen_set_idx_fully_assoc
    assign set_idx = 1'b0;
end else begin : gen_set_idx_normal
    assign set_idx = u_addr[OFFSET_BITS+SET_BITS-1:OFFSET_BITS];
end
endgenerate
wire [TAG_BITS-1:0] tag = u_addr[XLEN-1:OFFSET_BITS+SET_BITS];

reg                 valid   [0:NUM_LINES-1];
reg                 dirty   [0:NUM_LINES-1];   // inert (always 0) when WITH_DIRTY==0
reg [TAG_BITS-1:0]  tag_arr [0:NUM_LINES-1];
reg [XLEN-1:0]      data_arr[0:NUM_LINES*LINE_WORDS-1];
reg [WAY_BITS-1:0]  victim  [0:NUM_SETS-1];
reg [WAY_BITS-1:0]  age     [0:NUM_SETS-1][0:WAYS-1];

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
wire hit = |way_hit;

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

wire [WAY_BITS-1:0] victim_target_way = (REPLACEMENT_POLICY == POLICY_LRU) ? lru_way_idx : victim[set_idx];

// Width/sign extension for a load -- same funct3-keyed shape
// DataMemoryBRAM.v/DCache.v's own dcache_extend_read already use.
function [31:0] l2_extend_read;
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
                l2_extend_read = {{24{b[7]}}, b};
            end
            3'b100: begin // lbu
                case (byte_off_f)
                    2'd0: b = word[7:0];
                    2'd1: b = word[15:8];
                    2'd2: b = word[23:16];
                    default: b = word[31:24];
                endcase
                l2_extend_read = {24'b0, b};
            end
            3'b001: begin // lh
                h = byte_off_f[1] ? word[31:16] : word[15:0];
                l2_extend_read = {{16{h[15]}}, h};
            end
            3'b101: begin // lhu
                h = byte_off_f[1] ? word[31:16] : word[15:0];
                l2_extend_read = {16'b0, h};
            end
            default: l2_extend_read = word; // lw
        endcase
    end
endfunction

// Byte/halfword/word merge for a store -- same shape DCache.v's own
// dcache_merge_write already uses.
function [31:0] l2_merge_write;
    input [31:0] old_word;
    input [1:0]  funct3_lo;
    input [1:0]  byte_off_f;
    input [31:0] wdata;
    begin
        case (funct3_lo)
            2'b00: begin // sb
                case (byte_off_f)
                    2'd0: l2_merge_write = {old_word[31:8],  wdata[7:0]};
                    2'd1: l2_merge_write = {old_word[31:16], wdata[7:0], old_word[7:0]};
                    2'd2: l2_merge_write = {old_word[31:24], wdata[7:0], old_word[15:0]};
                    default: l2_merge_write = {wdata[7:0], old_word[23:0]};
                endcase
            end
            2'b01: // sh
                l2_merge_write = byte_off_f[1] ? {wdata[15:0], old_word[15:0]} : {old_word[31:16], wdata[15:0]};
            default: // sw
                l2_merge_write = wdata;
        endcase
    end
endfunction

localparam S_IDLE       = 3'd0;
localparam S_HIT_RD     = 3'd1;
localparam S_PROBE_WAIT = 3'd2;
localparam S_WB         = 3'd3;
localparam S_FILL       = 3'd4;

reg [2:0] state;

reg [LINE_IDX_BITS-1:0] hit_line_r;
reg [WORD_OFF_BITS-1:0] hit_word_r;
reg [2:0]               hit_funct3_r;
reg [1:0]               hit_byteoff_r;
reg [XLEN-1:0]          served_addr_r;

// Single-outstanding miss bookkeeping (no MSHR array -- this module is
// deliberately blocking, see header comment).
reg [SET_BITS-1:0]      miss_set_r;
reg [WAY_BITS-1:0]      miss_way_r;
reg [TAG_BITS-1:0]      miss_tag_r;
reg [XLEN-1:0]          miss_base_r;
reg [WORD_OFF_BITS-1:0] miss_word_off_r;
reg [1:0]               miss_byteoff_r;
reg [2:0]               miss_funct3_r;
reg                     miss_is_write_r;
reg [XLEN-1:0]          miss_wdata_r;
reg [XLEN-1:0]          miss_orig_addr_r;

reg [WORD_OFF_BITS-1:0] fill_word_r;   // shared progress counter, WB and FILL
reg [LINE_IDX_BITS-1:0] wb_line_r;
reg [XLEN-1:0]          wb_base_r;     // also this eviction's own probe_addr
reg                     probe_dirty_r;
reg [XLEN*LINE_WORDS-1:0] probe_data_r;

wire fill_is_last_word = (fill_word_r == LINE_WORDS-1);
wire fill_do_merge = miss_is_write_r && (fill_word_r == miss_word_off_r);
wire [31:0] fill_value = fill_do_merge
    ? l2_merge_write(m_data_i, miss_funct3_r[1:0], miss_byteoff_r, miss_wdata_r)
    : m_data_i;

wire [31:0] resp_fill_word = (miss_word_off_r == fill_word_r)
    ? fill_value
    : data_arr[(miss_set_r*WAYS + miss_way_r)*LINE_WORDS + miss_word_off_r];

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

wire access_hit_calc  = (state == S_IDLE && (u_cyc && u_stb) && u_we && hit) ||
                         (state == S_HIT_RD && u_addr == served_addr_r);
wire access_miss_calc = (state == S_IDLE) && (u_cyc && u_stb) && !hit;
assign access_hit  = access_hit_calc;
assign access_miss = access_miss_calc;

wire [WAY_BITS-1:0] access_hit_way = (state == S_IDLE) ? hit_line_idx[WAY_BITS-1:0]        : hit_line_r[WAY_BITS-1:0];
// docs/adr/0045-l2-cache-phase-f.md. Same SET_BITS==0 guard DCache.v's own
// access_hit_set copy uses -- [LINE_IDX_BITS-1:WAY_BITS] reverses to a
// high<low slice when SET_BITS==0 (a fully-associative L2, e.g. this
// phase's own tb_cache_l2_f1.v "correctness" sizing).
wire [SET_BITS-1:0] access_hit_set;
generate
if (SET_BITS == 0) begin : gen_access_hit_set_fully_assoc
    assign access_hit_set = 1'b0;
end else begin : gen_access_hit_set_normal
    assign access_hit_set = (state == S_IDLE) ? hit_line_idx[LINE_IDX_BITS-1:WAY_BITS] : hit_line_r[LINE_IDX_BITS-1:WAY_BITS];
end
endgenerate

integer reset_i, reset_j;
always @(posedge clk) begin
    if (~rst) begin
        state <= S_IDLE;
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
        if (REPLACEMENT_POLICY == POLICY_LRU && access_hit_calc)
            lru_touch(access_hit_set, access_hit_way);

        case (state)
            S_IDLE: begin
                if (u_cyc && u_stb) begin
                    if (hit) begin
                        if (u_we) begin
                            data_arr[hit_line_idx*LINE_WORDS + word_off] <=
                                l2_merge_write(hit_data, u_funct3[1:0], byte_off, u_data_o);
                            dirty[hit_line_idx] <= 1'b1;
                            // u_ack combinational this cycle, stays in S_IDLE
                        end
                        else begin
                            hit_line_r    <= hit_line_idx;
                            hit_word_r    <= word_off;
                            hit_funct3_r  <= u_funct3;
                            hit_byteoff_r <= byte_off;
                            served_addr_r <= u_addr;
                            state <= S_HIT_RD;
                        end
                    end
                    else begin
                        miss_set_r       <= set_idx;
                        miss_way_r       <= victim_target_way;
                        miss_tag_r       <= tag;
                        miss_base_r      <= {u_addr[XLEN-1:OFFSET_BITS], {OFFSET_BITS{1'b0}}};
                        miss_word_off_r  <= word_off;
                        miss_byteoff_r   <= byte_off;
                        miss_funct3_r    <= u_funct3;
                        miss_is_write_r  <= u_we;
                        miss_wdata_r     <= u_data_o;
                        miss_orig_addr_r <= u_addr;
                        if (valid[set_idx*WAYS + victim_target_way]) begin
                            wb_line_r <= set_idx*WAYS + victim_target_way;
                            wb_base_r <= {tag_arr[set_idx*WAYS + victim_target_way], set_idx, {OFFSET_BITS{1'b0}}};
                            state <= S_PROBE_WAIT;
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

            // Unconditional probe -- see module header. probe_req/probe_addr
            // are driven combinationally from state==S_PROBE_WAIT/wb_base_r
            // (below); this arm only handles the response.
            S_PROBE_WAIT: begin
                if (probe_ack) begin
                    probe_dirty_r <= probe_dirty;
                    probe_data_r  <= probe_data;
                    fill_word_r   <= {WORD_OFF_BITS{1'b0}};
                    if (dirty[wb_line_r] || probe_dirty)
                        state <= S_WB;
                    else
                        state <= S_FILL;
                end
            end

            S_WB: begin
                if (m_ack) begin
                    if (fill_is_last_word) begin
                        dirty[wb_line_r] <= 1'b0;
                        fill_word_r <= {WORD_OFF_BITS{1'b0}};
                        state <= S_FILL;
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
                        dirty[miss_set_r*WAYS + miss_way_r]   <= miss_is_write_r;
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

            default: state <= S_IDLE;
        endcase
    end
end

assign u_ack =
    (state == S_IDLE && (u_cyc && u_stb) && u_we && hit) ||
    (state == S_HIT_RD && u_addr == served_addr_r) ||
    (state == S_FILL && m_ack && fill_is_last_word && u_addr == miss_orig_addr_r);

assign u_data_i =
    (state == S_HIT_RD && u_addr == served_addr_r)
        ? l2_extend_read(data_arr[hit_line_r*LINE_WORDS + hit_word_r], hit_funct3_r, hit_byteoff_r) :
    (state == S_FILL && m_ack && fill_is_last_word && u_addr == miss_orig_addr_r)
        ? l2_extend_read(resp_fill_word, miss_funct3_r, miss_byteoff_r) :
    {XLEN{1'b0}};

assign probe_req  = (state == S_PROBE_WAIT);
assign probe_addr = wb_base_r;

assign m_cyc = (state == S_WB) || (state == S_FILL);
assign m_stb = m_cyc;
assign m_we  = (state == S_WB);
assign m_addr = (state == S_WB) ? (wb_base_r + {{(XLEN-OFFSET_BITS){1'b0}}, fill_word_r, 2'b00})
                                 : (miss_base_r + {{(XLEN-OFFSET_BITS){1'b0}}, fill_word_r, 2'b00});
assign m_data_o = (state == S_WB)
    ? (probe_dirty_r ? probe_data_r[fill_word_r*XLEN +: XLEN] : data_arr[wb_line_r*LINE_WORDS + fill_word_r])
    : {XLEN{1'b0}};
assign m_sel    = {`WB_SEL_WIDTH{1'b1}};
assign m_funct3 = 3'b010;   // fill/writeback are always full-word transfers

endmodule

`default_nettype wire
