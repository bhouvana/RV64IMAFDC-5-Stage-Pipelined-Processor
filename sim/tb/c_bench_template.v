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

// Template for real compiled-C programs (docs/ROADMAP.md Phase 10 --
// CoreMark/Dhrystone, following up on the hand-written sim/benchmarks/
// bench_*.s kernels). Combines bench_template.v's generic halt-detecting
// cycle count with dump_regs_template.v's final-state dump: compiled
// programs have no UART/printf on this core (see sim/benchmarks/c/'s
// README), so the only way to get a result out -- main()'s return value
// in x10/a0 per the standard RISC-V calling convention, or e.g. CoreMark's
// results[0].crc sitting at a known data-memory address -- is reading
// architectural state directly after the program halts, the same way
// every other tool in this repo that needs final state already does.
//
// __INIT_FILE__/__DATA_INIT_FILE__/__MEM_SIZE__/__MAX_TIME__/
// __CYCLES_OUT_FILE__/__STATE_OUT_FILE__/__HAZARD_STRATEGY__ substituted
// per run.
module c_bench_run;
    reg clk = 0;
    reg start = 0;
    integer fd;
    integer cycle_count;
    reg done;
    integer i;

    PIPELINED #(
        .INIT_FILE("__INIT_FILE__"),
        .DATA_INIT_FILE("__DATA_INIT_FILE__"),
        .MEM_SIZE_BYTES(__MEM_SIZE__),
        .HAZARD_STRATEGY(__HAZARD_STRATEGY__)
    ) dut(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    initial begin
        start = 0;
        cycle_count = 0;
        done = 0;
        #10 start = 1;
    end

    always @(posedge clk) begin
        if (start && !done) begin
            cycle_count = cycle_count + 1;
            // Generic "reached its own halt spin loop" detection -- see
            // bench_template.v's header comment for the full reasoning.
            if (dut.unconditional_redirect && (dut.redirect_target == dut.pc_o_regde)) begin
                done = 1;
                fd = $fopen("__CYCLES_OUT_FILE__", "w");
                $fdisplay(fd, "%0d", cycle_count);
                $fclose(fd);

                fd = $fopen("__STATE_OUT_FILE__", "w");
                for (i = 0; i < 32; i = i + 1)
                    $fdisplay(fd, "%0d", dut.m_Register.regs[i]);
                for (i = 0; i < __MEM_SIZE__; i = i + 1)
                    $fdisplay(fd, "%0d", dut.m_DataMemory.m_ram.data_memory[i]);
                $fclose(fd);

                $finish;
            end
        end
    end

    initial begin
        #__MAX_TIME__;
        if (!done) begin
            $display("TIMEOUT: __INIT_FILE__ never reached its halt loop within __MAX_TIME__ time units");
            $finish;
        end
    end
endmodule
