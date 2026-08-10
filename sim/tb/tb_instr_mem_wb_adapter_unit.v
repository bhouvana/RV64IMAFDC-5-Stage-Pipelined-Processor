`include "InstructionMemoryWishboneAdapter.v"
`include "InstructionMemory.v"

// docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). Standalone
// smoke test for InstructionMemoryWishboneAdapter.v -- directed reads at
// known addresses, content poked directly into the wrapped
// InstructionMemory.v's own `insts` array (hierarchical reference,
// INIT_FILE("") so nothing external is loaded) rather than depending on any
// existing .mem file's real content.
module tb_instr_mem_wb_adapter_unit;
    reg clk = 0;
    always #5 clk = ~clk;

    integer fails = 0;
    integer checks = 0;

    task check_word;
        input [31:0] actual, expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: 0x%08h, expected 0x%08h", label, actual, expected);
            end else begin
                $display("pass  %0s: 0x%08h", label, actual);
            end
        end
    endtask

    task check_bit;
        input actual, expected;
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

    reg         rst = 0;
    reg         s_cyc = 0, s_stb = 0, s_we = 0;
    reg  [31:0] s_addr = 0, s_data_o = 0;
    reg  [3:0]  s_sel = 4'hF;
    wire [31:0] s_data_i;
    wire        s_ack;

    InstructionMemoryWishboneAdapter #(.SIZE_BYTES(64), .XLEN(32), .INIT_FILE("")) dut(
        .clk(clk), .rst(rst),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we), .s_addr(s_addr), .s_data_o(s_data_o),
        .s_sel(s_sel), .s_data_i(s_data_i), .s_ack(s_ack)
    );

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;
        @(posedge clk);

        // LSB-first, matching InstructionMemory.v's own real convention
        // (docs/adr/0037) -- insts[addr] is the LOW byte.
        dut.m_imem.insts[0] = 8'h11; dut.m_imem.insts[1] = 8'h22;
        dut.m_imem.insts[2] = 8'h33; dut.m_imem.insts[3] = 8'h44;
        dut.m_imem.insts[8] = 8'hAA; dut.m_imem.insts[9] = 8'hBB;
        dut.m_imem.insts[10] = 8'hCC; dut.m_imem.insts[11] = 8'hDD;

        // Combinational ack -- no wait states, unlike RamWishboneAdapter.v.
        @(negedge clk);
        s_addr = 0; s_cyc = 1; s_stb = 1; s_we = 0;
        #1;
        check_bit(s_ack, 1'b1, "case1: ack fires combinationally, same cycle");
        check_word(s_data_i, 32'h44332211, "case1: LSB-first word at addr0");

        @(negedge clk);
        s_addr = 8;
        #1;
        check_bit(s_ack, 1'b1, "case2: ack fires combinationally at a new address too");
        check_word(s_data_i, 32'hDDCCBBAA, "case2: LSB-first word at addr8");

        // A write is silently ignored -- no corruption, ack still fires.
        @(negedge clk);
        s_addr = 0; s_we = 1; s_data_o = 32'hFFFFFFFF;
        #1;
        check_bit(s_ack, 1'b1, "case3: write still acks (ignored, not stalled)");
        @(negedge clk);
        s_we = 0;
        #1;
        check_word(s_data_i, 32'h44332211, "case3: addr0 content unchanged after a write attempt");

        // No cyc/stb -- no ack.
        @(negedge clk);
        s_cyc = 0; s_stb = 0;
        #1;
        check_bit(s_ack, 1'b0, "case4: no ack while cyc/stb are both low");

        $display("=== tb_instr_mem_wb_adapter_unit: %0d/%0d checks passed ===", checks - fails, checks);
        if (fails == 0) $display("PASS  instr_mem_wb_adapter_unit (%0d checks)", checks);
        else $display("FAIL  instr_mem_wb_adapter_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
