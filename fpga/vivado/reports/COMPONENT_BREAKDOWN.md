# Component resource breakdown (Phase 7)

## Scope, honestly stated up front

The original goal (per the workflow plan) was to break down `OOOCore`'s
resource usage by major sub-block (ROB, reservation stations, physical
register file, LSQ, vector unit, crypto ALU logic, branch predictor,
caches, MMU) using `report_utilization -hierarchical` against the routed
`ooo` config, and to read Vector (V)'s specific hardware cost off the
named `m_VALU`/`m_VLSU` instances.

**That data does not exist.** `OOOCore` synthesis hangs reproducibly and
never completes -- see `fpga/vivado/AUDIT.md`'s addendum and
`fpga/vivado/reports/SWEEP_LOG.md`'s `ooo` section for the full diagnostic
trail. There is no routed (or even synthesized) `OOOCore` netlist to run
`report_utilization -hierarchical` against. B and K were never
independently isolable in the first place (no `ifdef` guard, shared ALU
case-statement logic -- see `fpga/vivado/AUDIT.md`'s main body), so even a
successful `ooo` build would only have shown V's cost directly, not B's or
K's.

## What real data does exist: `inorder` (PIPELINED) hierarchy

`fpga/vivado/reports/inorder/100mhz/impl_utilization_hierarchical.rpt`,
routed, real:

| Instance | Module | Total LUTs | Logic LUTs | LUTRAMs | FFs | BRAM | DSP |
|---|---|---:|---:|---:|---:|---:|---:|
| PIPELINED (top) | -- | 215 | 201 | 14 | 556 | 0 | 0 |
| `gen_mmu_ptw_sv32.m_Ptw` | Ptw | 92 | 92 | 0 | 31 | 0 | 0 |
| `m_CSR` | CSR | 14 | 14 | 0 | 65 | 0 | 0 |
| `m_Register` | Register | 1 | 1 | 0 | 224 | 0 | 0 |
| `m_Timer` | Timer | 1 | 1 | 0 | 64 | 0 | 0 |

Only 4 sub-instances appear as separate rows; everything else (`ALU`,
`Divider`, `FDivider`, `FALU`, `ICache`, `DCache`, branch predictor,
`Uart`, etc.) got fully absorbed into the top-level `PIPELINED` bucket by
Vivado's synthesis optimizer -- expected behavior for a design this small
(215 LUTs total) on a device this large (203,800 LUTs available, 0.11%
utilized): cross-hierarchy LUT combining flattens small blocks rather than
keeping them as separately-reportable instances. `m_Register` (the
architectural register file, 32×32-bit) dominates flip-flop count (224 of
556, 40%) -- unsurprising, it's the one structure whose size scales
directly with register count regardless of how simple the rest of the
pipeline's control logic is.

## Honest conclusion

This workflow answers "how big is the in-order core, and roughly where do
its registers live" with real data. It does **not** answer "what does
Vector/B/K/OoO scheduling cost in hardware" -- that would need `OOOCore`
to actually synthesize, which it doesn't in this environment. Presenting
the `inorder` table above as if it said anything about Gen6/Gen7 hardware
cost would be exactly the kind of fabrication the workflow's own integrity
rules forbid; it doesn't, and this document says so.
