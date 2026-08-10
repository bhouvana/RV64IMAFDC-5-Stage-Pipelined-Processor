# ADR 0049: FreeList Alloc/Commit Split — Fixes the Gen6-L Deadlock (Gen6-M)

## Problem

`docs/adr/0048` (Gen6-L4) found and root-caused a real, reproducible deadlock in `design/OOOCore.v`:
`FreeList.v`'s `alloc_en0`/`alloc_en1` drove both the availability query (`alloc_ok0`/`alloc_ok1`,
which `dispatch_stall` needs combinationally, before the final `do_dispatch` decision exists) and the
actual pop (`head_r`/`count_r` mutation). Every cycle dispatch stalled for any unrelated reason
(ROB/RS/LSQ full, a store forcing `try_dual_issue` false) while `needs_dest` was also true silently
and permanently orphaned one physical register. A store followed by a WAW-renamed ALU instruction in
a sustained loop (>=8 iterations) exhausted the 32-entry free pool and hung dispatch forever
(`bench_sum_array.s` under `bench_runner.py --compare-ooo`).

## Design

`FreeList.v` gains `commit_en0`/`commit_en1` — genuinely separate from `alloc_en0`/`alloc_en1`.
`alloc_en`/`alloc_ok`'s own query semantics are unchanged (still unconditional on `do_dispatch`, still
what `dispatch_stall` reads); only the actual pop moves to `commit_en0`/`commit_en1`.
`design/OOOCore.v` wires `commit_en0`/`commit_en1` to each slot's own confirmed
`do_dispatch`/`do_dispatch_slot1` decision, for both `m_FreeList` (integer) and `m_FreeList_Float`.
A new `ifdef ASSERT_ON` check catches a caller asserting `commit_en` without `alloc_ok` having been
true the same cycle (a contract violation that would otherwise silently corrupt `count_r`).

No other module needed this fix — `PhysicalRegisterFile.v`'s own `alloc_en0`/`alloc_en1` (which clear
the `valid` bit for a freshly-allocated preg) were already correctly gated on `do_dispatch` in
`OOOCore.v`'s own instantiation; only `FreeList.v`'s pop had the bug.

## Testing

`tb_freelist_unit.v` gained 2 new cases directly reproducing and proving the fix: a query that
succeeds but whose commit is withheld must not consume the entry, and the same entry must still be
correctly retrievable on a later commit (no leak, no double-pop). 21/21 (up from 19/19).

`bench_sum_array.s` no longer hangs under `--compare-ooo`: was infinite, now 201 cycles, OOOCore
28.2% *faster* than PIPELINED on this kernel. `bench_fib.s` also improved substantially (330->186
cycles, now 13.9% faster than PIPELINED instead of 52.8% slower) — the same leak was silently
throttling even memory-op-free workloads whenever `dispatch_stall` held for any other reason (ROB/RS
room), just far less catastrophically than the store-triggered case. 35/35 constrained-random `--ooo`
seeds (`run_random_tests.py`) still match the ISS reference exactly. Full directed regression 123/123,
zero-warning compile.

## Future improvements

Everything ADR 0048's own Future improvements section still lists (jal/jalr/lui/auipc/csrrX
implementation, widening the ROB formal properties to full `mode prove`, more `--compare-ooo`
benchmarks once jal/jalr work, deep speculation, general AMO-RMW+SC, Sv39 MMU+interrupts, FDIV/FSQRT/
FMADD/FLW/FSW/FCVT/FCMP) remains open. This phase closed the one item flagged as highest-priority.
