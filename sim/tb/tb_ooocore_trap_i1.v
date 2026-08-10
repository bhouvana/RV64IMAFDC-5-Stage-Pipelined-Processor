`include "OOOCore.v"
`include "InstructionMemory.v"
`include "Control.v"
`include "ALUCtrl.v"
`include "ImmGen.v"
`include "ALU.v"
`include "FALU.v"
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

// Generation 6, Gen6-I. OOOCore.v's first precise-exception end-to-end
// test: illegal-instruction detection at decode -> dispatch (as an
// ordinary no-dest ROB entry) -> ROB-retire-gated trap_taken -> CSR.v
// captures mepc/mcause -> PC redirect to mtvec -- for
// sim/programs/ooocore_trap_i1.s's own self-re-triggering loop (see its
// own header for why looping forever is the actual intended test
// shape, not a bug). Checks BOTH the architectural-state-never-
// corrupted property (x3 stays 0, forever) and CSR.v's own real state
// capture (mepc/mcause), via direct hierarchical reference.
module tb_ooocore_trap_i1;
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
        input [63:0] actual, expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: %0d, expected %0d", label, actual, expected);
            end else begin
                $display("pass  %0s: %0d", label, actual);
            end
        end
    endtask

    reg rst = 0;

    OOOCore #(
        .XLEN(64), .NUM_AREGS(32), .NUM_PREGS(64),
        .ROB_ENTRIES(16), .RS_ALU_ENTRIES(8),
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_trap_i1.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // Generous fixed wait -- enough for several loop iterations
        // (each pass is only 3 real dispatches: addi/addi/illegal).
        for (i = 0; i < 300; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd1, 64'd5, "x1 = 5, re-committed identically every loop pass");
        check_areg(5'd2, 64'd7, "x2 = 7, re-committed identically every loop pass");
        check_areg(5'd3, 64'd0, "x3 = 0 -- the post-fault instruction NEVER retires, not even once across many loop passes");

        check_val(dut.m_CSR.mepc, 64'd8, "CSR mepc == 8, the illegal instruction's own PC");
        check_val(dut.m_CSR.mcause, 64'd2, "CSR mcause == 2 (MCAUSE_ILLEGAL_INSTRUCTION)");

        if (fails == 0) $display("PASS  ooocore_trap_i1 (%0d checks)", checks);
        else $display("FAIL  ooocore_trap_i1 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
