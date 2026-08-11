`include "OOOCore.v"
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

// Generation 6, Gen6-P5 (docs/adr/0056). OOOCore.v's own first BTB-
// predicted jalr test: the same jalr (fixed PC) executes twice via a
// real loop -- first a genuine BTB miss+mispredict+recover, second a
// genuine BTB hit+correct-predict+no-redirect. For
// sim/programs/ooocore_jalr_btb_p5.s.
module tb_ooocore_jalr_btb_p5;
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

    task check_bit;
        input actual;
        input expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: %b, expected %b", label, actual, expected);
            end else begin
                $display("pass  %0s: %b", label, actual);
            end
        end
    endtask

    reg rst = 0;

    OOOCore #(
        .XLEN(64), .NUM_AREGS(32), .NUM_PREGS(64),
        .ROB_ENTRIES(16), .RS_ALU_ENTRIES(8),
        .IMEM_SIZE_BYTES(128), .IMEM_INIT_FILE("sim/programs/ooocore_jalr_btb_p5.mem"),
        .DMEM_SIZE_BYTES(256)
    ) dut (
        .clk(clk), .rst(rst), .mailbox_readData(64'b0),
        .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0)
    );

    // Live monitor: capture jr_mispredict the two cycles jr_resolve pulses.
    integer jr_resolve_count = 0;
    reg first_mispredict = 1'bx;
    reg second_mispredict = 1'bx;
    always @(posedge clk) begin
        if (rst && dut.jr_resolve) begin
            jr_resolve_count = jr_resolve_count + 1;
            if (jr_resolve_count == 1) first_mispredict <= dut.jr_mispredict;
            else if (jr_resolve_count == 2) second_mispredict <= dut.jr_mispredict;
        end
    end

    integer i;
    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        for (i = 0; i < 300; i = i + 1)
            @(posedge clk);
        #1;

        check_bit(jr_resolve_count >= 2, 1'b1, "jalr resolved at least twice (the loop really ran both iterations)");
        check_bit(first_mispredict, 1'b1, "iteration 1: genuine BTB miss -> mispredict -> recover");
        check_bit(second_mispredict, 1'b0, "iteration 2: genuine BTB hit -> correct predict -> no redirect");
        check_areg(5'd3, 64'd2, "x3 = 2 -- the loop counter, both iterations really ran");
        check_areg(5'd5, 64'd12, "x5 = 12 -- jalr's own link value (pc+4), same both iterations");
        check_areg(5'd20, 64'd42, "x20 = 42 -- reached only after the loop correctly exits on iteration 2");

        if (fails == 0) $display("PASS  ooocore_jalr_btb_p5 (%0d checks)", checks);
        else $display("FAIL  ooocore_jalr_btb_p5 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
