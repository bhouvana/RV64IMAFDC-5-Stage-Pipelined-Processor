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

// docs/adr/0019-f-extension.md (Phase C8): fcsr (frm + fflags) fully live.
// Covers: RM_DYN resolution actually reading CSR.v's live frm (same
// fcvt.w.s(2.5) computed twice with a different frm each time, since
// round-to-nearest-even and round-up disagree on that exact input), a
// static (non-DYN) rm staying unaffected by frm's current value, sticky
// fflags accumulation from a real exception (fdiv.s by zero -> DZ) without
// any explicit csrrX write, a later *exact* op not clobbering that sticky
// bit (OR, not overwrite), an explicit software csrrwi clear, and the
// fcsr packed {frm,fflags} view reading/writing consistently with frm/
// fflags addressed individually.
module tb_float_fcsr;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/float_fcsr.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #2000;

        check_reg(5,  32'd3, "fcvt.w.s x5,f1,dyn -- frm=RUP -- ceil(2.5)=3");
        check_reg(6,  32'd2, "fcvt.w.s x6,f1,dyn -- frm=RNE -- round-to-even(2.5)=2");
        check_reg(14, 32'd3, "fcvt.w.s x14,f1,rup (static) -- ceil(2.5)=3 regardless of frm");
        // NX is already set going into the fdiv.s: fcvt.w.s of 2.5 (all
        // three conversions above, dyn and static alike) is inherently
        // inexact -- 2.5 has no exact integer representation under any
        // rounding mode -- so NX accumulates before DZ does. DZ joins it
        // (sticky-OR, not overwrite) once the divide-by-zero executes.
        check_reg(7,  32'h00000009, "fflags after fdiv.s by zero -- DZ|NX (NX already set by the fcvt.w.s ops above)");
        check_reg(10, 32'h00000009, "fflags unchanged by a later exact op -- still DZ|NX");
        check_reg(11, 32'h00000000, "fflags after explicit csrrwi clear");
        check_reg(15, 32'd3,        "frm reads back 3 (RUP) after fcsr <- x13");
        check_reg(16, 32'h0000000d, "fflags reads back 0x0d after fcsr <- x13");
        check_reg(17, 32'h0000006d, "fcsr packed reads back {frm,fflags} = 0x6d");

        report("float_fcsr");
        $finish;
    end
endmodule
