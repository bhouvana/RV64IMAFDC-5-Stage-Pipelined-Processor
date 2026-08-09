`include "riscvpipeline.v"
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
`include "reg1a.v"
`include "reg2.v"
`include "reg3.v"
`include "reg4.v"
`include "Hazard.v"
`include "HazardNoForward.v"
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
`include "Bht.v"
`include "Btb.v"
`include "Gshare.v"
`include "Chooser.v"
`include "ICache.v"
`include "DCache.v"
`include "VictimCache.v"
`include "MemoryLatencyModel.v"

// docs/adr/0020-soc-integration.md (Phase D10). Interrupt-mode sibling of
// dump_regs_template.v -- used only by sim/tools/run_random_tests.py's
// --interrupt runs, never by the plain (default) corpus, which keeps using
// the original template completely untouched. Two differences from that
// template: (1) MEM_SIZE_BYTES is a substituted, typically-larger value
// (random_gen.py's interrupt-mode programs need room for the extra
// prefix/handler instructions the plain corpus doesn't carry), and (2) a
// real uart_rx/uart_tx wiring plus an optional substituted stimulus
// snippet below (empty for timer-mode runs) that drives a byte in for
// UART-source runs -- the "externally controlled, easy to pin" timing the
// plan's own D10 section describes, as opposed to the timer source's own
// real (generously-margined, not precisely timed) MTIMECMP compare. (3)
// __BRANCH_PREDICTOR__ (docs/adr/0021-branch-prediction.md) is substituted
// the same way __HAZARD_STRATEGY__/__PIPELINE_PROFILE__ already are --
// interrupt-mode programs are just as valid a cross-check target under
// either predictor setting, confirmed by the ADR's own research pass
// (misprediction recovery injects no new control flow, so it can't
// interact with interrupt-injection's own termination-safety machinery).
// __REPLACEMENT_POLICY__ (docs/adr/0041-cache-replacement-policy-phase-b.md)
// substituted the same way -- purely timing, no cache model in iss.py at
// all, same category as CACHE_MODE/MEM_LATENCY_I/_D above. __VICTIM_ENTRIES__
// (docs/adr/0042-victim-cache-phase-c.md) joins the same category.
module dump_regs_interrupt;
    reg clk = 0;
    reg start = 0;
    reg uart_rx = 1;
    wire uart_tx;
    integer i;
    integer fd;

    PIPELINED #(.INIT_FILE("__INIT_FILE__"), .HAZARD_STRATEGY(__HAZARD_STRATEGY__),
                .PIPELINE_PROFILE(__PIPELINE_PROFILE__), .MEM_SIZE_BYTES(__MEM_SIZE__),
                .BRANCH_PREDICTOR(__BRANCH_PREDICTOR__), .CACHE_MODE(__CACHE_MODE__),
                .REPLACEMENT_POLICY(__REPLACEMENT_POLICY__), .VICTIM_ENTRIES(__VICTIM_ENTRIES__),
                .MEM_LATENCY_I(__MEM_LATENCY_I__), .MEM_LATENCY_D(__MEM_LATENCY_D__),
                .UART_CLKS_PER_BIT(4), .XLEN(__XLEN__))
        dut(.clk(clk), .start(start), .uart_rx(uart_rx), .uart_tx(uart_tx));

    always #5 clk = ~clk;

    task drive_rx_byte;
        input [7:0] byte_in;
        integer k;
        begin
            uart_rx = 0;
            repeat (4) @(posedge clk);
            for (k = 0; k < 8; k = k + 1) begin
                uart_rx = byte_in[k];
                repeat (4) @(posedge clk);
            end
            uart_rx = 1;
            repeat (4) @(posedge clk);
        end
    endtask

    initial begin
        start = 0;
        #10 start = 1;
        __UART_STIMULUS__
    end

    initial begin
        #__MAX_TIME__;
        fd = $fopen("__OUT_FILE__", "w");
        for (i = 0; i < 32; i = i + 1)
            $fdisplay(fd, "%0d", dut.m_Register.regs[i]);
        // Phase Q (docs/adr/0033-memory-capacity-scale-up-phase-q.md): dump
        // only the __DUMP_WINDOW__-byte window (== __MEM_SIZE__ at every
        // pre-existing call site, since dump_window = min(mem_size,
        // SCALEUP_WINDOW_BYTES) in run_random_tests.py), instead of the
        // full __MEM_SIZE__ -- a constrained-random program's real touched
        // range is provably confined to a small low window regardless of
        // MEM_SIZE_BYTES (random_gen.py's own base_addr/addr_space/offset
        // caps), so dumping the full array at MB scale would be tens of
        // millions of lines for no correctness benefit. An earlier version
        // of this fix also spot-checked a few high addresses beyond the
        // window for defense-in-depth -- removed after running found those
        // addresses are genuinely undefined (X) in the RTL beyond
        // DataMemoryBRAM.v's own bounded zero-init, so comparing them
        // against the ISS's always-defined-zero model isn't a sound check
        // at all, just a guaranteed parse failure regardless of any real
        // bug (docs/adr/0033's own "Real bugs/findings" section).
        for (i = 0; i < __DUMP_WINDOW__; i = i + 1)
            $fdisplay(fd, "%0d", dut.m_DataMemory.m_ram.data_memory[i]);
        for (i = 0; i < 32; i = i + 1)
            $fdisplay(fd, "%0d", dut.m_FRegister.regs[i]);
        $fdisplay(fd, "%0d", dut.m_CSR.fflags);
        $fdisplay(fd, "%0d", dut.m_CSR.frm);
        $fclose(fd);
        $finish;
    end
endmodule
