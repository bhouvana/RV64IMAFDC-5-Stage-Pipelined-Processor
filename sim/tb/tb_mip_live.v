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

// docs/adr/0020-soc-integration.md (Phase D8): confirms mip.MTIP/MEIP
// track real, live hardware transitions (Timer.v counting up to a
// software-programmed MTIMECMP; Uart.v's irq once a real byte arrives
// and IER.ERBFI is set) -- not just a static snapshot, and that
// reading RBR clears MEIP while MTIP (no software clear except
// reprogramming MTIMECMP) stays sticky. No interrupt redirect exists yet
// (D9) -- this is entirely CSR-read-side, via software polling loops.
module tb_mip_live;
    localparam CLKS_PER_BIT = 4;

    reg clk = 0;
    reg start = 0;
    reg uart_rx = 1;
    wire uart_tx;

    PIPELINED #(.INIT_FILE("sim/programs/mip_live.mem"), .UART_CLKS_PER_BIT(CLKS_PER_BIT))
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
        repeat (10) @(posedge clk);
        drive_rx_byte(8'h99);   // arrives well before the program's own uart_poll loop gets there

        #3000;

        check_reg(5,  32'h00000000, "MTIP clear right after setting MTIMECMP=50 (mtime still near 0)");
        check_reg(7,  32'h00000080, "MTIP set once the timer_poll loop observes mtime >= 50");
        check_reg(10, 32'h00000800, "MEIP set once the uart_poll loop observes the driven byte, IER.ERBFI=1");
        check_reg(12, 32'h00000880, "both MTIP and MEIP read pending simultaneously");
        check_reg(13, 32'h00000099, "RXDATA read returns the byte the testbench drove (0x99)");
        check_reg(15, 32'h00000000, "MEIP clears once RXDATA is read (rx_ready consumed)");
        check_reg(16, 32'h00000080, "MTIP stays set -- no software clear except reprogramming MTIMECMP");

        report("mip_live");
        $finish;
    end
endmodule
