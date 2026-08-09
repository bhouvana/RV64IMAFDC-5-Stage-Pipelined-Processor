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

// docs/adr/0021-branch-prediction.md (Phase E4). Pipeline-level directed
// test for BRANCH_PREDICTOR=PREDICTOR_DYNAMIC_BHT_BTB, using
// sim/programs/branch_predict.s's 5-iteration backward-branch loop (see
// that file's own header for the exact per-iteration state-transition
// story this test verifies). Two independent lines of evidence, both
// needed: (1) architectural correctness (x10/x11 end at the right values,
// same as any other directed test -- misprediction must never change a
// program's actual result), and (2) the actual point of this phase --
// mispredict fires on exactly the iterations it should (1, 2, 5) and stays
// silent on the two truly zero-bubble correctly-predicted iterations (3,
// 4), confirmed by tapping riscvpipeline.v's own internal `mispredict` wire
// via hierarchical reference every cycle `branch_regde` is live, the same
// technique this project's own bug hunts (D8/D11) already used, turned
// into a real check instead of a one-off $display.
module tb_branch_predictor;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/branch_predict.mem"), .BRANCH_PREDICTOR(1))
        dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    // Records dut.mispredict on every cycle the loop's bne is actually
    // resolving in EX (branch_regde high) -- one sample per loop iteration,
    // in program order, since this tiny program has no hold/stall source
    // that could hold the same bne in EX across multiple cycles.
    reg [4:0] mispredict_log = 5'b0;
    integer sample_count = 0;
    always @(posedge clk) begin
        if (dut.branch_regde && sample_count < 5) begin
            mispredict_log[sample_count] <= dut.mispredict;
            sample_count <= sample_count + 1;
        end
    end

    initial begin
        start = 0;
        #10 start = 1;
        // docs/adr/0025-hpc-performance-csrs.md (Phase J4). An early
        // checkpoint at t=270, BEFORE the original #400 one below --
        // confirmed against a cycle-by-cycle debug trace: all 5 real
        // branches resolve by t=245, but the mandatory `halt: jal x0,halt`
        // spin loop's own first iteration reaches EX at t=285 (and would
        // keep counting every further spin-loop retirement/misprediction
        // past this program's own interesting part, the same "genuine
        // event, not a repeat" pulse discipline as everywhere else in this
        // phase) -- also confirmed x11's own writeback (777) doesn't land
        // until t=295, *after* that first spin-loop jal, so this early
        // checkpoint can only check the new branch/mispredict counters,
        // not x11 (the original #400 checkpoint below still does that).
        #260;
        check_val(dut.m_CSR.mhpmcounter_lo[0], 32'd5, "mhpmcounter3 (branches retired, default event): 5");
        check_val(dut.m_CSR.mhpmcounter_lo[1], 32'd3, "mhpmcounter4 (mispredicts, default event): 3");
        #140;

        // Architectural correctness: unaffected by misprediction timing.
        check_reg(10, 32'd5, "x10 (loop accumulator) = 5: every iteration ran exactly once");
        check_reg(11, 32'd777, "x11 = 777: loop exited via correct fall-through, not skipped/duplicated");
        check_reg(1, 32'd0, "x1 (loop counter) = 0: final decrement landed correctly");

        total_checks = total_checks + 1;
        if (sample_count !== 5) begin
            total_fails = total_fails + 1;
            $display("  FAIL  expected exactly 5 branch_regde samples (one per loop iteration), got %0d", sample_count);
        end else begin
            $display("  pass  exactly 5 branch_regde samples captured (one per loop iteration)");
        end

        // Iteration 1: cold BHT+BTB miss (predict not-taken by default),
        // actual outcome taken -> mispredict.
        total_checks = total_checks + 1;
        if (mispredict_log[0] !== 1'b1) begin
            total_fails = total_fails + 1;
            $display("  FAIL  iteration 1: mispredict=%b, expected 1 (cold miss)", mispredict_log[0]);
        end else $display("  pass  iteration 1: mispredict=1 (cold miss, as expected)");

        // Iteration 2: BHT counter is 01 (weakly-not-taken) after exactly
        // one "taken" training -- predict_taken is the counter's MSB, so
        // this iteration STILL predicts not-taken and STILL mispredicts.
        total_checks = total_checks + 1;
        if (mispredict_log[1] !== 1'b1) begin
            total_fails = total_fails + 1;
            $display("  FAIL  iteration 2: mispredict=%b, expected 1 (counter still weakly-not-taken)", mispredict_log[1]);
        end else $display("  pass  iteration 2: mispredict=1 (counter still weakly-not-taken, as expected)");

        // Iterations 3-4: BHT counter is now >=10 (weakly/strongly-taken)
        // and Btb.v has a valid target from iteration 1's own training --
        // the entire point of this phase: correctly predicted, zero-bubble.
        total_checks = total_checks + 1;
        if (mispredict_log[2] !== 1'b0) begin
            total_fails = total_fails + 1;
            $display("  FAIL  iteration 3: mispredict=%b, expected 0 (correctly predicted, zero-bubble)", mispredict_log[2]);
        end else $display("  pass  iteration 3: mispredict=0 (correctly predicted, zero-bubble)");

        total_checks = total_checks + 1;
        if (mispredict_log[3] !== 1'b0) begin
            total_fails = total_fails + 1;
            $display("  FAIL  iteration 4: mispredict=%b, expected 0 (correctly predicted, zero-bubble)", mispredict_log[3]);
        end else $display("  pass  iteration 4: mispredict=0 (correctly predicted, zero-bubble)");

        // Iteration 5: the loop actually exits here (x1 reaches 0) -- BHT
        // still predicts taken (never yet seen a not-taken outcome), so
        // this is a real "predicted taken, actually not taken" misprediction,
        // recovered via the fall-through path (branch_or_jump_target).
        total_checks = total_checks + 1;
        if (mispredict_log[4] !== 1'b1) begin
            total_fails = total_fails + 1;
            $display("  FAIL  iteration 5: mispredict=%b, expected 1 (predicted taken, loop actually exits)", mispredict_log[4]);
        end else $display("  pass  iteration 5: mispredict=1 (predicted taken, loop actually exits, as expected)");

        report("branch_predictor");
        $finish;
    end
endmodule
