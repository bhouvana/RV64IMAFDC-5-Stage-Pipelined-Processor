#!/usr/bin/env python3
"""
Constrained-random instruction sequence generator (docs/ROADMAP.md V-4).

Constraints chosen to make every generated program *safe to compare*
without needing exception handling (this core has none yet) or a general
loop-detector:
  - x31 is reserved as a fixed memory-safe base pointer, set once at the
    very start and never overwritten by random instructions; all loads/
    stores use it as rs1 with a small, width-appropriate-aligned offset so
    every address stays inside DataMemory's 128 bytes.
  - Branches/jumps only ever target a *later* instruction (forward-only) --
    guarantees termination without a step limit doing the real safety work.
  - Division-by-zero and INT_MIN/-1 overflow are NOT avoided: both
    design/Divider.v and sim/tools/iss.py implement the same spec-mandated
    results, so hitting those cases is extra coverage, not a hazard.
  - CSR read/write (`csrrw`/`csrrs`/`csrrc`(+i)) is included in the mix --
    pure register/CSR data movement, no control-flow risk. `ecall`/`ebreak`/
    `mret`/deliberately-illegal instructions are deliberately NOT generated:
    unlike CSR reads/writes, those redirect control flow to mtvec/mepc,
    which would need real safety machinery (a guaranteed-safe mtvec, trap-
    recursion tracking) to keep programs forward-only and terminating --
    disproportionate for what's already covered by directed tests
    (ecall_trap.s, ebreak_trap.s, illegal_instr.s, aluctl_illegal.s,
    mret_return.s). See docs/ROADMAP.md / ARCHITECTURE.md sec 15.
  - docs/adr/0019-f-extension.md (Phase C9): float instructions are mixed
    in too, no new safety machinery needed -- flw/fsw reuse the same
    BASE_REG-relative safe-addressing pattern as lw/sw (the *address*
    register is always integer, even for fsw/flw), and NaN/Inf/subnormal/
    overflow/underflow results are extra coverage exactly like integer
    div-by-zero above: design/FALU.v & friends and sim/tools/iss.py's
    float model both implement the same spec-mandated results (including
    this core's own documented subnormal-flush-to-zero deviation), so
    hitting those cases is exactly the point, not a hazard. A handful of
    "interesting" float32 bit patterns (0, -0, 1.0, +/-inf, NaN,
    subnormal, near the overflow/underflow boundary) are seeded into a
    subset of float registers up front (construction needs a scratch
    integer register, GP_REGS is reused for this transiently -- no
    permanent reservation needed, since seeding happens once, before any
    randomly generated instruction) precisely so those edge cases show up
    in the arithmetic mix at a much higher rate than uniform-random 32-bit
    patterns would produce on their own (most random bit patterns land on
    unremarkable finite normals).
"""
import random

R_TYPE = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
          "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
I_TYPE = ["addi", "slti", "sltiu", "xori", "ori", "andi"]  # slli/srli/srai handled separately (shamt, not full imm)
SHIFT_I = ["slli", "srli", "srai"]
BRANCH = ["beq", "bne", "blt", "bge", "ble", "bgt", "bltu", "bgeu"]
CSR_REG_OP = ["csrrw", "csrrs", "csrrc"]
CSR_IMM_OP = ["csrrwi", "csrrsi", "csrrci"]
CSR_NAMES = ["mstatus", "mtvec", "mscratch", "mepc", "mcause"]

BASE_REG = 31       # reserved memory-safe base pointer
GP_REGS = list(range(1, 31))  # x1..x30, random general-purpose pool

# docs/adr/0019-f-extension.md (Phase C9). No reserved index -- FRegister.v
# hardwires nothing, every one of f0-f31 is fair game.
FREGS = list(range(0, 32))
FP_ARITH = ["fadd.s", "fsub.s", "fmul.s", "fdiv.s"]  # 2-operand + optional rm
FP_SGNJ = ["fsgnj.s", "fsgnjn.s", "fsgnjx.s"]
FP_MINMAX = ["fmin.s", "fmax.s"]
FP_CMP = ["feq.s", "flt.s", "fle.s"]  # writes the INTEGER file
FP_CVT_TO_INT = ["fcvt.w.s", "fcvt.wu.s"]  # writes the INTEGER file
FP_CVT_FROM_INT = ["fcvt.s.w", "fcvt.s.wu"]  # reads the INTEGER file
FMADD_FAMILY = ["fmadd.s", "fmsub.s", "fnmsub.s", "fnmadd.s"]
RM_NAMES = ["rne", "rtz", "rdn", "rup", "rmm", "dyn"]
FCSR_NAMES = ["fflags", "frm", "fcsr"]  # via asm.py's raw-address fallback (no name table entry needed)
FCSR_ADDR = {"fflags": "0x1", "frm": "0x2", "fcsr": "0x3"}

# A curated set of "interesting" float32 bit patterns -- see this module's
# own docstring for why these are seeded explicitly rather than relying on
# uniform-random 32-bit patterns to stumble into them. Kept short (each
# entry costs 2 instructions -- lui + fmv.w.x, all chosen with zero low-12
# bits specifically to avoid a 3rd addi instruction) since InstructionMemory
# is only 128 bytes (32 instructions) end to end, shared with the leading
# base-pointer setup, the trailing halt loop, and n_instrs of actual random
# instructions -- see gen_program's own budget comment.
# Gen6-L, replaced Gen6-P6 (docs/adr/0057): was 32 nops of flat padding
# (jal wasn't real in OOOCore.v yet at Gen6-L time, so a genuine self-loop
# halt -- non-ooo mode's own `jal x0,__halt` -- wasn't reachable; see this
# file's own git history for the original nop-count reasoning, since
# superseded). A REAL bug found by running, root-caused by direct cycle
# tracing (not guessed): fdiv.s/fsqrt.s's own genuine multi-cycle latency
# (FDivider.v/FSqrt.v, tens of cycles each, and BACK-TO-BACK ones on the
# same shared unit serialize) can easily exceed flat padding's own
# "2x ROB_ENTRIES" sizing assumption -- fetch is NOT gated by a slow
# instruction's own retirement (OOOCore.v's frontend dispatches ahead
# freely), so a long enough in-flight fdiv/fsqrt chain lets fetch run
# clean off the end of the nop padding into the zero-filled tail BEFORE
# the real program's own last instruction retires -- illegal-opcode traps,
# mtvec's own reset default of 0 redirects, and the ENTIRE program
# silently restarts from scratch mid-comparison, corrupting whatever
# hadn't retired yet with a LATER pass's own value (observed directly: a
# generated program's own fsqrt.s destination read back as a stale value
# from an earlier restart, not garbage -- root-caused by tracing
# fdiv_complete_valid/rob_retire_* across multiple ~640-time-unit-apart
# repeats of the identical PC, the unmistakable signature of this exact
# restart loop). Gen6-O3 made jal real in OOOCore.v since Gen6-L's own
# original design -- a genuine self-loop (`jal x0,__halt`, this generator's
# own non-ooo mode already uses it) is reachable now, and ELIMINATES the
# race entirely rather than just widening the margin: once reached, PC can
# never advance past the halt loop again, regardless of how slow anything
# upstream is. Exactly 1 real instruction (the jal itself; the label costs
# nothing) is all the trailer needs now -- name kept (many call sites
# import it) despite no longer being a nop count.
OOO_TRAILER_NOP_COUNT = 1

FLOAT_SEED_BITS = [
    0x00000000,  # +0.0
    0x3F800000,  # 1.0
    0xBF800000,  # -1.0
    0x7F800000,  # +infinity
    0x7FC00000,  # canonical quiet NaN
    0x00400000,  # a subnormal (input flush-to-zero coverage)
]


R_TYPE_W = ["addw", "subw", "sllw", "srlw", "sraw", "mulw", "divw", "divuw", "remw", "remuw"]
I_TYPE_W = ["addiw", "slliw", "srliw", "sraiw"]


def const64_to_reg_instrs(rd, rd_scratch, bits64, no_lui=False):
    """Generation 2 (Phase M15, docs/adr/0028-rv64-migration-phase-m.md).
    Builds an arbitrary 64-bit constant into `rd`, using `rd_scratch` as a
    second, clobbered register. Splits into hi32/lo32, builds each half via
    the existing 32-bit const_to_reg_instrs (which sign-extends its result
    to 64 bits -- an artifact, not a bug: `slli rd,rd,32` washes that out
    for the hi half, since shifting left by 32 discards the original upper
    32 bits entirely and zero-fills the new low 32; for the lo half, a
    slli-then-srli-by-32 pair zero-extends it the same way before the two
    halves are OR'd together (their bit ranges never overlap, so OR and ADD
    are equivalent here -- OR makes that non-overlap explicit). no_lui
    (Gen6-L): forwarded to both const_to_reg_instrs calls -- see that
    function's own docstring/comment."""
    hi32 = (bits64 >> 32) & 0xFFFFFFFF
    lo32 = bits64 & 0xFFFFFFFF
    lines = const_to_reg_instrs(rd, hi32, no_lui=no_lui)
    lines.append(f"slli x{rd}, x{rd}, 32")
    lines.extend(const_to_reg_instrs(rd_scratch, lo32, no_lui=no_lui))
    lines.append(f"slli x{rd_scratch}, x{rd_scratch}, 32")
    lines.append(f"srli x{rd_scratch}, x{rd_scratch}, 32")
    lines.append(f"or x{rd}, x{rd}, x{rd_scratch}")
    return lines


def _self_check_const64(bits64):
    # Replays the exact arithmetic const64_to_reg_instrs's own instruction
    # sequence performs (not a re-derivation from hi32/lo32 directly, which
    # would just restate the function's own assumption) -- a real, if
    # small, independent check on the construction logic itself.
    hi32 = (bits64 >> 32) & 0xFFFFFFFF
    lo32 = bits64 & 0xFFFFFFFF
    MASK64 = (1 << 64) - 1

    def sext32(v):
        v &= 0xFFFFFFFF
        return v - (1 << 32) if v & 0x80000000 else v

    rd = sext32(hi32) & MASK64          # const_to_reg_instrs(rd, hi32) -- sign-extends to 64 bits
    rd = (rd << 32) & MASK64             # slli rd,rd,32
    scratch = sext32(lo32) & MASK64      # const_to_reg_instrs(rd_scratch, lo32)
    scratch = (scratch << 32) & MASK64   # slli rd_scratch,rd_scratch,32
    scratch = scratch >> 32              # srli rd_scratch,rd_scratch,32 (logical, zero-fills)
    rd = (rd | scratch) & MASK64         # or rd,rd,rd_scratch
    assert rd == (bits64 & MASK64), f"const64_to_reg_instrs self-check failed: got {rd:#x}, expected {bits64 & MASK64:#x}"


for _v in (0, 0xFFFFFFFFFFFFFFFF, 0x8000000000000000, 0x7FFFFFFFFFFFFFFF,
           0x123456789ABCDEF0, 0xFFFFFFFF00000001, 0x00000000FFFFFFFF, 0xDEADBEEF00000000):
    _self_check_const64(_v)


def const_to_reg_instrs(rd, bits32, no_lui=False):
    # Standard "build an arbitrary 32-bit constant" idiom: lui supplies the
    # upper 20 bits, addi's sign-extended 12-bit immediate corrects the
    # lower 12 -- when the low 12 bits' own top bit is set, addi would
    # sign-extend them negative, so the lui half is pre-incremented by 1 to
    # compensate (the classic lui+addi construction every RISC-V assembler
    # uses for li).
    #
    # no_lui (Gen6-L): design/OOOCore.v never wires lui_c into any
    # operand-A-forced-to-0 mux the way design/riscvpipeline.v's own
    # execute stage does (design/riscvpipeline.v:1395-1398's own comment
    # documents that forcing) -- lui genuinely computes garbage-register +
    # imm instead of 0+imm there, confirmed by direct code read before
    # this phase touched anything. This builds the same constant from
    # three 11-bit chunks using only addi/slli (both real, correctly-
    # executed OOOCore.v ops): addi loads each chunk as a small POSITIVE
    # immediate (0..2047, never sign-extension-ambiguous, unlike the lo-12
    # correction above), slli shifts the accumulator left 11 bits between
    # chunks. 3 chunks x 11 bits = 33 >= 32, so the top chunk only ever
    # carries 10 significant bits -- never overflows addi's own signed
    # 12-bit range either.
    if no_lui:
        bits32 &= 0xFFFFFFFF
        chunk_bits = 11
        n_chunks = 3
        top_shift = (n_chunks - 1) * chunk_bits
        chunks = [(bits32 >> (top_shift - i * chunk_bits)) & ((1 << chunk_bits) - 1) for i in range(n_chunks)]
        lines = [f"addi x{rd}, x0, {chunks[0]}"]
        for c in chunks[1:]:
            lines.append(f"slli x{rd}, x{rd}, {chunk_bits}")
            if c:
                lines.append(f"addi x{rd}, x{rd}, {c}")
        return lines
    lo = bits32 & 0xFFF
    hi = (bits32 >> 12) & 0xFFFFF
    if lo & 0x800:
        hi = (hi + 1) & 0xFFFFF
    lines = [f"lui x{rd}, {hi:#x}"]
    if lo != 0:
        lo_signed = lo - 0x1000 if (lo & 0x800) else lo
        lines.append(f"addi x{rd}, x{rd}, {lo_signed}")
    return lines


def _self_check_const32_no_lui(bits32):
    # Same "replay the exact instruction sequence" rigor as
    # _self_check_const64 below, for the new no_lui construction.
    MASK32 = (1 << 32) - 1

    def sext32(v):
        v &= MASK32
        return v - (1 << 32) if v & 0x80000000 else v

    lines = const_to_reg_instrs(0, bits32, no_lui=True)
    v = sext32(int(lines[0].rsplit(",", 1)[1]))  # addi x,x0,chunk0 -- sign-extends, but chunk0 < 1024, always positive
    for ln in lines[1:]:
        if ln.strip().startswith("slli"):
            v = (v << 11) & MASK32
        else:  # addi x,x,chunk -- chunk always 0..2047, positive, never sign-extends
            v = (v + int(ln.rsplit(",", 1)[1])) & MASK32
    assert v == (bits32 & MASK32), f"const_to_reg_instrs(no_lui=True) self-check failed: got {v:#x}, expected {bits32 & MASK32:#x}"


for _v in (0, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF, 0x12345678, 0xDEADBEEF, 1, 0x800):
    _self_check_const32_no_lui(_v)


def gen_program(seed, n_instrs=16, base_addr=32, mem_size=128, interrupt=None, mmu=False, xlen=32, ooo=False):
    """ooo (Generation 6, Gen6-L; widened Gen6-P6, docs/adr/0057):
    restricts the generated instruction mix to OOOCore.v's own actually-
    implemented subset, confirmed by direct code read (not assumed)
    before each phase touched anything. Gen6-O/P1/P4/P5 (docs/adr/0051,
    0052, 0055, 0056) closed real gaps this docstring used to list as
    unsafe: jal, csrrX (mscratch only, mirroring interrupt mode's own
    established restriction below), and fdiv.s/fsqrt.s are ALL now real,
    correctly-executing OOOCore.v instructions and have been moved back
    into the ooo=True pool. Still excluded, real gaps confirmed still
    open by direct code read: jalr (excluded from EVERY mode this
    generator has ever had, not ooo-specific -- a random register-
    dependent target isn't safe to generate for ANY core, nothing to do
    with OOOCore.v's own support); fcvt.w.s/fcvt.wu.s/feq.s/flt.s/fle.s
    (regWrite=1 path reads garbage from the INTEGER RAT instead of the
    float one); fsw (reads garbage integer "store data" instead of the
    intended float register); fcvt.s.w*/the fmadd family/flw (still
    quietly no-dest no-ops, docs/adr/0055's own explicitly-deferred
    scope); LR/SC/AMO-RMW (docs/adr/0052 made these real in OOOCore.v,
    but sim/tools/iss.py -- the reference model THIS generator's own
    RTL-vs-ISS cross-check depends on -- has ZERO AMO opcode support at
    all, confirmed by direct code read, not assumed; widening this
    generator without first teaching iss.py the A-extension would just
    produce spurious cross-check failures unrelated to real RTL bugs --
    real future work, a separate, substantial ISS change, not attempted
    here). ooo=True generates: r/i/shift/load/store/branch (conditional
    only), jal, csr (mscratch only), and a float pool now including
    fdiv.s (via fp_arith, no longer truncated to FP_ARITH[:3]) and
    fsqrt.s (fp_sqrt), plus fsgnj*/fmin.s/fmax.s -- every one of these
    OOOCore.v actually executes
    correctly end-to-end (Gen6-D/E/G/H). No CSR (csr_weight forced 0, same
    "exclude what can't be made safe to compare" precedent mmu mode
    already established below), no "w"-suffixed family even at xlen=64
    (design/OOOCore.v's own is_div_op check was never confirmed to
    recognize a DIVW/REMW-distinct ALUCtl encoding -- excluded rather than
    assumed safe), no ecall/illegal/mret injection (OOOCore.v's own
    single-outstanding-trap machinery is already covered by
    tb_ooocore_trap_i1.v; duplicating fault-injection here is disproportionate,
    same reasoning this docstring's own interrupt/mmu-mode CSR restrictions
    already use), no interrupt/mmu (mutually exclusive with those modes
    below -- OOOCore.v implements both for real now, docs/adr/0053/0054,
    but combining either with the ooo-mode instruction pool is real,
    separate future work, a genuinely new integration this generator
    doesn't attempt yet, not a limitation of OOOCore.v itself).

    xlen (Generation 2, docs/adr/0028-rv64-migration-phase-m.md): 32
    (default, every existing call site's exact behavior, unaffected) or 64
    -- gates in the "w"-suffixed instruction family (addw/subw/sllw/srlw/
    sraw/mulw/divw/divuw/remw/remuw/addiw/slliw/srliw/sraiw) and ld/sd/lwu
    into the random instruction mix, and seeds one scratch register with a
    genuine wide 64-bit pattern via const64_to_reg_instrs (mirroring the
    float-seeding rationale above -- ordinary add/sub/etc. alone rarely
    produce a register value with both meaningfully-set upper AND lower
    32-bit halves, under-exercising exactly the truncation/sign-extension
    boundary this generation's own RTL changes are about).

    docs/adr/00NN-mmu-sv32.md (Phase F7). mmu=True (opt-in, default False
    -- every existing call site unaffected): prepend a real, M-mode-built
    Sv32 page table and drop to U-mode via mret before any of the
    random-generated instructions run, so every one of them (fetch, load,
    store) is a genuinely translated access -- mirrors docs/adr/0020 D10's
    own "agree by construction" philosophy, extended from interrupt-timing
    agreement to translation-validity agreement: a generator-*guaranteed-
    valid* identity mapping (VA==PA everywhere, satp_ppn=0), never a truly
    random satp, so every generated access is guaranteed mapped and
    permitted -- there is nothing here for a page fault to legitimately hit
    (fault-injection is a separate, deliberately directed-only concern, the
    same "exclude what can't be made safe to compare" principle this
    generator already applies to ecall/ebreak/mret/illegal instructions and
    interrupt mode's own restricted CSR pool below).

    Mutually exclusive with `interrupt` in this phase -- combining real
    hardware-interrupt injection with a live page-table walk is real,
    genuinely separate future work, not attempted here.

    The page table needs real memory: a level-1 table (one PDE, at
    physical address 0 -- satp_ppn=0) and a level-0 table (one PTE, at
    physical page 1, address 0x1000 -- Sv32's own page-table alignment is
    fixed by the spec, not a tunable choice) both need to exist, which the
    tiny 128/256-byte mem_size this generator otherwise defaults to cannot
    hold. Callers must pass a real mem_size (this module's own __main__ and
    run_random_tests.py both default to 8192 -- two 4KB pages -- when mmu
    is set). The random program's own working region (base pointer,
    loads/stores) is deliberately kept within the FIRST page only (see
    addr_space below) -- the single level-0 PTE only maps VPN0=0, so an
    access into the second page (where the level-0 table itself lives)
    would be genuinely unmapped, breaking the "always guaranteed valid"
    property this mode exists to provide.

    interrupt: None (default -- every existing caller's behavior,
    completely unaffected), or one of "timer"/"uart"/"both" to additionally
    arm that interrupt source (or, for "both", arm and pend both sources
    simultaneously -- docs/adr/0020-soc-integration.md Phase D11 -- so the
    real interrupt taken must be the external one, MEI-over-MTI priority,
    D9's own already-proven redirect condition, now exercised under a
    random program body instead of only a directed test) and inject it
    somewhere during the random body. docs/adr/0020-soc-integration.md
    (Phase D10).

    The injected handler is deliberately architecturally inert -- `csrrw
    x0, mie, x0` (disarm both sources, preventing an immediate re-trigger
    once mstatus.MIE is restored -- mip is a real level signal on the RTL
    side, not edge-triggered) then `mret`, touching no GP/FP register and
    no memory. This is *why* the RTL and the ISS's own externally-scheduled
    firing point (see iss.py's schedule_interrupt) don't need to agree on
    the exact instruction boundary the interrupt lands on: since nothing
    the handler does is part of the compared final state, and D9's own
    redirect logic already guarantees no instruction is skipped or
    re-executed, the final architectural state after the whole program
    runs is identical regardless of exactly which cycle interrupted it --
    only *that* it fires (at most once) somewhere before the program's own
    halt loop is what this generator arranges, not precisely *when*. The
    RTL's own timing (a real, generously-margined MTIMECMP for the timer
    source, or the test rig's own driven UART byte for the external source)
    only needs to land somewhere in that same broad window, not at a
    specific cycle.
    """
    if interrupt is not None and mmu:
        raise ValueError("interrupt and mmu modes are mutually exclusive in this generator (Phase F7 scope)")
    if ooo and (interrupt is not None or mmu):
        raise ValueError("ooo mode is mutually exclusive with interrupt/mmu in this generator (Gen6-L scope -- "
                          "OOOCore.v implements neither yet)")

    # docs/adr/00NN-mmu-sv32.md (Phase F7). See gen_program's own docstring
    # for why: the random body's own loads/stores must stay within the
    # single mapped page (VPN0=0) even though mem_size itself is bigger (to
    # make room for the level-0 table in the second page).
    addr_space = min(mem_size, 4096) if mmu else mem_size

    # Budget check, not just documentation: InstructionMemory is mem_size
    # bytes -- 1 (base addi) + 2*len(FLOAT_SEED_BITS) (seeding) + n_instrs +
    # 1 (trailing jal), plus interrupt mode's own prefix+handler, must not
    # exceed that, or asm.py's write_mem raises before this is ever a
    # silent problem.
    interrupt_prefix_cost = 0
    if interrupt is not None:
        # Common: addi+csrrw(mtvec)=2, addi+csrrw(mie)=2, csrrsi(mstatus)=1
        # -> 5. Timer-specific: TIMER_BASE+CLINT_OFF_MTIMECMP's single lui
        # (1, Phase R -- real CLINT address, low 12 bits 0), the mtimecmp
        # constant (up to 2, lui+addi) + its sw(1) -> up to 4. UART-specific:
        # UART_BASE's lui(1) + enable-value addi(1) + its sw(1) -> 3.
        # MSI-specific (Phase R): TIMER_BASE's single lui (1, CLINT_OFF_MSIP
        # == 0) + enable-value addi(1) + its sw(1) -> 3, same shape as UART.
        # "both" needs both sources armed -- their own lui's each target a
        # different register (x1 vs x2), so neither can be shared -> up to
        # 4 + 3 = 7. Handler (all cases): csrrw(mie<-0) + mret -> 2.
        source_cost = {"timer": 4, "uart": 3, "msi": 3, "both": 7}[interrupt]
        interrupt_prefix_cost = 5 + source_cost + 2
    # docs/adr/00NN-mmu-sv32.md (Phase F7): level-1 PDE (const_to_reg, up to
    # 2, + sw = 3) + level-0 table address (lui = 1) + level-0 PTE (up to 2,
    # + sw = 3) + satp (up to 2, + csrrw = 3) + mepc placeholder+csrrw+mret
    # (3) = up to 13, generous upper bound (mem_size=8192 leaves enormous
    # headroom regardless).
    #
    # docs/adr/00NN-sv39-mmu-phase-p.md (Phase P5): xlen=64's Sv39 prefix
    # has one more table level (level-2/level-1/level-0, each up to 2 +
    # lui/sw) plus a genuinely 64-bit satp constant (const64_to_reg_instrs,
    # up to 8 -- same upper bound the RV64 seeding cost above already uses)
    # -- generous upper bound, mem_size is generous there too (see below).
    mmu_prefix_cost = (24 if xlen >= 64 else 13) if mmu else 0
    # Gen6-L: no_lui's chunked addi/slli construction costs more
    # instructions than lui+addi (up to 5 per 32-bit half vs up to 2) --
    # per-float-seed cost and the 64-bit seed's own upper bound both widen
    # under ooo. Still just a generous upper bound for this budget
    # pre-check, not a correctness-critical exact count (see const64_to_
    # reg_instrs's own "washes out" argument for why the exact per-half
    # construction never affects final correctness).
    xlen64_seed_cost = (20 if ooo else 8) if xlen >= 64 else 0  # const64_to_reg_instrs's own upper bound, see above
    trailer_cost = OOO_TRAILER_NOP_COUNT if ooo else 1  # ooo mode's own trailer is a bare `jal x0,self` (no fence -- OOOCore.v has no cache), see the trailer's own emission comment below
    budget = (1 + (6 if ooo else 2) * len(FLOAT_SEED_BITS) + xlen64_seed_cost + n_instrs + trailer_cost
              + interrupt_prefix_cost + mmu_prefix_cost)
    if budget > mem_size // 4:
        raise ValueError(f"n_instrs={n_instrs} would overflow the {mem_size}-byte budget "
                          f"(everything else already uses {budget - n_instrs} instructions)")
    rnd = random.Random(seed)
    interrupt_k = rnd.randint(1, n_instrs) if interrupt is not None else None
    lines = [f"addi x{BASE_REG}, x0, {base_addr}"]
    # docs/adr/0019-f-extension.md (Phase C9): seed a subset of float
    # registers with curated "interesting" bit patterns before any
    # randomly generated instruction runs -- x30 is scratch here only
    # (see this module's own docstring for why no permanent reservation
    # is needed). Every float register not seeded here just starts at its
    # reset default (0.0), itself a perfectly good input. Kept as a
    # separate static block (not folded into `lines`, which the label-
    # resolution pass below only ever reads index 0 of) -- unconditional,
    # sequential, and never itself a branch/jal target, so it can just be
    # spliced in after the base-pointer line with no index bookkeeping.
    seed_lines = []
    for i, bits in enumerate(FLOAT_SEED_BITS):
        fr = i + 1  # f1, f2, ... -- f0 deliberately left at its 0.0 reset default
        seed_lines.extend(const_to_reg_instrs(30, bits, no_lui=ooo))
        seed_lines.append(f"fmv.w.x f{fr}, x30")
    if xlen >= 64:
        # Generation 2 (Phase M15): x29 lands in the ordinary GP_REGS pool
        # afterward (fair game for any later random instruction, same as
        # every other register) -- x30 is transient scratch here only, same
        # convention the float seeding above already uses.
        seed_lines.extend(const64_to_reg_instrs(29, 30, 0xDEADBEEF12345678, no_lui=ooo))
    labels_at = {}  # instruction index -> label name, resolved into text at the end

    # docs/adr/0020-soc-integration.md (Phase D10/D11). mstatus/mepc/mcause
    # are mutated by the interrupt itself (mstatus's MIE/MPIE swap at trap
    # entry/mret, mepc, mcause) -- since the RTL's real hardware timing and
    # the ISS's own externally-scheduled firing point deliberately don't
    # agree on the exact instruction boundary (see this function's own
    # docstring), a random instruction that happens to *read* one of these
    # three CSRs would observe different values on either side of
    # wherever each side's interrupt actually landed, a genuine and
    # unavoidable divergence -- not a bug in the redirect logic itself.
    # mtvec is a *different* hazard, found the same way (D11, by running,
    # not by review): it isn't mutated by the interrupt itself, but a
    # csrrw/csrrs/csrrc targeting it *writes* a new redirect target -- and
    # since the redirect only actually fires later, at a real cycle the two
    # engines don't agree on, RTL and ISS can each still be holding
    # whatever pre-rewrite/post-rewrite mtvec value happened to be current
    # at their own (different) firing moments, sending the interrupt to two
    # different addresses and unraveling everything downstream from there.
    # Only mscratch (genuinely inert -- no control-flow role at all) stays
    # safe. Same "exclude what can't be made safe to compare" principle
    # this generator already applies to ecall/ebreak/mret/illegal
    # instructions (see the module docstring), just for CSR *reads*/*writes*
    # instead of control flow.
    # Gen6-P6 (docs/adr/0057): ooo mode's own csrrX pool (newly enabled --
    # see gen_program's own docstring) gets the SAME mscratch-only
    # restriction as interrupt mode, defensively -- ooo mode never sets a
    # real mtvec, so a random csrrX writing mstatus/mepc/mcause/mtvec
    # followed by ANY later redirect (even an unintended one) risks the
    # exact "RTL and ISS land at two different addresses" divergence this
    # comment's own interrupt-mode reasoning already describes. mscratch
    # alone (genuinely inert, no control-flow role) stays safe.
    csr_names_pool = CSR_NAMES if (interrupt is None and not ooo) else [
        n for n in CSR_NAMES if n not in ("mstatus", "mepc", "mcause", "mtvec")]

    # docs/adr/00NN-mmu-sv32.md (Phase F7). A real bug found by running: all
    # five of CSR_NAMES (mstatus/mtvec/mscratch/mepc/mcause) are M-only CSRs
    # (addr bits[9:8]==3) -- harmless for the plain/interrupt-mode corpus,
    # which stays in M throughout, but the whole random body runs as
    # TRANSLATED U-MODE code in mmu mode, so a random csrrX targeting any of
    # them now correctly privilege-traps (this same phase's own F6 addition
    # to iss.py, mirroring riscvpipeline.v's csr_priv_violation) -- and since
    # this generator never sets mtvec to anything but its 0 reset default,
    # that redirects execution to address 0 (the level-1 page-table PDE's
    # own raw bit pattern, not a real instruction), corrupting everything
    # downstream. Same "exclude what can't be made safe to compare"
    # principle this generator already applies to interrupt mode's own
    # restricted CSR pool. Gen6-P6: ooo mode no longer excludes `csr`
    # outright -- csrrX is real in OOOCore.v now (docs/adr/0051) -- but
    # still forces the same mscratch-only pool interrupt mode uses
    # (csr_names_pool above), for the same reason. mmu mode's own
    # exclusion is unrelated and unchanged (fflags/frm/fcsr, the separate
    # `fcsr` kind below, stay included there: their addresses are U-mode
    # accessible, genuinely safe).
    csr_weight = 0 if mmu else 6

    # Build a flat instruction list first (as dicts), then assign forward-only
    # branch/jump targets once every instruction's final index is known.
    # Generation 2 (Phase M15): "rw"/"iw" (the "w"-suffixed family) and
    # widened load/store mnemonic pools only exist in the choice list when
    # xlen>=64 -- at xlen=32 the exact same list/weights as every prior
    # phase, so existing seeds reproduce bit-exact programs.
    if ooo:
        # Gen6-L, widened Gen6-P6 (docs/adr/0057): see gen_program's own
        # docstring for exactly which kinds this still excludes and why.
        # jal/csr/fp_sqrt rejoined the pool now that OOOCore.v actually
        # executes them correctly (docs/adr/0051, 0055); fp_cmp/fp_cvt*/
        # fp_madd/fload/fstore/fcsr stay excluded (still real, confirmed
        # gaps). The "w"-suffixed family stays excluded regardless of
        # xlen (DIVW/REMW routing through OOOCore.v's is_div_op was never
        # confirmed).
        kind_names = ["r", "i", "shift", "load", "store", "branch", "jal", "csr",
                      "fp_arith", "fp_sqrt", "fp_sgnj", "fp_minmax"]
        kind_weights = [24, 16, 8, 10, 10, 8, 5, csr_weight,
                         10, 4, 4, 4]
    else:
        kind_names = ["r", "i", "shift", "load", "store", "branch", "jal", "csr",
                      "fp_arith", "fp_sqrt", "fp_sgnj", "fp_minmax", "fp_cmp",
                      "fp_cvt_to_int", "fp_cvt_from_int", "fp_madd", "fload", "fstore", "fcsr"]
        kind_weights = [24, 16, 8, 10, 10, 8, 5, csr_weight,
                         10, 4, 4, 4, 4,
                         4, 4, 6, 6, 6, 4]
        if xlen >= 64:
            kind_names = kind_names + ["rw", "iw"]
            kind_weights = kind_weights + [12, 8]
    load_mnemonics = ["lb", "lh", "lw", "lbu", "lhu"] + (["ld", "lwu"] if xlen >= 64 else [])
    store_mnemonics = ["sb", "sh", "sw"] + (["sd"] if xlen >= 64 else [])
    load_widths = {"lb": 1, "lbu": 1, "lh": 2, "lhu": 2, "lw": 4, "lwu": 4, "ld": 8}
    store_widths = {"sb": 1, "sh": 2, "sw": 4, "sd": 8}

    instrs = []
    for _ in range(n_instrs):
        kind = rnd.choices(kind_names, weights=kind_weights)[0]

        if kind == "r":
            mn = rnd.choice(R_TYPE)
            rd, rs1, rs2 = rnd.choice(GP_REGS), rnd.choice(GP_REGS), rnd.choice(GP_REGS)
            instrs.append(f"{mn} x{rd}, x{rs1}, x{rs2}")
        elif kind == "rw":  # Generation 2: addw/subw/sllw/srlw/sraw/mulw/divw/divuw/remw/remuw
            mn = rnd.choice(R_TYPE_W)
            rd, rs1, rs2 = rnd.choice(GP_REGS), rnd.choice(GP_REGS), rnd.choice(GP_REGS)
            instrs.append(f"{mn} x{rd}, x{rs1}, x{rs2}")
        elif kind == "i":
            mn = rnd.choice(I_TYPE)
            rd, rs1 = rnd.choice(GP_REGS), rnd.choice(GP_REGS)
            imm = rnd.randint(-2048, 2047)
            instrs.append(f"{mn} x{rd}, x{rs1}, {imm}")
        elif kind == "iw":  # Generation 2: addiw/slliw/srliw/sraiw
            mn = rnd.choice(I_TYPE_W)
            rd, rs1 = rnd.choice(GP_REGS), rnd.choice(GP_REGS)
            if mn == "addiw":
                imm = rnd.randint(-2048, 2047)
            else:
                imm = rnd.randint(0, 31)  # shamt always 5 bits regardless of xlen, see I_TYPE_W's own comment
            instrs.append(f"{mn} x{rd}, x{rs1}, {imm}")
        elif kind == "shift":
            mn = rnd.choice(SHIFT_I)
            rd, rs1 = rnd.choice(GP_REGS), rnd.choice(GP_REGS)
            # Generation 2: 6-bit shamt range at xlen=64 (design/ImmGen.v/
            # design/ALUCtrl.v's own widened split), 5-bit at 32 (bit-exact).
            shamt = rnd.randint(0, 63) if xlen >= 64 else rnd.randint(0, 31)
            instrs.append(f"{mn} x{rd}, x{rs1}, {shamt}")
        elif kind == "load":
            mn = rnd.choice(load_mnemonics)
            rd = rnd.choice(GP_REGS)
            width = load_widths[mn]
            max_off = min(addr_space - base_addr - width, 2047)  # 12-bit signed load/store immediate
            off = rnd.randrange(0, max_off + 1, width) if max_off >= 0 else 0
            instrs.append(f"{mn} x{rd}, {off}(x{BASE_REG})")
        elif kind == "store":
            mn = rnd.choice(store_mnemonics)
            rs2 = rnd.choice(GP_REGS)
            width = store_widths[mn]
            max_off = min(addr_space - base_addr - width, 2047)  # 12-bit signed load/store immediate
            off = rnd.randrange(0, max_off + 1, width) if max_off >= 0 else 0
            instrs.append(f"{mn} x{rs2}, {off}(x{BASE_REG})")
        elif kind == "branch":
            mn = rnd.choice(BRANCH)
            rs1, rs2 = rnd.choice(GP_REGS), rnd.choice(GP_REGS)
            instrs.append(("branch", mn, rs1, rs2))
        elif kind == "csr":
            csr = rnd.choice(csr_names_pool)
            rd = rnd.choice(GP_REGS)
            if rnd.random() < 0.5:
                mn = rnd.choice(CSR_REG_OP)
                rs1 = rnd.choice(GP_REGS)
                instrs.append(f"{mn} x{rd}, {csr}, x{rs1}")
            else:
                mn = rnd.choice(CSR_IMM_OP)
                uimm = rnd.randint(0, 31)  # zero-extended 5-bit field, see ImmGen.v/Control.v
                instrs.append(f"{mn} x{rd}, {csr}, {uimm}")
        elif kind == "jal":
            rd = rnd.choice(GP_REGS)
            instrs.append(("jal", rd))
        elif kind == "fp_arith":
            # Gen6-P6 (docs/adr/0057): fdiv.s no longer excluded under ooo
            # -- RS_FDIV/FDivider.v are real now (docs/adr/0055). Full
            # FP_ARITH pool for both modes.
            mn = rnd.choice(FP_ARITH)
            rd, rs1, rs2 = rnd.choice(FREGS), rnd.choice(FREGS), rnd.choice(FREGS)
            rm = rnd.choice(RM_NAMES)
            instrs.append(f"{mn} f{rd}, f{rs1}, f{rs2}, {rm}")
        elif kind == "fp_sqrt":
            rd, rs1 = rnd.choice(FREGS), rnd.choice(FREGS)
            rm = rnd.choice(RM_NAMES)
            instrs.append(f"fsqrt.s f{rd}, f{rs1}, {rm}")
        elif kind == "fp_sgnj":
            mn = rnd.choice(FP_SGNJ)
            rd, rs1, rs2 = rnd.choice(FREGS), rnd.choice(FREGS), rnd.choice(FREGS)
            instrs.append(f"{mn} f{rd}, f{rs1}, f{rs2}")
        elif kind == "fp_minmax":
            mn = rnd.choice(FP_MINMAX)
            rd, rs1, rs2 = rnd.choice(FREGS), rnd.choice(FREGS), rnd.choice(FREGS)
            instrs.append(f"{mn} f{rd}, f{rs1}, f{rs2}")
        elif kind == "fp_cmp":
            mn = rnd.choice(FP_CMP)
            rd, rs1, rs2 = rnd.choice(GP_REGS), rnd.choice(FREGS), rnd.choice(FREGS)
            instrs.append(f"{mn} x{rd}, f{rs1}, f{rs2}")
        elif kind == "fp_cvt_to_int":
            mn = rnd.choice(FP_CVT_TO_INT)
            rd, rs1 = rnd.choice(GP_REGS), rnd.choice(FREGS)
            rm = rnd.choice(RM_NAMES)
            instrs.append(f"{mn} x{rd}, f{rs1}, {rm}")
        elif kind == "fp_cvt_from_int":
            mn = rnd.choice(FP_CVT_FROM_INT)
            rd, rs1 = rnd.choice(FREGS), rnd.choice(GP_REGS)
            rm = rnd.choice(RM_NAMES)
            instrs.append(f"{mn} f{rd}, x{rs1}, {rm}")
        elif kind == "fp_madd":
            mn = rnd.choice(FMADD_FAMILY)
            rd, rs1, rs2, rs3 = rnd.choice(FREGS), rnd.choice(FREGS), rnd.choice(FREGS), rnd.choice(FREGS)
            rm = rnd.choice(RM_NAMES)
            instrs.append(f"{mn} f{rd}, f{rs1}, f{rs2}, f{rs3}, {rm}")
        elif kind == "fload":
            rd = rnd.choice(FREGS)
            max_off = min(addr_space - base_addr - 4, 2047)  # 12-bit signed load/store immediate
            off = rnd.randrange(0, max_off + 1, 4) if max_off >= 0 else 0
            instrs.append(f"flw f{rd}, {off}(x{BASE_REG})")
        elif kind == "fstore":
            rs2 = rnd.choice(FREGS)
            max_off = min(addr_space - base_addr - 4, 2047)  # 12-bit signed load/store immediate
            off = rnd.randrange(0, max_off + 1, 4) if max_off >= 0 else 0
            instrs.append(f"fsw f{rs2}, {off}(x{BASE_REG})")
        elif kind == "fcsr":
            csr = FCSR_ADDR[rnd.choice(FCSR_NAMES)]
            rd = rnd.choice(GP_REGS)
            if rnd.random() < 0.5:
                mn = rnd.choice(CSR_REG_OP)
                rs1 = rnd.choice(GP_REGS)
                instrs.append(f"{mn} x{rd}, {csr}, x{rs1}")
            else:
                mn = rnd.choice(CSR_IMM_OP)
                uimm = rnd.randint(0, 31)
                instrs.append(f"{mn} x{rd}, {csr}, {uimm}")

    # Second pass: resolve forward-only branch/jal targets now that the
    # total instruction count (hence valid label positions) is known.
    out = [lines[0]] + seed_lines
    for idx, item in enumerate(instrs):
        cur_idx = idx + 1  # +1 for the leading addi
        if isinstance(item, tuple) and item[0] == "branch":
            _, mn, rs1, rs2 = item
            # Strictly forward; if this is the last instruction there's
            # nothing after it to target, so fall back to the trailing end
            # label instead of an invalid (empty) range.
            target_idx = rnd.randint(min(cur_idx + 1, len(instrs)), len(instrs))  # strictly forward, may be the end label
            out.append(f"{mn} x{rs1}, x{rs2}, __L{target_idx}")
            labels_at.setdefault(target_idx, f"__L{target_idx}")
        elif isinstance(item, tuple) and item[0] == "jal":
            _, rd = item
            # Strictly forward; if this is the last instruction there's
            # nothing after it to target, so fall back to the trailing end
            # label instead of an invalid (empty) range.
            target_idx = rnd.randint(min(cur_idx + 1, len(instrs)), len(instrs))
            out.append(f"jal x{rd}, __L{target_idx}")
            labels_at.setdefault(target_idx, f"__L{target_idx}")
        else:
            out.append(item)

        if (cur_idx + 1) in labels_at:
            out.append(labels_at[cur_idx + 1] + ":")

    if len(instrs) in labels_at:
        out.append(labels_at[len(instrs)] + ":")
    if ooo:
        # Gen6-P6 (docs/adr/0057): a REAL self-loop now -- jal is real in
        # OOOCore.v (Gen6-O3), unlike at Gen6-L time when this used flat
        # nop padding instead (see OOO_TRAILER_NOP_COUNT's own header for
        # the full real-restart-loop bug that padding approach eventually
        # hit, once fdiv.s/fsqrt.s's own genuine multi-cycle latency grew
        # large enough to outrun a FIXED instruction-count margin). Once
        # PC reaches this jal, it can never advance past it again --
        # eliminates the race outright rather than widening the margin.
        out.append("__ooo_halt:")
        out.append("jal x0, __ooo_halt")
    else:
        # docs/adr/0023-caches.md (Phase G7). fence immediately before the
        # halt spin -- under CACHE_MODE=1 (write-back D$), a store's dirty
        # data can sit in the cache, invisible to the harness's own
        # post-halt dump (which reads DataMemoryBRAM.v's backing array
        # directly, bypassing any cache). Harmless, real no-op under
        # CACHE_MODE=0 (fence has nothing to flush there).
        out.append("fence")
        # Spin here instead of running off the end into instruction
        # memory's zero-filled remainder -- opcode 0000000 is not a valid
        # instruction and (correctly, after docs/adr/0011-csr-and-
        # exceptions.md) now traps.
        out.append("__halt:")
        out.append("jal x0, __halt")

    if mmu and xlen >= 64:
        # docs/adr/00NN-sv39-mmu-phase-p.md (Phase P5). Sv39 twin of the
        # Sv32 prefix below (same "generator-guaranteed-valid identity
        # mapping" philosophy, same M-mode-builds-then-mret-to-U shape) --
        # one more table level (level-2/level-1/level-0, all index 0, since
        # the random body stays confined to page 0 the same way Sv32's own
        # addr_space restriction does), and a genuinely 64-bit satp
        # constant (const64_to_reg_instrs, not const_to_reg_instrs -- Sv39's
        # MODE field sits at bit 60). x1/x2/x3/x6 are reused as scratch here
        # (x6 is const64_to_reg_instrs's own required second/clobbered
        # register), visible to the random body afterward like any other
        # pre-existing register value both RTL and ISS agree on.
        pde2_lines = const_to_reg_instrs(1, 0x401)   # level-2 PDE: level-1 table at PPN=1, V=1 (non-leaf)
        pde1_lines = const_to_reg_instrs(2, 0x801)   # level-1 PDE: level-0 table at PPN=2, V=1 (non-leaf)
        pte0_lines = const_to_reg_instrs(3, 0x1F)    # level-0 PTE: PPN=0 (identity), V|R|W|X|U -- guaranteed-permitted
        satp_lines = const64_to_reg_instrs(1, 6, 8 << 60)  # satp: MODE=8/Sv39, PPN=0
        prefix = (
            pde2_lines + ["sw x1, 0(x0)"] +                        # level-2[VPN2=0] <- PDE (satp_ppn=0 -> table at addr 0)
            ["lui x4, 0x1"] + pde1_lines + ["sw x2, 0(x4)"] +         # level-1[VPN1=0] <- PDE (table @ 0x1000)
            ["lui x5, 0x2"] + pte0_lines + ["sw x3, 0(x5)"] +           # level-0[VPN0=0] <- identity PTE (table @ 0x2000)
            # docs/adr/0023-caches.md (Phase G6) fence requirement, same
            # reasoning as the Sv32 prefix's own comment below -- Ptw39.v's
            # bus-master reads bypass DCache.v the same way Ptw.v's do.
            ["fence"] +
            satp_lines + ["csrrw x0, 0x180, x1"] +
            ["addi x1, x0, __MEPC_PLACEHOLDER__", "csrrw x0, mepc, x1", "mret"]
        )
        prefix_instr_count = sum(1 for l in prefix if not l.rstrip().endswith(":"))
        mepc_target = prefix_instr_count * 4
        prefix = [l.replace("__MEPC_PLACEHOLDER__", str(mepc_target)) for l in prefix]
        return "\n".join(prefix + out) + "\n", None

    if mmu:
        # docs/adr/00NN-mmu-sv32.md (Phase F7). Runs entirely in M-mode
        # (physical addressing, bypasses translation) before `out` (the
        # base-pointer setup, float seeding, random body, and halt loop --
        # completely unchanged) begins. x1/x2/x3 are reused as scratch here
        # the same way interrupt mode's own prefix reuses x1/x2/x5/x6/x7/x8
        # -- their residual values after the prefix are visible to the
        # random body like any other GP register, but both RTL and ISS see
        # the identical prefix execution, so they agree on them, same as
        # every other pre-existing register value the random body might
        # read.
        pde_lines = const_to_reg_instrs(1, 0x401)   # level-1 PDE: level-0 table at PPN=1, V=1 (non-leaf)
        pte_lines = const_to_reg_instrs(2, 0x1F)    # level-0 PTE: PPN=0 (identity), V|R|W|X|U -- guaranteed-permitted
        satp_lines = const_to_reg_instrs(1, 0x80000000)  # satp: MODE=Sv32, PPN=0
        prefix = (
            pde_lines + ["sw x1, 0(x0)"] +                      # level-1[VPN1=0] <- PDE (satp_ppn=0 -> table at addr 0)
            ["lui x3, 0x1"] + pte_lines + ["sw x2, 0(x3)"] +      # level-0[VPN0=0] <- identity PTE (level-0 table @ 0x1000)
            # docs/adr/0023-caches.md (Phase G6). Under CACHE_MODE=1, these
            # two stores go through the write-back D$ like any other store
            # and can stay dirty there -- but Ptw.v's own bus-master reads
            # bypass DCache.v entirely (by design, same "plain mux, no real
            # arbiter/coherency" scope docs/adr/0022 already established for
            # sharing the bus with the LSU). Without a flush here, the very
            # first page-table walk (triggered below by mret's own itlb_miss
            # at the U-mode target) reads the REAL backing memory directly
            # and sees a stale, pre-write (all-zero) PDE -- an immediate
            # page fault, trapping to mtvec's reset default of 0 and
            # silently restarting the entire program from address 0,
            # forever (found by running CACHE_MODE=1 --mmu constrained-
            # random programs, not anticipated in the design). A real OS
            # has the identical obligation (flush/fence page-table writes
            # before relying on translation through them) -- this is the
            # generator's own equivalent, mirroring its existing
            # "generator-guaranteed-valid page table" discipline (F7) one
            # step further: guaranteed *visible*, not just well-formed.
            ["fence"] +
            satp_lines + ["csrrw x0, 0x180, x1"] +
            ["addi x1, x0, __MEPC_PLACEHOLDER__", "csrrw x0, mepc, x1", "mret"]
        )
        # mepc = `out`'s own first instruction -- identity-mapped, so its
        # virtual address equals its physical (assembled) address, computed
        # once the prefix's own instruction count is known (same
        # "placeholder, then substitute the resolved address" approach the
        # D9 directed test programs and interrupt mode's own mtvec patching
        # both already use).
        prefix_instr_count = sum(1 for l in prefix if not l.rstrip().endswith(":"))
        mepc_target = prefix_instr_count * 4
        prefix = [l.replace("__MEPC_PLACEHOLDER__", str(mepc_target)) for l in prefix]
        return "\n".join(prefix + out) + "\n", None

    if interrupt is None:
        return "\n".join(out) + "\n", None

    # docs/adr/0020-soc-integration.md (Phase D10). Prefix arms the chosen
    # source and enables interrupts; the handler (placed after the halt
    # loop, only ever reached via a real hardware redirect, never by
    # straight-line fall-through) is architecturally inert -- see this
    # function's own docstring for why. `mtvec` is patched in once the
    # prefix's own final instruction count is known -- same "placeholder,
    # then substitute the resolved address" approach the D9 directed test
    # programs used.
    core_instr_count = sum(1 for l in out if not l.rstrip().endswith(":"))
    if interrupt == "timer":
        mtimecmp_est = 100 + interrupt_k * 10  # generous, not precise -- see docstring
        prefix = [
            "lui   x2, 0x10104",      # x2 = TIMER_BASE + CLINT_OFF_MTIMECMP (Phase R -- real CLINT address, low 12 bits 0)
            "addi  x5, x0, __MTVEC_PLACEHOLDER__",
            "csrrw x0, mtvec, x5",
            "addi  x6, x0, 128",      # MIE_MTIE_BIT
            "csrrw x0, mie, x6",
        ]
        prefix.extend(const_to_reg_instrs(7, mtimecmp_est))
        prefix.append("sw    x7, 0(x2)")   # MTIMECMP low half
        prefix.append("csrrsi x0, mstatus, 8")
        cause = 0x80000007
    elif interrupt == "uart":
        prefix = [
            "lui   x1, 0x10000",      # x1 = UART_BASE
            "addi  x5, x0, __MTVEC_PLACEHOLDER__",
            "csrrw x0, mtvec, x5",
            "addi  x6, x0, -2048",    # MIE_MEIE_BIT, sign-extended (harmless -- CSR.v's mie_masked only reads bits 3/7/11)
            "csrrw x0, mie, x6",
            "addi  x8, x0, 1",
            "sw    x8, 4(x1)",        # IER.ERBFI <- 1 (Phase R)
            "csrrsi x0, mstatus, 8",
        ]
        cause = 0x8000000B
    elif interrupt == "msi":
        # docs/adr/0034-uart-clint-register-compat-phase-r.md (Phase R).
        # Mirrors the "timer" case exactly, arming the new CLINT `msip`
        # register (offset 0x0000, always a plain 32-bit access
        # regardless of XLEN) instead of mtimecmp.
        prefix = [
            "lui   x2, 0x10100",      # x2 = TIMER_BASE (CLINT_OFF_MSIP == 0, so this IS the msip address)
            "addi  x5, x0, __MTVEC_PLACEHOLDER__",
            "csrrw x0, mtvec, x5",
            "addi  x6, x0, 8",        # MIE_MSIE_BIT
            "csrrw x0, mie, x6",
            "addi  x7, x0, 1",
            "sw    x7, 0(x2)",        # msip <- 1
            "csrrsi x0, mstatus, 8",
        ]
        cause = 0x80000003
    elif interrupt == "both":
        # docs/adr/0020-soc-integration.md (Phase D11). Both sources armed
        # and pended simultaneously -- the real interrupt taken must be the
        # external one, MEI-over-MSI-over-MTI priority (D9's own already-
        # proven redirect condition, extended by Phase R), so the ISS is
        # told to expect that cause directly rather than derive it, the
        # same way this generator doesn't re-derive div/rem or float
        # special-case results either (design/*.v and iss.py are
        # independently checked against each other, not against a
        # from-scratch re-implementation of the priority logic here).
        mtimecmp_est = 100 + interrupt_k * 10
        prefix = [
            "lui   x1, 0x10000",      # x1 = UART_BASE
            "lui   x2, 0x10104",      # x2 = TIMER_BASE + CLINT_OFF_MTIMECMP (Phase R)
            "addi  x5, x0, __MTVEC_PLACEHOLDER__",
            "csrrw x0, mtvec, x5",
            "addi  x6, x0, -1920",    # MIE_MTIE_BIT|MIE_MEIE_BIT, sign-extended (harmless, same masking reasoning)
            "csrrw x0, mie, x6",
        ]
        prefix.extend(const_to_reg_instrs(7, mtimecmp_est))
        prefix.append("sw    x7, 0(x2)")   # MTIMECMP low half
        prefix.append("addi  x8, x0, 1")
        prefix.append("sw    x8, 4(x1)")   # IER.ERBFI <- 1 (Phase R)
        prefix.append("csrrsi x0, mstatus, 8")
        cause = 0x8000000B
    else:
        raise ValueError(f"unknown interrupt source {interrupt!r}")

    prefix_instr_count = sum(1 for l in prefix if not l.rstrip().endswith(":"))
    handler_addr = (prefix_instr_count + core_instr_count) * 4
    prefix = [l.replace("__MTVEC_PLACEHOLDER__", str(handler_addr)) for l in prefix]
    handler = ["handler:", "csrrw x0, mie, x0", "mret"]

    full = prefix + out + handler
    interrupt_info = {"after": interrupt_k, "cause": cause}
    return "\n".join(full) + "\n", interrupt_info


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--seed", type=int, required=True)
    ap.add_argument("--n", type=int, default=16)
    ap.add_argument("--mem-size", type=int, default=None)
    ap.add_argument("--interrupt", choices=["timer", "uart", "msi", "both"], default=None)
    ap.add_argument("--mmu", action="store_true",
                     help="opt-in translation mode: Sv32 at XLEN=32 (docs/adr/00NN-mmu-sv32.md Phase F7) "
                          "or Sv39 at XLEN=64 (docs/adr/00NN-sv39-mmu-phase-p.md Phase P5)")
    ap.add_argument("--xlen", type=int, default=32, choices=[32, 64],
                     help="Generation 2 (docs/adr/0028-rv64-migration-phase-m.md): 32=default, 64=RV64")
    ap.add_argument("--ooo", action="store_true",
                     help="Gen6-L: restrict the generated mix to OOOCore.v's own actually-implemented "
                          "instruction subset (see gen_program's own docstring). Mutually exclusive "
                          "with --interrupt/--mmu")
    ap.add_argument("-o", "--output")
    args = ap.parse_args()
    mem_size = args.mem_size if args.mem_size is not None else \
        ((16384 if args.xlen == 64 else 8192) if args.mmu else 128)
    text, interrupt_info = gen_program(args.seed, args.n, mem_size=mem_size, interrupt=args.interrupt,
                                        mmu=args.mmu, xlen=args.xlen, ooo=args.ooo)
    if interrupt_info is not None:
        print(f"# interrupt scheduled after instruction {interrupt_info['after']}, "
              f"cause={interrupt_info['cause']:#010x}")
    if args.output:
        with open(args.output, "w") as f:
            f.write(text)
    else:
        print(text)
