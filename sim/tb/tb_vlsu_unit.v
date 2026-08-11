`include "VLSU.v"
`include "DataMemoryBRAM.v"

// Generation 7, Pillar V, Phase 3 (docs/adr/0064). VLSU.v proven
// standalone, wired directly to a real DataMemoryBRAM.v (no arbitration
// needed here, single requester) -- mirrors tb_valu_unit.v's own "new
// module, own testbench, before any real caller" precedent.
module tb_vlsu_unit;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 0;

    reg          start, is_store;
    reg [63:0]   base_addr;
    reg [511:0]  store_data, v0_data;
    reg [2:0]    eew;
    reg          vm;
    reg [6:0]    vl;
    wire         mem_memRead, mem_memWrite;
    wire [63:0]  mem_address, mem_writeData;
    wire [2:0]   mem_funct3;
    wire [63:0]  mem_readData;
    wire         busy, done;
    wire [511:0] result;

    VLSU #(.VLEN(512), .XLEN(64)) dut(
        .clk(clk), .rst(rst), .start(start), .is_store(is_store),
        .base_addr(base_addr), .store_data(store_data), .eew(eew),
        .v0_data(v0_data), .vm(vm), .vl(vl),
        .mem_memRead(mem_memRead), .mem_memWrite(mem_memWrite),
        .mem_address(mem_address), .mem_writeData(mem_writeData), .mem_funct3(mem_funct3),
        .mem_readData(mem_readData),
        .busy(busy), .done(done), .result(result)
    );

    DataMemoryBRAM #(.SIZE_BYTES(256), .XLEN(64)) m_mem(
        .clk(clk), .rst(rst),
        .memWrite(mem_memWrite), .memRead(mem_memRead),
        .address(mem_address), .writeData(mem_writeData), .funct3(mem_funct3),
        .readData(mem_readData)
    );

    integer fails = 0, checks = 0;
    task run_and_wait;
        begin
            @(posedge clk); start <= 1'b1;
            @(posedge clk); start <= 1'b0;
            while (!done) @(posedge clk);
            @(negedge clk);
        end
    endtask
    task check_elem64;
        input [63:0] expected;
        input [255:0] label;
        reg [63:0] actual;
        begin
            actual = result[63:0];
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: %h, expected %h", label, actual, expected);
            end else
                $display("pass  %0s: %h", label, actual);
        end
    endtask

    initial begin
        rst = 0; start = 0; is_store = 0; vm = 1; v0_data = 512'h0;
        @(posedge clk); rst <= 1;

        // Store 16 SEW32 elements (0x11,0x22,...,0x11+15) starting at addr 0,
        // then load them back and confirm round-trip.
        store_data = 512'h0;
        store_data[31:0]  = 32'h000000AA;
        store_data[63:32] = 32'h000000BB;
        store_data[95:64] = 32'h000000CC;
        base_addr = 64'd0; eew = 3'b110; vl = 3; is_store = 1;
        run_and_wait();

        is_store = 0;
        run_and_wait();
        check_elem64(64'h000000BB000000AA, "vle32 round-trip elem0/1 = 0xAA,0xBB");
        checks = checks + 1;
        if (result[95:64] !== 32'h000000CC) begin fails=fails+1; $display("FAIL vle32 elem2: %h", result[95:64]); end
        else $display("pass  vle32 elem2 = 0xCC: %h", result[95:64]);
        checks = checks + 1;
        if (result[127:96] !== 32'd0) begin fails=fails+1; $display("FAIL vle32 elem3 (past vl=3, should be 0): %h", result[127:96]); end
        else $display("pass  vle32 elem3 (past vl=3, tail-agnostic zero): %h", result[127:96]);

        // Masked store: only elem0 active (v0 bit0=1, bit1=0), SEW8, vl=2.
        // Pre-fill memory with a known nonzero byte at elem1's address so a
        // real "skip" (not just writing zero) is provable.
        store_data = 512'h0; store_data[7:0] = 8'hFF; store_data[15:8] = 8'hFF;
        base_addr = 64'd100; eew = 3'b000; vl = 2; is_store = 1;
        v0_data = 512'h0; v0_data[0] = 1'b1; v0_data[1] = 1'b0; vm = 0;
        run_and_wait();

        // Unmasked readback of both bytes -- elem0 should be 0xFF (written),
        // elem1 should be whatever reset gave it (0, DataMemoryBRAM.v zero-inits).
        is_store = 0; vm = 1; v0_data = 512'h0;
        run_and_wait();
        checks = checks + 1;
        if (result[7:0] !== 8'hFF) begin fails=fails+1; $display("FAIL masked-store elem0 (active): %h", result[7:0]); end
        else $display("pass  masked-store elem0 (active, wrote 0xFF): %h", result[7:0]);
        checks = checks + 1;
        if (result[15:8] !== 8'h00) begin fails=fails+1; $display("FAIL masked-store elem1 (should be untouched/0): %h", result[15:8]); end
        else $display("pass  masked-store elem1 (masked off, memory untouched, reads 0): %h", result[15:8]);

        if (fails == 0) $display("PASS  vlsu_unit (%0d checks)", checks);
        else $display("FAIL  vlsu_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
