`include "riscvpipeline.v"
`include "Scoreboard.v"
`include "MemoryController.v"
`include "CompressedExpander.v"
`include "PC.v"
`include "Adder.v"
`include "ALU.v"
`include "ALUCtrl.v"
`include "Control.v"
`include "DataMemoryBRAM.v"
`include "ImmGen.v"
`include "InstructionMemory.v"
`include "Mux2to1.v"
`include "Mux4to1.v"
`include "MuxN.v"
`include "FRegister.v"
`include "FALU.v"
`include "FDivider.v"
`include "FSqrt.v"
`include "FMADDUnit.v"
`include "Register.v"
`include "ShiftLeftOne.v"
`include "reg1.v"
`include "reg1a.v"
`include "reg2.v"
`include "reg3.v"
`include "reg4.v"
`include "Hazard.v"
`include "HazardNoForward.v"
`include "Forward.v"
`include "FForward.v"
`include "Divider.v"
`include "CSR.v"
`include "WbDecoder.v"
`include "RamWishboneAdapter.v"
`include "Uart.v"
`include "Timer.v"
`include "Tlb.v"
`include "Ptw.v"
`include "Tlb39.v"
`include "Ptw39.v"
`include "Bht.v"
`include "Btb.v"

// docs/adr/0025-hpc-performance-csrs.md (Phase J7). mcountinhibit gating,
// confirmed via before/after snapshots rather than exact absolute values
// (robust against off-by-one cycle counting): sim/programs/
// perf_countinhibit_j7.s inhibits mcycle/minstret/mhpmcounter3 together
// (bits 0,2,3), executes a real branch + filler while inhibited, then
// re-enables and executes another real branch + filler. Confirmed against
// a cycle-by-cycle debug trace before committing to these exact
// checkpoints: mcountinhibit reads back 13 (0xD) for the whole window
// [t=55,t=105], during which mcycle/minstret/mhpmcounter3 are completely
// flat (4/1/0) -- the first branch's own retirement pulse genuinely fires
// in that window but is correctly blocked by mhpmcounter3's own inhibit
// bit, not just "nothing happened yet". By t=200 (well after re-enable
// and the second branch), all three have visibly advanced.
module tb_perf_countinhibit_j7;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/perf_countinhibit_j7.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    reg [31:0] mcycle_a, minstret_a, mhc3_a;
    reg [31:0] mcycle_b, minstret_b, mhc3_b;
    reg [31:0] mcycle_c, minstret_c, mhc3_c;

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #80;   // t=90, comfortably inside the inhibited window
        mcycle_a = dut.m_CSR.mcycle_lo; minstret_a = dut.m_CSR.minstret_lo; mhc3_a = dut.m_CSR.mhpmcounter_lo[0];
        check_val(dut.m_CSR.mcountinhibit, 32'h00000D, "mcountinhibit reads back 0xD while inhibited");

        #10;   // t=100, still inside the inhibited window
        mcycle_b = dut.m_CSR.mcycle_lo; minstret_b = dut.m_CSR.minstret_lo; mhc3_b = dut.m_CSR.mhpmcounter_lo[0];
        check_val(mcycle_b, mcycle_a, "mcycle_lo frozen while mcountinhibit[0] set");
        check_val(minstret_b, minstret_a, "minstret_lo frozen while mcountinhibit[2] set");
        check_val(mhc3_b, mhc3_a, "mhpmcounter3 frozen while mcountinhibit[3] set (first branch's pulse correctly blocked)");

        #100;  // t=200, well after re-enable and the second branch
        mcycle_c = dut.m_CSR.mcycle_lo; minstret_c = dut.m_CSR.minstret_lo; mhc3_c = dut.m_CSR.mhpmcounter_lo[0];
        check_val(dut.m_CSR.mcountinhibit, 32'h000000, "mcountinhibit reads back 0 after re-enable");

        total_checks = total_checks + 1;
        if (mcycle_c <= mcycle_b) begin
            total_fails = total_fails + 1;
            $display("  FAIL  mcycle_lo did not resume after re-enable: %0d -> %0d", mcycle_b, mcycle_c);
        end else $display("  pass  mcycle_lo resumed after re-enable: %0d -> %0d", mcycle_b, mcycle_c);

        total_checks = total_checks + 1;
        if (minstret_c <= minstret_b) begin
            total_fails = total_fails + 1;
            $display("  FAIL  minstret_lo did not resume after re-enable: %0d -> %0d", minstret_b, minstret_c);
        end else $display("  pass  minstret_lo resumed after re-enable: %0d -> %0d", minstret_b, minstret_c);

        total_checks = total_checks + 1;
        if (mhc3_c <= mhc3_b) begin
            total_fails = total_fails + 1;
            $display("  FAIL  mhpmcounter3 did not resume after re-enable: %0d -> %0d", mhc3_b, mhc3_c);
        end else $display("  pass  mhpmcounter3 resumed after re-enable (second branch counted): %0d -> %0d", mhc3_b, mhc3_c);

        report("perf_countinhibit_j7");
        $finish;
    end
endmodule
