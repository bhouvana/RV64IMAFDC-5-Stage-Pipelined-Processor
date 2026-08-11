`include "HeteroSoC.v"
`include "riscvpipeline.v"
`include "Scoreboard.v"
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
`include "Prefetcher.v"
`include "DCache.v"
`include "L2Cache.v"
`include "InstructionMemoryWishboneAdapter.v"
`include "VictimCache.v"
`include "MemoryLatencyModel.v"
`include "OOOCore.v"
`include "VALU.v"
`include "VLSU.v"
`include "RegisterAliasTable.v"
`include "FreeList.v"
`include "PhysicalRegisterFile.v"
`include "ReorderBuffer.v"
`include "ReservationStation.v"
`include "LoadStoreQueue.v"
`include "Mailbox.v"

// Generation 6, Gen6-N (docs/adr/0050). Real, end-to-end proof that
// PIPELINED and OOOCore.v work together in design/HeteroSoC.v: PIPELINED
// writes a 6-element array into the shared Mailbox.v and raises GO;
// OOOCore.v (running SIMULTANEOUSLY, its own independent instruction
// stream) polls for it, sums the array, writes the result back and
// raises DONE; PIPELINED polls for DONE and reads the result. Both
// programs' own source (sim/programs/hetero_pipelined_n1.s/
// hetero_ooo_n1.s) fully documents the protocol and each core's own
// real ISA constraints.
module tb_hetero_soc_n1;
    reg clk = 0;
    always #5 clk = ~clk;

    integer fails = 0;
    integer checks = 0;

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

    reg rst_ooo = 0;
    reg start_pipelined = 0;

    HeteroSoC #(
        .XLEN(64),
        .INIT_FILE_PIPELINED("sim/programs/hetero_pipelined_n1.mem"), .MEM_SIZE_BYTES_PIPELINED(512),
        .IMEM_INIT_FILE_OOO("sim/programs/hetero_ooo_n1.mem"), .IMEM_SIZE_BYTES_OOO(512),
        .DMEM_SIZE_BYTES_OOO(512)
    ) dut (.clk(clk), .rst_ooo(rst_ooo), .start_pipelined(start_pipelined));

    initial begin
        @(posedge clk); rst_ooo <= 0; start_pipelined <= 0;
        @(posedge clk); rst_ooo <= 1;
        #10 start_pipelined <= 1;

        // Generous fixed wait -- both cores are tiny programs (22/20
        // static instructions), OOOCore.v's own poll loop adds a real
        // but small number of extra spin cycles waiting for PIPELINED's
        // own 6 stores to land; 2000 time units (200 cycles) is a big
        // multiple of either program's own real critical path.
        #2000;

        // PIPELINED's own result register -- the real proof this is a
        // genuine cross-core handoff, not two cores that merely coexist:
        // x10 only ever gets written from the Mailbox's own RESULT word,
        // which only OOOCore.v's worker program ever writes, which only
        // happens after it actually observed GO and computed the sum
        // itself.
        check_val(dut.m_PIPELINED.m_Register.regs[10], 64'd21, "PIPELINED x10 == 1+2+...+6 == 21 (OOOCore.v's own computed result)");

        // Direct mailbox-word checks, independent of either core's own
        // register file -- proves the handoff itself, not just that
        // PIPELINED's own load happened to read the right value.
        check_val(dut.m_Mailbox.mem[0], 64'd1, "mailbox GO == 1 (PIPELINED's own write)");
        check_val(dut.m_Mailbox.mem[1], 64'd6, "mailbox N == 6 (PIPELINED's own write)");
        check_val(dut.m_Mailbox.mem[2], 64'd1, "mailbox DONE == 1 (OOOCore.v's own write)");
        check_val(dut.m_Mailbox.mem[3], 64'd21, "mailbox RESULT == 21 (OOOCore.v's own write)");
        // Plain Verilog-2005 (this project's whole harness compiles with
        // `iverilog -g2005`, no SystemVerilog $sformatf) -- unrolled
        // instead of a loop with a dynamically-built label.
        check_val(dut.m_Mailbox.mem[4], 64'd1, "mailbox data[0] == 1 (PIPELINED's own write, untouched by OOOCore.v)");
        check_val(dut.m_Mailbox.mem[5], 64'd2, "mailbox data[1] == 2 (PIPELINED's own write, untouched by OOOCore.v)");
        check_val(dut.m_Mailbox.mem[6], 64'd3, "mailbox data[2] == 3 (PIPELINED's own write, untouched by OOOCore.v)");
        check_val(dut.m_Mailbox.mem[7], 64'd4, "mailbox data[3] == 4 (PIPELINED's own write, untouched by OOOCore.v)");
        check_val(dut.m_Mailbox.mem[8], 64'd5, "mailbox data[4] == 5 (PIPELINED's own write, untouched by OOOCore.v)");
        check_val(dut.m_Mailbox.mem[9], 64'd6, "mailbox data[5] == 6 (PIPELINED's own write, untouched by OOOCore.v)");

        if (fails == 0) $display("PASS  hetero_soc_n1 (%0d checks)", checks);
        else $display("FAIL  hetero_soc_n1 (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
