#!/usr/bin/env python3
"""
Interactive step debugger (docs/ROADMAP.md Phase 8), built directly on
sim/tools/iss.py -- the existing, already-verified ISA-level reference
model. Runs the *model*, not the RTL: instant single-instruction stepping
with no Verilog simulator round-trip, at the cost of not reflecting
pipeline-specific timing (stalls/flushes/forwarding cycles) -- for that,
sim/tools/build_viewer.py's cycle-accurate pipeline viewer is the right
tool. This one is for "what does the program actually do, instruction by
instruction" -- architectural state only, same scope iss.py itself has.

Usage:
    python debugger.py sim/programs/arith.s
    python debugger.py sim/programs/arith.mem   # pre-assembled .mem also works

Commands (see `help` inside the debugger):
    step [n], continue, break <addr>, delete <addr>, regs, reg <n>,
    mem <addr> [len], csr, disas [n], pc, restart, quit
"""
import argparse
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from disasm import disasm  # noqa: E402
from iss import ISS, CSR_MSTATUS, CSR_MTVEC, CSR_MSCRATCH, CSR_MEPC, CSR_MCAUSE  # noqa: E402

CSR_BY_ADDR = {CSR_MSTATUS: "mstatus", CSR_MTVEC: "mtvec", CSR_MSCRATCH: "mscratch",
               CSR_MEPC: "mepc", CSR_MCAUSE: "mcause"}


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


def assemble_if_needed(path, mem_size, xlen=32):
    if path.endswith(".mem"):
        return load_words(path)
    here = os.path.dirname(os.path.abspath(__file__))
    asm_py = os.path.join(here, "asm.py")
    fd, tmp_mem = tempfile.mkstemp(suffix=".mem")
    os.close(fd)
    try:
        r = subprocess.run([sys.executable, asm_py, path, "-o", tmp_mem,
                             "--size", str(mem_size), "--xlen", str(xlen)],
                            capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr, file=sys.stderr)
            sys.exit(1)
        return load_words(tmp_mem)
    finally:
        os.unlink(tmp_mem)


class Debugger:
    def __init__(self, words, mem_size, xlen=32):
        self.words = words
        self.mem_size = mem_size
        self.xlen = xlen  # Generation 2 (Phase M12, docs/adr/0028-rv64-migration-phase-m.md)
        self.reg_hex_digits = xlen // 4
        self.breakpoints = set()
        self.history = []  # (pc, word) pairs actually executed, most recent last
        self.iss = None
        self.reset()

    def reset(self):
        self.iss = ISS(mem_size=self.mem_size, xlen=self.xlen)
        self.history = []

    def word_at(self, pc):
        idx = pc // 4
        if 0 <= idx < len(self.words):
            return self.words[idx]
        return 0

    def at_end(self):
        return self.iss.pc >= len(self.words) * 4

    def step_one(self):
        """Execute exactly one instruction. Returns False if already at end."""
        if self.at_end():
            return False
        word = self.word_at(self.iss.pc)
        self.history.append((self.iss.pc, word))
        self.iss.step(word)
        return True

    def run_until(self, max_steps=200000):
        """Run until a breakpoint, a self-loop (halt), or the program end.
        Returns a short status string describing why it stopped."""
        steps = 0
        while steps < max_steps:
            if self.at_end():
                return "end of program"
            pc = self.iss.pc
            word = self.word_at(pc)
            if word & 0x7F == 0b1101111:  # jal self-loop halt, same convention iss.py's run() uses
                b20 = (word >> 31) & 1
                b19_12 = (word >> 12) & 0xFF
                b11 = (word >> 20) & 1
                b10_1 = (word >> 21) & 0x3FF
                off = ((b20 << 20) | (b19_12 << 12) | (b11 << 11) | (b10_1 << 1))
                if off & (1 << 20):
                    off -= 1 << 21
                if off == 0:
                    return "halted (self-loop)"
            # steps > 0 guards against re-triggering immediately if `continue`
            # is called while already sitting on a breakpoint's address (e.g.
            # calling `continue` twice in a row) -- always make progress.
            if pc in self.breakpoints and steps > 0:
                return f"breakpoint hit @ pc={pc}"
            self.step_one()
            steps += 1
        return f"stopped: exceeded {max_steps} steps"

    def print_regs(self):
        w = self.reg_hex_digits
        for i in range(0, 32, 4):
            row = "  ".join(f"x{i+j:<2}=0x{self.iss.regs[i+j]:0{w}x}" for j in range(4))
            print(row)

    def print_csrs(self):
        for addr, name in CSR_BY_ADDR.items():
            print(f"  {name:<8} = {self.iss.csr[addr]:#010x}")

    def print_disas(self, n=5):
        pc = self.iss.pc
        for i in range(n):
            addr = pc + i * 4
            word = self.word_at(addr)
            marker = "-> " if i == 0 else "   "
            bp = "*" if addr in self.breakpoints else " "
            print(f"{marker}{bp}{addr:5d}: {word:08x}  {disasm(word, xlen=self.xlen)}")


HELP = """\
Commands:
  step [n]          execute n instructions (default 1)
  continue          run until a breakpoint, halt, or program end
  break <addr>      set a breakpoint at a byte address (multiple of 4)
  delete <addr>     remove a breakpoint
  breakpoints       list active breakpoints
  regs              dump all 32 registers
  reg <n>           show register xN
  mem <addr> [len]  dump `len` (default 16) bytes of data memory from `addr`
  csr               dump the 5 implemented CSRs
  disas [n]         disassemble n instructions starting at pc (default 5)
  pc                show the current pc
  restart           reset architectural state and start over
  history [n]       show the last n executed instructions (default 10)
  help              this message
  quit              exit
"""


def repl(dbg):
    print(f"Loaded {len(dbg.words)} instructions. Type `help` for commands.")
    dbg.print_disas(3)
    while True:
        try:
            line = input("(dbg) ").strip()
        except EOFError:
            print()
            return
        if not line:
            continue
        parts = line.split()
        cmd, args = parts[0], parts[1:]

        if cmd in ("q", "quit", "exit"):
            return
        elif cmd in ("h", "help"):
            print(HELP)
        elif cmd in ("s", "step"):
            n = int(args[0]) if args else 1
            for _ in range(n):
                if not dbg.step_one():
                    print("(end of program)")
                    break
            dbg.print_disas(1)
        elif cmd in ("c", "continue"):
            status = dbg.run_until()
            print(status)
            if not dbg.at_end():
                dbg.print_disas(1)
        elif cmd == "break":
            if not args:
                print("usage: break <addr>")
                continue
            dbg.breakpoints.add(int(args[0], 0))
        elif cmd == "delete":
            if not args:
                print("usage: delete <addr>")
                continue
            dbg.breakpoints.discard(int(args[0], 0))
        elif cmd == "breakpoints":
            print(sorted(dbg.breakpoints) or "(none)")
        elif cmd in ("r", "regs"):
            dbg.print_regs()
        elif cmd == "reg":
            if not args:
                print("usage: reg <n>")
                continue
            n = int(args[0])
            print(f"x{n} = 0x{dbg.iss.regs[n]:0{dbg.reg_hex_digits}x} ({dbg.iss.regs[n]})")
        elif cmd == "mem":
            if not args:
                print("usage: mem <addr> [len]")
                continue
            addr = int(args[0], 0)
            length = int(args[1]) if len(args) > 1 else 16
            chunk = bytes(dbg.iss.mem[addr:addr + length])
            print(" ".join(f"{b:02x}" for b in chunk))
        elif cmd == "csr":
            dbg.print_csrs()
        elif cmd == "disas":
            n = int(args[0]) if args else 5
            dbg.print_disas(n)
        elif cmd == "pc":
            print(dbg.iss.pc)
        elif cmd == "restart":
            dbg.reset()
            print("restarted")
            dbg.print_disas(3)
        elif cmd == "history":
            n = int(args[0]) if args else 10
            for pc, word in dbg.history[-n:]:
                print(f"   {pc:5d}: {word:08x}  {disasm(word, xlen=dbg.xlen)}")
        else:
            print(f"unknown command {cmd!r} -- type `help`")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("program", help=".s (assembled on the fly) or pre-assembled .mem file")
    ap.add_argument("--mem-size", type=int, default=128)
    ap.add_argument("--xlen", type=int, default=32,
                     help="Generation 2 (docs/adr/0028-rv64-migration-phase-m.md): 32 or 64")
    args = ap.parse_args()

    words = assemble_if_needed(args.program, args.mem_size, args.xlen)
    dbg = Debugger(words, args.mem_size, args.xlen)
    repl(dbg)


if __name__ == "__main__":
    main()
