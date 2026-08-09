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

// docs/adr/00NN-mmu-sv32.md (Phase F2, updated for F3). Directed test for
// Control.v's sret/sfence.vma decode, and (as of F3) sret's real return-
// from-trap behavior -- see sim/programs/mmu_decode_f2.s's own header.
// sfence.vma still has zero live effect (F5's job), so its own coverage
// stays decode-only (sticky hierarchical taps, the same technique this
// project's own bug hunts use). sret now genuinely redirects and changes
// priv_mode -- confirmed by x10 stopping at exactly 4 (never reaching the
// unreachable-if-correct 5th marker) and priv_mode dropping to U (SPP's
// reset value) after the sret actually executes.
module tb_mmu_decode_f2;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/mmu_decode_f2.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    reg seen_sret = 0;
    reg seen_sfence_vma = 0;
    reg seen_illegal = 0;
    always @(posedge clk) begin
        if (dut.isSret_regde) seen_sret <= 1;
        if (dut.isSfenceVma_regde) seen_sfence_vma <= 1;
        if (dut.illegalOpcode_regde) seen_illegal <= 1;
    end

    initial begin
        start = 0;
        #10 start = 1;
        #300;

        check_reg(10, 32'd3, "x10 = 3: sret redirected to sepc (halt) instead of falling through to the 4th marker");

        total_checks = total_checks + 1;
        if (dut.m_CSR.priv_mode !== `PRIV_U) begin
            total_fails = total_fails + 1;
            $display("  FAIL  priv_mode after sret: %b, expected PRIV_U (SPP's reset value)", dut.m_CSR.priv_mode);
        end else $display("  pass  priv_mode after sret: PRIV_U (restored from SPP, reset default)");

        total_checks = total_checks + 1;
        if (seen_sret !== 1'b1) begin
            total_fails = total_fails + 1;
            $display("  FAIL  sret never decoded (isSret_regde stayed 0 throughout)");
        end else $display("  pass  sret decoded correctly (isSret_regde seen)");

        total_checks = total_checks + 1;
        if (seen_sfence_vma !== 1'b1) begin
            total_fails = total_fails + 1;
            $display("  FAIL  sfence.vma never decoded (isSfenceVma_regde stayed 0 throughout)");
        end else $display("  pass  sfence.vma decoded correctly, both forms (isSfenceVma_regde seen)");

        total_checks = total_checks + 1;
        if (seen_illegal !== 1'b0) begin
            total_fails = total_fails + 1;
            $display("  FAIL  illegalOpcode fired somewhere -- sret/sfence.vma must never trap");
        end else $display("  pass  illegalOpcode never fired");

        report("mmu_decode_f2");
        $finish;
    end
endmodule
