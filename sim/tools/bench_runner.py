#!/usr/bin/env python3
"""
Benchmark runner (docs/ROADMAP.md Phase 10). Runs each sim/benchmarks/bench_*.s
kernel through both the independent ISS (sim/tools/iss.py, for instruction
count and a correctness cross-check -- same reference model V-4's random
testing already trusts) and the real RTL (Icarus Verilog, for cycle count),
and reports cycles / instructions / IPC per benchmark.

This is NOT CoreMark/Dhrystone: those need a real C compiler targeting this
core, and no RISC-V toolchain is available in this environment (checked
directly, not assumed -- see docs/adr, no ADR filed since this is pure
tooling, but the check is worth recording: `which riscv64-unknown-elf-gcc`
etc. all fail). These are small, hand-written kernels in this core's own
assembly dialect instead -- real, but not standardized, performance data.
Useful for relative comparisons between this core's own changes (e.g.
"did the MEM-stage retiming change memory-bound IPC"), not for comparing
against other cores' published CoreMark scores.

Cycle count is measured as the cycle EX first resolves the program's own
`jal x0, self` halt loop (see sim/tb/bench_template.v) -- a few cycles
before the pipeline fully drains, but that offset is constant across every
benchmark, so relative comparisons between them are unaffected.

Also doubles as the "compare hazard strategies" tool docs/ROADMAP.md Phase 6
named as a research-platform goal (docs/adr/0016-swappable-hazard-strategy.md):
--compare-strategies runs every benchmark under both riscvpipeline.v's
HAZARD_STRATEGY=0 (forwarding, the default/original design) and =1
(stall-only, no forwarding) and reports the cycle-count delta.

--compare-profiles does the same for "compare pipeline depths"
(docs/adr/0018-variable-pipeline-depth.md, Phase A6): every benchmark under
both PIPELINE_PROFILE=0 (PROFILE_5STAGE, the default) and =1
(PROFILE_6STAGE_SPLIT_FETCH, the split-fetch alternate), reporting the
cycle-count delta -- the honest cost of profile 1's one extra redirect-
recovery cycle (see docs/adr/0018's Design section), not a hypothetical.

--compare-predictors does the same for branch prediction
(docs/adr/0021-branch-prediction.md, Phase E5): every benchmark under both
BRANCH_PREDICTOR=0 (PREDICTOR_STATIC, the default) and =1
(PREDICTOR_DYNAMIC_BHT_BTB), reporting the cycle-count delta -- the real,
measured benefit of speculative fetch on branch/loop-heavy kernels, not a
hypothetical.

--compare-cache does the same for caching (docs/adr/0023-caches.md, Phase
G8): every benchmark under both CACHE_MODE=0 (CACHE_NONE, the default) and
=1 (CACHE_WRITEBACK_SETASSOC, 4-way/4KB/16B I$+D$), reporting the
cycle-count delta plus I$/D$ hit/miss counters (sim/tb/bench_template.v's
own testbench-side taps -- evidence the cache mode is doing real work, not
precise hardware performance counters, which is a separate, real
docs/ROADMAP_VISION.md Generation-1 item).

--compare-latency does the same for variable-latency memory (docs/adr/0024-
variable-latency-memory.md, Phase I6): every benchmark under both
MEM_LATENCY_I=MEM_LATENCY_D=0 (the default, bit-exact) and whatever
--mem-latency-i/--mem-latency-d were passed (both default to 3 specifically
when --compare-latency is used and neither was set, since comparing 0
against 0 would be a no-op), reporting the cycle-count delta.

--compare-replacement does the same for cache replacement policy
(docs/adr/0041-cache-replacement-policy-phase-b.md, Generation 4 Phase B):
every benchmark under all 3 REPLACEMENT_POLICY values (forces --cache-mode 1,
since the parameter is a no-op otherwise), reporting the cycle-count delta.
POLICY_ROUND_ROBIN and POLICY_FIFO are the same underlying mechanism, so
expect identical numbers between those two -- POLICY_LRU is the real
comparison.

--compare-victim-cache does the same for the victim buffer (docs/adr/0042-
victim-cache-phase-c.md, Generation 4 Phase C): every benchmark at
VICTIM_ENTRIES=0 (disabled) vs. =4 (forces --cache-mode 1, same no-op-
otherwise reasoning as --compare-replacement), reporting the cycle-count
delta. Real result may be near-zero on these small kernels -- the same
"not much pressure to exploit" pattern --compare-replacement's own
benchmark run already found; the forced-thrash unit/directed tests
(tb_victimcache_unit.v, tb_icache_unit.v's dut4, tb_dcache_unit.v's dut3,
tb_cache_victim_c1.v) are the real proof either way.

Usage: python bench_runner.py --iverilog-dir /c/iverilog/bin
       python bench_runner.py --compare-strategies --iverilog-dir /c/iverilog/bin
       python bench_runner.py --compare-profiles --iverilog-dir /c/iverilog/bin
       python bench_runner.py --compare-predictors --iverilog-dir /c/iverilog/bin
       python bench_runner.py --compare-cache --iverilog-dir /c/iverilog/bin
       python bench_runner.py --compare-latency --iverilog-dir /c/iverilog/bin
       python bench_runner.py --compare-replacement --iverilog-dir /c/iverilog/bin
       python bench_runner.py --compare-victim-cache --iverilog-dir /c/iverilog/bin
"""
import argparse
import glob
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from iss import ISS  # noqa: E402
from random_gen import OOO_TRAILER_NOP_COUNT  # noqa: E402

# Per-benchmark memory size override (bytes; shared by instruction and data
# memory, see design/riscvpipeline.v's MEM_SIZE_BYTES). Default 128 (every
# other test program's assumption) unless a kernel needs more room --
# bench_bubble_sort.s does (docs/adr/0015 is what makes this a one-line
# runner change instead of an RTL one).
MEM_SIZE_OVERRIDES = {
    "bench_bubble_sort": 512,
}

# Expected x10/a0 result per benchmark, for the correctness cross-check
# (independent of the ISS -- these are hand-computed from what each kernel
# is actually supposed to do, the same way directed tests' expected values
# are, not derived from either model).
EXPECTED_X10 = {
    "bench_fib": 832040,           # fib(30)
    "bench_sum_array": 136,        # 1+2+...+16
    "bench_bubble_sort": 1,        # smallest of {1..6} after sorting ascending
}


def load_words(mem_path):
    # Generation 4, Phase A (docs/adr/0040): byte order here was stale --
    # see run_random_tests.py's own copy of this same helper for the full
    # story (Phase U, docs/adr/0037, flipped IMEM/DMEM to LSB-first; this
    # copy was never updated). Reversed to match.
    with open(mem_path) as f:
        lines = [l.strip() for l in f if l.strip()]
    words = []
    for i in range(0, len(lines), 4):
        b = lines[i:i + 4]
        if len(b) < 4:
            break
        words.append(int(b[3] + b[2] + b[1] + b[0], 2))
    return words


def run_bench(name, prog_s, work_dir, iverilog_bin, template, mem_size, hazard_strategy=0, pipeline_profile=0,
              branch_predictor=0, cache_mode=0, replacement_policy=0, mem_latency_i=0, mem_latency_d=0,
              victim_entries=0, burst_enable=0, mem_latency_d_burst=0, xlen=32, mshr_entries=1,
              l2_size=0, l2_ways=4, l2_replacement=0, prefetch_mode=0):
    here = os.path.dirname(os.path.abspath(__file__))
    prog_mem = os.path.join(work_dir, f"{name}.mem")
    asm_py = os.path.join(here, "asm.py")
    r = subprocess.run([sys.executable, asm_py, prog_s, "-o", prog_mem,
                         "--size", str(mem_size), "--xlen", str(xlen)],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return None, f"assembler error: {r.stderr.strip()}"

    words = load_words(prog_mem)
    iss = ISS(mem_size=mem_size, xlen=xlen)
    try:
        instrs = iss.run(words, max_steps=200000)
    except Exception as e:  # noqa: BLE001
        return None, f"ISS error: {e}"

    expected = EXPECTED_X10.get(name)
    if expected is not None and iss.regs[10] != expected:
        return None, f"ISS correctness check failed: x10={iss.regs[10]}, expected {expected}"

    # Neither the stall-only hazard strategy nor the split-fetch pipeline
    # profile can ever take *fewer* cycles per instruction than the defaults
    # -- generous margin, not tuned per-strategy/per-profile.
    # Neither is true of branch prediction, unlike the comment above about
    # the stall-only strategy/split-fetch profile: a correct prediction
    # only ever removes cycles relative to the static baseline, so the same
    # generous margin (computed independent of branch_predictor) still
    # covers PREDICTOR_DYNAMIC_BHT_BTB runs too.
    # docs/adr/0023-caches.md (Phase G8): CACHE_MODE=1 needs its own flat
    # extra margin -- every bench_*.s kernel now ends in `fence` (Phase G7),
    # whose own flush scans all 256 lines at the real 4-way/4KB/16B default
    # sizing even to skip the clean ones (~277 cycles, confirmed directly
    # while debugging G6/G7), plus a smaller one-time cold-fill cost the
    # first time through each kernel's own tiny (<=512B) code/data -- both
    # bounded, one-time costs, not a per-instruction multiplier.
    # docs/adr/0024-variable-latency-memory.md (Phase I6): each added
    # wait-state cycle costs at most one extra cycle per instruction
    # (memory-bound kernels access memory roughly once per instruction) --
    # a flat per-instruction margin, not tuned per-kernel.
    max_time = (instrs * (60 + 2 * (mem_latency_i + mem_latency_d)) + 500) * 10 + (4000 if cache_mode else 0)
    tag = (f"{name}_hs{hazard_strategy}_p{pipeline_profile}_bp{branch_predictor}_cm{cache_mode}"
           f"_rp{replacement_policy}_ve{victim_entries}_be{burst_enable}_ldb{mem_latency_d_burst}"
           f"_li{mem_latency_i}_ld{mem_latency_d}_me{mshr_entries}_l2{l2_size}_pf{prefetch_mode}")
    dump_v = os.path.join(work_dir, f"{tag}.v")
    out_path = os.path.join(work_dir, f"{tag}.out").replace("\\", "/")
    init_file_rel = os.path.relpath(prog_mem, start=os.getcwd()).replace("\\", "/")
    with open(template) as f:
        tpl = f.read()
    tpl = (tpl.replace("__INIT_FILE__", init_file_rel)
              .replace("__MAX_TIME__", str(max_time))
              .replace("__OUT_FILE__", out_path)
              .replace("__MEM_SIZE__", str(mem_size))
              .replace("__HAZARD_STRATEGY__", str(hazard_strategy))
              .replace("__PIPELINE_PROFILE__", str(pipeline_profile))
              .replace("__BRANCH_PREDICTOR__", str(branch_predictor))
              .replace("__CACHE_MODE__", str(cache_mode))
              .replace("__REPLACEMENT_POLICY__", str(replacement_policy))
              .replace("__VICTIM_ENTRIES__", str(victim_entries))
              .replace("__MSHR_ENTRIES__", str(mshr_entries))
              .replace("__L2_SIZE_BYTES__", str(l2_size))
              .replace("__L2_WAYS__", str(l2_ways))
              .replace("__L2_REPLACEMENT_POLICY__", str(l2_replacement))
              .replace("__BURST_ENABLE__", str(burst_enable))
              .replace("__MEM_LATENCY_D_BURST__", str(mem_latency_d_burst))
              .replace("__XLEN__", str(xlen))
              .replace("__MEM_LATENCY_I__", str(mem_latency_i))
              .replace("__MEM_LATENCY_D__", str(mem_latency_d))
              .replace("__PREFETCH_MODE__", str(prefetch_mode)))
    with open(dump_v, "w") as f:
        f.write(tpl)

    vvp_path = os.path.join(work_dir, f"{tag}.vvp")
    iverilog_exe = os.path.join(iverilog_bin, "iverilog.exe") if iverilog_bin else "iverilog"
    vvp_exe = os.path.join(iverilog_bin, "vvp.exe") if iverilog_bin else "vvp"
    r = subprocess.run([iverilog_exe, "-g2005", "-I", "design", "-o", vvp_path, dump_v],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return None, f"compile error: {r.stderr.strip()[:500]}"
    r = subprocess.run([vvp_exe, vvp_path], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out_path):
        return None, f"simulation error: {r.stdout.strip()[:500]} {r.stderr.strip()[:500]}"

    with open(out_path) as f:
        vals = [int(l.strip()) for l in f if l.strip()]
    cycles = vals[0]
    # docs/adr/0023-caches.md (Phase G8): bench_template.v now always emits
    # the I$/D$ counters (3 more lines after cycle_count), zero/meaningless
    # under CACHE_MODE=0 but present either way -- one output format, not
    # two, so this parsing doesn't need to know which mode produced it.
    icache_misses, icache_accesses, dcache_misses = vals[1], vals[2], vals[3]

    return {"instructions": instrs, "cycles": cycles, "ipc": instrs / cycles,
            "icache_misses": icache_misses, "icache_accesses": icache_accesses,
            "dcache_misses": dcache_misses}, None


# Generation 6, Gen6-L4. bench_sum_array.s is EXPECTED to FAIL under
# --compare-ooo today -- not a tooling bug, a real, confirmed, root-caused
# OOOCore.v deadlock this tooling found: FreeList.v's alloc_en0/alloc_en1
# (and PhysicalRegisterFile.v's own alloc_en-driven valid-clear) are
# unconditional on needs_dest/needs_dest_1 alone, NOT gated by the actual
# do_dispatch/do_dispatch_slot1 decision -- necessary today to avoid a
# genuine combinational cycle (dispatch_stall's own fl_alloc_ok0 term would
# otherwise depend on itself through do_dispatch), but means every cycle
# dispatch stalls for ANY reason (rob_full/rs_alu_full/lsq_full/a store
# forcing try_dual_issue false) while needs_dest is simultaneously true
# silently ORPHANS one physical register permanently. Confirmed by direct
# RTL trace, not assumed: a store immediately followed by a WAW-renamed
# ALU instruction in a real sustained loop (bench_sum_array.s's own
# fill_loop, >=8 iterations) exhausts the 32-entry free pool and
# permanently deadlocks dispatch -- the concrete, previously-theoretical
# manifestation of design/OOOCore.v's own Gen6-D header comment ("no real
# resource-exhaustion stall beyond a simple whole-cycle bubble... genuinely
# insufficient for sustained high-occupancy execution"). A real fix needs
# a query/commit split on FreeList.v's (and possibly
# PhysicalRegisterFile.v's) own alloc interface -- availability must
# become a pure function of internal state, with a separate, later-gated
# commit pulse (tied to the CONFIRMED dispatch decision) doing the actual
# pop/clear. Out of Gen6-L's own verification-tooling scope; real future
# work, not attempted here -- this is exactly what building this tooling
# was for: bench_fib.s (no memory ops) never exercises sustained
# dispatch_stall-while-needs_dest, so it was never going to surface this.
#
# --compare-ooo's own supported benchmark subset --
# bench_bubble_sort.s uses `jal x0, inner`/`jal x0, outer` as genuine
# backward-loop control flow (not just the shared halt trailer every
# kernel ends in), and OOOCore.v cannot execute jal at all (jump_c is
# decoded, design/Control.v, but never consumed anywhere in
# design/OOOCore.v -- confirmed by direct code read, same finding
# random_gen.py's own gen_program docstring documents). Real future work
# once/if OOOCore.v ever implements jal, not attempted here -- excluded
# rather than silently producing a meaningless comparison.
OOO_COMPATIBLE_BENCHES = ("bench_fib", "bench_sum_array")


# Generation 7, Pillar V backlog closure (docs/adr/0066). --compare-vector's
# own benchmark pair -- see bench_vecadd_scalar.s/bench_vecadd_vector.s's
# own headers for the real workload (C[i]=A[i]+B[i], 8x int32). Both hand-
# computed independent of any model: x10=396 is the real checksum
# (11+22+...+88); the retirement targets were derived by running the
# SCALAR file through iss.py (ISS has no vector-opcode support, so it can
# only ever validate that half directly) to get its true dynamic count
# (208), then swapping in the vector kernel's own measured-region dynamic
# count by construction (4 setup + 5 fixed instructions = 9, no loop, no
# ambiguity) in place of the scalar measured region's own (4 setup + 8
# iterations * 9-instruction body = 76) -- 208 - 76 + 9 = 141. The shared
# fill/reduction portions are byte-identical between the two files by
# construction (see both files' own headers), so this subtraction is exact,
# not an estimate.
VECTOR_PAIR = ("bench_vecadd_scalar", "bench_vecadd_vector")
EXPECTED_X10_VECTOR_PAIR = 396
TARGET_RETIRED_VECTOR_PAIR = {"bench_vecadd_scalar": 208, "bench_vecadd_vector": 141}


def run_bench_ooo_vector(name, prog_s, work_dir, iverilog_bin, mem_size, target_retired, xlen=64):
    """Gen7-V backlog closure (docs/adr/0066). Like run_bench_ooo() but with
    NO iss.py cross-check at all -- iss.py has zero OP-V opcode support
    (confirmed by direct code read, sim/tools/iss.py's own step() dispatch
    chain traps any opcode it doesn't recognize), so it cannot validate a
    program containing real vector instructions, and cannot report a
    trustworthy dynamic instruction count for one either. target_retired is
    the caller's own hand-computed value instead (see VECTOR_PAIR's own
    comment for how). Correctness is checked directly against the RTL's own
    retired x10 value (bench_ooocore_vector_template.v's own extra dump
    line), not an ISS comparison.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    with open(prog_s) as f:
        original_text = f.read()
    stripped_text = strip_halt_trailer_for_ooo(original_text)
    prog_s_ooo = os.path.join(work_dir, f"{name}_ooo.s")
    with open(prog_s_ooo, "w") as f:
        f.write(stripped_text)
    asm_py = os.path.join(here, "asm.py")
    prog_mem = os.path.join(work_dir, f"{name}_ooo.mem")
    r = subprocess.run([sys.executable, asm_py, prog_s_ooo, "-o", prog_mem,
                         "--size", str(mem_size), "--xlen", str(xlen)],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return None, f"assembler error: {r.stderr.strip()}"

    max_time = (target_retired * 70 + 500) * 10
    tag = f"{name}_ooovec"
    dump_v = os.path.join(work_dir, f"{tag}.v")
    out_path = os.path.join(work_dir, f"{tag}.out").replace("\\", "/")
    init_file_rel = os.path.relpath(prog_mem, start=os.getcwd()).replace("\\", "/")
    template = os.path.join(here, "..", "tb", "bench_ooocore_vector_template.v")
    with open(template) as f:
        tpl = f.read()
    tpl = (tpl.replace("__INIT_FILE__", init_file_rel).replace("__MAX_TIME__", str(max_time))
              .replace("__OUT_FILE__", out_path).replace("__MEM_SIZE__", str(mem_size))
              .replace("__XLEN__", str(xlen)).replace("__TARGET_RETIRED__", str(target_retired)))
    with open(dump_v, "w") as f:
        f.write(tpl)

    vvp_path = os.path.join(work_dir, f"{tag}.vvp")
    iverilog_exe = os.path.join(iverilog_bin, "iverilog.exe") if iverilog_bin else "iverilog"
    vvp_exe = os.path.join(iverilog_bin, "vvp.exe") if iverilog_bin else "vvp"
    r = subprocess.run([iverilog_exe, "-g2005", "-I", "design", "-o", vvp_path, dump_v],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return None, f"compile error: {r.stderr.strip()[:500]}"
    r = subprocess.run([vvp_exe, vvp_path], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out_path):
        return None, f"simulation error: {r.stdout.strip()[:500]} {r.stderr.strip()[:500]}"
    if "TIMEOUT" in r.stdout:
        return None, f"RTL never reached target retirement count: {r.stdout.strip()[:300]}"

    with open(out_path) as f:
        vals = [int(l.strip()) for l in f if l.strip()]
    cycles, x10 = vals[0], vals[1]
    if x10 != EXPECTED_X10_VECTOR_PAIR:
        return None, f"RTL correctness check failed: x10={x10}, expected {EXPECTED_X10_VECTOR_PAIR}"
    return {"instructions": target_retired, "cycles": cycles, "ipc": target_retired / cycles}, None


def strip_halt_trailer_for_ooo(text):
    """Gen6-L4: every sim/benchmarks/bench_*.s kernel ends in the identical
    `fence` + `halt:` + `jal x0, halt` block -- replaces it with plain nop
    padding instead, same convention random_gen.py's own ooo mode uses and
    for the same reason (see that module's gen_program docstring): jal
    doesn't redirect PC in OOOCore.v, so the "self-loop" doesn't loop, and
    OOOCore.v's frontend would otherwise keep fetching/dispatching past the
    kernel's own real end into the zero-filled tail, eventually tripping
    the illegal-opcode trap and restarting the whole program from address
    0 (measured directly building random_gen.py's own ooo mode -- a
    restart every ~100-150 cycles on a real generated program, far too
    fast to let retirement-counting termination land reliably otherwise).
    """
    lines = text.splitlines()
    cut = next((i for i, ln in enumerate(lines) if ln.strip() == "fence"), None)
    if cut is None:
        raise ValueError("no `fence` trailer line found -- benchmark doesn't match the expected shape")
    return "\n".join(lines[:cut] + ["addi x0, x0, 0"] * OOO_TRAILER_NOP_COUNT) + "\n"


def run_bench_ooo(name, prog_s, work_dir, iverilog_bin, mem_size, xlen=64):
    """Gen6-L4: OOOCore.v's own --compare-ooo path. Runs the ORIGINAL
    (unmodified, real jal-halting) file through iss.py for both the
    EXPECTED_X10 correctness cross-check AND the DYNAMIC instruction count
    (iss.run()'s own return value -- how many instructions actually
    execute/retire, accounting for every loop iteration, NOT asm.py's
    static per-file count) -- unlike sim/tools/run_random_tests.py's own
    run_one_ooo(), whose generated programs are forward-only by
    construction (random_gen.py's gen_program never emits a backward
    branch), these are real hand-written kernels with real loops, so the
    static and dynamic counts genuinely differ (a real bug found by
    running: using the static count terminated the RTL run after roughly
    one loop iteration, an impossible-looking 20x "speedup" was the tell).
    The RTL run itself uses a SEPARATE, nop-trailer-stripped assembly of
    the same source (jal doesn't work in OOOCore.v, see
    strip_halt_trailer_for_ooo's own docstring), targeting that same
    dynamic count for its own retirement-counting termination.
    """
    here = os.path.dirname(os.path.abspath(__file__))
    with open(prog_s) as f:
        original_text = f.read()

    # Correctness cross-check on the ORIGINAL (unmodified, real jal-halt)
    # file -- iss.py handles jal correctly, no need to strip anything here.
    prog_mem_orig = os.path.join(work_dir, f"{name}_ooo_orig.mem")
    asm_py = os.path.join(here, "asm.py")
    r = subprocess.run([sys.executable, asm_py, prog_s, "-o", prog_mem_orig,
                         "--size", str(mem_size), "--xlen", str(xlen)],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return None, f"assembler error (original): {r.stderr.strip()}"
    words = load_words(prog_mem_orig)
    iss = ISS(mem_size=mem_size, xlen=xlen)
    try:
        # Gen6-L4: unlike run_one_ooo()'s own forward-only-by-construction
        # generated programs (random_gen.py's gen_program never emits a
        # backward branch), these are real hand-written kernels with real
        # loops -- the DYNAMIC instruction count (how many times
        # instructions actually execute/retire, iss.run()'s own return
        # value) is what OOOCore.v's retirement counter below needs to
        # match, not asm.py's STATIC per-file instruction count (which
        # would only ever cover one loop iteration, terminating the RTL
        # run absurdly early -- a real bug found by running: an
        # impossible-looking 20x "speedup" was the tell).
        dynamic_instrs = iss.run(words, max_steps=200000)
    except Exception as e:  # noqa: BLE001
        return None, f"ISS error: {e}"
    expected = EXPECTED_X10.get(name)
    if expected is not None and iss.regs[10] != expected:
        return None, f"ISS correctness check failed: x10={iss.regs[10]}, expected {expected}"
    target_retired = dynamic_instrs
    if target_retired <= 0:
        return None, f"ISS reported dynamic_instrs={dynamic_instrs} <= 0"

    stripped_text = strip_halt_trailer_for_ooo(original_text)
    prog_s_ooo = os.path.join(work_dir, f"{name}_ooo.s")
    with open(prog_s_ooo, "w") as f:
        f.write(stripped_text)
    prog_mem = os.path.join(work_dir, f"{name}_ooo.mem")
    r = subprocess.run([sys.executable, asm_py, prog_s_ooo, "-o", prog_mem,
                         "--size", str(mem_size), "--xlen", str(xlen)],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return None, f"assembler error (stripped): {r.stderr.strip()}"

    max_time = (target_retired * 70 + 500) * 10
    tag = f"{name}_ooo"
    dump_v = os.path.join(work_dir, f"{tag}.v")
    out_path = os.path.join(work_dir, f"{tag}.out").replace("\\", "/")
    init_file_rel = os.path.relpath(prog_mem, start=os.getcwd()).replace("\\", "/")
    template = os.path.join(here, "..", "tb", "bench_ooocore_template.v")
    with open(template) as f:
        tpl = f.read()
    tpl = (tpl.replace("__INIT_FILE__", init_file_rel).replace("__MAX_TIME__", str(max_time))
              .replace("__OUT_FILE__", out_path).replace("__MEM_SIZE__", str(mem_size))
              .replace("__XLEN__", str(xlen)).replace("__TARGET_RETIRED__", str(target_retired)))
    with open(dump_v, "w") as f:
        f.write(tpl)

    vvp_path = os.path.join(work_dir, f"{tag}.vvp")
    iverilog_exe = os.path.join(iverilog_bin, "iverilog.exe") if iverilog_bin else "iverilog"
    vvp_exe = os.path.join(iverilog_bin, "vvp.exe") if iverilog_bin else "vvp"
    r = subprocess.run([iverilog_exe, "-g2005", "-I", "design", "-o", vvp_path, dump_v],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return None, f"compile error: {r.stderr.strip()[:500]}"
    r = subprocess.run([vvp_exe, vvp_path], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out_path):
        return None, f"simulation error: {r.stdout.strip()[:500]} {r.stderr.strip()[:500]}"
    if "TIMEOUT" in r.stdout:
        return None, f"RTL never reached target retirement count: {r.stdout.strip()[:300]}"

    with open(out_path) as f:
        vals = [int(l.strip()) for l in f if l.strip()]
    cycles = vals[0]
    return {"instructions": target_retired, "cycles": cycles, "ipc": target_retired / cycles}, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iverilog-dir", default=None)
    ap.add_argument("--programs-dir", default="sim/benchmarks")
    ap.add_argument("--hazard-strategy", type=int, default=0, choices=[0, 1],
                     help="riscvpipeline.v's HAZARD_STRATEGY (docs/adr/0016): 0=forwarding (default), 1=stall-only")
    ap.add_argument("--pipeline-profile", type=int, default=0, choices=[0, 1],
                     help="riscvpipeline.v's PIPELINE_PROFILE (docs/adr/0018): 0=PROFILE_5STAGE (default), "
                          "1=PROFILE_6STAGE_SPLIT_FETCH")
    ap.add_argument("--branch-predictor", type=int, default=0, choices=[0, 1, 2, 3],
                     help="riscvpipeline.v's BRANCH_PREDICTOR (docs/adr/0021, docs/adr/0040): "
                          "0=PREDICTOR_STATIC (default), 1=PREDICTOR_DYNAMIC_BHT_BTB, "
                          "2=PREDICTOR_GSHARE, 3=PREDICTOR_TOURNAMENT")
    ap.add_argument("--cache-mode", type=int, default=0, choices=[0, 1],
                     help="riscvpipeline.v's CACHE_MODE (docs/adr/0023-caches.md): 0=CACHE_NONE (default), "
                          "1=CACHE_WRITEBACK_SETASSOC")
    ap.add_argument("--replacement-policy", type=int, default=0, choices=[0, 1, 2],
                     help="riscvpipeline.v's REPLACEMENT_POLICY (docs/adr/0041-cache-replacement-policy-"
                          "phase-b.md): 0=POLICY_ROUND_ROBIN (default), 1=POLICY_FIFO, 2=POLICY_LRU. "
                          "Only meaningful under --cache-mode 1")
    ap.add_argument("--victim-entries", type=int, default=0,
                     help="riscvpipeline.v's VICTIM_ENTRIES (docs/adr/0042-victim-cache-phase-c.md): "
                          "0=disabled (default). Only meaningful under --cache-mode 1")
    ap.add_argument("--mshr-entries", type=int, default=1,
                     help="riscvpipeline.v's MSHR_ENTRIES (docs/adr/0044-non-blocking-dcache-mshr-"
                          "phase-e.md): 1=disabled (default). Only meaningful under --cache-mode 1")
    ap.add_argument("--mem-latency-i", type=int, default=0,
                     help="riscvpipeline.v's MEM_LATENCY_I (docs/adr/0024-variable-latency-memory.md): "
                          "extra I-side wait-state cycles, 0=bit-exact default")
    ap.add_argument("--mem-latency-d", type=int, default=0,
                     help="riscvpipeline.v's MEM_LATENCY_D (docs/adr/0024-variable-latency-memory.md): "
                          "extra D-side wait-state cycles, 0=bit-exact default")
    ap.add_argument("--burst-enable", type=int, default=0, choices=[0, 1],
                     help="riscvpipeline.v's BURST_ENABLE (docs/adr/0043-memory-controller-phase-d.md): "
                          "0=disabled (default). Only meaningful under --cache-mode 1")
    ap.add_argument("--mem-latency-d-burst", type=int, default=0,
                     help="riscvpipeline.v's MEM_LATENCY_D_BURST (docs/adr/0043-memory-controller-"
                          "phase-d.md): extra wait-state cycles for a burst-continuation beat instead "
                          "of the full --mem-latency-d. Only meaningful under --burst-enable 1")
    ap.add_argument("--l2-size", type=int, default=0,
                     help="riscvpipeline.v's L2_SIZE_BYTES (docs/adr/0045-l2-cache-phase-f.md): "
                          "0=disabled (default). Only meaningful under --cache-mode 1")
    ap.add_argument("--l2-ways", type=int, default=4,
                     help="riscvpipeline.v's L2_WAYS (docs/adr/0045-l2-cache-phase-f.md). "
                          "Only meaningful under --l2-size > 0")
    ap.add_argument("--l2-replacement", type=int, default=0, choices=[0, 1, 2],
                     help="riscvpipeline.v's L2_REPLACEMENT_POLICY (docs/adr/0045-l2-cache-phase-f.md): "
                          "0=round-robin (default), 1=FIFO, 2=LRU. Only meaningful under --l2-size > 0")
    ap.add_argument("--prefetch-mode", type=int, default=0, choices=[0, 1, 2, 3],
                     help="riscvpipeline.v's PREFETCH_MODE (docs/adr/0046-hardware-prefetchers-phase-g.md): "
                          "0=disabled (default), 1=next-line, 2=stride, 3=stream. Only meaningful under "
                          "--cache-mode 1; D$ prefetching also needs --mshr-entries > 1, I$ prefetching "
                          "also needs --l2-size > 0")
    compare = ap.add_mutually_exclusive_group()
    compare.add_argument("--compare-strategies", action="store_true",
                          help="run every benchmark under both hazard strategies "
                               "(at --pipeline-profile/--branch-predictor/--cache-mode) and report the delta")
    compare.add_argument("--compare-profiles", action="store_true",
                          help="run every benchmark under both pipeline profiles "
                               "(at --hazard-strategy/--branch-predictor/--cache-mode) and report the delta")
    compare.add_argument("--compare-predictors", action="store_true",
                          help="run every benchmark under both branch predictors "
                               "(at --hazard-strategy/--pipeline-profile/--cache-mode) and report the delta")
    compare.add_argument("--compare-cache", action="store_true",
                          help="run every benchmark under both cache modes "
                               "(at --hazard-strategy/--pipeline-profile/--branch-predictor) and report the "
                               "cycle-count delta plus I$/D$ hit/miss counters")
    compare.add_argument("--compare-latency", action="store_true",
                          help="run every benchmark under MEM_LATENCY_I=MEM_LATENCY_D=0 and whatever "
                               "--mem-latency-i/--mem-latency-d were passed (both default to 3 here if neither "
                               "was set) and report the cycle-count delta")
    compare.add_argument("--compare-replacement", action="store_true",
                          help="run every benchmark under all 3 REPLACEMENT_POLICY values "
                               "(at --hazard-strategy/--pipeline-profile/--branch-predictor, forced "
                               "--cache-mode 1 since the parameter is a no-op otherwise) and report the delta")
    compare.add_argument("--compare-victim-cache", action="store_true",
                          help="run every benchmark at VICTIM_ENTRIES=0 vs. =4 "
                               "(at --hazard-strategy/--pipeline-profile/--branch-predictor/"
                               "--replacement-policy, forced --cache-mode 1 since the parameter is a "
                               "no-op otherwise) and report the delta")
    compare.add_argument("--compare-burst", action="store_true",
                          help="run every benchmark under BURST_ENABLE=1 with MEM_LATENCY_D_BURST at "
                               "no discount (equal to --mem-latency-d) vs. full discount (0) (forces "
                               "--cache-mode 1 and --burst-enable 1, and a nonzero --mem-latency-d if "
                               "neither was set, since the discount has nothing to amortize otherwise) "
                               "and report the delta")
    compare.add_argument("--compare-mshr", action="store_true",
                          help="run every benchmark across MSHR_ENTRIES in [1, 2, 4] "
                               "(at --hazard-strategy/--pipeline-profile/--branch-predictor/"
                               "--replacement-policy, forced --cache-mode 1 since the parameter is a "
                               "no-op otherwise) and report the delta")
    compare.add_argument("--compare-l2", action="store_true",
                          help="run every benchmark at L2_SIZE_BYTES=0 (disabled) vs. whatever --l2-size "
                               "was passed (defaults to 8192 here if not set) (at --hazard-strategy/"
                               "--pipeline-profile/--branch-predictor/--replacement-policy/--l2-ways/"
                               "--l2-replacement, forced --cache-mode 1 since the parameter is a no-op "
                               "otherwise) and report the delta")
    compare.add_argument("--compare-prefetch", action="store_true",
                          help="run every benchmark at PREFETCH_MODE=0 (disabled) vs. whatever "
                               "--prefetch-mode was passed (defaults to 1/next-line here if not set) "
                               "(at --hazard-strategy/--pipeline-profile/--branch-predictor/"
                               "--replacement-policy, forced --cache-mode 1 and --mshr-entries 2 since "
                               "D$ prefetching is a no-op otherwise) and report the delta")
    compare.add_argument("--compare-vector", action="store_true",
                          help="Gen7-V backlog closure (docs/adr/0066): run bench_vecadd_scalar.s vs. "
                               "bench_vecadd_vector.s, both on OOOCore.v (the only core with real vector "
                               "support) -- a scalar loop vs. real vle32.v/vadd.vv/vse32.v computing the "
                               "IDENTICAL result, and report the cycle/IPC delta. A separate code path "
                               "entirely (like --compare-ooo), not part of the axis/pairs machinery below.")
    compare.add_argument("--compare-ooo", action="store_true",
                          help="Gen6-L4: run PIPELINED (default config, --hazard-strategy/--pipeline-"
                               "profile/--branch-predictor/--cache-mode/... all as passed) vs. OOOCore.v "
                               "on bench_fib.s/bench_sum_array.s only (bench_bubble_sort.s excluded -- "
                               "see OOO_COMPATIBLE_BENCHES's own comment) and report the cycle/IPC delta. "
                               "A separate code path entirely, not part of the axis/pairs machinery below "
                               "(none of PIPELINED's own config knobs apply to OOOCore.v)")
    args = ap.parse_args()

    if args.compare_vector:
        # docs/adr/0066: deliberately NOT args.programs_dir -- these two
        # files contain real OP-V opcodes riscvpipeline.v's own Control.v
        # never decodes at all; living in sim/benchmarks/vector/ (not
        # sim/benchmarks/ itself) keeps them out of the plain `bench_*.s`
        # glob every other --compare-* mode and the no-flag default run
        # both use against args.programs_dir, so they can never get routed
        # through a core that would silently misexecute them.
        vector_dir = os.path.join(args.programs_dir, "vector")
        with tempfile.TemporaryDirectory() as work_dir:
            results = {}
            for name in VECTOR_PAIR:
                prog_s = os.path.join(vector_dir, f"{name}.s")
                if not os.path.exists(prog_s):
                    print(f"FAIL  {name}: not found under {args.programs_dir}")
                    continue
                result, err = run_bench_ooo_vector(name, prog_s, work_dir, args.iverilog_dir,
                                                    512, TARGET_RETIRED_VECTOR_PAIR[name], xlen=64)
                if err:
                    print(f"FAIL  {name}: {err}")
                    continue
                results[name] = result
                print(f"{name:<22} cycles={result['cycles']:<6} IPC={result['ipc']:.3f} "
                      f"instructions={result['instructions']}")
            if len(results) == len(VECTOR_PAIR):
                scalar_r, vector_r = results[VECTOR_PAIR[0]], results[VECTOR_PAIR[1]]
                delta_pct = (vector_r["cycles"] - scalar_r["cycles"]) / scalar_r["cycles"] * 100
                print(f"\nscalar cycles={scalar_r['cycles']}  vector cycles={vector_r['cycles']}  "
                      f"delta={delta_pct:+.1f}% (negative = vector faster)")
        sys.exit(0)

    if args.compare_ooo:
        here = os.path.dirname(os.path.abspath(__file__))
        pipe_template = os.path.join(here, "..", "tb", "bench_template.v")
        with tempfile.TemporaryDirectory() as work_dir:
            for name in OOO_COMPATIBLE_BENCHES:
                prog_s = os.path.join(args.programs_dir, f"{name}.s")
                if not os.path.exists(prog_s):
                    print(f"FAIL  {name}: not found under {args.programs_dir}")
                    continue
                mem_size = MEM_SIZE_OVERRIDES.get(name, 128)
                pipe_result, pipe_err = run_bench(name, prog_s, work_dir, args.iverilog_dir, pipe_template,
                                                   mem_size, xlen=64)
                ooo_result, ooo_err = run_bench_ooo(name, prog_s, work_dir, args.iverilog_dir,
                                                     max(mem_size, 512), xlen=64)
                if pipe_err or ooo_err:
                    print(f"FAIL  {name}: PIPELINED: {pipe_err or 'ok'}  OOOCore: {ooo_err or 'ok'}")
                    continue
                delta_pct = (ooo_result["cycles"] - pipe_result["cycles"]) / pipe_result["cycles"] * 100
                print(f"{name:<18} PIPELINED cycles={pipe_result['cycles']:<6} IPC={pipe_result['ipc']:.3f}"
                      f"   OOOCore cycles={ooo_result['cycles']:<6} IPC={ooo_result['ipc']:.3f}"
                      f"   delta={delta_pct:+.1f}%")
        sys.exit(0)

    if args.compare_latency and args.mem_latency_i == 0 and args.mem_latency_d == 0:
        args.mem_latency_i = args.mem_latency_d = 3
    if args.compare_replacement:
        args.cache_mode = 1
    if args.compare_victim_cache:
        args.cache_mode = 1
    if args.compare_burst:
        args.cache_mode = 1
        args.burst_enable = 1
        if args.mem_latency_d == 0:
            args.mem_latency_d = 5
    if args.compare_mshr:
        args.cache_mode = 1
    if args.compare_l2:
        args.cache_mode = 1
        if args.l2_size == 0:
            args.l2_size = 8192
    if args.compare_prefetch:
        args.cache_mode = 1
        if args.mshr_entries <= 1:
            args.mshr_entries = 2
        if args.prefetch_mode == 0:
            args.prefetch_mode = 1

    here = os.path.dirname(os.path.abspath(__file__))
    template = os.path.join(here, "..", "tb", "bench_template.v")

    progs = sorted(glob.glob(os.path.join(args.programs_dir, "bench_*.s")))
    if not progs:
        print(f"No bench_*.s programs found under {args.programs_dir}")
        sys.exit(1)

    # pairs are always (hazard_strategy, pipeline_profile, branch_predictor,
    # cache_mode, replacement_policy, mem_latency_i, mem_latency_d,
    # victim_entries, burst_enable, mem_latency_d_burst) 10-tuples; a
    # --compare-* flag varies exactly one axis while holding the rest at
    # whatever --hazard-strategy/--pipeline-profile/--branch-predictor/
    # --cache-mode/--replacement-policy/--mem-latency-i/--mem-latency-d/
    # --victim-entries/--burst-enable/--mem-latency-d-burst were passed
    # (defaulting to 0 each).
    if args.compare_strategies:
        axis, axis_label = "strategy", "HAZARD_STRATEGY"
        keys = (0, 1)
        pairs = [(s, args.pipeline_profile, args.branch_predictor, args.cache_mode,
                  args.replacement_policy, args.mem_latency_i, args.mem_latency_d, args.victim_entries,
                  args.burst_enable, args.mem_latency_d_burst, args.mshr_entries, args.l2_size,
                  args.prefetch_mode) for s in keys]
    elif args.compare_profiles:
        axis, axis_label = "profile", "PIPELINE_PROFILE"
        keys = (0, 1)
        pairs = [(args.hazard_strategy, p, args.branch_predictor, args.cache_mode,
                  args.replacement_policy, args.mem_latency_i, args.mem_latency_d, args.victim_entries,
                  args.burst_enable, args.mem_latency_d_burst, args.mshr_entries, args.l2_size,
                  args.prefetch_mode) for p in keys]
    elif args.compare_predictors:
        axis, axis_label = "predictor", "BRANCH_PREDICTOR"
        keys = (0, 1, 2, 3)   # Generation 4, Phase A (docs/adr/0040): GShare + tournament joined the axis
        pairs = [(args.hazard_strategy, args.pipeline_profile, bp, args.cache_mode,
                  args.replacement_policy, args.mem_latency_i, args.mem_latency_d, args.victim_entries,
                  args.burst_enable, args.mem_latency_d_burst, args.mshr_entries, args.l2_size,
                  args.prefetch_mode) for bp in keys]
    elif args.compare_cache:
        axis, axis_label = "cache", "CACHE_MODE"
        keys = (0, 1)
        pairs = [(args.hazard_strategy, args.pipeline_profile, args.branch_predictor, cm,
                  args.replacement_policy, args.mem_latency_i, args.mem_latency_d, args.victim_entries,
                  args.burst_enable, args.mem_latency_d_burst, args.mshr_entries, args.l2_size,
                  args.prefetch_mode) for cm in keys]
    elif args.compare_latency:
        axis, axis_label = "latency", "MEM_LATENCY_I/D"
        keys = (0, 1)
        pairs = [(args.hazard_strategy, args.pipeline_profile, args.branch_predictor, args.cache_mode,
                  args.replacement_policy, li, ld, args.victim_entries, args.burst_enable, args.mem_latency_d_burst,
                  args.mshr_entries, args.l2_size, args.prefetch_mode)
                 for li, ld in ((0, 0), (args.mem_latency_i, args.mem_latency_d))]
    elif args.compare_replacement:
        axis, axis_label = "replacement", "REPLACEMENT_POLICY"
        keys = (0, 1, 2)
        pairs = [(args.hazard_strategy, args.pipeline_profile, args.branch_predictor, args.cache_mode,
                  rp, args.mem_latency_i, args.mem_latency_d, args.victim_entries,
                  args.burst_enable, args.mem_latency_d_burst, args.mshr_entries, args.l2_size,
                  args.prefetch_mode) for rp in keys]
    elif args.compare_victim_cache:
        axis, axis_label = "victim", "VICTIM_ENTRIES"
        keys = (0, 4)
        pairs = [(args.hazard_strategy, args.pipeline_profile, args.branch_predictor, args.cache_mode,
                  args.replacement_policy, args.mem_latency_i, args.mem_latency_d, ve,
                  args.burst_enable, args.mem_latency_d_burst, args.mshr_entries, args.l2_size,
                  args.prefetch_mode) for ve in keys]
    elif args.compare_burst:
        axis, axis_label = "burst", "MEM_LATENCY_D_BURST"
        keys = (0, 1)   # 0=no discount (MEM_LATENCY_D_BURST==MEM_LATENCY_D), 1=full discount (0)
        pairs = [(args.hazard_strategy, args.pipeline_profile, args.branch_predictor, args.cache_mode,
                  args.replacement_policy, args.mem_latency_i, args.mem_latency_d, args.victim_entries,
                  args.burst_enable, ldb, args.mshr_entries, args.l2_size,
                  args.prefetch_mode) for ldb in (args.mem_latency_d, 0)]
    elif args.compare_mshr:
        axis, axis_label = "mshr", "MSHR_ENTRIES"
        keys = (1, 2, 4)
        pairs = [(args.hazard_strategy, args.pipeline_profile, args.branch_predictor, args.cache_mode,
                  args.replacement_policy, args.mem_latency_i, args.mem_latency_d, args.victim_entries,
                  args.burst_enable, args.mem_latency_d_burst, me, args.l2_size,
                  args.prefetch_mode) for me in keys]
    elif args.compare_l2:
        axis, axis_label = "l2", "L2_SIZE_BYTES"
        keys = (0, args.l2_size)
        pairs = [(args.hazard_strategy, args.pipeline_profile, args.branch_predictor, args.cache_mode,
                  args.replacement_policy, args.mem_latency_i, args.mem_latency_d, args.victim_entries,
                  args.burst_enable, args.mem_latency_d_burst, args.mshr_entries, l2,
                  args.prefetch_mode) for l2 in keys]
    elif args.compare_prefetch:
        axis, axis_label = "prefetch", "PREFETCH_MODE"
        keys = (0, args.prefetch_mode)
        pairs = [(args.hazard_strategy, args.pipeline_profile, args.branch_predictor, args.cache_mode,
                  args.replacement_policy, args.mem_latency_i, args.mem_latency_d, args.victim_entries,
                  args.burst_enable, args.mem_latency_d_burst, args.mshr_entries, args.l2_size,
                  pf) for pf in keys]
    else:
        axis, axis_label = None, None
        keys = (args.hazard_strategy,)  # single run, keyed arbitrarily by hazard_strategy
        pairs = [(args.hazard_strategy, args.pipeline_profile, args.branch_predictor, args.cache_mode,
                  args.replacement_policy, args.mem_latency_i, args.mem_latency_d, args.victim_entries,
                  args.burst_enable, args.mem_latency_d_burst, args.mshr_entries, args.l2_size,
                  args.prefetch_mode)]

    all_results = {k: [] for k in keys}
    with tempfile.TemporaryDirectory() as work_dir:
        for key, (strategy, profile, predictor, cache_mode, replacement_policy, mem_latency_i, mem_latency_d,
                  victim_entries, burst_enable, mem_latency_d_burst, mshr_entries, l2_size,
                  prefetch_mode) in zip(keys, pairs):
            if axis == "strategy":
                print(f"--- HAZARD_STRATEGY={strategy} ({'forwarding' if strategy == 0 else 'stall-only'}) ---")
            elif axis == "profile":
                print(f"--- PIPELINE_PROFILE={profile} "
                      f"({'PROFILE_5STAGE' if profile == 0 else 'PROFILE_6STAGE_SPLIT_FETCH'}) ---")
            elif axis == "predictor":
                predictor_names = {0: "PREDICTOR_STATIC", 1: "PREDICTOR_DYNAMIC_BHT_BTB",
                                    2: "PREDICTOR_GSHARE", 3: "PREDICTOR_TOURNAMENT"}
                print(f"--- BRANCH_PREDICTOR={predictor} ({predictor_names[predictor]}) ---")
            elif axis == "cache":
                print(f"--- CACHE_MODE={cache_mode} "
                      f"({'CACHE_NONE' if cache_mode == 0 else 'CACHE_WRITEBACK_SETASSOC'}) ---")
            elif axis == "latency":
                print(f"--- MEM_LATENCY_I={mem_latency_i} MEM_LATENCY_D={mem_latency_d} ---")
            elif axis == "replacement":
                policy_names = {0: "POLICY_ROUND_ROBIN", 1: "POLICY_FIFO", 2: "POLICY_LRU"}
                print(f"--- REPLACEMENT_POLICY={replacement_policy} ({policy_names[replacement_policy]}) ---")
            elif axis == "victim":
                print(f"--- VICTIM_ENTRIES={victim_entries} "
                      f"({'disabled' if victim_entries == 0 else f'{victim_entries} entries'}) ---")
            elif axis == "burst":
                print(f"--- MEM_LATENCY_D_BURST={mem_latency_d_burst} "
                      f"({'no discount' if mem_latency_d_burst == mem_latency_d else 'full discount'}, "
                      f"MEM_LATENCY_D={mem_latency_d}) ---")
            elif axis == "mshr":
                print(f"--- MSHR_ENTRIES={mshr_entries} "
                      f"({'disabled' if mshr_entries == 1 else f'{mshr_entries} outstanding'}) ---")
            elif axis == "l2":
                print(f"--- L2_SIZE_BYTES={l2_size} "
                      f"({'disabled' if l2_size == 0 else f'{l2_size} bytes, L2_WAYS={args.l2_ways}'}) ---")
            elif axis == "prefetch":
                prefetch_names = {0: "disabled", 1: "PF_NEXT_LINE", 2: "PF_STRIDE", 3: "PF_STREAM"}
                print(f"--- PREFETCH_MODE={prefetch_mode} ({prefetch_names[prefetch_mode]}) ---")
            for prog_s in progs:
                name = os.path.splitext(os.path.basename(prog_s))[0]
                mem_size = MEM_SIZE_OVERRIDES.get(name, 128)
                result, err = run_bench(name, prog_s, work_dir, args.iverilog_dir, template, mem_size,
                                         strategy, profile, predictor, cache_mode, replacement_policy,
                                         mem_latency_i, mem_latency_d, victim_entries,
                                         burst_enable, mem_latency_d_burst, mshr_entries=mshr_entries,
                                         l2_size=l2_size, l2_ways=args.l2_ways, l2_replacement=args.l2_replacement,
                                         prefetch_mode=prefetch_mode)
                if err:
                    print(f"FAIL  {name}: {err}")
                    all_results[key].append((name, None))
                else:
                    cache_info = ""
                    if cache_mode:
                        cache_info = (f"  I$miss={result['icache_misses']}/{result['icache_accesses']} "
                                      f"D$miss={result['dcache_misses']}")
                    print(f"{name:<20} instructions={result['instructions']:<6} "
                          f"cycles={result['cycles']:<6} IPC={result['ipc']:.3f}{cache_info}")
                    all_results[key].append((name, result))
            print()

    if axis is not None:
        # labels[axis][key] -- a per-key name lookup, not just a 0/1 pair,
        # so an axis with more than two keys (BRANCH_PREDICTOR now has
        # four, Generation 4 Phase A / docs/adr/0040) works the same way
        # every other axis already does. A strict generalization of the
        # old hardcoded labels0/labels1 pair-diff below: for every
        # existing 2-key axis (strategy/profile/cache/latency), a loop
        # over one element (keys[1:]) produces byte-identical output to
        # the old single comparison.
        labels = {
            "strategy": {0: "forwarding (HS=0)", 1: "stall-only (HS=1)"},
            "profile": {0: "PROFILE_5STAGE (PP=0)", 1: "PROFILE_6STAGE_SPLIT_FETCH (PP=1)"},
            "predictor": {0: "PREDICTOR_STATIC (BP=0)", 1: "PREDICTOR_DYNAMIC_BHT_BTB (BP=1)",
                          2: "PREDICTOR_GSHARE (BP=2)", 3: "PREDICTOR_TOURNAMENT (BP=3)"},
            "cache": {0: "CACHE_NONE (CM=0)", 1: "CACHE_WRITEBACK_SETASSOC (CM=1)"},
            "latency": {0: "MEM_LATENCY_I=D=0", 1: f"MEM_LATENCY_I={args.mem_latency_i} "
                                                     f"MEM_LATENCY_D={args.mem_latency_d}"},
            "replacement": {0: "POLICY_ROUND_ROBIN (RP=0)", 1: "POLICY_FIFO (RP=1)", 2: "POLICY_LRU (RP=2)"},
            "victim": {0: "VICTIM_ENTRIES=0 (disabled)", 4: "VICTIM_ENTRIES=4"},
            "burst": {0: "no discount (MEM_LATENCY_D_BURST=MEM_LATENCY_D)", 1: "full discount (MEM_LATENCY_D_BURST=0)"},
            "mshr": {1: "MSHR_ENTRIES=1 (disabled)", 2: "MSHR_ENTRIES=2", 4: "MSHR_ENTRIES=4"},
            "l2": {0: "L2_SIZE_BYTES=0 (disabled)", args.l2_size: f"L2_SIZE_BYTES={args.l2_size}"},
            "prefetch": {0: "PREFETCH_MODE=0 (disabled)",
                         args.prefetch_mode: f"PREFETCH_MODE={args.prefetch_mode} "
                                              f"({['disabled', 'PF_NEXT_LINE', 'PF_STRIDE', 'PF_STREAM'][args.prefetch_mode]})"},
        }
        baseline_key = keys[0]
        by_name_baseline = dict(all_results[baseline_key])
        for key in keys[1:]:
            label0, label1 = labels[axis][baseline_key], labels[axis][key]
            print(f"=== comparison: {label0} vs. {label1} ===")
            by_name_key = dict(all_results[key])
            for name, r0 in all_results[baseline_key]:
                r1 = by_name_key.get(name)
                if r0 is None or r1 is None:
                    print(f"{name:<20} (incomplete, see FAIL above)")
                    continue
                delta = r1["cycles"] - r0["cycles"]
                pct = 100.0 * delta / r0["cycles"]
                cache_info = ""
                if axis == "cache":
                    cache_info = (f"   I$miss={r1['icache_misses']}/{r1['icache_accesses']} "
                                  f"D$miss={r1['dcache_misses']}")
                print(f"{name:<20} cycles: {r0['cycles']:<6} -> {r1['cycles']:<6}  "
                      f"({delta:+d}, {pct:+.1f}%)   IPC: {r0['ipc']:.3f} -> {r1['ipc']:.3f}{cache_info}")

    failed = [n for results in all_results.values() for n, r in results if r is None]
    total = sum(len(results) for results in all_results.values())
    if failed:
        print(f"\n=== {len(failed)}/{total} benchmark run(s) FAILED: {', '.join(failed)} ===")
        sys.exit(1)
    print(f"\n=== {total}/{total} benchmark run(s) completed cleanly ===")


if __name__ == "__main__":
    main()
