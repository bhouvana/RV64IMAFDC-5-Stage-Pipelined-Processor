`include "OOOCore.v"
`include "VALU.v"
`include "VLSU.v"
`include "InstructionMemory.v"
`include "Control.v"
`include "ALUCtrl.v"
`include "ImmGen.v"
`include "ALU.v"
`include "FALU.v"
`include "FDivider.v"
`include "FSqrt.v"
`include "RegisterAliasTable.v"
`include "FreeList.v"
`include "PhysicalRegisterFile.v"
`include "ReorderBuffer.v"
`include "ReservationStation.v"
`include "LoadStoreQueue.v"
`include "DataMemoryBRAM.v"
`include "Divider.v"
`include "Bht.v"
`include "Btb.v"
`include "CSR.v"
`include "Tlb39.v"
`include "Ptw39.v"

// Generation 7, Pillar K (Gen7-K7, docs/adr/0059/0067). Scalar-vs-hardware
// clmul benchmark, hardware half -- mirrors bench_clmul_scalar_cycles.v
// exactly, just against sim/benchmarks/crypto/bench_clmul_hw.s (3
// instructions, one real `clmul`) instead of the 7-instruction scalar
// sequence. Same expected x2=0xc8c8 final value.
module bench_clmul_hw_cycles;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 0;

    OOOCore #(
        .XLEN(64), .NUM_AREGS(32), .NUM_PREGS(64),
        .ROB_ENTRIES(16), .RS_ALU_ENTRIES(8),
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/benchmarks/crypto/bench_clmul_hw.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer cycles;
    reg [5:0] preg;
    reg [63:0] x2val;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;
        cycles = 0;
        forever begin
            @(posedge clk);
            cycles = cycles + 1;
            preg = dut.m_RAT.arch_map[5'd2];
            x2val = dut.m_PRF.regs[preg];
            if (x2val === 64'hc8c8) begin
                $display("PASS  bench_clmul_hw_cycles: x2=0x%h retired at cycle %0d", x2val, cycles);
                $finish;
            end
            if (cycles > 500) begin
                $display("FAIL  bench_clmul_hw_cycles: timeout, x2=0x%h", x2val);
                $finish;
            end
        end
    end
endmodule
