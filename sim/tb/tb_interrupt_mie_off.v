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

// docs/adr/0020-soc-integration.md (Phase D9). Directed test:
// sim/programs/interrupt_mie_off.s enables both mie.MTIE and mie.MEIE, and
// mip.MTIP is genuinely pending from reset onward (Timer.v resets with
// mtime=0/mtimecmp=0), but mstatus.MIE is never set -- stays 0 the whole
// run. Confirms interrupt_taken's top-level `mstatus_mie &` gate actually
// blocks a real, live-pending, enabled interrupt: the loop runs to
// completion untouched and the handler never executes.
module tb_interrupt_mie_off;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/interrupt_mie_off.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    initial begin
        start = 0;
        #10 start = 1;
        #1500;

        check_reg(10, 32'd20,  "x10 = 20: the full loop ran, completely untouched by the pending-but-disabled interrupt");
        check_reg(11, 32'd0,   "x11 = 0 (reset value): the handler never ran");
        check_val(dut.m_CSR.mcause, 32'd0, "mcause = 0 (reset value): no trap was ever taken");
        check_val(dut.m_CSR.mepc, 32'd0,   "mepc = 0 (reset value): never written");
        check_val(dut.m_CSR.mstatus, 32'h00, "mstatus stays 0 -- MIE was never set by this program");

        report("interrupt_mie_off");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
