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

module tb_arith;
    `include "check_tasks.vh"
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/arith.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #800;

        check_reg(1,  32'd5,          "addi x1,x0,5");
        check_reg(2,  32'd3,          "addi x2,x0,3");
        check_reg(3,  32'd8,          "add x3,x1,x2");
        check_reg(4,  32'd2,          "sub x4,x1,x2");
        check_reg(5,  32'd40,         "sll x5,x1,x2");
        check_reg(6,  32'd1,          "slt x6,x2,x1");
        check_reg(7,  32'd0,          "sltu x7,x1,x2");
        check_reg(8,  32'd6,          "xor x8,x1,x2");
        check_reg(9,  32'd5,          "srl x9,x5,x2");
        check_reg(10, 32'd5,          "sra x10,x5,x2 (positive)");
        check_reg(11, 32'd7,          "or x11,x1,x2");
        check_reg(12, 32'd1,          "and x12,x1,x2");
        check_reg(13, 32'hFFFFFFFF,   "addi x13,x0,-1");
        check_reg(14, 32'h0FFFFFFF,   "srli x14,x13,4 (logical)");
        check_reg(15, 32'hFFFFFFFF,   "srai x15,x13,4 (arithmetic, sign preserved)");
        check_reg(16, 32'd20,         "slli x16,x1,2");
        check_reg(17, 32'd1,          "slti x17,x2,10");
        check_reg(18, 32'd0,          "sltiu x18,x1,3");
        check_reg(19, 32'd6,          "xori x19,x1,3");
        check_reg(20, 32'd7,          "ori x20,x1,3");
        check_reg(21, 32'd1,          "andi x21,x1,3");
        check_reg(22, 32'd32,         "ctz x22,x23 (x23=0 -> ctz=32, fixed off-by-one, docs/adr/0041)");

        report("arith");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
