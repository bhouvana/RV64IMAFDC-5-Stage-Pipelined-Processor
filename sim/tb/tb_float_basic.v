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

// docs/adr/0019-f-extension.md (Phase C6): first end-to-end exercise of the
// live float datapath -- fmv.w.x/fmv.x.w (bit-pattern moves), fadd.s/fmul.s
// (single-cycle FALU.v path), fdiv.s/fsqrt.s (multi-cycle interlocked
// units), fmadd.s (R4-type FMADDUnit.v), feq.s/flt.s/fle.s (float-reads,
// int-writes), fcvt.w.s, and flw/fsw (float loads/stores). Hand-encoded via
// asm.py's `word` escape hatch (real F-mnemonic assembler support is C9) --
// see the encodings in sim/programs/float_basic.s's comments.
module tb_float_basic;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/float_basic.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        // The conservative C6h float_hazard_stall fully drains the pipeline
        // between every float-writing instruction (real forwarding is C7),
        // and fdiv.s/fsqrt.s each take dozens of cycles on top of that --
        // budget generously, same rationale as tb_muldiv.v's #5000.
        #6000;

        check_freg(1, 32'h40400000, "fmv.w.x f1,x1 = 3.0");
        check_freg(2, 32'h40800000, "fmv.w.x f2,x2 = 4.0");
        check_freg(3, 32'h40e00000, "fadd.s f3 = 3.0+4.0 = 7.0");
        check_freg(4, 32'h41400000, "fmul.s f4 = 3.0*4.0 = 12.0");
        check_freg(5, 32'h3f400000, "fdiv.s f5 = 3.0/4.0 = 0.75");
        check_freg(6, 32'h40000000, "fsqrt.s f6 = sqrt(4.0) = 2.0");
        check_freg(8, 32'h41500000, "fmadd.s f8 = 3.0*4.0+1.0 = 13.0");

        check_reg(11, 32'h40e00000, "fmv.x.w x11 = bits of f3 (7.0)");
        check_reg(12, 32'h41400000, "fmv.x.w x12 = bits of f4 (12.0)");
        check_reg(13, 32'h3f400000, "fmv.x.w x13 = bits of f5 (0.75)");
        check_reg(14, 32'h40000000, "fmv.x.w x14 = bits of f6 (2.0)");
        check_reg(15, 32'h41500000, "fmv.x.w x15 = bits of f8 (13.0)");
        check_reg(16, 32'd3,        "fcvt.w.s x16 = (int)3.0");
        check_reg(17, 32'd1,        "feq.s x17 = (3.0==3.0)");
        check_reg(18, 32'd1,        "flt.s x18 = (3.0<4.0)");
        check_reg(19, 32'd0,        "fle.s x19 = (4.0<=3.0)");
        check_mem_word(64, 32'h40e00000, "fsw f3 -> mem[64] = 7.0's bits");
        check_reg(20, 32'h40e00000, "fmv.x.w x20 = bits of f9 (round-tripped through flw)");

        report("float_basic");
        $finish;
    end
endmodule
