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

// docs/adr/0019-f-extension.md (Phase C7): exercises FForward.v's actual
// forwarding paths with back-to-back dependent float instructions (no
// C6-style stall-drain between them), rather than tb_float_basic.v's more
// spread-out sequence. Covers: EX/MEM forward into rs1/rs2, MEM/WB forward
// into rs1/rs2, both sources forwarding into the *same* instruction at
// once, EX/MEM and MEM/WB forward into rs3 (the R4-type FMADD-family read
// port FForward.v alone among the forwarding units needs), the flw
// load-use hazard still correctly stalling (forwarding cannot resolve a
// load's data one cycle early), and float/integer instructions sharing a
// numeric register index interleaved back-to-back without cross-file
// contamination. See sim/programs/float_forward.s's per-instruction
// comments for exactly which forwarding path each one is targeting.
module tb_float_forward;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/float_forward.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #2000;

        check_freg(3,  32'h40c00000, "fadd.s f3=f1+f2 -- f1 MEM/WB fwd, f2 EX/MEM fwd -- 6.0");
        check_freg(4,  32'h42100000, "fmul.s f4=f3*f3 -- both operands EX/MEM fwd -- 36.0");
        check_freg(5,  32'h42280000, "fadd.s f5=f4+f3 -- f4 EX/MEM fwd, f3 MEM/WB fwd -- 42.0");
        check_freg(7,  32'h41400000, "fmadd.s f7=f1*f2+f6 -- rs3(f6) EX/MEM fwd -- 12.0");
        check_freg(9,  32'h41400000, "fmadd.s f9=f1*f2+f8 -- rs3(f8) MEM/WB fwd -- 12.0");
        check_freg(11, 32'h40c00000, "fadd.s f11=f10+f10 -- flw load-use hazard correctly stalled -- 6.0");
        check_reg(6,   32'd200,      "add x6=x5+x5 -- integer fwd unaffected by interleaved float op");
        check_freg(12, 32'h40c00000, "fadd.s f12=f13+f13 -- f13 (float idx 13) MEM/WB fwd, no cross-file contamination from x13 -- 6.0");

        report("float_forward");
        $finish;
    end
endmodule
