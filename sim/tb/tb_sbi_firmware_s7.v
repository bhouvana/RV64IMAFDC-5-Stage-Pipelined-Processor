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

// docs/adr/0035-minimal-sbi-firmware-phase-s.md. Runs the real, built
// (sim/tools/build_sbi_firmware.py) M-mode SBI firmware + S-mode test
// payload through Icarus. Confirms: the M->S mode switch itself
// (boot.S's own mret, a0=hart id/a1=DTB address landing correctly),
// the DTB blob is byte-correct at the address firmware actually passed
// (S-mode's own big-endian magic-number read), the Base extension's
// GET_SPEC_VERSION ecall round-trips through trap_entry.S/sbi_dispatch,
// CONSOLE_PUTCHAR's real UART output decodes correctly off uart_tx, and
// the real machine-timer-interrupt forwarding round trip (mask mtimecmp,
// synthesize mip.STIP, riscvpipeline.v's own new sti_pending path
// retrapping into S-mode's own s_trap_handler) actually happens --
// this last one is what this phase's own real RTL fix (interrupt_taken's
// new supervisor-interrupt term) makes possible at all.
module tb_sbi_firmware_s7;
    localparam MEM_SIZE = 32768;

    reg clk = 0;
    reg start = 0;
    reg uart_rx = 1;
    wire uart_tx;

    PIPELINED #(
        .XLEN(64),
        .MEM_SIZE_BYTES(MEM_SIZE),
        .INIT_FILE("sim/firmware/build/imem.mem"),
        .DATA_INIT_FILE("sim/firmware/build/dmem.mem")
    ) dut(.clk(clk), .start(start), .uart_rx(uart_rx), .uart_tx(uart_tx));

    `include "check_tasks.vh"

    always #5 clk = ~clk;

    // Background: decode every byte the DUT transmits (mirrors
    // tb_uart_polled.v's own approach) -- payload_main's own "OK\n" via
    // CONSOLE_PUTCHAR should produce exactly this on uart_tx.
    reg [7:0] decoded_bytes [0:7];
    integer decoded_count = 0;
    localparam CLKS_PER_BIT = 4;  // UART_CLKS_PER_BIT default (design/riscvpipeline.v)
    integer bi;
    always begin
        @(negedge uart_tx);
        #(CLKS_PER_BIT * 10 / 2);
        for (bi = 0; bi < 8; bi = bi + 1) begin
            #(CLKS_PER_BIT * 10);
            decoded_bytes[decoded_count][bi] = uart_tx;
        end
        #(CLKS_PER_BIT * 10);
        decoded_count = decoded_count + 1;
    end

    initial begin
        start = 0;
        #10 start = 1;

        // Generous budget -- the timer round trip needs real cycles (a
        // machine-timer interrupt to actually fire, get forwarded, retrap
        // into S-mode), mirroring timer_interrupt.s's own generous margin.
        #200000;

        // SENTINEL_BASE = 0x6000 (payload.c's own fixed addresses, no `nm`
        // lookup needed -- both sides hardcode the same values directly).
        check_mem_word(32'h6000, 32'h00000000, "SENT_HART_ID low 32 bits: 0 (hart 0)");
        check_mem_word(32'h6008, 32'h00004000, "SENT_DTB_ADDR low 32 bits: 0x4000 (link_sbi.ld's own DTB_ADDR)");
        check_mem_word(32'h6010, 32'h00000001, "SENT_DTB_MAGIC_OK: 1 (real FDT magic 0xd00dfeed read back correctly)");
        check_mem_word(32'h6014, 32'h00000000, "SENT_SPEC_VERSION: 0 (this firmware's own 'legacy v0.1' signal)");
        check_mem_word(32'h6018, 32'h00000001,
                        "SENT_TIMER_OBSERVED: 1 (the real machine-timer-interrupt-forwarding round trip happened)");
        check_mem_word(32'h601C, 32'h00000001, "SENT_ALL_DONE: 1 (payload_main ran to completion)");

        total_checks = total_checks + 1;
        if (decoded_count < 3 || decoded_bytes[0] !== "O" || decoded_bytes[1] !== "K" || decoded_bytes[2] !== 8'h0A) begin
            total_fails = total_fails + 1;
            $display("  FAIL  CONSOLE_PUTCHAR output: decoded %0d bytes, expected \"OK\\n\"", decoded_count);
        end else begin
            $display("  pass  CONSOLE_PUTCHAR output: decoded \"OK\\n\" off uart_tx");
        end

        report("sbi_firmware_s7");
        $finish;
    end
endmodule
