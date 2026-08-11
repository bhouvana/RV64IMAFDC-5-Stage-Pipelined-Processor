`include "OOOCore.v"
`include "VALU.v"
`include "VLSU.v"
`include "InstructionMemory.v"
`include "Control.v"
`include "ALUCtrl.v"
`include "ImmGen.v"
`include "ALU.v"
`include "FALU.v"
`include "FDivider.v"
`include "FSqrt.v"
`include "RegisterAliasTable.v"
`include "FreeList.v"
`include "PhysicalRegisterFile.v"
`include "ReorderBuffer.v"
`include "ReservationStation.v"
`include "LoadStoreQueue.v"
`include "DataMemoryBRAM.v"
`include "Divider.v"
`include "Bht.v"
`include "Btb.v"
`include "CSR.v"
`include "Tlb39.v"
`include "Ptw39.v"

// Generation 6, Gen6-P3 (docs/adr/0054). OOOCore.v's own first real
// interrupt: machine-timer, recognized once the ROB drains (rob_empty),
// not at an arbitrary mid-flight instruction boundary -- a real,
// deliberate, documented scope cut (see the RTL's own interrupt section
// header). For sim/programs/ooocore_int_p3.s.
module tb_ooocore_int_p3;
    reg clk = 0;
    always #5 clk = ~clk;

    integer fails = 0;
    integer checks = 0;

    task check_areg;
        input [4:0] areg;
        input [63:0] expected;
        input [1023:0] label;
        reg [5:0] preg;
        reg [63:0] actual;
        begin
            preg = dut.m_RAT.arch_map[areg];
            actual = dut.m_PRF.regs[preg];
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s (x%0d via preg%0d): %h, expected %h", label, areg, preg, actual, expected);
            end else begin
                $display("pass  %0s (x%0d via preg%0d): %h", label, areg, preg, actual);
            end
        end
    endtask

    task check_val;
        input [63:0] actual;
        input [63:0] expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: %h, expected %h", label, actual, expected);
            end else begin
                $display("pass  %0s: %h", label, actual);
            end
        end
    endtask

    reg rst = 0;
    reg timer_pending_r = 0;

    OOOCore #(
        .XLEN(64), .NUM_AREGS(32), .NUM_PREGS(64),
        .ROB_ENTRIES(16), .RS_ALU_ENTRIES(8),
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_int_p3.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (
        .clk(clk), .rst(rst), .mailbox_readData(64'b0),
        .msip_pending(1'b0), .timer_pending(timer_pending_r), .ext_pending(1'b0)
    );

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Let the setup instructions (mie/mstatus/mtvec) retire and the
        // core settle into the spin loop first.
        for (i = 0; i < 100; i = i + 1)
            @(posedge clk);

        check_val(dut.m_CSR.mstatus[3], 1'b1, "mstatus.MIE == 1 before the interrupt (setup really landed)");
        check_val(dut.mie_mtie, 1'b1, "mie.MTIE == 1 before the interrupt (setup really landed)");

        // Now assert the real timer_pending input -- a genuine level, held
        // (matching real hardware: a CLINT's mtimecmp comparison doesn't
        // self-clear).
        timer_pending_r <= 1;

        for (i = 0; i < 200; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd10, 64'd123, "x10 = 123 -- the interrupt correctly redirected to the handler");
        // CSR.v's own existing mcause update is `{trap_is_interrupt,
        // trap_cause[30:0]}` -- a 32-bit concat zero-extended into the
        // wider register, so the interrupt bit lands at bit 31, not
        // XLEN-1/bit 63 the RISC-V spec technically specifies for RV64.
        // Pre-existing CSR.v behavior (shared, unmodified, with
        // PIPELINED's own already-tested Phase R interrupt support) --
        // not something this phase changes or should "fix" here; the
        // real assertion is that trap_is_interrupt correctly reached
        // CSR.v and combined with the right cause, which this confirms.
        check_val(dut.m_CSR.mcause, 64'h0000_0000_8000_0007, "mcause == 0x80000007 (interrupt bit set at bit 31, MCAUSE_INT_MACHINE_TIMER -- CSR.v's own existing encoding)");

        if (fails == 0) $display("PASS  ooocore_int_p3 (%0d checks)", checks);
        else $display("FAIL  ooocore_int_p3 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
