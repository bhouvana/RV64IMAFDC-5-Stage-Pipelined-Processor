#!/usr/bin/env python3
"""
Constrained-random cross-check driver (docs/ROADMAP.md V-4). For each of N
seeds: generate a random program (random_gen.py), compute expected final
architectural state with the reference model (iss.py), run the same program
through the real RTL simulation (Icarus Verilog), and compare.

Usage: python run_random_tests.py --count 30 --iverilog-dir /c/iverilog/bin
Must be run from the repository root.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from iss import ISS  # noqa: E402
from random_gen import gen_program  # noqa: E402

# Phase Q (docs/adr/0033-memory-capacity-scale-up-phase-q.md): a fixed 64KB
# window every constrained-random program's real touched range provably
# stays within regardless of mem_size (random_gen.py's own base_addr/
# addr_space/offset caps -- confirmed by direct code read, not assumed;
# see the ADR). Used to bound three things that would otherwise scale
# uselessly with a large --mem-size: the .mem file asm.py writes (real
# programs never need more than this many bytes of instruction memory),
# the RTL-side memory dump loop, and the Python-side dump parse/compare --
# matches design/InstructionMemory.v's own ZERO_INIT_LIMIT bound.
SCALEUP_WINDOW_BYTES = 65536


def load_words(mem_path):
    # Generation 4, Phase A (docs/adr/0040): byte order here was stale --
    # design/InstructionMemory.v/DataMemoryBRAM.v have read LSB-first
    # (`{mem[addr+3], mem[addr+2], mem[addr+1], mem[addr]}`) since Phase U
    # (docs/adr/0037), but this helper still concatenated b[0..3] MSB-first,
    # the pre-Phase-U convention -- silently decoding every word here as
    # garbage (found because it broke ISS reference-model execution for
    # every seed regardless of BRANCH_PREDICTOR value, not something this
    # phase's own RTL work caused). Reversed to match.
    with open(mem_path) as f:
        lines = [l.strip() for l in f if l.strip()]
    words = []
    for i in range(0, len(lines), 4):
        b = lines[i:i + 4]
        if len(b) < 4:
            break
        words.append(int(b[3] + b[2] + b[1] + b[0], 2))
    return words


def run_one(seed, n_instrs, work_dir, iverilog_bin, template, hazard_strategy=0, pipeline_profile=0,
            mem_size=128, interrupt=None, branch_predictor=0, mmu=False, cache_mode=0,
            replacement_policy=0, victim_entries=0, mem_latency_i=0, mem_latency_d=0,
            burst_enable=0, mem_latency_d_burst=0, xlen=32, mshr_entries=1,
            l2_size=0, l2_ways=4, l2_replacement=0):
    prog_s = os.path.join(work_dir, f"r{seed}.s")
    prog_mem = os.path.join(work_dir, f"r{seed}.mem")
    # Generation 2 (Phase M, docs/adr/0028-rv64-migration-phase-m.md): xlen
    # threaded through gen_program too (random_gen.py's own xlen-gated *w/
    # ld/sd/lwu generation, M15) -- default 32 is bit-exact with every prior
    # call site.
    text, interrupt_info = gen_program(seed, n_instrs, mem_size=mem_size, interrupt=interrupt, mmu=mmu, xlen=xlen)
    with open(prog_s, "w") as f:
        f.write(text)

    # Phase Q: the .mem file only ever needs to hold the real (tiny)
    # generated program -- asm.py's own write_mem() pads/zero-fills the
    # file out to whatever --size says, so passing the true (possibly
    # 64MB-scale) mem_size here would write tens of millions of lines to
    # disk per seed. dump_window (bounded to SCALEUP_WINDOW_BYTES) is
    # always >= any real generated program's size, and stays == mem_size
    # (today's exact old behavior) whenever mem_size <= SCALEUP_WINDOW_BYTES.
    dump_window = min(mem_size, SCALEUP_WINDOW_BYTES)
    asm_py = os.path.join(os.path.dirname(os.path.abspath(__file__)), "asm.py")
    r = subprocess.run([sys.executable, asm_py, prog_s, "-o", prog_mem,
                         "--size", str(dump_window), "--xlen", str(xlen)],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return False, f"assembler error: {r.stderr.strip()}"

    # Phase Q: asm.py's own stdout ("N instructions -> ...") is the real
    # program length, independent of how large --size padded the .mem file
    # out to. Real bug found by running (docs/adr/0033): before this fix,
    # max_time below was computed from len(words) -- the full *padded* file,
    # not the real program -- which was already a latent inefficiency at the
    # old small mem_size values but became catastrophic once dump_window
    # (65536) became a much larger --size than any real program needs: a
    # single seed at MEM_SIZE_BYTES=64MB ran for over a million simulated
    # cycles (~2m40s wall-clock) instead of a few hundred.
    m = re.search(r":\s*(\d+)\s+instructions", r.stdout)
    real_n_instrs = int(m.group(1)) if m else n_instrs
    words = load_words(prog_mem)
    iss = ISS(mem_size=mem_size, xlen=xlen)
    # docs/adr/0020-soc-integration.md (Phase D10). Matches the RTL's own
    # real (armed but not precisely timed) hardware interrupt with an
    # externally scheduled one on the ISS side -- see gen_program's own
    # docstring for why the two don't need to agree on the exact
    # instruction boundary.
    if interrupt_info is not None:
        iss.schedule_interrupt(interrupt_info["after"], interrupt_info["cause"])
    try:
        iss.run(words, max_steps=5000)
    except Exception as e:  # noqa: BLE001
        return False, f"ISS error: {e}"

    # Multi-cycle divisions/fdiv.s/fsqrt.s dominate runtime -- budget
    # generously: every instruction could in principle be one (fdiv.s is
    # the longest at ~51 iterations, docs/adr/0019 Phase C4), plus margin.
    # real_n_instrs (Phase Q), not len(words) -- see the note above.
    # Generation 4, Phase E (docs/adr/0044-non-blocking-dcache-mshr-phase-e.md).
    # This formula never had a cache_mode-conditional margin term at all
    # (unlike bench_runner.py's own +4000, sized for fence-flush cost) --
    # a real, previously-latent gap flagged before it was ever exercised by
    # a genuinely long-running worst case, not found by running: reuse the
    # identical +4000 constant bench_runner.py's own cache_mode margin
    # already uses (fence's own whole-cache-flush scan dominates worst-case
    # duration far more than any single miss/fill sequence, MSHR or not).
    # docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). No separate
    # margin term for L2 -- a probe-before-evict round trip costs at most a
    # handful of cycles per eviction, dwarfed by the existing +4000 fence-
    # flush-scan margin cache_mode already carries, same reasoning
    # docs/adr/0044's own MSHR margin decision used.
    max_time = (real_n_instrs * 70 + 200) * 10 + (4000 if cache_mode else 0)
    dump_v = os.path.join(work_dir, f"r{seed}.v")
    out_path = os.path.join(work_dir, f"r{seed}.out").replace("\\", "/")
    init_file_rel = os.path.relpath(prog_mem, start=os.getcwd()).replace("\\", "/")
    with open(template) as f:
        tpl = f.read()
    uart_stimulus = ""
    if interrupt in ("uart", "both"):
        # Starts almost immediately and completes in ~40 cycles
        # (CLKS_PER_BIT=4 * 10 bit periods) -- comfortably early and fast
        # relative to max_time, landing well within the generously-margined
        # "somewhere before the program's own halt loop" safety window
        # gen_program's docstring describes.
        uart_stimulus = "repeat (5) @(posedge clk);\n        drive_rx_byte(8'hA5);"
    tpl = (tpl.replace("__INIT_FILE__", init_file_rel).replace("__MAX_TIME__", str(max_time))
              .replace("__OUT_FILE__", out_path).replace("__HAZARD_STRATEGY__", str(hazard_strategy))
              .replace("__PIPELINE_PROFILE__", str(pipeline_profile)).replace("__MEM_SIZE__", str(mem_size))
              .replace("__DUMP_WINDOW__", str(dump_window))
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
              .replace("__MEM_LATENCY_I__", str(mem_latency_i))
              .replace("__MEM_LATENCY_D__", str(mem_latency_d))
              .replace("__XLEN__", str(xlen))
              .replace("__UART_STIMULUS__", uart_stimulus))
    with open(dump_v, "w") as f:
        f.write(tpl)

    vvp_path = os.path.join(work_dir, f"r{seed}.vvp")
    iverilog_exe = os.path.join(iverilog_bin, "iverilog.exe") if iverilog_bin else "iverilog"
    vvp_exe = os.path.join(iverilog_bin, "vvp.exe") if iverilog_bin else "vvp"
    r = subprocess.run([iverilog_exe, "-g2005", "-I", "design", "-o", vvp_path, dump_v],
                        capture_output=True, text=True)
    if r.returncode != 0:
        return False, f"compile error: {r.stderr.strip()[:500]}"
    r = subprocess.run([vvp_exe, vvp_path], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(out_path):
        return False, f"simulation error: {r.stdout.strip()[:500]} {r.stderr.strip()[:500]}"

    # Generation 2 (Phase M14): was a hardcoded & 0xFFFFFFFF -- at xlen=64
    # that silently truncated every dumped integer register to its low 32
    # bits, hiding real mismatches confined to the upper half as false
    # passes. mem/freg/fflags/frm values are all already <=32-bit-valued
    # regardless of xlen, so widening this mask to xlen bits never corrupts
    # them -- it only matters for (and only ever narrows) the register dump.
    reg_mask = (1 << xlen) - 1
    with open(out_path) as f:
        vals = [int(l.strip()) & reg_mask for l in f if l.strip()]
    # Layout matches dump_regs_template.v exactly: 32 int regs, mem_size mem
    # bytes, 32 float regs, fflags, frm (docs/adr/0019-f-extension.md Phase
    # C9). dump_regs_interrupt_template.v (Phase Q, docs/adr/0033) instead
    # dumps only dump_window mem bytes -- dump_window == mem_size (today's
    # exact old layout) whenever mem_size <= SCALEUP_WINDOW_BYTES, which is
    # every size ever used before this phase, so mem_window below reduces
    # to the old plain layout bit-for-bit at every pre-existing call site.
    # (An earlier version of this also spot-checked a few high addresses
    # beyond the window -- removed after running found those addresses are
    # genuinely undefined/X in the RTL beyond DataMemoryBRAM.v's own bounded
    # zero-init, making that comparison unsound; see docs/adr/0033.)
    uses_dump_window = os.path.basename(template) == "dump_regs_interrupt_template.v"
    mem_window = dump_window if uses_dump_window else mem_size
    rtl_regs = vals[:32]
    rtl_mem = vals[32:32 + mem_window]
    rtl_fregs = vals[32 + mem_window:32 + mem_window + 32]
    rtl_fflags = vals[32 + mem_window + 32]
    rtl_frm = vals[32 + mem_window + 33]

    mismatches = []
    for i in range(32):
        if rtl_regs[i] != iss.regs[i]:
            mismatches.append(f"x{i}: RTL={rtl_regs[i]:#x} ISS={iss.regs[i]:#x}")
    for i in range(mem_window):
        if rtl_mem[i] != iss.mem[i]:
            mismatches.append(f"mem[{i}]: RTL={rtl_mem[i]:#x} ISS={iss.mem[i]:#x}")
    for i in range(32):
        if rtl_fregs[i] != iss.fregs[i]:
            mismatches.append(f"f{i}: RTL={rtl_fregs[i]:#010x} ISS={iss.fregs[i]:#010x}")
    if rtl_fflags != iss.fflags:
        mismatches.append(f"fflags: RTL={rtl_fflags:#x} ISS={iss.fflags:#x}")
    if rtl_frm != iss.frm:
        mismatches.append(f"frm: RTL={rtl_frm:#x} ISS={iss.frm:#x}")

    if mismatches:
        return False, "; ".join(mismatches[:8]) + (" ..." if len(mismatches) > 8 else "")
    return True, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=30)
    ap.add_argument("--n-instrs", type=int, default=16)
    ap.add_argument("--seed-start", type=int, default=1)
    ap.add_argument("--iverilog-dir", default=None)
    ap.add_argument("--keep-failures", action="store_true", help="don't delete work dir contents for failing seeds")
    ap.add_argument("--hazard-strategy", type=int, default=0, choices=[0, 1],
                     help="riscvpipeline.v's HAZARD_STRATEGY (docs/adr/0016): 0=forwarding (default), 1=stall-only")
    ap.add_argument("--pipeline-profile", type=int, default=0, choices=[0, 1],
                     help="riscvpipeline.v's PIPELINE_PROFILE (docs/adr/0018): "
                          "0=5-stage (default), 1=6-stage split-fetch")
    ap.add_argument("--branch-predictor", type=int, default=0, choices=[0, 1, 2, 3],
                     help="riscvpipeline.v's BRANCH_PREDICTOR (docs/adr/0021, docs/adr/0040): "
                          "0=static not-taken (default), 1=dynamic BHT+BTB, "
                          "2=GShare, 3=tournament (BHT+GShare+chooser)")
    ap.add_argument("--cache-mode", type=int, default=0, choices=[0, 1],
                     help="riscvpipeline.v's CACHE_MODE (docs/adr/0023-caches.md): "
                          "0=no cache (default, bit-exact), 1=4-way write-back I$/D$")
    ap.add_argument("--replacement-policy", type=int, default=0, choices=[0, 1, 2],
                     help="riscvpipeline.v's REPLACEMENT_POLICY (docs/adr/0041-cache-replacement-"
                          "policy-phase-b.md): 0=round-robin (default, bit-exact), 1=FIFO "
                          "(identical mechanism to round-robin), 2=LRU. Only meaningful under "
                          "--cache-mode 1")
    ap.add_argument("--victim-entries", type=int, default=0,
                     help="riscvpipeline.v's VICTIM_ENTRIES (docs/adr/0042-victim-cache-phase-c.md): "
                          "0=disabled (default, bit-exact), N=that many fully-associative "
                          "victim-buffer entries per cache. Only meaningful under --cache-mode 1")
    ap.add_argument("--burst-enable", type=int, default=0, choices=[0, 1],
                     help="riscvpipeline.v's BURST_ENABLE (docs/adr/0043-memory-controller-phase-d.md): "
                          "0=disabled (default, bit-exact, DCache.v always drives CTI_CLASSIC), "
                          "1=real Wishbone B3 CTI burst signaling on D$ fill/writeback. Only "
                          "meaningful under --cache-mode 1")
    ap.add_argument("--mem-latency-d-burst", type=int, default=0,
                     help="riscvpipeline.v's MEM_LATENCY_D_BURST (docs/adr/0043-memory-controller-"
                          "phase-d.md): extra wait-state cycles for a burst-continuation beat "
                          "instead of the full --mem-latency-d. Only meaningful under --burst-enable 1")
    ap.add_argument("--mshr-entries", type=int, default=1,
                     help="riscvpipeline.v's MSHR_ENTRIES (docs/adr/0044-non-blocking-dcache-mshr-"
                          "phase-e.md): 1=disabled (default, bit-exact), N=that many outstanding "
                          "load misses. Only meaningful under --cache-mode 1")
    ap.add_argument("--l2-size", type=int, default=0,
                     help="riscvpipeline.v's L2_SIZE_BYTES (docs/adr/0045-l2-cache-phase-f.md): "
                          "0=disabled (default, bit-exact), N=a shared, inclusive L2 behind both "
                          "I$/D$ of that size in bytes. Only meaningful under --cache-mode 1")
    ap.add_argument("--l2-ways", type=int, default=4,
                     help="riscvpipeline.v's L2_WAYS (docs/adr/0045-l2-cache-phase-f.md). "
                          "Only meaningful under --l2-size > 0")
    ap.add_argument("--l2-replacement", type=int, default=0, choices=[0, 1, 2],
                     help="riscvpipeline.v's L2_REPLACEMENT_POLICY (docs/adr/0045-l2-cache-"
                          "phase-f.md): 0=round-robin (default), 1=FIFO, 2=LRU -- independent of "
                          "--replacement-policy (L1's own). Only meaningful under --l2-size > 0")
    ap.add_argument("--mem-latency-i", type=int, default=0,
                     help="riscvpipeline.v's MEM_LATENCY_I (docs/adr/0024-variable-latency-memory.md): "
                          "extra I-side wait-state cycles, 0=bit-exact default")
    ap.add_argument("--mem-latency-d", type=int, default=0,
                     help="riscvpipeline.v's MEM_LATENCY_D (docs/adr/0024-variable-latency-memory.md): "
                          "extra D-side wait-state cycles, 0=bit-exact default")
    # docs/adr/0020-soc-integration.md (Phase D10). Opt-in, not default-on --
    # every existing invocation (no --interrupt) behaves exactly as before,
    # against the original dump_regs_template.v at mem_size=128.
    ap.add_argument("--interrupt", choices=["timer", "uart", "msi", "both"], default=None,
                     help="opt-in interrupt-injection mode (docs/adr/0020 Phase D10/D11, "
                          "\"msi\" added docs/adr/0034 Phase R): arm and fire the given source once "
                          "during each generated program "
                          "(\"both\" arms and pends timer+uart simultaneously, exercising MEI-over-MTI priority)")
    ap.add_argument("--mem-size", type=int, default=None,
                     help="override InstructionMemory/DataMemory size in bytes; "
                          "defaults to 128 normally, 256 when --interrupt is set "
                          "(room for the extra prefix/handler instructions), "
                          "8192 when --mmu is set at XLEN=32 (Sv32, two table pages), "
                          "16384 when --mmu is set at XLEN=64 (Sv39, three table pages, "
                          "rounded up to a power of 2 -- see gen_program's own mem_mask note)")
    # docs/adr/00NN-mmu-sv32.md (Phase F7). Opt-in, not default-on -- every
    # existing invocation (no --mmu) behaves exactly as before. Mutually
    # exclusive with --interrupt in this phase (see gen_program's own
    # docstring for why). docs/adr/00NN-sv39-mmu-phase-p.md (Phase P5):
    # now dispatches to Sv32 (XLEN=32) or Sv39 (XLEN=64) translation --
    # no longer XLEN-restricted (Sv39 didn't exist yet in Phase F7).
    ap.add_argument("--mmu", action="store_true",
                     help="opt-in translation mode: Sv32 at XLEN=32 (docs/adr/00NN-mmu-sv32.md "
                          "Phase F7) or Sv39 at XLEN=64 (docs/adr/00NN-sv39-mmu-phase-p.md Phase P5) "
                          "-- run the whole generated program as translated U-mode code, through a "
                          "generator-guaranteed-valid identity page table")
    ap.add_argument("--xlen", type=int, default=32, choices=[32, 64],
                     help="riscvpipeline.v's XLEN (Generation 2, docs/adr/0028-rv64-migration-"
                          "phase-m.md): 32=default/bit-exact, 64=RV64 (Sv39 MMU support since Phase P3)")
    args = ap.parse_args()

    if args.interrupt and args.mmu:
        print("error: --interrupt and --mmu are mutually exclusive in this generator (Phase F7 scope)", file=sys.stderr)
        sys.exit(2)

    if args.mem_size is not None:
        mem_size = args.mem_size
    elif args.mmu:
        # docs/adr/00NN-sv39-mmu-phase-p.md (Phase P5): Sv39 needs a third
        # table level (level-2/level-1/level-0, one page each) vs. Sv32's
        # two. 16384 (4x4KB), not 12288 (3x4KB) -- a real bug found by
        # running: iss.py's own store_mem_byte/load_mem_byte mask addresses
        # with `mem_size - 1` (its own header comment documents "mem_size
        # is always a power of 2"), which silently corrupts addressing for
        # any non-power-of-2 size (12288 & 0x2FFF == 0 for a 0x1000 address,
        # not 0x1000 -- bit 12 isn't set in that mask). 16384 keeps the
        # existing power-of-2 convention with one spare page of headroom.
        mem_size = 16384 if args.xlen == 64 else 8192
    elif args.interrupt:
        mem_size = 256
    else:
        mem_size = 128

    here = os.path.dirname(os.path.abspath(__file__))
    # docs/adr/00NN-mmu-sv32.md (Phase F7): MMU mode reuses the interrupt
    # template -- it already parameterizes MEM_SIZE_BYTES and the memory-
    # dump loop correctly (the plain default template hardcodes 128 bytes
    # both places); its own interrupt-specific pieces (uart_rx wiring,
    # drive_rx_byte) are simply unused/harmless when --mmu is set without
    # --interrupt (uart_stimulus stays the empty string, same as a plain
    # --interrupt-less run through this same template would see). Phase Q
    # (docs/adr/0033): also route any explicit non-default --mem-size
    # through this same parameterized template -- the plain template
    # hardcodes 128 both at the PIPELINED instantiation and the dump loop,
    # so it silently ignored --mem-size entirely before this (a real,
    # pre-existing gap, found by design while scoping this phase's own
    # large-memory sweep, not by running).
    template_name = ("dump_regs_interrupt_template.v"
                      if (args.interrupt or args.mmu or (args.mem_size is not None and args.mem_size != 128))
                      else "dump_regs_template.v")
    template = os.path.join(here, "..", "tb", template_name)

    passed = 0
    failed = 0
    with tempfile.TemporaryDirectory() as work_dir:
        for i in range(args.count):
            seed = args.seed_start + i
            ok, msg = run_one(seed, args.n_instrs, work_dir, args.iverilog_dir, template,
                              args.hazard_strategy, args.pipeline_profile,
                              mem_size=mem_size, interrupt=args.interrupt,
                              branch_predictor=args.branch_predictor, mmu=args.mmu,
                              cache_mode=args.cache_mode,
                              replacement_policy=args.replacement_policy,
                              victim_entries=args.victim_entries,
                              burst_enable=args.burst_enable, mem_latency_d_burst=args.mem_latency_d_burst,
                              mem_latency_i=args.mem_latency_i, mem_latency_d=args.mem_latency_d,
                              xlen=args.xlen, mshr_entries=args.mshr_entries,
                              l2_size=args.l2_size, l2_ways=args.l2_ways, l2_replacement=args.l2_replacement)
            if ok:
                passed += 1
                print(f"pass  seed={seed}")
            else:
                failed += 1
                print(f"FAIL  seed={seed}: {msg}")
                if args.keep_failures:
                    keep_dir = os.path.join(os.getcwd(), f"random_fail_{seed}")
                    os.makedirs(keep_dir, exist_ok=True)
                    for fn in (f"r{seed}.s", f"r{seed}.mem", f"r{seed}.v"):
                        src = os.path.join(work_dir, fn)
                        if os.path.exists(src):
                            with open(src, "rb") as sf, open(os.path.join(keep_dir, fn), "wb") as df:
                                df.write(sf.read())

    print(f"\n=== random cross-check: {passed}/{passed+failed} programs matched ISS reference ===")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
