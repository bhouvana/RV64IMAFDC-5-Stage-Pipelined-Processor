`include "riscvpipeline.v"
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

// docs/adr/0023-caches.md (Phase G1). Directed test for Control.v's fence
// decode -- zero live effect yet (G6's job), so coverage stays decode-only
// (sticky hierarchical taps), same technique tb_mmu_decode_f2.v used for
// sfence.vma. Confirms fence falls through normally (twice, mid-stream)
// instead of illegal-instruction-trapping, and that x10's marker chain
// reaches its expected final value.
module tb_fence_decode_g1;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/fence_decode_g1.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    reg seen_fence = 0;
    reg seen_illegal = 0;
    always @(posedge clk) begin
        if (dut.isFence_regde) seen_fence <= 1;
        if (dut.illegalOpcode_regde) seen_illegal <= 1;
    end

    initial begin
        start = 0;
        #10 start = 1;
        #200;

        check_reg(10, 32'd3, "x10 = 3: both fences fell through (markers 1+2+3 all executed)");

        total_checks = total_checks + 1;
        if (seen_fence !== 1'b1) begin
            total_fails = total_fails + 1;
            $display("  FAIL  fence never decoded (isFence_regde stayed 0 throughout)");
        end else $display("  pass  fence decoded correctly (isFence_regde seen)");

        total_checks = total_checks + 1;
        if (seen_illegal !== 1'b0) begin
            total_fails = total_fails + 1;
            $display("  FAIL  illegalOpcode fired somewhere -- fence must never trap");
        end else $display("  pass  illegalOpcode never fired");

        report("fence_decode_g1");
        $finish;
    end
endmodule
