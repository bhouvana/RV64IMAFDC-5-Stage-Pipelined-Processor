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

// Generation 6, Gen6-L. Template for sim/tools/random_gen.py's --ooo mode,
// driven by sim/tools/run_random_tests.py's own --ooo cross-check path.
//
// Termination is real retirement counting, NOT the fixed-cycle-then-dump
// convention every OOOCore directed testbench uses -- found by running to
// be genuinely unreliable for a generated program: random_gen.py's shared
// trailer is a `jal x0, __halt` self-loop, which works for PIPELINED (jal
// is fully implemented there) but NOT for OOOCore.v (jump_c is decoded,
// design/Control.v, but never consumed anywhere in design/OOOCore.v --
// confirmed by direct code read before this phase touched anything). The
// "self-loop" doesn't loop: PC just falls through past it into the
// zero-filled tail of IMEM, reads an all-zero word (illegal opcode),
// traps, and -- since csrrw is never dispatched in OOOCore.v either, so
// mtvec never leaves its own reset default of 0 -- redirects straight
// back to address 0, restarting the ENTIRE program. Measured directly on
// a real generated 61-instruction program: a full restart every ~100-150
// cycles (29 traps in 4000 cycles), far too fast for any generic fixed-
// cycle budget to reliably land inside "pass 1 fully retired, pass 2 not
// yet begun" -- at 400 cycles the dump caught mid-seed-prefix state, at
// 4000 cycles mid-body state from a LATER pass, at 20000 cycles
// mid-seed-prefix again (a different pass) -- silently wrong committed
// state, not a hang, which is worse. Counting real retirements and
// stopping at exactly the assembled program's own instruction count
// (before OOOCore.v ever fetches past the end) sidesteps the whole
// problem: dump happens deterministically after pass 1's last real
// instruction retires and before the illegal-opcode/trap/restart
// machinery even engages.
//
// __INIT_FILE__/__OUT_FILE__/__MEM_SIZE__/__XLEN__/__TARGET_RETIRED__ are
// substituted per run by run_random_tests.py -- __TARGET_RETIRED__ is the
// exact instruction count asm.py itself reports for the assembled
// program (run_random_tests.py already parses this for its own PIPELINED
// max_time formula, see run_one()'s own real_n_instrs). __MAX_TIME__ is
// a SAFETY timeout only (a genuine hang -- e.g. resource-exhaustion
// deadlock -- would otherwise wait forever); reaching it dumps whatever
// state exists at that point, which a real comparison mismatch then
// surfaces as a clear failure rather than a silent false pass.
//
// Dump layout: 32 integer regs (via RegisterAliasTable.v's own
// arch_map[areg] -> PhysicalRegisterFile.v's own regs[preg], the same
// hierarchical-reference pattern every OOOCore directed testbench already
// uses), __MEM_SIZE__ data memory bytes, 32 float regs (same arch_map
// indirection through m_RAT_Float/m_PRF_Float). No fflags/frm line --
// OOOCore.v's own CSR.v instance has fp_flags_we permanently tied 0 (see
// OOOCore.v's own m_CSR instantiation comment): no FP op in this phase's
// supported subset ever latches fflags, so there is nothing real to
// compare there yet (a genuine, flagged gap, not silently faked as
// always-0 correct) -- run_random_tests.py's own --ooo comparison path
// skips fflags/frm entirely instead of asserting a comparison neither
// side can honestly satisfy.
module dump_regs_ooocore;
    reg clk = 0;
    reg rst = 0;
    integer i;
    integer fd;
    integer retired;
    integer cyc;
    reg done;

    // SP_INIT: unlike design/riscvpipeline.v (which derives its own
    // Register.v's SP_INIT from MEM_SIZE_BYTES internally -- see
    // riscvpipeline.v:919), OOOCore.v's SP_INIT is a fully independent
    // parameter (default 64'd128) -- must be wired to __MEM_SIZE__
    // explicitly here to match sim/tools/iss.py's own `self.regs[2] =
    // mem_size` convention. Sized as __XLEN__'d__MEM_SIZE__, NOT a bare
    // unsized literal -- a real bug found by running: an unsized decimal
    // override self-determines as 32-bit in Icarus regardless of the
    // parameter's own declared 64-bit default, so PhysicalRegisterFile.v's
    // own `regs[2] <= SP_INIT[XLEN-1:0]` (XLEN=64) part-selects 32 bits
    // past that override's real width, reading back X for the upper half
    // -- x2 came back X at every __MEM_SIZE__ other than the untested-by-
    // override default (128) before this fix.
    OOOCore #(
        .XLEN(__XLEN__), .NUM_AREGS(32), .NUM_PREGS(64),
        .ROB_ENTRIES(16), .RS_ALU_ENTRIES(8), .RS_FALU_ENTRIES(8),
        .IMEM_SIZE_BYTES(__MEM_SIZE__), .IMEM_INIT_FILE("__INIT_FILE__"),
        .DMEM_SIZE_BYTES(__MEM_SIZE__), .SP_INIT(__XLEN__'d__MEM_SIZE__)
    ) dut (.clk(clk), .rst(rst));

    always #5 clk = ~clk;

    initial begin
        retired = 0;
        done = 0;
        cyc = 0;
    end

    // Plain Verilog-2001 (this project's whole random-test harness compiles
    // templates with `iverilog -g2005`, no SystemVerilog fork/join_any) --
    // a polled while-loop below stops on whichever of done/timeout comes
    // first instead.
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
        for (i = 0; i < 32; i = i + 1)
            $fdisplay(fd, "%0d", dut.m_PRF.regs[dut.m_RAT.arch_map[i]]);
        for (i = 0; i < __MEM_SIZE__; i = i + 1)
            $fdisplay(fd, "%0d", dut.m_DMem.data_memory[i]);
        for (i = 0; i < 32; i = i + 1)
            $fdisplay(fd, "%0d", dut.m_PRF_Float.regs[dut.m_RAT_Float.arch_map[i]]);
        $fclose(fd);
        if (!done)
            $display("TIMEOUT: only %0d/%0d instructions retired within __MAX_TIME__", retired, __TARGET_RETIRED__);
        $finish;
    end
endmodule
