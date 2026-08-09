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

// docs/adr/0020-soc-integration.md (Phase D5). First live-pipeline UART
// exercise: real lw/sw instructions (sim/programs/uart_polled.s) target
// the UART's MMIO address, with software polling STATUS the way real
// polled-I/O code would (no interrupt path exists yet -- D8/D9's job).
// A background process plays the external-receiver role, continuously
// watching the DUT's uart_tx pin and decoding every frame it sees (the
// CPU's own polling loop runs concurrently, real wall-clock time, same as
// tb_uart_unit.v's decode approach but now driven by actual instructions
// instead of direct bus pokes); a second background process drives
// uart_rx with one hand-built serial frame shortly after reset, which the
// program's own RX polling loop picks up whenever it naturally gets there.
module tb_uart_polled;
    localparam CLKS_PER_BIT = 4;

    reg clk = 0;
    reg start = 0;
    reg uart_rx = 1;
    wire uart_tx;

    PIPELINED #(.INIT_FILE("sim/programs/uart_polled.mem"), .UART_CLKS_PER_BIT(CLKS_PER_BIT))
        dut(.clk(clk), .start(start), .uart_rx(uart_rx), .uart_tx(uart_tx));
    `include "check_tasks.vh"

    always #5 clk = ~clk;

    // Background external-receiver role: decode every byte the DUT
    // transmits into a small history the checks below inspect.
    reg [7:0] decoded_tx_byte;
    reg decoded_tx_valid = 0;
    integer i;
    always begin
        @(negedge uart_tx);
        #(CLKS_PER_BIT * 10 / 2);  // sample the start bit's midpoint
        for (i = 0; i < 8; i = i + 1) begin
            #(CLKS_PER_BIT * 10);
            decoded_tx_byte[i] = uart_tx;
        end
        #(CLKS_PER_BIT * 10);  // stop bit
        decoded_tx_valid = 1;
    end

    // Background external-transmitter role: drive one frame into uart_rx
    // shortly after reset -- the program's own polling loop picks it up
    // whenever it gets there, no tight synchronization needed.
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
        repeat (20) @(posedge clk);   // let reset settle, past the program's TX write
        drive_rx_byte(8'h5A);

        #4000;

        total_checks = total_checks + 1;
        if (!decoded_tx_valid) begin
            total_fails = total_fails + 1;
            $display("  FAIL  UART TX: no frame ever decoded on uart_tx");
        end else if (decoded_tx_byte !== 8'hA5) begin
            total_fails = total_fails + 1;
            $display("  FAIL  UART TX: decoded 0x%02h, expected 0xa5", decoded_tx_byte);
        end else begin
            $display("  pass  UART TX: software wrote TXDATA=0xa5, decoded serial output = 0x%02h", decoded_tx_byte);
        end

        check_reg(6, 32'h0000005A, "UART RX: software polled STATUS.rx_ready then read RXDATA into x6");

        report("uart_polled");
        $finish;
    end
endmodule
