# docs/adr/0043-memory-controller-phase-d.md (Generation 4, Phase D). Single
# write-allocate miss at the default D$ line size (4 words/16B) -- forces
# exactly one real multi-word fill. tb_memctrl_burst_d1.v runs this SAME
# program through two PIPELINED instances at the same nonzero MEM_LATENCY_D
# -- one BURST_ENABLE(0), one BURST_ENABLE(1) with a cheaper
# MEM_LATENCY_D_BURST -- and asserts the burst-enabled run completes in
# strictly fewer real cycles: the actual measurable win this phase
# delivers (unlike the victim cache's own honest zero-delta).
addi x1, x0, 100
sw   x1, 0(x0)
fence
halt:
jal x0, halt
