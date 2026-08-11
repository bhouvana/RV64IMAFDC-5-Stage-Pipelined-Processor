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

// Generation 6, Gen6-L4. bench_runner.py's own --compare-ooo path.
// Same retirement-counting termination as sim/tb/dump_regs_ooocore_
// template.v (see that file's own header for why the jal-halt-loop-based
// convention bench_template.v uses doesn't work for OOOCore.v) -- reports
// just the cycle count at that point (bench_runner.py's own comparison
// only needs cycles/IPC here, not a full architectural-state dump).
//
// __INIT_FILE__/__OUT_FILE__/__MEM_SIZE__/__XLEN__/__TARGET_RETIRED__/
// __MAX_TIME__ substituted per run by bench_runner.py's own --compare-ooo
// path -- __TARGET_RETIRED__ is the benchmark kernel's real instruction
// count (fence/halt-loop trailer stripped and replaced with plain nops
// before assembly, same convention sim/tools/random_gen.py's own ooo mode
// established, done in Python before this template is even filled in).
module bench_run_ooocore;
    reg clk = 0;
    reg rst = 0;
    integer fd;
    integer retired;
    integer cyc;
    reg done;

    // See dump_regs_ooocore_template.v's own comment for why SP_INIT must
    // be sized explicitly (__XLEN__'d__MEM_SIZE__, not a bare literal).
    OOOCore #(
        .XLEN(__XLEN__), .NUM_AREGS(32), .NUM_PREGS(64),
        .ROB_ENTRIES(16), .RS_ALU_ENTRIES(8), .RS_FALU_ENTRIES(8),
        .IMEM_SIZE_BYTES(__MEM_SIZE__), .IMEM_INIT_FILE("__INIT_FILE__"),
        .DMEM_SIZE_BYTES(__MEM_SIZE__), .SP_INIT(__XLEN__'d__MEM_SIZE__)
    ) dut (.clk(clk), .rst(rst), .mailbox_readData(64'b0), .msip_pending(1'b0), .timer_pending(1'b0), .ext_pending(1'b0));

    always #5 clk = ~clk;

    initial begin
        retired = 0;
        done = 0;
        cyc = 0;
    end

    always @(posedge clk) begin
        if (~rst) begin
            retired <= 0;
            cyc <= 0;
        end
        else begin
            cyc <= cyc + 1;
            if (!done)
                retired <= retired + (dut.rob_retire_valid0 ? 1 : 0) + (dut.rob_retire_valid1 ? 1 : 0);
        end
        if (rst && !done && (retired + (dut.rob_retire_valid0 ? 1 : 0) + (dut.rob_retire_valid1 ? 1 : 0)) >= __TARGET_RETIRED__)
            done <= 1;
    end

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;
        while (!done && cyc < (__MAX_TIME__ / 10))
            @(posedge clk);
        fd = $fopen("__OUT_FILE__", "w");
        $fdisplay(fd, "%0d", cyc);
        $fclose(fd);
        if (!done)
            $display("TIMEOUT: __INIT_FILE__ only retired %0d/%0d instructions within __MAX_TIME__", retired, __TARGET_RETIRED__);
        $finish;
    end
endmodule
