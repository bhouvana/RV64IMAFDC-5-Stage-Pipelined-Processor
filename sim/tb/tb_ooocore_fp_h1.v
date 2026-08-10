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
`include "Tlb39.v"
`include "Ptw39.v"

// Generation 6, Gen6-H. OOOCore.v's first F-extension end-to-end test:
// fetch->decode->rename(SEPARATE float RAT/FreeList/PRF)->dispatch->
// RS_FALU->FALU.v->CDB->ROB retire(float-dest-aware), for
// sim/programs/ooocore_fp_h1.s. Checks both the integer bootstrap values
// (x1/x2, via the ordinary integer path) and the float results (via
// RegisterAliasTable_Float's own architectural table + PhysicalRegisterFile_Float's
// own storage) -- proving the two rename stacks are genuinely independent
// yet correctly interoperate through FMV.W.X's own cross-file read.
module tb_ooocore_fp_h1;
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

    task check_freg;
        input [4:0] areg;
        input [31:0] expected;
        input [1023:0] label;
        reg [5:0] preg;
        reg [31:0] actual;
        begin
            preg = dut.m_RAT_Float.arch_map[areg];
            actual = dut.m_PRF_Float.regs[preg];
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s (f%0d via fpreg%0d): %h, expected %h", label, areg, preg, actual, expected);
            end else begin
                $display("pass  %0s (f%0d via fpreg%0d): %h", label, areg, preg, actual);
            end
        end
    endtask

    reg rst = 0;

    OOOCore #(
        .XLEN(64), .NUM_AREGS(32), .NUM_PREGS(64),
        .ROB_ENTRIES(16), .RS_ALU_ENTRIES(8),
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_fp_h1.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        for (i = 0; i < 300; i = i + 1)
            @(posedge clk);
        #1;

        check_areg(5'd1, 64'h3F800000, "x1 = 1.0f's bit pattern");
        check_areg(5'd2, 64'h40000000, "x2 = 2.0f's bit pattern");
        check_freg(5'd1, 32'h3F800000, "f1 = 1.0f (via FMV.W.X)");
        check_freg(5'd2, 32'h40000000, "f2 = 2.0f (via FMV.W.X)");
        check_freg(5'd3, 32'h40400000, "f3 = f1+f2 = 3.0f (FADD.S)");
        check_freg(5'd4, 32'h3F800000, "f4 = f2-f1 = 1.0f (FSUB.S)");
        check_freg(5'd5, 32'h40000000, "f5 = f1*f2 = 2.0f (FMUL.S)");
        check_freg(5'd6, 32'h3F800000, "f6 = min(f1,f2) = 1.0f (FMIN.S)");
        check_freg(5'd7, 32'h40000000, "f7 = max(f1,f2) = 2.0f (FMAX.S)");
        check_freg(5'd8, 32'h3F800000, "f8 = fsgnjx(f1,f1) = 1.0f (FSGNJX.S)");

        if (fails == 0) $display("PASS  ooocore_fp_h1 (%0d checks)", checks);
        else $display("FAIL  ooocore_fp_h1 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
