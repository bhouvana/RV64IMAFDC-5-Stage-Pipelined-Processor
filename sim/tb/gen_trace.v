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
`include "reg2.v"
`include "reg3.v"
`include "reg4.v"
`include "Hazard.v"
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
`include "reg1a.v"

// Emits one CSV row per cycle to trace.csv -- every field here is read
// directly off a real DUT signal, nothing is inferred/reconstructed. Used
// by sim/tools/gen_trace.py to build the interactive pipeline viewer.
// Columns:
//   cycle,
//   if_pc,if_inst,
//   id_pc,id_inst,stall,flush,
//   ex_pc,ex_inst,branch_taken,jump,alu_out,forwardA,forwardB,
//   mem_we,mem_re,mem_addr,mem_dest,mem_regwrite,
//   wb_dest,wb_val,wb_regwrite
module gen_trace;
    // Mirrors PIPELINED's own PIPELINE_PROFILE parameter (docs/adr/0018) so it
    // can be overridden the same documented way (e.g.
    // `iverilog -Pgen_trace.PIPELINE_PROFILE=1 ...`) instead of hand-editing
    // this file. Default 0 (PROFILE_5STAGE) -- see the guard below for why
    // anything else is refused rather than attempted.
    parameter PIPELINE_PROFILE = 0;

    reg clk = 0;
    reg start = 0;
    integer fd;
    integer cycle;

    PIPELINED #(.INIT_FILE("sim/programs/demo.mem"), .PIPELINE_PROFILE(PIPELINE_PROFILE)) dut(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    initial begin
        // This tracer's CSV schema is hardcoded to exactly 5 named stages
        // (IF/ID/EX/MEM/WB) end-to-end -- sim/tools/gen_trace.py's column
        // parsing and sim/tools/viewer_template.html's STAGE_LABELS map and
        // `repeat(5, ...)` grid all assume it. PROFILE_6STAGE_SPLIT_FETCH adds
        // a real extra pipeline register (reg1a) this schema has no column
        // for, so tracing it here would silently produce a trace that looks
        // complete but is missing/misattributing a real stage. Refuse
        // loudly instead of doing that; full viewer rework for variable
        // stage counts is out of scope (docs/adr/0018, Phase A4).
        if (PIPELINE_PROFILE != 0) begin
            $fatal(1, "gen_trace.v: PIPELINE_PROFILE=%0d is not supported -- the pipeline viewer's trace format is hardcoded to PROFILE_5STAGE (0). See docs/adr/0018-variable-pipeline-depth.md.", PIPELINE_PROFILE);
        end
        fd = $fopen("trace.csv", "w");
        $fwrite(fd, "cycle,if_pc,if_inst,id_pc,id_inst,stall,flush,ex_pc,ex_inst,branch_taken,jump,alu_out,forwardA,forwardB,mem_we,mem_re,mem_addr,mem_dest,mem_regwrite,wb_dest,wb_val,wb_regwrite\n");
        cycle = 0;
        start = 0;
        #10 start = 1;
        #500;
        $fclose(fd);
        $finish;
    end

    always @(posedge clk) begin
        if (start) begin
            cycle = cycle + 1;
            $fwrite(fd, "%0d,%0d,%h,%0d,%h,%0d,%0d,%0d,%h,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d\n",
                cycle,
                dut.pc_o, dut.inst,
                dut.pc_o_regfd, dut.inst_regfd, dut.stall, dut.flush,
                dut.pc_o_regde, dut.inst_regde, dut.branch_taken, dut.jump_regde, dut.ALUOut, dut.forwardA, dut.forwardB,
                dut.memWrite_regem, dut.memRead_regem, dut.ALUOut_regem, dut.write_to_Reg_regem, dut.regWrite_regem,
                dut.write_to_Reg_regwb, dut.writeData_regwb, dut.regWrite_regwb);
        end
    end
endmodule
