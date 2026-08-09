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
// sim/programs/interrupt_priority.s arms both interrupt sources so they are
// simultaneously pending and enabled by the time mstatus.MIE is set. A
// small CLKS_PER_BIT (2, vs. the 4 most other testbenches use) is
// deliberately picked here so the driven byte's full serial frame (10 bit
// periods) finishes comfortably before the .s file's own setup + spacer
// NOPs complete, guaranteeing mip.MEIP is genuinely pending -- not a race
// -- alongside mip.MTIP (pending almost immediately regardless, MTIMECMP=5)
// by the time mstatus.MIE is armed. Confirms the spec-mandated
// machine-external-over-machine-timer priority: mcause must show the
// external cause code, not the timer one.
module tb_interrupt_priority;
    localparam CLKS_PER_BIT = 2;

    reg clk = 0;
    reg start = 0;
    reg uart_rx = 1;
    wire uart_tx;

    PIPELINED #(.INIT_FILE("sim/programs/interrupt_priority.mem"), .UART_CLKS_PER_BIT(CLKS_PER_BIT))
        dut(.clk(clk), .start(start), .uart_rx(uart_rx), .uart_tx(uart_tx));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    task drive_rx_byte;
        input [7:0] byte_in;
        integer k;
        begin
            uart_rx = 0;
            repeat (CLKS_PER_BIT) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_rx = byte_in[k];
                repeat (CLKS_PER_BIT) @(posedge clk);
            end
            uart_rx = 1;
            repeat (CLKS_PER_BIT) @(posedge clk);
        end
    endtask

    initial begin
        start = 0;
        #10 start = 1;
        repeat (2) @(posedge clk);
        drive_rx_byte(8'hAA);   // fully arrives (~20 cycles) well before the .s file's setup+spacers do

        #1000;

        check_reg(11, 32'd555, "x11 = 555: a handler ran");
        check_val(dut.m_CSR.mcause, 32'h8000000B,
                   "mcause = 0x8000000B (external, cause 11) -- MEI takes priority over MTI when both pend");

        report("interrupt_priority");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
