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
`include "Gshare.v"
`include "Chooser.v"

// docs/adr/0040-gshare-tournament-branch-predictor.md (Generation 4, Phase
// A). Pipeline-level directed test for BRANCH_PREDICTOR=PREDICTOR_GSHARE
// (2), using sim/programs/branch_predict_history.s's strictly-alternating
// branch pattern (see that file's own header). Architectural correctness
// only -- misprediction timing under GShare genuinely differs from BHT+BTB
// by design (docs/adr/0040's own Real bugs/findings section) and is not
// itself a pass/fail criterion here.
module tb_branch_predictor_gshare;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/branch_predict_history.mem"), .BRANCH_PREDICTOR(2))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #2000;

        check_reg(10, 32'd12, "x10 (iteration count) = 12: every iteration ran exactly once");
        check_reg(11, 32'd777, "x11 = 777: loop exited via correct fall-through, not skipped/duplicated");
        check_reg(12, 32'd6, "x12 (odd-parity count) = 6: the alternating branch took the correct arm every time");
        check_reg(1, 32'd0, "x1 (loop counter) = 0: final decrement landed correctly");

        report("branch_predictor_gshare");
        $finish;
    end
endmodule
