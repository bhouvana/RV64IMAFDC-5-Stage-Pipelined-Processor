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

// docs/adr/0020-soc-integration.md (Phase D9). Directed test for the
// interrupt redirect path, UART RX source: sim/programs/uart_interrupt.s
// enables mie.MEIE/IER.ERBFI/mstatus.MIE, then runs a loop
// while this testbench (playing the external-transmitter role, same as
// tb_uart_unit.v/tb_mip_live.v) drives a real byte into rx. Checks: the
// interrupt is taken (handler ran, mcause carries the interrupt bit + the
// external cause code), RXDATA in the handler matches the driven byte,
// mepc lands somewhere in the valid [loop_start, self] range (deliberately
// not pinned to an exact cycle -- see the .s file's header), and the loop's
// own final count is exactly right.
module tb_uart_interrupt;
    localparam CLKS_PER_BIT = 4;

    reg clk = 0;
    reg start = 0;
    reg uart_rx = 1;
    wire uart_tx;

    PIPELINED #(.INIT_FILE("sim/programs/uart_interrupt.mem"), .UART_CLKS_PER_BIT(CLKS_PER_BIT))
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
        repeat (12) @(posedge clk);   // let mtvec/mie/CONTROL/mstatus setup land first
        drive_rx_byte(8'h6B);

        #1500;

        check_reg(10, 32'd16,        "x10 = 16: every loop iteration ran exactly once despite the interrupt");
        check_reg(11, 32'd888,       "x11 = 888: the UART RX interrupt handler ran");
        check_reg(13, 32'h0000006B, "x13 = 0x6B: RXDATA in the handler matches the driven byte");
        check_val(dut.m_CSR.mcause, 32'h8000000B,
                   "mcause = 0x8000000B: interrupt bit set (bit31) + MCAUSE_INT_MACHINE_EXTERNAL(11)");
        check_val(dut.m_CSR.mstatus, 32'h88,
                   "mstatus after mret: MIE(bit3)=1 restored from MPIE, MPIE(bit7)=1 set by mret");

        // mepc must land inside [loop_start, self] (word-aligned) -- see
        // uart_interrupt.s's header comment for why this is a range, not an
        // exact value: the interrupt may land mid-loop or after the loop's
        // already spinning in `self`, both valid.
        total_checks = total_checks + 1;
        if (dut.m_CSR.mepc < 32'd32 || dut.m_CSR.mepc > 32'd96 || dut.m_CSR.mepc[1:0] != 2'b00) begin
            total_fails = total_fails + 1;
            $display("  FAIL  mepc in-range check: mepc = 0x%08h, expected in [32,96], word-aligned",
                      dut.m_CSR.mepc);
        end else begin
            $display("  pass  mepc in-range check: mepc = 0x%08h", dut.m_CSR.mepc);
        end

        report("uart_interrupt");
`ifdef COVERAGE
        dut.dump_coverage;
`endif
        $finish;
    end
endmodule
