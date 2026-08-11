`default_nettype none

`include "riscv_defs.vh"

// Machine-mode-only CSR file (docs/adr/0011-csr-and-exceptions.md), plus
// (docs/adr/0019-f-extension.md, Phase C8) the F-extension's fflags/frm/
// fcsr, plus (docs/adr/0020-soc-integration.md, Phase D7) mie/mip. Nine
// CSRs total: mstatus (MIE/MPIE only -- no S/U mode, so every other field
// is hardwired 0), mie, mtvec, mscratch, mepc, mcause, mip, fflags, frm
// (fcsr is not separate storage -- it's just {frm, fflags} packed into one
// address, same "one more view onto the same bits" relationship the real
// spec defines). No S-mode/U-mode, no PMP -- this core is M-mode only
// throughout, same scope docs/adr/0011 originally drew for exceptions, now
// extended to the two interrupt sources docs/adr/0020 adds (a timer and
// one external device, UART RX) rather than a spec-complete privileged
// architecture.
//
// mie/mip have three real bits (`MIE_MSIE_BIT`/`MIE_MTIE_BIT`/
// `MIE_MEIE_BIT`, riscv_defs.vh) -- docs/adr/0034-uart-clint-register-
// compat-phase-r.md (Phase R) added the machine-software-interrupt bit,
// driven by Timer.v's own new CLINT `msip` register (this core is still
// single-hart, so nothing but a hart interrupting itself ever sets it, real
// spec-legal behavior). No S-mode/U-mode delegation bits exist. mip is
// read-only from software's perspective (its three real bits, MSIP/MTIP/
// MEIP, are hardware-driven straight from Timer.v's/the PLIC-lite's own
// live pending signals -- see `msip_pending`/`timer_pending`/`ext_pending`
// below); a csrrX write to its address is silently dropped, the same
// "unimplemented CSR writes are silently dropped" default every other
// unimplemented address already gets.
module CSR #(
    parameter XLEN = 32,  // docs/adr/0015-xlen-and-regcount-parameterization.md.
                            // csr_addr stays a fixed 12 bits regardless -- the
                            // CSR address space width is set by the privileged
                            // spec's encoding, not XLEN.
    parameter VLEN = 512   // Gen7 Pillar V Phase 1 (docs/adr/0061) -- only
                             // used by CSR_ADDR_VLENB's own read value below;
                             // every existing instantiation of this module
                             // (riscvpipeline.v, and OOOCore.v before this
                             // phase) simply gets the default, unused.
)(
    input wire clk,
    input wire rst,

    // csrrw/csrrs/csrrc(+immediate variants), resolved by the caller into a
    // uniform (addr, op, wdata) triple -- riscvpipeline.v handles picking
    // rs1 vs. the zero-extended uimm before this port.
    input wire csr_write_en,
    input wire [11:0] csr_addr,
    input wire [1:0] csr_op,      // == inst[13:12] == funct3[1:0] directly: 2'b01=write(csrrw/csrrwi)
                              // 2'b10=set(csrrs/csrrsi) 2'b11=clear(csrrc/csrrci) -- no remapping
                              // needed at the call site, riscv_defs.vh's CSR_F3_* already follow
                              // this same low-2-bits pattern
    input wire [XLEN-1:0] csr_wdata,
    output reg [XLEN-1:0] csr_rdata,  // current value at csr_addr, combinational (old value, for rd)

    input wire trap_taken,
    input wire [XLEN-1:0] trap_pc,     // faulting instruction's own PC (exception) or the PC of the
                                    // instruction that would have executed next (interrupt) -> mepc
    input wire [XLEN-1:0] trap_cause,  // low bits only (never bit31 set) -> mcause[30:0]
    // docs/adr/0020-soc-integration.md (Phase D9). Set by riscvpipeline.v's
    // interrupt_taken exactly when this trap is an interrupt rather than a
    // synchronous exception -> mcause[31], the spec's own
    // interrupt-vs-exception disambiguating bit. trap_cause's low bits are
    // already the correct code either way (riscv_defs.vh's MCAUSE_* and
    // MCAUSE_INT_* deliberately share the low-bit numbering space, per
    // their own header comment) -- this bit is the only thing that tells
    // them apart.
    input wire trap_is_interrupt,
    // docs/adr/00NN-mmu-sv32.md (Phase F3). The faulting virtual address,
    // for mtval/stval -- 0 for every cause this phase itself raises (a
    // spec-legal choice; mtval's content for non-page-fault causes is
    // implementation-defined and this core simply doesn't bother). F5
    // wires the real value in for page faults with zero further changes
    // needed here, the same tie-off-then-real-wire staging D7/D8 used for
    // timer_pending/ext_pending.
    input wire [XLEN-1:0] trap_value,

    input wire mret_taken,
    input wire sret_taken,  // docs/adr/00NN-mmu-sv32.md (Phase F3) -- riscvpipeline.v
                         // gates this off before it ever reaches here (see
                         // sret_real there), same as mret_taken already is

    // docs/adr/0019-f-extension.md (Phase C8). Sticky hardware accumulation:
    // every F-extension instruction that actually executes ORs its own
    // exception flags into fflags this same cycle, independent of (and, in
    // legitimate operation, never simultaneous with -- isOpFp_regde/isCsr_regde
    // are mutually exclusive opcodes) an explicit software csrrX write to
    // the same address below. frm_val is the live rounding mode, read by
    // riscvpipeline.v to resolve any instruction whose own rm field is
    // RM_DYN (3'b111) before it ever reaches FALU.v/FMADDUnit.v/FDivider.v/
    // FSqrt.v -- see FALU.v's own header comment for why those modules
    // themselves only ever see an already-resolved rm.
    input wire fp_flags_we,
    input wire [4:0] fp_flags_in,
    output wire [2:0] frm_val,

    // docs/adr/0020-soc-integration.md (Phase D7/D8) originally wired
    // timer_pending/ext_pending; docs/adr/0034 (Phase R) adds msip_pending
    // -- Timer.v's own new CLINT `msip` register -- alongside them. All
    // three feed mip's three real, read-only bits.
    input wire msip_pending,
    input wire timer_pending,
    input wire ext_pending,

    // docs/adr/0020-soc-integration.md (Phase D9). Consumed by
    // riscvpipeline.v's interrupt-detection condition (mstatus_mie &
    // ((mip.MEIP & mie.MEIE) | (mip.MSIP & mie.MSIE) | (mip.MTIP &
    // mie.MTIE)), Phase R) -- CSR.v's own interface needed no further
    // changes to support it, exactly as D7 anticipated.
    output wire mstatus_mie,  // mstatus[3], the global trap/interrupt enable
    output wire mie_msie,     // mie's machine-software-interrupt enable bit (Phase R)
    output wire mie_mtie,     // mie's machine-timer-interrupt enable bit
    output wire mie_meie,     // mie's machine-external-interrupt enable bit

    // docs/adr/0035-minimal-sbi-firmware-phase-s.md (Phase S). Real
    // consumers, not formal-observability-only: riscvpipeline.v's own
    // supervisor-interrupt recognition (ssi_pending/sti_pending), a genuine
    // gap Phase S's own SBI firmware design found -- mip_sw's SSIP/STIP
    // bits (real, software-writable storage since Phase F) had no path
    // into interrupt_taken at all before this phase, so a software-
    // synthesized S-mode timer interrupt (the real SBI TIME-extension
    // mechanism, since mtimecmp is M-mode-only CLINT state) could never
    // actually retrap. mie_ssie/mie_stie mirror mie_msie's own exact idiom;
    // mip_ssip/mip_stip expose mip_sw's own SSIP/STIP bits the identical
    // way timer_pending/ext_pending already expose Timer.v/Uart.v's real
    // hardware pending state.
    output wire mie_ssie,     // mie's supervisor-software-interrupt enable bit
    output wire mie_stie,     // mie's supervisor-timer-interrupt enable bit
    output wire mip_ssip,     // mip_sw's supervisor-software-interrupt pending bit
    output wire mip_stip,     // mip_sw's supervisor-timer-interrupt pending bit

    // docs/adr/0027-formal-verification.md (Phase L3) added these as
    // formal-observability-only outputs; docs/adr/0035 (Phase S) gives
    // mstatus_sie a real, live consumer too (riscvpipeline.v's own new
    // supervisor-interrupt gating, mirroring mstatus_mie's own role for
    // the machine-level condition) -- the rest stay formal-only. Mirrors
    // mstatus_mie's own exact idiom (a single bit of `mstatus` exposed as
    // its own named output). Added because Yosys's `read_verilog` can't
    // resolve a hierarchical `dut.mstatus`-style peek from outside this
    // module (confirmed by running -- it silently becomes an implicitly-
    // declared, driverless stand-in signal, unlike iverilog's simulator,
    // which resolves this hierarchy path natively); an ordinary port is
    // the portable way to expose it to both toolchains.
    output wire mstatus_mpie,        // mstatus[7]
    output wire mstatus_sie,         // mstatus[1]
    output wire mstatus_spie,        // mstatus[5]
    output wire mstatus_spp,         // mstatus[8]
    output wire [1:0] mstatus_mpp,   // mstatus[12:11]

    output wire [XLEN-1:0] mtvec_val,  // trap target for the redirect mux
    output wire [XLEN-1:0] mepc_val,   // mret target for the redirect mux

    // Phase F of the redesign (docs/adr/00NN-mmu-sv32.md; docs/adr/0011/0020
    // both explicitly deferred this).
    output wire [1:0] priv_mode_val,   // current privilege -- PRIV_U/PRIV_S/PRIV_M
    // docs/adr/00NN-mmu-sv32.md (Phase F3). stvec_val/sepc_val mirror
    // mtvec_val/mepc_val for the S-mode redirect targets; trap_target_is_s
    // tells riscvpipeline.v's redirect mux which pair to use for THIS
    // trap, computed here (not there) since the decision needs mideleg/
    // medeleg/priv_mode, all of which already live in this module.
    output wire [XLEN-1:0] stvec_val,
    output wire [XLEN-1:0] sepc_val,
    output wire trap_target_is_s,

    // docs/adr/00NN-mmu-sv32.md (Phase F5). satp's own two fields the
    // translation gate needs: MODE (bit 31 -- 0=Bare/1=Sv32) and PPN
    // (bits [21:0], the root page table's own physical page number).
    // ASID (bits [30:22]) has no consumer this phase (no selective TLB
    // invalidation, see the phase plan's own scoping default), so it's
    // not exposed here.
    //
    // docs/adr/0031 (Phase O): at XLEN==64 these now decode Sv39's own
    // completely different satp layout (MODE is a 4-bit field at 63:60,
    // not a single bit at 31) rather than Sv32's -- see the `always`
    // block below. satp_mode_val's meaning generalizes correctly at both
    // XLENs: "a real, non-Bare translation mode is selected."
    //
    // docs/adr/00NN-sv39-mmu-phase-p.md (Phase P3): satp_ppn_val widened
    // from 22 to 44 bits -- Sv39's real spec PPN field is 44 bits (vs.
    // Sv32's 22), and Ptw39.v's own `satp_ppn` port needs the full width
    // (it does its own low-20-bits truncation internally, the same
    // "decode the root pointer at full width, truncate only what the
    // walker itself forms" principle Ptw.v/Ptw39.v's own headers document).
    // At XLEN==32 the value is simply zero-extended into the wider port --
    // Ptw.v's own `satp_ppn` port stays 22 bits, fed this value's low 22
    // bits at the call site (riscvpipeline.v), so this widening is a
    // pure superset, no behavior change at XLEN==32.
    output reg satp_mode_val,
    output reg [43:0] satp_ppn_val,

    // docs/adr/0025-hpc-performance-csrs.md (Phase J). One pulse input per
    // hardware-countable event (index 1-9 into `hpmevent`'s own selector
    // range -- see `hpm_event_pulse` below for the exact mapping), plus
    // `instret_pulse` for minstret specifically (architecturally fixed to
    // "an instruction retired," not reconfigurable, matching the real
    // spec -- minstret isn't one of the generic mhpmcounters). Every pulse
    // here is already the caller's own responsibility to gate exactly-once
    // per real event (riscvpipeline.v's own comments document each one);
    // CSR.v just counts whatever it's handed.
    input wire instret_pulse,
    input wire branch_retired_pulse,
    input wire mispredict_pulse,
    input wire icache_hit_pulse,
    input wire icache_miss_pulse,
    input wire dcache_hit_pulse,
    input wire dcache_miss_pulse,
    input wire stall_cycle_pulse,
    input wire interrupt_pulse,
    input wire exception_pulse,

    // Phase K (docs/adr/0026-performance-profiler.md). Nine more countable
    // events (indices 10-18) -- the same raw per-cause wires whose OR
    // already forms `stall_cycle_pulse`/`pc_stall` above, exposed
    // individually so a program can select one of them onto a counter
    // instead of only ever seeing the aggregate. Each is a LEVEL (true for
    // every cycle that cause is part of the active stall), matching
    // `stall_cycle_pulse`'s own "count cycles, not occurrences" shape --
    // NOT the edge-detected occurrence-pulses events 3/4 already use for
    // I$ hit/miss (icache_hit_pulse/icache_miss_pulse), which is a
    // deliberately different question ("how many misses happened" vs.
    // "how many cycles did a miss cost").
    input wire stall_hazard_pulse,      // riscvpipeline.v's own `stall` (Hazard.v/HazardNoForward.v)
    input wire stall_div_pulse,         // div_stall
    input wire stall_mem_pulse,         // mem_stall
    input wire stall_fp_pulse,          // fp_stall
    input wire stall_float_lu_pulse,    // float_load_use_hazard
    input wire stall_itlb_pulse,        // itlb_miss
    input wire stall_dtlb_pulse,        // dtlb_miss
    input wire stall_icache_pulse,      // icache_miss
    input wire stall_imem_wait_pulse,   // imem_wait

    // Gen7 Pillar V Phase 1 (docs/adr/0061). vl/vsew/vlmul/vill: live
    // decoded vtype/vl state -- unconnected until a future phase's vector
    // arithmetic ops need it (mirrors frm_val's own "declared ahead of its
    // real consumer" precedent, docs/adr/0019 Phase C1). vec_cfg_write_en/
    // vec_cfg_new_*: a dedicated side channel, separate from the generic
    // csr_write_en path, fired only by OOOCore.v's own single-outstanding
    // vsetvli/vsetivli issue -- same "own independent write port, not the
    // generic mux" precedent trap-entry CSRs (mepc/mcause, both driven by
    // trap_taken above, not csr_write_en) already established in this file.
    output wire [XLEN-1:0] vl_o,
    output wire [2:0]      vsew_o,
    output wire [2:0]      vlmul_o,
    output wire            vill_o,

    input  wire             vec_cfg_write_en,
    input  wire [7:0]       vec_cfg_new_vtype,
    input  wire             vec_cfg_new_vill,
    input  wire [XLEN-1:0]  vec_cfg_new_vl
);

    reg [XLEN-1:0] mstatus;  // bit3(MIE)/bit7(MPIE) real since docs/adr/0011; bit1(SIE)/bit5(SPIE)/
                               // bit8(SPP)/bits12:11(MPP) real as of this phase (F1) -- see mstatus_masked
    reg [XLEN-1:0] mie;      // MIE_MTIE_BIT/MIE_MEIE_BIT real since D7; MIE_SSIE_BIT/MIE_STIE_BIT/
                               // MIE_SEIE_BIT real since Phase F; MIE_MSIE_BIT real since Phase R -- see mie_masked
    reg [XLEN-1:0] mtvec;
    reg [XLEN-1:0] mscratch;
    reg [XLEN-1:0] mepc;
    reg [XLEN-1:0] mcause;
    reg [4:0] fflags;  // {NV, DZ, OF, UF, NX} -- sticky, OR-accumulated, not overwritten by hardware
    reg [2:0] frm;

    // Gen7 Pillar V Phase 1 (docs/adr/0061). vstart is an ordinary R/W CSR
    // (spec allows plain csrrw); vtype/vl are written ONLY via the
    // dedicated vec_cfg_write_en side channel below -- real spec technically
    // allows plain csrrw to vl/vtype too (recomputing vl' from the OLD vl
    // as AVL against the NEW vtype), but this core's own dispatch never
    // generates that path in Phase 1's scope (only vsetvli/vsetivli write
    // them) -- a real, narrow, flagged gap if a compiled program ever
    // issues a raw `csrrw x0, vl, x5`, same honesty standard as every
    // other Gen6/7 phase's own documented scope cut.
    reg [15:0]      vstart;
    reg [7:0]       vtype_fields;   // {vma,vta,vsew[2:0],vlmul[2:0]}
    reg             vill;
    reg [XLEN-1:0]  vl;
    reg [1:0]       vxrm;    // storage only, no real fixed-point consumer yet
    reg             vxsat;   // storage only, same reason

    // Phase F additions (storage only in this commit -- see the module
    // header/priv_mode_val's own comment above). sstatus/sie/sip are
    // deliberately NOT separate storage -- read/write VIEWS onto mstatus/
    // mie/mip's S-mode-visible bit subset, mirroring fcsr's existing
    // view-of-{frm,fflags} relationship (this IS how the real privileged
    // spec itself defines sstatus's relationship to mstatus, not a
    // shortcut taken here). mtval is new M-mode storage (this core never
    // implemented it before -- a real page fault, added in F5, is the
    // first thing that actually needs it).
    reg [1:0] priv_mode;      // PRIV_U/PRIV_S/PRIV_M -- reset to PRIV_M (spec boot behavior);
                               // held at PRIV_M until F3 adds mret/sret/trap-entry mutation
    reg [XLEN-1:0] sscratch;
    reg [XLEN-1:0] sepc;
    reg [XLEN-1:0] scause;
    reg [XLEN-1:0] stval;
    reg [XLEN-1:0] mtval;
    reg [XLEN-1:0] stvec;
    reg [XLEN-1:0] satp;
    reg [XLEN-1:0] mideleg;  // only the three real interrupt causes (bits 3/7/11, matching mie/mip's
                               // own MIE_MSIE_BIT/MIE_MTIE_BIT/MIE_MEIE_BIT, Phase R) are meaningful;
                               // every other bit reads/writes as 0 since no other interrupt source exists
    reg [XLEN-1:0] medeleg;  // exception causes; every bit this core can actually raise
                               // (illegal instruction, breakpoint, ecall from U/S, the three
                               // page faults) is independently delegable per spec

    // docs/adr/0025-hpc-performance-csrs.md (Phase J). mcycle/minstret: free-
    // running/retirement-gated 64-bit counters, spec-standard low/high-half
    // register pairs. mcountinhibit: spec-standard (bit0=CY, bit2=IR,
    // bit[3+i]=this core's own mhpmcounter[3+i]); bit1 and every bit past
    // `NUM_HPM_COUNTERS` are hardwired 0 (this core has nothing else to
    // inhibit). mhpmcounter3-11/mhpmevent3-11: a genuine indexed array (not
    // 9 hand-unrolled registers) -- these 9 counters are structurally
    // identical (same 64-bit up-counter, same event-select mux, zero
    // trap-entry coupling), unlike every other CSR in this file, which is
    // why this is the one place CSR.v reaches for an array/loop instead of
    // its usual all-named-registers style (mirrors Tlb.v's own indexed-
    // array precedent). `mhpmevent[i]` holds a 5-bit event index (0=off,
    // 1-9 this file's original hardware events, 10-18 Phase K's per-cause
    // stall breakdown -- widened from 4 to 5 bits since 18 no longer fits
    // 4 bits); reset default is `i+1` so a fresh boot already has all 9
    // original events observable 1:1 with zero software configuration,
    // while staying fully reconfigurable per the real spec's own mhpmevent
    // semantics (a program reprograms mhpmeventN to 10-18 to observe a
    // stall cause instead).
    reg [XLEN-1:0] mcycle_lo, mcycle_hi;
    reg [XLEN-1:0] minstret_lo, minstret_hi;
    reg [XLEN-1:0] mcountinhibit;
    reg [XLEN-1:0] mhpmcounter_lo [0:`NUM_HPM_COUNTERS-1];
    reg [XLEN-1:0] mhpmcounter_hi [0:`NUM_HPM_COUNTERS-1];
    reg [4:0]      mhpmevent      [0:`NUM_HPM_COUNTERS-1];
    integer hpm_i;

    // Phase K: highest valid event index (9 original + 9 stall-cause).
    localparam NUM_HPM_EVENTS = 18;

    localparam [XLEN-1:0] MCOUNTINHIBIT_MASK = {XLEN{1'b0}} |
        12'hFFD;  // bits 0,2-11 real (CY, IR, HPM3-11); bit1 and bits12+ hardwired 0

    // Index 0 is "off" (tied low); 1-9 are this core's 9 countable hardware
    // events, in the same order docs/adr/0025's Design section lists them.
    // Every entry here is already the exactly-once-per-real-event pulse
    // riscvpipeline.v's own comments document -- CSR.v does no further
    // gating, just selects and counts.
    wire [NUM_HPM_EVENTS:0] hpm_event_pulse;
    assign hpm_event_pulse[0] = 1'b0;
    assign hpm_event_pulse[1] = branch_retired_pulse;
    assign hpm_event_pulse[2] = mispredict_pulse;
    assign hpm_event_pulse[3] = icache_hit_pulse;
    assign hpm_event_pulse[4] = icache_miss_pulse;
    assign hpm_event_pulse[5] = dcache_hit_pulse;
    assign hpm_event_pulse[6] = dcache_miss_pulse;
    assign hpm_event_pulse[7] = stall_cycle_pulse;
    assign hpm_event_pulse[8] = interrupt_pulse;
    assign hpm_event_pulse[9] = exception_pulse;
    // Phase K (docs/adr/0026): stall cause breakdown, indices 10-18.
    assign hpm_event_pulse[10] = stall_hazard_pulse;
    assign hpm_event_pulse[11] = stall_div_pulse;
    assign hpm_event_pulse[12] = stall_mem_pulse;
    assign hpm_event_pulse[13] = stall_fp_pulse;
    assign hpm_event_pulse[14] = stall_float_lu_pulse;
    assign hpm_event_pulse[15] = stall_itlb_pulse;
    assign hpm_event_pulse[16] = stall_dtlb_pulse;
    assign hpm_event_pulse[17] = stall_icache_pulse;
    assign hpm_event_pulse[18] = stall_imem_wait_pulse;

    // Reading `mhpmcounter_lo/hi`/`mhpmevent` via a variable index directly
    // inside the `always @(*)` read block below would make Icarus flag it
    // as "sensitive to all N words" (DCache.v/ICache.v's own header
    // comments already document hitting this exact warning for their own
    // per-way arrays and avoiding it with `generate`+`assign` instead of a
    // procedural loop) -- this project's zero-warning bar, so the same
    // fix applies here: an OR-accumulator built by `generate`, one term
    // per counter, each term zero unless `csr_addr` actually selects it.
    genvar hgi;
    wire [XLEN-1:0] hpm_lo_acc [0:`NUM_HPM_COUNTERS];
    wire [XLEN-1:0] hpm_hi_acc [0:`NUM_HPM_COUNTERS];
    wire [4:0]      hpm_ev_acc [0:`NUM_HPM_COUNTERS];
    assign hpm_lo_acc[0] = {XLEN{1'b0}};
    assign hpm_hi_acc[0] = {XLEN{1'b0}};
    assign hpm_ev_acc[0] = 5'b0;
    generate
        for (hgi = 0; hgi < `NUM_HPM_COUNTERS; hgi = hgi + 1) begin : gen_hpm_rd
            assign hpm_lo_acc[hgi+1] = hpm_lo_acc[hgi] |
                ((csr_addr == `CSR_ADDR_MHPMCOUNTER3_BASE + hgi)  ? mhpmcounter_lo[hgi] : {XLEN{1'b0}});
            assign hpm_hi_acc[hgi+1] = hpm_hi_acc[hgi] |
                ((csr_addr == `CSR_ADDR_MHPMCOUNTER3H_BASE + hgi) ? mhpmcounter_hi[hgi] : {XLEN{1'b0}});
            assign hpm_ev_acc[hgi+1] = hpm_ev_acc[hgi] |
                ((csr_addr == `CSR_ADDR_MHPMEVENT3_BASE + hgi)    ? mhpmevent[hgi]      : 5'b0);
        end
    endgenerate
    wire [XLEN-1:0] hpm_counter_lo_rd = hpm_lo_acc[`NUM_HPM_COUNTERS];
    wire [XLEN-1:0] hpm_counter_hi_rd = hpm_hi_acc[`NUM_HPM_COUNTERS];
    wire [4:0]      hpm_event_rd      = hpm_ev_acc[`NUM_HPM_COUNTERS];

    // mip: bits 3(MSIP, Phase R)/7(MTIP)/11(MEIP) are read-only, hardware-
    // driven straight from Timer.v/the PLIC-lite, never software-writable.
    // Phase F adds three more real bits, but unlike MSIP/MTIP/MEIP these
    // ARE software-writable per spec (a real platform's own S-level
    // software/timer/external interrupt sources are conventionally driven
    // by software -- e.g. M-mode's own trap handler -- not fixed hardware
    // the way this core's real timer/UART/CLINT-msip are). mip_sw holds
    // exactly those three S-level bits (SSIP@1/STIP@5/SEIP@9); every other
    // mip bit (including the three hardware ones) is either the fixed
    // hardware OR-in below or hardwired 0.
    reg [XLEN-1:0] mip_sw;
    wire [XLEN-1:0] mip = mip_sw | (msip_pending << `MIE_MSIE_BIT) |
        (timer_pending << `MIE_MTIE_BIT) | (ext_pending << `MIE_MEIE_BIT);

    // sstatus/sie/sip: NOT separate storage -- masked VIEWS onto mstatus/
    // mie/mip's S-mode-visible bit subset (SIE@1/SPIE@5/SPP@8 of mstatus;
    // SSIE@1/STIE@5/SEIE@9 of mie; SSIP@1/STIP@5/SEIP@9 of mip), the same
    // relationship fcsr already has onto {frm,fflags}. Genuinely
    // independent bit *positions* from mstatus's own MIE@3/MPIE@7 or
    // mie/mip's own MTIE/MEIE@7/11 -- per the real privileged spec, these
    // are different, coexisting interrupt-enable/pending bits sharing one
    // physical register, not aliases of the machine-level ones.
    wire [XLEN-1:0] sstatus_view = {XLEN{1'b0}} |
        (mstatus[`MSTATUS_SPP_BIT]  << `MSTATUS_SPP_BIT) |
        (mstatus[`MSTATUS_SPIE_BIT] << `MSTATUS_SPIE_BIT) |
        (mstatus[`MSTATUS_SIE_BIT]  << `MSTATUS_SIE_BIT);
    wire [XLEN-1:0] sie_view = {XLEN{1'b0}} |
        (mie[`MIE_SEIE_BIT] << `MIE_SEIE_BIT) |
        (mie[`MIE_STIE_BIT] << `MIE_STIE_BIT) |
        (mie[`MIE_SSIE_BIT] << `MIE_SSIE_BIT);
    wire [XLEN-1:0] sip_view = {XLEN{1'b0}} |
        (mip[`MIE_SEIE_BIT] << `MIE_SEIE_BIT) |
        (mip[`MIE_STIE_BIT] << `MIE_STIE_BIT) |
        (mip[`MIE_SSIE_BIT] << `MIE_SSIE_BIT);

    assign mtvec_val = mtvec;
    assign mepc_val = mepc;
    assign frm_val = frm;
    // Gen7 Pillar V Phase 1 (docs/adr/0061).
    assign vl_o    = vl;
    assign vsew_o  = vtype_fields[5:3];
    assign vlmul_o = vtype_fields[2:0];
    assign vill_o  = vill;
    assign mstatus_mie = mstatus[3];
    assign mstatus_mpie = mstatus[7];
    assign mstatus_sie = mstatus[`MSTATUS_SIE_BIT];
    assign mstatus_spie = mstatus[`MSTATUS_SPIE_BIT];
    assign mstatus_spp = mstatus[`MSTATUS_SPP_BIT];
    assign mstatus_mpp = mstatus[`MSTATUS_MPP_LO+1:`MSTATUS_MPP_LO];
    assign mie_msie = mie[`MIE_MSIE_BIT];
    assign mie_mtie = mie[`MIE_MTIE_BIT];
    assign mie_meie = mie[`MIE_MEIE_BIT];
    assign mie_ssie = mie[`MIE_SSIE_BIT];
    assign mie_stie = mie[`MIE_STIE_BIT];
    assign mip_ssip = mip_sw[`MIE_SSIE_BIT];
    assign mip_stip = mip_sw[`MIE_STIE_BIT];
    assign priv_mode_val = priv_mode;
    assign stvec_val = stvec;
    assign sepc_val = sepc;
    // docs/adr/0031 (Phase O). XLEN-conditional satp decode: a plain
    // procedural `if` keyed on the elaboration-time-constant XLEN, not a
    // continuous-assign ternary -- matches DataMemoryBRAM.v's own proven
    // "if (XLEN >= 64) ..." idiom (docs/adr/0028) for an out-of-range
    // bit-slice that must dead-code-eliminate cleanly under
    // `iverilog -Wall` at the XLEN this build doesn't select.
    always @(*) begin
        if (XLEN == 32) begin
            satp_mode_val = satp[`SATP_MODE_BIT];
            // Zero-extended into the wider (Phase P3) port -- Ptw.v's own
            // satp_ppn port stays 22 bits, fed this value's low 22 bits at
            // the call site.
            satp_ppn_val  = {22'b0, satp[`SATP_PPN_HI:`SATP_PPN_LO]};
        end else begin  // XLEN == 64: Sv39's own MODE/PPN layout, not Sv32's
            satp_mode_val = (satp[`SATP64_MODE_HI:`SATP64_MODE_LO] == `SATP_MODE_SV39);
            // docs/adr/00NN-sv39-mmu-phase-p.md (Phase P3): full 44-bit Sv39
            // PPN, no truncation here -- satp's own PPN field is a root
            // pointer, not an address this module forms; Ptw39.v does its
            // own low-20-bits truncation internally (its `satp_ppn20`),
            // matching Ptw.v's identical "decode at full width, truncate
            // only what the walker itself forms" principle.
            satp_ppn_val  = satp[`SATP64_PPN_HI:`SATP64_PPN_LO];
        end
    end

    // docs/adr/00NN-mmu-sv32.md (Phase F3). Delegation decision: a trap is
    // taken directly into S (rather than M) iff it's NOT sourced from M
    // itself (a trap that occurs while already in M is never delegated,
    // per spec -- there's nowhere lower to hand it to from M's own
    // perspective) AND the matching mideleg/medeleg bit is set. Indexed by
    // the same low 5 bits mcause itself uses (every real cause code this
    // core raises fits in 0-31); trap_is_interrupt picks which of the two
    // delegation registers applies, exactly mirroring how it already picks
    // between MCAUSE_INT_*/plain MCAUSE_* numbering for mcause itself.
    wire trap_delegated = trap_is_interrupt ? mideleg[trap_cause[4:0]] : medeleg[trap_cause[4:0]];
    assign trap_target_is_s = trap_taken && (priv_mode != `PRIV_M) && trap_delegated;

    always @(*) begin
        case (csr_addr)
            `CSR_ADDR_MSTATUS:  csr_rdata = mstatus;
            `CSR_ADDR_MIE:      csr_rdata = mie;
            `CSR_ADDR_MTVEC:    csr_rdata = mtvec;
            `CSR_ADDR_MSCRATCH: csr_rdata = mscratch;
            `CSR_ADDR_MEPC:     csr_rdata = mepc;
            `CSR_ADDR_MCAUSE:   csr_rdata = mcause;
            `CSR_ADDR_MIP:      csr_rdata = mip;
            `CSR_ADDR_FFLAGS:   csr_rdata = {{(XLEN-5){1'b0}}, fflags};
            `CSR_ADDR_FRM:      csr_rdata = {{(XLEN-3){1'b0}}, frm};
            `CSR_ADDR_FCSR:     csr_rdata = {{(XLEN-8){1'b0}}, frm, fflags};
            // Phase F additions (storage only in this commit -- see the
            // module header). sstatus/sie/sip read their masked views;
            // everything else reads its own real, independent storage.
            `CSR_ADDR_SSTATUS:  csr_rdata = sstatus_view;
            `CSR_ADDR_SIE:      csr_rdata = sie_view;
            `CSR_ADDR_SIP:      csr_rdata = sip_view;
            `CSR_ADDR_STVEC:    csr_rdata = stvec;
            `CSR_ADDR_SSCRATCH: csr_rdata = sscratch;
            `CSR_ADDR_SEPC:     csr_rdata = sepc;
            `CSR_ADDR_SCAUSE:   csr_rdata = scause;
            `CSR_ADDR_STVAL:    csr_rdata = stval;
            `CSR_ADDR_SATP:     csr_rdata = satp;
            `CSR_ADDR_MTVAL:    csr_rdata = mtval;
            `CSR_ADDR_MIDELEG:  csr_rdata = mideleg;
            `CSR_ADDR_MEDELEG:  csr_rdata = medeleg;
            // Gen7 Pillar V Phase 1 (docs/adr/0061).
            `CSR_ADDR_VSTART:   csr_rdata = {{(XLEN-16){1'b0}}, vstart};
            `CSR_ADDR_VTYPE:    csr_rdata = {vill, {(XLEN-9){1'b0}}, vtype_fields};
            `CSR_ADDR_VL:       csr_rdata = vl;
            `CSR_ADDR_VLENB:    csr_rdata = (VLEN/8);
            `CSR_ADDR_VXRM:     csr_rdata = {{(XLEN-2){1'b0}}, vxrm};
            `CSR_ADDR_VXSAT:    csr_rdata = {{(XLEN-1){1'b0}}, vxsat};
            `CSR_ADDR_VCSR:     csr_rdata = {{(XLEN-3){1'b0}}, vxrm, vxsat};
            default:            csr_rdata = {XLEN{1'b0}};  // unimplemented CSR reads as 0 rather than trapping
        endcase

        // docs/adr/0031 (Phase O). mstatus.UXL/SXL (RV64 only, bits 33:32/
        // 35:34) -- fixed WARL-to-2 ("64-bit") constants applied at the
        // read mux, not real storage (mstatus/mstatus_masked never touch
        // these bits, so nothing here is ever writable). Guarded exactly
        // like DataMemoryBRAM.v's own proven `if (XLEN >= 64)` idiom
        // (docs/adr/0028) for an otherwise out-of-range part-select --
        // confirmed to dead-code-eliminate cleanly under `iverilog -Wall`
        // at XLEN=32, since the branch is constant-folded away entirely.
        if (XLEN == 64 && csr_addr == `CSR_ADDR_MSTATUS) begin
            csr_rdata[`MSTATUS_UXL_LO+1 -: 2] = `MXL_XLEN64;
            csr_rdata[`MSTATUS_SXL_LO+1 -: 2] = `MXL_XLEN64;
        end

        // docs/adr/0025-hpc-performance-csrs.md (Phase J). The 9 generic
        // HPM counters/event-selectors are contiguous address ranges,
        // decoded by subtraction (a real indexed array, see the storage
        // declaration above) rather than an explicit `case` arm per
        // address -- `case` items must be constant expressions, which
        // can't express "one of 9 addresses computed from a loop index."
        // Evaluated after the case above so these addresses simply
        // override that block's own `default: 0` arm.
        if (csr_addr == `CSR_ADDR_MCOUNTINHIBIT)
            csr_rdata = mcountinhibit;
        else if (csr_addr == `CSR_ADDR_MCYCLE)
            csr_rdata = mcycle_lo;
        else if (csr_addr == `CSR_ADDR_MCYCLEH)
            csr_rdata = mcycle_hi;
        else if (csr_addr == `CSR_ADDR_MINSTRET)
            csr_rdata = minstret_lo;
        else if (csr_addr == `CSR_ADDR_MINSTRETH)
            csr_rdata = minstret_hi;
        else if (csr_addr >= `CSR_ADDR_MHPMCOUNTER3_BASE &&
                 csr_addr <  `CSR_ADDR_MHPMCOUNTER3_BASE + `NUM_HPM_COUNTERS)
            csr_rdata = hpm_counter_lo_rd;
        else if (csr_addr >= `CSR_ADDR_MHPMCOUNTER3H_BASE &&
                 csr_addr <  `CSR_ADDR_MHPMCOUNTER3H_BASE + `NUM_HPM_COUNTERS)
            csr_rdata = hpm_counter_hi_rd;
        else if (csr_addr >= `CSR_ADDR_MHPMEVENT3_BASE &&
                 csr_addr <  `CSR_ADDR_MHPMEVENT3_BASE + `NUM_HPM_COUNTERS)
            csr_rdata = {{(XLEN-5){1'b0}}, hpm_event_rd};
    end

    wire [XLEN-1:0] new_val = (csr_op == 2'b10) ? (csr_rdata | csr_wdata) :   // csrrs: set
                               (csr_op == 2'b11) ? (csr_rdata & ~csr_wdata) : // csrrc: clear
                                                   csr_wdata;                 // csrrw (2'b01): write

    // Bit masks identifying exactly which mstatus/mie bits sstatus/sie
    // expose -- used for read-modify-write preservation of the machine-
    // only bits a write through the S-mode address must never touch.
    localparam [XLEN-1:0] SSTATUS_BITS = ({XLEN{1'b0}} |
        (1 << `MSTATUS_SIE_BIT) | (1 << `MSTATUS_SPIE_BIT) | (1 << `MSTATUS_SPP_BIT));
    localparam [XLEN-1:0] SIE_BITS = ({XLEN{1'b0}} |
        (1 << `MIE_SSIE_BIT) | (1 << `MIE_STIE_BIT) | (1 << `MIE_SEIE_BIT));

    // mstatus's real bits as of this phase: MIE@3/MPIE@7 (docs/adr/0011),
    // plus SIE@1/SPIE@5/SPP@8/MPP@12:11 (Phase F). Used when the write
    // targets `mstatus` directly -- every real bit can be set this way.
    wire [XLEN-1:0] mstatus_masked = ({XLEN{1'b0}} | (new_val[3] << 3) | (new_val[7] << 7) |
        (new_val[`MSTATUS_SIE_BIT]  << `MSTATUS_SIE_BIT) |
        (new_val[`MSTATUS_SPIE_BIT] << `MSTATUS_SPIE_BIT) |
        (new_val[`MSTATUS_SPP_BIT]  << `MSTATUS_SPP_BIT) |
        (new_val[12:11] << `MSTATUS_MPP_LO));

    // A write THROUGH `sstatus` (not `mstatus` directly) must only ever
    // affect the S-visible subset (SIE/SPIE/SPP) -- never MIE/MPIE/MPP,
    // even if the raw bit pattern software supplies (e.g. via csrrw, which
    // ignores the read side entirely) happens to have those bits set. Real
    // spec requirement: sstatus is a *restricted* window, not just a
    // same-bits alias with a different name.
    wire [XLEN-1:0] sstatus_write_masked = {XLEN{1'b0}} |
        (new_val[`MSTATUS_SIE_BIT]  << `MSTATUS_SIE_BIT) |
        (new_val[`MSTATUS_SPIE_BIT] << `MSTATUS_SPIE_BIT) |
        (new_val[`MSTATUS_SPP_BIT]  << `MSTATUS_SPP_BIT);

    // mie's real bits as of this phase: MTIE@7/MEIE@11 (docs/adr/0020),
    // MSIE@3 (docs/adr/0034, Phase R), plus SSIE@1/STIE@5/SEIE@9 (Phase F,
    // genuinely independent bits from the machine-level ones -- see
    // mip_sw's own comment above for why). Used when the write targets
    // `mie` directly.
    wire [XLEN-1:0] mie_masked = ({XLEN{1'b0}} |
        (new_val[`MIE_MSIE_BIT] << `MIE_MSIE_BIT) |
        (new_val[`MIE_MTIE_BIT] << `MIE_MTIE_BIT) | (new_val[`MIE_MEIE_BIT] << `MIE_MEIE_BIT) |
        (new_val[`MIE_SSIE_BIT] << `MIE_SSIE_BIT) | (new_val[`MIE_STIE_BIT] << `MIE_STIE_BIT) |
        (new_val[`MIE_SEIE_BIT] << `MIE_SEIE_BIT));

    // A write through `sie` must only ever affect SSIE/STIE/SEIE -- same
    // restricted-window reasoning as sstatus_write_masked above.
    wire [XLEN-1:0] sie_write_masked = {XLEN{1'b0}} |
        (new_val[`MIE_SSIE_BIT] << `MIE_SSIE_BIT) | (new_val[`MIE_STIE_BIT] << `MIE_STIE_BIT) |
        (new_val[`MIE_SEIE_BIT] << `MIE_SEIE_BIT);

    // mip_sw's three real bits (SSIP/STIP/SEIP) are the only ones software
    // can ever write, via either `mip` or `sip` -- MTIP/MEIP are never
    // storage at all (see mip_sw's own declaration above), so there's
    // nothing address-dependent to distinguish here, unlike mstatus/mie.
    wire [XLEN-1:0] mip_sw_masked = {XLEN{1'b0}} |
        (new_val[`MIE_SSIE_BIT] << `MIE_SSIE_BIT) | (new_val[`MIE_STIE_BIT] << `MIE_STIE_BIT) |
        (new_val[`MIE_SEIE_BIT] << `MIE_SEIE_BIT);

    // mideleg/medeleg: only the causes this core can actually raise are
    // real bits; everything else is hardwired 0 (mirrors mie/mip's own
    // "only the bits with a real source behind them" convention).
    // mideleg allows delegating this core's own three real hardware
    // interrupt sources (bits 3/7/11, Phase R added bit3/MSI alongside the
    // original bits 7/11) directly, alongside the conventionally-S-level
    // software/timer/external bits (1/5/9) -- a real but slightly
    // non-standard choice for this core's minimal-source design: see
    // docs/adr/00NN-mmu-sv32.md for why (no separate S-level hardware
    // timer/external source exists, so bits 3/7/11 are the only way to give
    // S-mode direct access to this core's real software/timer/UART
    // interrupts).
    wire [XLEN-1:0] mideleg_masked = {XLEN{1'b0}} |
        (new_val[`MIE_SSIE_BIT] << `MIE_SSIE_BIT) | (new_val[`MIE_STIE_BIT] << `MIE_STIE_BIT) |
        (new_val[`MIE_MSIE_BIT] << `MIE_MSIE_BIT) | (new_val[`MIE_MTIE_BIT] << `MIE_MTIE_BIT) |
        (new_val[`MIE_SEIE_BIT] << `MIE_SEIE_BIT) | (new_val[`MIE_MEIE_BIT] << `MIE_MEIE_BIT);
    wire [XLEN-1:0] medeleg_masked = {XLEN{1'b0}} |
        (new_val[2] << 2) | (new_val[3] << 3) |
        (new_val[8] << 8) | (new_val[9] << 9) | (new_val[11] << 11) |
        (new_val[12] << 12) | (new_val[13] << 13) | (new_val[15] << 15);

    always @(posedge clk) begin
        if (~rst) begin
            mstatus  <= {XLEN{1'b0}};
            mie      <= {XLEN{1'b0}};
            mtvec    <= {XLEN{1'b0}};
            mscratch <= {XLEN{1'b0}};
            mepc     <= {XLEN{1'b0}};
            mcause   <= {XLEN{1'b0}};
            fflags   <= 5'b0;
            frm      <= 3'b0;
            // Phase F additions. priv_mode resets to PRIV_M -- the spec's
            // own boot behavior (a hart always starts in machine mode) --
            // and, as of this commit (F1), is never written anywhere else;
            // F3 adds the mret/sret/trap-entry logic that actually moves
            // it. Every other new register resets to 0, same convention as
            // every existing CSR.
            priv_mode <= `PRIV_M;
            mip_sw    <= {XLEN{1'b0}};
            sscratch  <= {XLEN{1'b0}};
            sepc      <= {XLEN{1'b0}};
            scause    <= {XLEN{1'b0}};
            stval     <= {XLEN{1'b0}};
            mtval     <= {XLEN{1'b0}};
            stvec     <= {XLEN{1'b0}};
            satp      <= {XLEN{1'b0}};
            mideleg   <= {XLEN{1'b0}};
            medeleg   <= {XLEN{1'b0}};
            // Gen7 Pillar V Phase 1 (docs/adr/0061).
            vstart       <= 16'd0;
            vtype_fields <= 8'd0;
            vill         <= 1'b0;
            vl           <= {XLEN{1'b0}};
            vxrm         <= 2'd0;
            vxsat        <= 1'b0;
            // docs/adr/0025-hpc-performance-csrs.md (Phase J). mcountinhibit
            // resets to 0 (every counter counting by default, same "reset
            // to 0" convention every other CSR here already follows).
            // mhpmevent[i] resets to i+1, not 0 -- see its own declaration
            // comment above for why (fresh-boot observability default).
            mcycle_lo <= {XLEN{1'b0}};
            mcycle_hi <= {XLEN{1'b0}};
            minstret_lo <= {XLEN{1'b0}};
            minstret_hi <= {XLEN{1'b0}};
            mcountinhibit <= {XLEN{1'b0}};
            for (hpm_i = 0; hpm_i < `NUM_HPM_COUNTERS; hpm_i = hpm_i + 1) begin
                mhpmcounter_lo[hpm_i] <= {XLEN{1'b0}};
                mhpmcounter_hi[hpm_i] <= {XLEN{1'b0}};
                mhpmevent[hpm_i] <= hpm_i[4:0] + 5'd1;
            end
        end
        else begin
            // docs/adr/0020-soc-integration.md (Phase D11). Each register
            // below is updated by its own independent if/else-if chain,
            // not one shared chain covering every register at once --
            // found necessary (by a real 60-seed random-cross-check
            // mismatch, not by design review) once D9 made trap_taken
            // includable for reasons entirely unrelated to whatever
            // instruction currently sits in EX (an interrupt). Before D9,
            // trap_taken/mret_taken were only ever true for the *same*
            // instruction csr_write_en could be true for, and that
            // instruction is never both (an opcode is either ecall/ebreak/
            // illegal/mret or a real csrrX, never both) -- so one shared
            // "trap_taken > mret_taken > csr_write_en" chain correctly
            // treated them as mutually exclusive. An interrupt breaks that:
            // it can fire on the exact same cycle an *unrelated*, perfectly
            // legitimate csrrX instruction elsewhere in EX is retiring its
            // own CSR write. A shared chain would silently drop that write
            // whenever a same-cycle interrupt happened to also be taken
            // (found via mcause/mstatus.MIE-swap being fine but an
            // ordinary mtvec/mscratch/fflags/frm/mie write vanishing on
            // exactly that cycle). Splitting by register fixes this while
            // preserving the *genuine* collisions (trap_taken/mret_taken
            // racing an ordinary write to the specific registers they
            // themselves also touch -- mstatus/mepc/mcause) exactly as
            // before, trap/mret still winning there.
            if (fp_flags_we)
                fflags <= fflags | fp_flags_in;
            else if (csr_write_en && (csr_addr == `CSR_ADDR_FFLAGS || csr_addr == `CSR_ADDR_FCSR))
                fflags <= new_val[4:0];

            if (csr_write_en && csr_addr == `CSR_ADDR_FRM)
                frm <= new_val[2:0];
            else if (csr_write_en && csr_addr == `CSR_ADDR_FCSR)
                frm <= new_val[7:5];

            // Gen7 Pillar V Phase 1 (docs/adr/0061). vstart is an ordinary
            // csrrX-writable CSR. vtype/vl are written ONLY via the
            // dedicated vec_cfg_write_en side channel (see this module's
            // own header) -- never through csr_write_en, so there's no
            // collision to arbitrate against a plain CSR write the way
            // e.g. mepc/trap_taken need.
            if (csr_write_en && csr_addr == `CSR_ADDR_VSTART)
                vstart <= new_val[15:0];

            if (vec_cfg_write_en) begin
                vtype_fields <= vec_cfg_new_vtype;
                vill         <= vec_cfg_new_vill;
                vl           <= vec_cfg_new_vl;
            end

            if (csr_write_en && csr_addr == `CSR_ADDR_VXRM)
                vxrm <= new_val[1:0];
            else if (csr_write_en && csr_addr == `CSR_ADDR_VCSR)
                vxrm <= new_val[2:1];

            if (csr_write_en && csr_addr == `CSR_ADDR_VXSAT)
                vxsat <= new_val[0];
            else if (csr_write_en && csr_addr == `CSR_ADDR_VCSR)
                vxsat <= new_val[0];

            // docs/adr/00NN-mmu-sv32.md (Phase F3). trap_taken now splits
            // on trap_target_is_s -- a trap delegated to S touches
            // sepc/scause/stval/mstatus's S-half instead of M's. mepc/
            // mcause/mtval themselves are UNTOUCHED by a delegated trap
            // (real spec behavior: M's own trap state is only ever
            // updated by a trap M itself is handling), so each still
            // falls through to its own plain csrrX-write arm otherwise.
            if (trap_taken && !trap_target_is_s) begin
                mepc <= trap_pc;
            end
            else if (csr_write_en && csr_addr == `CSR_ADDR_MEPC)
                mepc <= new_val;

            if (trap_taken && !trap_target_is_s) begin
                // docs/adr/0020-soc-integration.md (Phase D9). mcause[31]
                // is the spec's interrupt-vs-exception bit; trap_cause
                // itself never sets it (riscv_defs.vh's MCAUSE_*/
                // MCAUSE_INT_* constants are all small values, well under
                // bit31).
                mcause <= {trap_is_interrupt, trap_cause[30:0]};
            end
            else if (csr_write_en && csr_addr == `CSR_ADDR_MCAUSE)
                mcause <= new_val;

            if (trap_taken && !trap_target_is_s)
                mtval <= trap_value;
            else if (csr_write_en && csr_addr == `CSR_ADDR_MTVAL)
                mtval <= new_val;

            // docs/adr/00NN-mmu-sv32.md (Phase F3). sepc/scause/stval are
            // the S-mode mirror of mepc/mcause/mtval above, touched only
            // when THIS trap is delegated -- an M-targeted trap leaves
            // them alone (they fall through to their own plain csrrX-write
            // arm, same as before this phase).
            if (trap_taken && trap_target_is_s)
                sepc <= trap_pc;
            else if (csr_write_en && csr_addr == `CSR_ADDR_SEPC)
                sepc <= new_val;

            if (trap_taken && trap_target_is_s)
                scause <= {trap_is_interrupt, trap_cause[30:0]};
            else if (csr_write_en && csr_addr == `CSR_ADDR_SCAUSE)
                scause <= new_val;

            if (trap_taken && trap_target_is_s)
                stval <= trap_value;
            else if (csr_write_en && csr_addr == `CSR_ADDR_STVAL)
                stval <= new_val;

            // docs/adr/00NN-mmu-sv32.md (Phase F3). mstatus's MIE/MPIE
            // swap (docs/adr/0011) now only fires for an M-targeted trap;
            // a delegated trap swaps SIE/SPIE instead, and both trap
            // arms additionally record the *previous* privilege (MPP for
            // M, SPP for S) so mret/sret know what to restore. mret/sret
            // restore their own half symmetrically -- MPP resets to
            // PRIV_U (spec: "the least-privileged supported mode", which
            // for this core is U) after mret; SPP is reset to 0 (U) after
            // sret too, for the same reason, though the real spec text is
            // less explicit about SPP specifically since it's a single
            // bit already fully overwritten by the next delegated trap
            // regardless.
            if (trap_taken && !trap_target_is_s) begin
                mstatus[7] <= mstatus[3];       // MPIE <= MIE
                mstatus[3] <= 1'b0;             // MIE  <= 0 (traps disabled while handling this one)
                mstatus[12:11] <= priv_mode;    // MPP  <= previous privilege
            end
            else if (trap_taken && trap_target_is_s) begin
                mstatus[`MSTATUS_SPIE_BIT] <= mstatus[`MSTATUS_SIE_BIT];  // SPIE <= SIE
                mstatus[`MSTATUS_SIE_BIT]  <= 1'b0;                        // SIE  <= 0
                mstatus[`MSTATUS_SPP_BIT]  <= priv_mode[0];  // SPP <= previous privilege (U=0/S=1 fits in 1 bit;
                                                               // never delegated when previous priv is M, see
                                                               // trap_target_is_s's own !=PRIV_M condition above)
            end
            else if (mret_taken) begin
                mstatus[3] <= mstatus[7];  // MIE  <= MPIE
                mstatus[7] <= 1'b1;        // MPIE <= 1 (spec default)
                mstatus[12:11] <= `PRIV_U; // MPP  <= U (spec: least-privileged supported mode)
            end
            else if (sret_taken) begin
                mstatus[`MSTATUS_SIE_BIT]  <= mstatus[`MSTATUS_SPIE_BIT];  // SIE  <= SPIE
                mstatus[`MSTATUS_SPIE_BIT] <= 1'b1;                         // SPIE <= 1 (spec default)
                mstatus[`MSTATUS_SPP_BIT]  <= 1'b0;                         // SPP  <= U
            end
            else if (csr_write_en && csr_addr == `CSR_ADDR_MSTATUS)
                mstatus <= mstatus_masked;  // MIE/MPIE/SIE/SPIE/SPP/MPP are real (Phase F extends this)
            // A write through `sstatus` only ever touches the S-visible
            // subset -- SIE_BITS/SSTATUS_BITS below preserve every other
            // mstatus/mie bit exactly, the same restricted-window
            // reasoning sstatus_write_masked's own comment explains.
            else if (csr_write_en && csr_addr == `CSR_ADDR_SSTATUS)
                mstatus <= (mstatus & ~SSTATUS_BITS) | sstatus_write_masked;

            // docs/adr/00NN-mmu-sv32.md (Phase F3). priv_mode itself: a
            // trap always raises it (to S if delegated, M otherwise);
            // mret/sret each restore it from their own saved field.
            // Mutually exclusive with each other by construction (a
            // single instruction is never trap-taken and mret/sret at
            // once), so a plain if/else-if chain (no `reg2_hold`
            // collision risk beyond what trap_taken/mret_taken/sret_taken
            // themselves already carry from riscvpipeline.v) is correct.
            if (trap_taken)
                priv_mode <= trap_target_is_s ? `PRIV_S : `PRIV_M;
            else if (mret_taken)
                priv_mode <= mstatus[12:11];
            else if (sret_taken)
                priv_mode <= {1'b0, mstatus[`MSTATUS_SPP_BIT]};

            // mie/mtvec/mscratch are never touched by trap_taken/mret_taken
            // at all -- no collision to arbitrate, a real csrrX write is
            // the only source, ever. (Phase F: sie is a second address that
            // reaches the same underlying `mie` storage, read-modify-write
            // preserving the machine-only bits sie itself never exposes.)
            if (csr_write_en && csr_addr == `CSR_ADDR_MIE)
                mie <= mie_masked;
            else if (csr_write_en && csr_addr == `CSR_ADDR_SIE)
                mie <= (mie & ~SIE_BITS) | sie_write_masked;

            if (csr_write_en && csr_addr == `CSR_ADDR_MTVEC)
                mtvec <= new_val;

            if (csr_write_en && csr_addr == `CSR_ADDR_MSCRATCH)
                mscratch <= new_val;

            // Phase F additions. Every one of these is a plain csrrX-only
            // write in this commit (F1) -- no trap_taken/mret_taken
            // involvement yet (that's F3's job, extending sepc/scause/
            // stval/priv_mode/mstatus's SPP-MPP swap the same way mepc/
            // mcause/mstatus's own MIE-MPIE swap already work). mip_sw is
            // reachable via either `mip` or `sip`'s own address -- both
            // ever only touch the same three real bits, so no
            // read-modify-write preservation is needed the way mstatus/mie
            // need for sstatus/sie (see mip_sw_masked's own comment).
            if (csr_write_en && (csr_addr == `CSR_ADDR_MIP || csr_addr == `CSR_ADDR_SIP))
                mip_sw <= mip_sw_masked;

            if (csr_write_en && csr_addr == `CSR_ADDR_SSCRATCH)
                sscratch <= new_val;

            // sepc/scause/stval/mtval's own plain csrrX-write arms live
            // above now, folded into their trap-aware if/else-if chains
            // (docs/adr/00NN-mmu-sv32.md Phase F3) -- not repeated here.

            if (csr_write_en && csr_addr == `CSR_ADDR_STVEC)
                stvec <= new_val;

            if (csr_write_en && csr_addr == `CSR_ADDR_SATP)
                satp <= new_val;

            if (csr_write_en && csr_addr == `CSR_ADDR_MIDELEG)
                mideleg <= mideleg_masked;

            if (csr_write_en && csr_addr == `CSR_ADDR_MEDELEG)
                medeleg <= medeleg_masked;

            // docs/adr/0025-hpc-performance-csrs.md (Phase J). mcycle/
            // minstret/mcountinhibit: no trap-entry coupling at all (unlike
            // mepc/mcause/mstatus above), so each gets its own simple
            // independent chain, same discipline as mtvec/mscratch's own
            // plain csrrX-only chains. A software write to either half
            // takes priority over the same-cycle hardware auto-increment
            // (spec-silent on this exact race; this is the simpler,
            // common real-hardware choice). mcycle is inhibited by
            // mcountinhibit[0] (CY); minstret by mcountinhibit[2] (IR) and
            // gated on `instret_pulse` (exactly one real retiring
            // instruction, never a bubble -- see riscvpipeline.v's own
            // `valid`-bit threading, docs/adr/0025's Design section).
            if (csr_write_en && csr_addr == `CSR_ADDR_MCYCLE)
                mcycle_lo <= new_val;
            else if (csr_write_en && csr_addr == `CSR_ADDR_MCYCLEH)
                mcycle_hi <= new_val;
            else if (!mcountinhibit[0])
                {mcycle_hi, mcycle_lo} <= {mcycle_hi, mcycle_lo} + 64'd1;

            if (csr_write_en && csr_addr == `CSR_ADDR_MINSTRET)
                minstret_lo <= new_val;
            else if (csr_write_en && csr_addr == `CSR_ADDR_MINSTRETH)
                minstret_hi <= new_val;
            else if (instret_pulse && !mcountinhibit[2])
                {minstret_hi, minstret_lo} <= {minstret_hi, minstret_lo} + 64'd1;

            if (csr_write_en && csr_addr == `CSR_ADDR_MCOUNTINHIBIT)
                mcountinhibit <= new_val & MCOUNTINHIBIT_MASK;

            // mhpmcounter3-11/mhpmevent3-11: one independent chain per
            // counter via a plain procedural loop over the array declared
            // above -- safe here (unlike DCache.v/ICache.v's own
            // `generate`-over-`always @*` choice) because this loop lives
            // inside a `posedge clk`-sensitive block, not a `always @*`
            // block sensitive to an entire unpacked array (the specific
            // Icarus warning DCache.v's own header comment documents
            // avoiding never applies here).
            for (hpm_i = 0; hpm_i < `NUM_HPM_COUNTERS; hpm_i = hpm_i + 1) begin
                if (csr_write_en && csr_addr == `CSR_ADDR_MHPMCOUNTER3_BASE + hpm_i)
                    mhpmcounter_lo[hpm_i] <= new_val;
                else if (csr_write_en && csr_addr == `CSR_ADDR_MHPMCOUNTER3H_BASE + hpm_i)
                    mhpmcounter_hi[hpm_i] <= new_val;
                else if (!mcountinhibit[3+hpm_i] && (mhpmevent[hpm_i] != 5'd0) &&
                         hpm_event_pulse[mhpmevent[hpm_i]])
                    {mhpmcounter_hi[hpm_i], mhpmcounter_lo[hpm_i]} <=
                        {mhpmcounter_hi[hpm_i], mhpmcounter_lo[hpm_i]} + 64'd1;

                if (csr_write_en && csr_addr == `CSR_ADDR_MHPMEVENT3_BASE + hpm_i)
                    mhpmevent[hpm_i] <= new_val[4:0];
            end
        end
    end

endmodule

`default_nettype wire
