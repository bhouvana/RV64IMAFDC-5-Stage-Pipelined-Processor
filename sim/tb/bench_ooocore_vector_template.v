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

// Generation 7, Pillar V backlog closure (docs/adr/0066). bench_runner.py's
// own --compare-vector path. Same retirement-counting termination as
// bench_ooocore_template.v (jal doesn't redirect PC in OOOCore.v, see that
// file's own header) -- the one real difference: this template ALSO dumps
// x10's own final architectural value (via the same dut.m_RAT.arch_map/
// dut.m_PRF.regs read every Gen7-V directed testbench already uses), since
// sim/tools/iss.py has no vector-opcode support at all and can't provide
// the usual correctness cross-check for a program containing real vector
// instructions -- the correctness check here is a real, independent,
// hand-computed constant (bench_runner.py's own EXPECTED_X10_OOO_VECTOR),
// not an ISS comparison, checked directly against the RTL's own retired
// architectural state.
//
// __INIT_FILE__/__OUT_FILE__/__MEM_SIZE__/__XLEN__/__TARGET_RETIRED__/
// __MAX_TIME__ substituted per run by bench_runner.py.
module bench_run_ooocore_vector;
    reg clk = 0;
    reg rst = 0;
    integer fd;
    integer retired;
    integer cyc;
    reg done;
    reg [63:0] x10_final;

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
        #1;
        x10_final = dut.m_PRF.regs[dut.m_RAT.arch_map[5'd10]];
        fd = $fopen("__OUT_FILE__", "w");
        $fdisplay(fd, "%0d", cyc);
        $fdisplay(fd, "%0d", x10_final);
        $fclose(fd);
        if (!done)
            $display("TIMEOUT: __INIT_FILE__ only retired %0d/%0d instructions within __MAX_TIME__", retired, __TARGET_RETIRED__);
        $finish;
    end
endmodule
