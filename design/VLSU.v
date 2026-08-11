`default_nettype none

`include "riscv_defs.vh"

// Generation 7, Pillar V, Phase 3 (docs/adr/0064). Vector load/store unit
// -- real vle8/16/32/64.v and vse8/16/32/64.v (unit-stride only; indexed/
// strided/segment forms are real spec but out of this phase's own scope,
// see the ADR's Future improvements). Drives its own dedicated,
// synchronous memory port (a 3rd requester on the shared m_DMem port,
// alongside LoadStoreQueue.v's own ordinary traffic and Ptw39's own
// walker traffic -- OOOCore.v's own existing 2-way arbitration widens to
// 3-way, mirroring the exact precedent Gen6-P2 already established
// widening it from 1-way to 2-way) rather than routing element-by-
// element through LoadStoreQueue.v's own rename/ROB machinery -- LSQ was
// built for one scalar-shaped access per dispatched instruction, not an
// internal multi-element loop, and this module's own accumulate-then-
// complete-once shape (mirrors VALU.v's own result_r pattern exactly)
// needs no new LSQ capability to get a real, working, honestly-scoped
// unit-stride vector load/store.
//
// Real EEW (effective element width) comes from the instruction's own
// funct3 field, independent of vtype.SEW -- real spec allows the two to
// differ (EMUL reshaping); this phase deliberately does NOT implement
// that reshaping (a real, narrow, flagged scope cut: EEW is assumed to
// match the current vtype.SEW, the overwhelmingly common real-code case,
// see the ADR).
//
// 2-cycle-per-element for loads (address+memRead one cycle, DataMemoryBRAM.v's
// own registered 1-cycle read latency means the data is only valid the
// NEXT cycle -- mirrors the existing LSQ/PTW arbitration's own identical
// latency assumption), 1-cycle-per-element for stores (DataMemoryBRAM.v's
// own writes complete the same cycle memWrite is asserted). A real,
// honest, not-maximally-fast tradeoff, not a hidden shortcut -- flagged
// in the ADR as future work if profiling ever motivates a wider/pipelined
// port.
//
// Masked-off elements (vm=0, v0 bit clear) and tail elements (index>=vl)
// get NO real memory access at all for either loads or stores -- real
// spec unit-stride behavior for stores (never touch memory for an
// inactive element) and a legal "agnostic" choice for loads (destination
// content unspecified -- this module writes zero, same tail-agnostic
// policy VALU.v already established).
module VLSU #(
    parameter VLEN = 512,
    parameter XLEN = 64
)(
    input  wire                        clk,
    input  wire                        rst,

    input  wire                        start,        // one-cycle pulse, caller-controlled (mirrors VALU.v/Divider.v)
    input  wire                        is_store,
    input  wire [XLEN-1:0]             base_addr,    // rs1's own value, captured at issue
    input  wire [VLEN-1:0]             store_data,   // source vector register (vs3), for stores
    input  wire [2:0]                  eew,          // real vle/vse funct3: 000=8,101=16,110=32,111=64
    input  wire [VLEN-1:0]             v0_data,
    input  wire                        vm,
    input  wire [$clog2(VLEN/8+1)-1:0] vl,

    // Dedicated synchronous memory port -- a 3rd requester on the shared
    // m_DMem arbitration (see OOOCore.v's own dmem_arb_* wiring).
    output reg                         mem_memRead,
    output reg                         mem_memWrite,
    output reg  [XLEN-1:0]             mem_address,
    output reg  [XLEN-1:0]             mem_writeData,
    output reg  [2:0]                  mem_funct3,
    input  wire [XLEN-1:0]             mem_readData,

    output wire                        busy,
    output reg                         done,         // one-cycle pulse
    output reg  [VLEN-1:0]             result        // accumulated load result
);

localparam MAX_ELEMS = VLEN/8;
localparam EIDX_BITS = $clog2(MAX_ELEMS);
localparam CNT_BITS  = EIDX_BITS + 1;    // see VALU.v's own identical header note -- a COUNT (up to
                                            // MAX_ELEMS itself) needs one more bit than an INDEX (0..MAX_ELEMS-1)
localparam SHIFT_BITS = $clog2(VLEN);

localparam S_IDLE        = 3'd0;
localparam S_LOAD_ISSUE  = 3'd1;
localparam S_LOAD_WAIT   = 3'd2;
localparam S_LOAD_CAPTURE = 3'd3;
localparam S_STORE_ISSUE = 3'd4;

reg [2:0]             state_r;
reg [EIDX_BITS-1:0]   elem_r;
reg [SHIFT_BITS-1:0]  shift_r;
reg [VLEN-1:0]        store_data_r, v0_r;
reg [XLEN-1:0]        base_addr_r;
reg                   vm_r;
reg [2:0]             eew_r;
reg [CNT_BITS-1:0]    vl_r;
reg                   is_store_r;

assign busy = (state_r != S_IDLE);

wire [7:0] elem_width  = (8'd8 << eew_r[1:0]);   // eew field 000/101/110/111 -> low 2 bits 00/01/10/11 -> 8/16/32/64
wire [3:0] elem_bytes  = elem_width[6:3];         // 1/2/4/8
wire [CNT_BITS-1:0] elems_this_eew = (MAX_ELEMS[CNT_BITS-1:0] >> eew_r[1:0]);

wire mask_bit    = (v0_r >> elem_r) & 1'b1;
wire elem_active = (elem_r < vl_r) && (vm_r || mask_bit);

// Real scalar load/store funct3 encodings (riscv_defs.vh), unsigned
// variants for loads (this module masks to elem_width itself regardless,
// so sign-extension doesn't matter functionally -- unsigned is simply
// the more honest choice of the two).
wire [2:0] load_funct3  = (eew_r[1:0] == 2'b00) ? 3'b100 :               // lbu
                           (eew_r[1:0] == 2'b01) ? 3'b101 :               // lhu
                           (eew_r[1:0] == 2'b10) ? 3'b110 : 3'b011;       // lwu / ld
wire [2:0] store_funct3 = (eew_r[1:0] == 2'b00) ? 3'b000 :               // sb
                           (eew_r[1:0] == 2'b01) ? 3'b001 :               // sh
                           (eew_r[1:0] == 2'b10) ? 3'b010 : `F3_STORE_SD; // sw / sd

wire [63:0] elem_mask64 = (elem_width >= 8'd64) ? {64{1'b1}} : (({64{1'b1}} << elem_width) ^ {64{1'b1}});
wire [63:0] store_elem_data = (store_data_r >> shift_r) & elem_mask64;

wire [VLEN-1:0] write_mask = ({{(VLEN-64){1'b0}}, elem_mask64} << shift_r);
wire [VLEN-1:0] write_data = ({{(VLEN-64){1'b0}}, (mem_readData & elem_mask64)} << shift_r);

always @(posedge clk) begin
    if (~rst) begin
        state_r      <= S_IDLE;
        done         <= 1'b0;
        mem_memRead  <= 1'b0;
        mem_memWrite <= 1'b0;
    end
    else begin
        done         <= 1'b0;
        mem_memRead  <= 1'b0;
        mem_memWrite <= 1'b0;

        case (state_r)
            S_IDLE: begin
                if (start) begin
                    elem_r       <= {EIDX_BITS{1'b0}};
                    shift_r      <= {SHIFT_BITS{1'b0}};
                    store_data_r <= store_data;
                    v0_r         <= v0_data;
                    base_addr_r  <= base_addr;
                    vm_r         <= vm;
                    eew_r        <= eew;
                    vl_r         <= vl[CNT_BITS-1:0];
                    is_store_r   <= is_store;
                    result       <= {VLEN{1'b0}};
                    state_r      <= is_store ? S_STORE_ISSUE : S_LOAD_ISSUE;
                end
            end

            S_LOAD_ISSUE: begin
                if (!elem_active) begin
                    // Masked-off/tail element: no real access, real
                    // tail-agnostic zero already sits in `result` from
                    // reset/the previous element's own write_mask
                    // exclusion -- just advance.
                    if (elem_r == elems_this_eew[EIDX_BITS-1:0] - 1'b1) begin
                        state_r <= S_IDLE;
                        done    <= 1'b1;
                    end else begin
                        elem_r  <= elem_r + 1'b1;
                        shift_r <= shift_r + {{(SHIFT_BITS-8){1'b0}}, elem_width};
                        state_r <= S_LOAD_ISSUE;
                    end
                end
                else begin
                    mem_memRead <= 1'b1;
                    mem_address <= base_addr_r + {{(XLEN-4){1'b0}}, elem_bytes} * {{(XLEN-EIDX_BITS){1'b0}}, elem_r};
                    mem_funct3  <= load_funct3;
                    state_r     <= S_LOAD_WAIT;
                end
            end

            // A genuine do-nothing pass-through cycle -- DataMemoryBRAM.v's
            // own registered read needs a FULL cycle to sample the
            // address/memRead this module asserted during S_LOAD_ISSUE
            // (its own posedge block, triggered the SAME edge S_LOAD_ISSUE's
            // own outputs first become stable, still sees the PRE-that-edge
            // 0 values -- a real off-by-one found by running the standalone
            // testbench, not assumed correct from the code reading right:
            // the naive 1-state design read mem_readData exactly one edge
            // before DataMemoryBRAM.v's own raw_word_r/mem_read_r had
            // actually captured it, silently reading back zero every time).
            S_LOAD_WAIT: begin
                state_r <= S_LOAD_CAPTURE;
            end

            S_LOAD_CAPTURE: begin
                // mem_readData is finally valid THIS cycle.
                result <= (result & ~write_mask) | (write_data & write_mask);
                if (elem_r == elems_this_eew[EIDX_BITS-1:0] - 1'b1) begin
                    state_r <= S_IDLE;
                    done    <= 1'b1;
                end else begin
                    elem_r  <= elem_r + 1'b1;
                    shift_r <= shift_r + {{(SHIFT_BITS-8){1'b0}}, elem_width};
                    state_r <= S_LOAD_ISSUE;
                end
            end

            S_STORE_ISSUE: begin
                if (elem_active) begin
                    mem_memWrite  <= 1'b1;
                    mem_address   <= base_addr_r + {{(XLEN-4){1'b0}}, elem_bytes} * {{(XLEN-EIDX_BITS){1'b0}}, elem_r};
                    mem_writeData <= store_elem_data;
                    mem_funct3    <= store_funct3;
                end
                if (elem_r == elems_this_eew[EIDX_BITS-1:0] - 1'b1) begin
                    state_r <= S_IDLE;
                    done    <= 1'b1;
                end else begin
                    elem_r  <= elem_r + 1'b1;
                    shift_r <= shift_r + {{(SHIFT_BITS-8){1'b0}}, elem_width};
                    state_r <= S_STORE_ISSUE;
                end
            end

            default: state_r <= S_IDLE;
        endcase
    end
end

`ifdef ASSERT_ON
always @(posedge clk) begin
    if (rst && start && busy)
        begin $display("ASSERTION FAILED @t=%0t: VLSU start while already busy", $time); $finish; end
end
`endif

endmodule

`default_nettype wire
