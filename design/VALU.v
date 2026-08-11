`default_nettype none

`include "riscv_defs.vh"

// Generation 7, Pillar V, Phase 2a (docs/adr/0062). One vector ALU
// instance, one physical vector register's worth of elements per run
// (VLEN/SEW elements, up to VLEN/8=64 at SEW=8) -- iterative, ONE
// ELEMENT PER CYCLE, mirroring Divider.v's own start/busy/done multi-
// cycle handshake shape (docs/adr/0006) -- the same honest "no wide
// parallel datapath, iterate instead" tradeoff this project already uses
// for DIV/REM, just per-vector-element instead of per-bit. No indexed
// part-select (`result_r[shift +: width]`) is used anywhere -- Verilog
// requires a COMPILE-TIME-CONSTANT width there, and SEW is a runtime
// value -- every element extraction/write below uses a variable SHIFT
// (fully legal for a runtime-variable amount) combined with an AND-mask
// instead.
//
// Tail/mask-agnostic policy (docs/adr/0062's own Global Constraints):
// every element at or past vl, or masked off by v0 when vm=0, is written
// ZERO -- a real spec-legal "agnostic" choice, not a shortcut.
module VALU #(
    parameter VLEN = 512
)(
    input  wire                          clk,
    input  wire                          rst,

    input  wire                          start,       // one-cycle pulse, caller-controlled
    input  wire [VLEN-1:0]               vs2_data,
    input  wire [VLEN-1:0]               vs1_data,    // .vv form
    input  wire [63:0]                   scalar_data, // .vx (rs1, sign/zero-extended by caller) / .vi (sign-extended 5-bit imm)
    input  wire                          use_scalar,  // 1 = .vx/.vi, 0 = .vv
    input  wire [VLEN-1:0]               v0_data,     // mask source, always read (harmless when vm=1)
    input  wire                          vm,          // 1 = unmasked, 0 = masked (real RVV encoding)
    input  wire [2:0]                    vsew,        // 000=8,001=16,010=32,011=64
    input  wire [$clog2(VLEN/8+1)-1:0]   vl,          // active element count in THIS physical register
    input  wire [5:0]                    funct6,      // VFUNCT6_RSUB's own case arm always computes b-a; b_slice
                                                          // always holds the scalar/imm for a real vrsub encoding by
                                                          // construction of the caller's own dispatch (OOOCore.v) --
                                                          // no separate is_rsub input needed, funct6 alone determines
                                                          // this op's semantics completely (a real, deliberate
                                                          // simplification from the plan's own draft interface, found
                                                          // once actually writing this module, not a missed spec case).

    output wire                          busy,
    output reg                           done,        // one-cycle pulse
    output reg  [VLEN-1:0]               result
);

localparam MAX_ELEMS = VLEN/8;              // SEW=8 is the narrowest -> most elements
// EIDX_BITS holds an ELEMENT INDEX (0..MAX_ELEMS-1, e.g. 0..63) -- 6 bits
// for VLEN=512. elems_this_sew/vl_r hold an ELEMENT COUNT (1..MAX_ELEMS,
// e.g. up to 64 ITSELF, a real value 6 bits cannot represent -- 64 in
// 6 bits truncates to 0) -- both need EIDX_BITS+1 bits. Conflating the
// two widths (a real bug found by running this module's own standalone
// testbench before ever wiring it into OOOCore.v) silently made
// elems_this_sew always 0, so the completion check `elem_r ==
// elems_this_sew-1` never matched until elem_r wrapped all the way to
// 63 regardless of the real SEW -- caught by tb_valu_unit.v's own
// vand.vx tail-agnostic check overwriting elements it should have left
// alone.
localparam EIDX_BITS = $clog2(MAX_ELEMS);
localparam CNT_BITS  = EIDX_BITS + 1;
localparam SHIFT_BITS = $clog2(VLEN);

reg                   busy_r;
reg  [EIDX_BITS-1:0]  elem_r;
reg  [SHIFT_BITS-1:0] shift_r;
reg  [VLEN-1:0]       vs2_r, vs1_r, v0_r;
reg  [63:0]           scalar_r;
reg                   use_scalar_r, vm_r;
reg  [2:0]            vsew_r;
reg  [CNT_BITS-1:0]   vl_r;
reg  [5:0]            funct6_r;

assign busy = busy_r;

wire [7:0] elem_width = (8'd8 << vsew_r);                         // 8/16/32/64
wire [CNT_BITS-1:0] elems_this_sew = (MAX_ELEMS[CNT_BITS-1:0] >> vsew_r);

// Element-width mask, built via a variable SHIFT (legal -- only indexed
// part-select needs a constant width, a plain `<<`/`>>` shift amount can
// be any runtime value).
wire [63:0] elem_mask64 = (elem_width >= 8'd64) ? {64{1'b1}} : (({64{1'b1}} << elem_width) ^ {64{1'b1}});

wire [63:0] a_slice = (vs2_r >> shift_r) & elem_mask64;
wire [63:0] b_slice_vv = (vs1_r >> shift_r) & elem_mask64;
wire [63:0] b_slice = use_scalar_r ? (scalar_r & elem_mask64) : b_slice_vv;
wire mask_bit = (v0_r >> elem_r) & 1'b1;
wire elem_active = (elem_r < vl_r) && (vm_r || mask_bit);

// Sign-extend a SEW-wide slice to 64 bits for signed min/max -- `width`
// is a runtime value here too (a function's own inputs are ordinary
// values, not part-select widths, so this is legal regardless).
function [63:0] sext_elem;
    input [63:0] v;
    input [7:0]  width;
    begin
        sext_elem = v[width-1] ? (v | (~64'h0 << width)) : v;
    end
endfunction

reg [63:0] alu_r;
always @(*) begin
    case (funct6_r)
        `VFUNCT6_ADD:  alu_r = a_slice + b_slice;
        `VFUNCT6_SUB:  alu_r = a_slice - b_slice;
        `VFUNCT6_RSUB: alu_r = b_slice - a_slice;   // real spec: scalar - vs2 (b_slice always the scalar/imm here, a_slice always vs2)
        `VFUNCT6_AND:  alu_r = a_slice & b_slice;
        `VFUNCT6_OR:   alu_r = a_slice | b_slice;
        `VFUNCT6_XOR:  alu_r = a_slice ^ b_slice;
        `VFUNCT6_MINU: alu_r = (a_slice < b_slice) ? a_slice : b_slice;
        `VFUNCT6_MIN:  alu_r = ($signed(sext_elem(a_slice, elem_width)) < $signed(sext_elem(b_slice, elem_width))) ? a_slice : b_slice;
        `VFUNCT6_MAXU: alu_r = (a_slice > b_slice) ? a_slice : b_slice;
        `VFUNCT6_MAX:  alu_r = ($signed(sext_elem(a_slice, elem_width)) > $signed(sext_elem(b_slice, elem_width))) ? a_slice : b_slice;
        default:       alu_r = 64'd0;
    endcase
end

// Generation 7, Pillar V backlog closure (docs/adr/0066). Mask-writing
// compares -- a genuinely different completion shape from every op
// above: the result is ONE BIT per element (not a SEW-wide value), and
// that bit lands at bit position elem_r of the destination (a raw
// bit-indexed mask, same v0-read convention already used above), not at
// shift_r (which tracks SEW-wide byte offsets). funct6 0x18-0x1f (top 3
// bits 011) are exactly the compare family -- verified against
// riscv/riscv-opcodes.
wire is_cmp_r = (funct6_r[5:3] == 3'b011);
reg  cmp_bit;
always @(*) begin
    case (funct6_r)
        `VFUNCT6_MSEQ:  cmp_bit = (a_slice == b_slice);
        `VFUNCT6_MSNE:  cmp_bit = (a_slice != b_slice);
        `VFUNCT6_MSLTU: cmp_bit = (a_slice < b_slice);
        `VFUNCT6_MSLT:  cmp_bit = ($signed(sext_elem(a_slice, elem_width)) < $signed(sext_elem(b_slice, elem_width)));
        `VFUNCT6_MSLEU: cmp_bit = (a_slice <= b_slice);
        `VFUNCT6_MSLE:  cmp_bit = ($signed(sext_elem(a_slice, elem_width)) <= $signed(sext_elem(b_slice, elem_width)));
        `VFUNCT6_MSGTU: cmp_bit = (a_slice > b_slice);
        `VFUNCT6_MSGT:  cmp_bit = ($signed(sext_elem(a_slice, elem_width)) > $signed(sext_elem(b_slice, elem_width)));
        default:        cmp_bit = 1'b0;
    endcase
end

wire [VLEN-1:0] cmp_bitpos = ({{(VLEN-1){1'b0}}, 1'b1} << elem_r);
wire [VLEN-1:0] write_mask = is_cmp_r ? cmp_bitpos : ({{(VLEN-64){1'b0}}, elem_mask64} << shift_r);
wire [VLEN-1:0] write_data = is_cmp_r
    ? ((elem_active && cmp_bit) ? cmp_bitpos : {VLEN{1'b0}})
    : (elem_active ? ({{(VLEN-64){1'b0}}, alu_r} << shift_r) : {VLEN{1'b0}});

always @(posedge clk) begin
    if (~rst) begin
        busy_r <= 1'b0;
        done   <= 1'b0;
    end
    else begin
        done <= 1'b0;
        if (start && !busy_r) begin
            busy_r       <= 1'b1;
            elem_r       <= {EIDX_BITS{1'b0}};
            shift_r      <= {SHIFT_BITS{1'b0}};
            vs2_r        <= vs2_data;
            vs1_r        <= vs1_data;
            scalar_r     <= scalar_data;
            use_scalar_r <= use_scalar;
            v0_r         <= v0_data;
            vm_r         <= vm;
            vsew_r       <= vsew;
            vl_r         <= vl[CNT_BITS-1:0];
            funct6_r     <= funct6;
            result       <= {VLEN{1'b0}};
        end
        else if (busy_r) begin
            result <= (result & ~write_mask) | (write_data & write_mask);
            if (elem_r == elems_this_sew - 1'b1) begin
                busy_r <= 1'b0;
                done   <= 1'b1;
            end
            else begin
                elem_r  <= elem_r + 1'b1;
                shift_r <= shift_r + {{(SHIFT_BITS-8){1'b0}}, elem_width};
            end
        end
    end
end

`ifdef ASSERT_ON
always @(posedge clk) begin
    if (rst && start && busy_r)
        begin $display("ASSERTION FAILED @t=%0t: VALU start while already busy", $time); $finish; end
end
`endif

endmodule

`default_nettype wire
