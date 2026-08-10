`include "ICache.v"
`include "InstructionMemory.v"
`include "InstructionMemoryWishboneAdapter.v"
`include "VictimCache.v"

// docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). Standalone unit
// test for ICache.v's own new L2_ENABLE-gated bus-master fill path.
//
// dut_off: L2_ENABLE=0 (default) -- the EXISTING private-InstructionMemory-
// direct-fill path, proving it's genuinely unchanged (content poked
// directly into dut_off.m_imem.insts[...], same hierarchical-reference
// shape tb_icache_unit.v's own poke_word helper already relies on --
// deliberately re-checked here since keeping that exact path alive is the
// whole reason this phase's own m_imem instantiation stayed OUTSIDE the new
// generate split, see ICache.v's own header comment on that instance).
//
// dut_on: L2_ENABLE=1 -- fetches over the new real Wishbone-master bus port
// instead, against a real InstructionMemoryWishboneAdapter.v +
// InstructionMemory.v instance (mirrors tb_l2cache_unit.v's own "reuse the
// real, already-verified adapter as the mock backing store" precedent).
module tb_icache_l2enable_unit;
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

    // -- dut_off: L2_ENABLE=0 (default) --
    reg         rst_off = 0;
    reg  [31:0] readAddr_off = 0;
    wire [31:0] inst_off;
    wire        hit_off, busy_off, done_off;

    ICache #(.INIT_FILE(""), .IMEM_SIZE_BYTES(64), .XLEN(32), .WAYS(2),
             .CACHE_SIZE_BYTES(64), .LINE_BYTES(16)) dut_off(
        .clk(clk), .rst(rst_off),
        .readAddr(readAddr_off), .inst(inst_off), .hit(hit_off), .busy(busy_off), .done(done_off),
        .probe_req(1'b0), .probe_addr(32'h0), .probe_ack(),
        .m_cyc(), .m_stb(), .m_addr(), .m_sel(), .m_funct3(), .m_data_i(32'h0), .m_ack(1'b0)
    );

    // -- dut_on: L2_ENABLE=1 --
    reg         rst_on = 0;
    reg  [31:0] readAddr_on = 0;
    wire [31:0] inst_on;
    wire        hit_on, busy_on, done_on;
    wire        m_cyc_on, m_stb_on;
    wire [31:0] m_addr_on;
    wire [3:0]  m_sel_on;
    wire [2:0]  m_funct3_on;
    wire [31:0] m_data_i_on;
    wire        m_ack_on;

    ICache #(.INIT_FILE(""), .IMEM_SIZE_BYTES(64), .XLEN(32), .WAYS(2),
             .CACHE_SIZE_BYTES(64), .LINE_BYTES(16), .L2_ENABLE(1)) dut_on(
        .clk(clk), .rst(rst_on),
        .readAddr(readAddr_on), .inst(inst_on), .hit(hit_on), .busy(busy_on), .done(done_on),
        .probe_req(1'b0), .probe_addr(32'h0), .probe_ack(),
        .m_cyc(m_cyc_on), .m_stb(m_stb_on), .m_addr(m_addr_on), .m_sel(m_sel_on),
        .m_funct3(m_funct3_on), .m_data_i(m_data_i_on), .m_ack(m_ack_on)
    );
    InstructionMemoryWishboneAdapter #(.SIZE_BYTES(128), .XLEN(32), .INIT_FILE("")) m_adapter_on(
        .clk(clk), .rst(rst_on),
        .s_cyc(m_cyc_on), .s_stb(m_stb_on), .s_we(1'b0), .s_addr(m_addr_on), .s_data_o(32'h0),
        .s_sel(m_sel_on), .s_data_i(m_data_i_on), .s_ack(m_ack_on)
    );

    task wait_hit;
        input [31:0] addr;
        output [31:0] hit_val;
        reg    seen;
        begin
            readAddr_off = addr;
            seen = 0;
            while (!seen) begin
                @(posedge clk); #1;
                if (hit_off) begin
                    seen = 1;
                    hit_val = inst_off;
                end
            end
        end
    endtask

    task wait_hit_on;
        input [31:0] addr;
        output [31:0] hit_val;
        reg    seen;
        begin
            readAddr_on = addr;
            seen = 0;
            while (!seen) begin
                @(posedge clk); #1;
                if (hit_on) begin
                    seen = 1;
                    hit_val = inst_on;
                end
            end
        end
    endtask

    reg [31:0] got;
    initial begin
        @(posedge clk); rst_off <= 0; rst_on <= 0;
        @(posedge clk); rst_off <= 1; rst_on <= 1;
        @(posedge clk);

        // dut_off: L2_ENABLE=0 -- poke the private InstructionMemory
        // directly, same hierarchical path every pre-existing ICache
        // testbench already relies on.
        dut_off.m_imem.insts[0] = 8'h11; dut_off.m_imem.insts[1] = 8'h22;
        dut_off.m_imem.insts[2] = 8'h33; dut_off.m_imem.insts[3] = 8'h44;
        readAddr_off = 0;
        wait_hit(0, got);
        check_word(got, 32'h44332211, "dut_off (L2_ENABLE=0): private InstructionMemory fill path unchanged");

        // dut_on: L2_ENABLE=1 -- poke the EXTERNAL adapter's own backing
        // memory instead; dut_on's own private m_imem (unconditionally
        // instantiated, unused at L2_ENABLE=1) stays untouched/irrelevant.
        m_adapter_on.m_imem.insts[16] = 8'hAA; m_adapter_on.m_imem.insts[17] = 8'hBB;
        m_adapter_on.m_imem.insts[18] = 8'hCC; m_adapter_on.m_imem.insts[19] = 8'hDD;
        wait_hit_on(16, got);
        check_word(got, 32'hDDCCBBAA, "dut_on (L2_ENABLE=1): fill via the new Wishbone-master bus path");
        check_bit(dut_on.m_imem.insts[16] == 8'h00, 1'b1, "dut_on: private m_imem instance genuinely untouched/unused at L2_ENABLE=1");

        $display("=== tb_icache_l2enable_unit: %0d/%0d checks passed ===", checks - fails, checks);
        if (fails == 0) $display("PASS  icache_l2enable_unit (%0d checks)", checks);
        else $display("FAIL  icache_l2enable_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
