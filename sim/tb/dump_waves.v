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

// Dumps every signal in the DUT (recursively, $dumpvars(0, dut)) to a real
// VCD file for viewing in a waveform tool (GTKWave, or any other VCD
// viewer) -- distinct from sim/tb/gen_trace.v, which extracts a curated
// subset of signals into a CSV for the web-based pipeline viewer
// (sim/tools/gen_trace.py). This is the "look at literally everything, the
// same way you would on real EDA tooling" complement to that, not a
// replacement for it. Same demo program (sim/programs/demo.s) so the two
// are directly comparable signal-for-signal.
module dump_waves;
    reg clk = 0;
    reg start = 0;

    PIPELINED #(.INIT_FILE("sim/programs/demo.mem")) dut(.clk(clk), .start(start), .uart_rx(1'b1));

    always #5 clk = ~clk;

    initial begin
        $dumpfile("build/demo.vcd");
        $dumpvars(0, dut);
        start = 0;
        #10 start = 1;
        #500;
        $finish;
    end
endmodule
