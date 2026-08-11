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

// Generation 6, Gen6-O (docs/adr/0051). OOOCore.v's own first jalr test --
// proves the new jr_inflight single-outstanding scope cut end to end:
// jalr's target (register-dependent, unlike jal's decode-time-known one)
// resolves only once rs1 is ready and RS_ALU actually issues the entry,
// at which point pc_r redirects for real -- if it worked, the two
// instructions between jalr and its target never execute/retire at all.
module tb_ooocore_jalr_o3;
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

    reg rst = 0;

    OOOCore #(
        .XLEN(64), .NUM_AREGS(32), .NUM_PREGS(64),
        .ROB_ENTRIES(16), .RS_ALU_ENTRIES(8),
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_jalr_o3.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        for (i = 0; i < 200; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd10, 64'd20, "x10 = 20 (jalr's own base register)");
        check_areg(5'd1,  64'd11, "x1 = 11 -- untouched by the SKIPPED addi x1,x0,99 instructions");
        check_areg(5'd5,  64'd12, "x5 = jalr's own link value (pc+4 = 8+4 = 12)");
        check_areg(5'd2,  64'd12, "x2 = x1+1 = 12 -- proves fetch/dispatch really landed at target, not fell through");

        if (fails == 0) $display("PASS  ooocore_jalr_o3 (%0d checks)", checks);
        else $display("FAIL  ooocore_jalr_o3 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
