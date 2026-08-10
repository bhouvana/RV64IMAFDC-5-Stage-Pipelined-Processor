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

// Closes the "each of blt/bge/ble/bgt/bltu/bgeu only has one branch
// direction covered" gap flagged in ARCHITECTURE.md section 15 / the
// ROADMAP status log -- see sim/programs/branch_dir_gaps.s.
module tb_branch_dir_gaps;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/branch_dir_gaps.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #800;

        check_reg(3, 32'd1, "bltu taken (1 unsigned is < 0xFFFFFFFF)");
        check_reg(4, 32'd1, "bgeu not taken (1 unsigned is not >= 0xFFFFFFFF)");
        check_reg(5, 32'd1, "blt not taken (1 signed is not < -1)");
        check_reg(6, 32'd1, "bge taken (1 signed is >= -1)");
        check_reg(7, 32'd1, "ble not taken (1 signed is not <= -1, custom op)");
        check_reg(8, 32'd1, "bgt taken (1 signed is > -1, custom op)");

        report("branch_dir_gaps");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
