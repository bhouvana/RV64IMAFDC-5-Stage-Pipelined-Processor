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

// docs/adr/0019-f-extension.md (Phase C9): exercises all four R4-type
// MADD-family ops (fmadd.s/fmsub.s/fnmsub.s/fnmadd.s), not just fmadd.s --
// closes a real gap C6/C7/C8's directed tests all shared (every one of
// them only ever used fmadd.s). Regression test for the Phase C9 bugfix:
// riscvpipeline.v's fma_op_regde originally sliced opcode[4:3], which is
// 00 for both fmadd.s and fmsub.s and 01 for both fnmsub.s and fnmadd.s
// (bit4 is 0 for all four MADD-family opcodes) -- silently aliasing
// fmsub.s with fmadd.s and fnmadd.s with fnmsub.s. Fixed to opcode[3:2],
// the bits that actually distinguish all four.
module tb_float_madd_family;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/float_madd_family.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #500;

        check_freg(10, 32'h41500000, "fmadd.s  f1*f2+f3 =  3*4+1  =  13.0");
        check_freg(11, 32'h41300000, "fmsub.s  f1*f2-f3 =  3*4-1  =  11.0");
        check_freg(12, 32'hc1300000, "fnmsub.s -(f1*f2)+f3 = -12+1 = -11.0");
        check_freg(13, 32'hc1500000, "fnmadd.s -(f1*f2)-f3 = -12-1 = -13.0");

        report("float_madd_family");
        $finish;
    end
endmodule
