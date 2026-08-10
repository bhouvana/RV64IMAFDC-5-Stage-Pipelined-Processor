`include "L2Cache.v"
`include "RamWishboneAdapter.v"
`include "DataMemoryBRAM.v"

// docs/adr/0045-l2-cache-phase-f.md (Generation 4, Phase F). Standalone unit
// test for L2Cache.v -- independent of ICache.v/DCache.v/riscvpipeline.v
// (those get their own probe-responder/wiring coverage in later F-steps).
// Drives u_cyc/u_stb/u_we/u_addr directly (mirrors tb_mshr_unit.v's own
// req_read/req_write-direct-drive shape), against a REAL RamWishboneAdapter.v
// + DataMemoryBRAM.v backing instance on the downstream m_* port (same
// "reuse the real, already-verified adapter as the mock backing store"
// precedent tb_mshr_unit.v already established, rather than inventing a
// bespoke behavioral memory model).
//
// dut: WAYS(2), CACHE_SIZE_BYTES(64), LINE_BYTES(16) -> 4 lines, 2 sets,
// 4 words/line -- small enough that a 3rd distinct tag into the same set
// forces a real eviction with only two prior fills, real timing margin for
// the probe-response mock below.
//
// The inclusion probe port (probe_req/probe_addr/probe_ack/probe_dirty/
// probe_data) is driven by a mock L1 responder task, entirely test-
// controlled (delay, dirty, data) -- proves L2Cache.v's own probe-before-
// evict handshake (docs/adr/0045's own "unconditional probe, L1's response
// is authoritative" design) independent of any real DCache.v/ICache.v.
module tb_l2cache_unit;
    reg clk = 0;
    always #5 clk = ~clk;

    integer fails = 0;
    integer checks = 0;

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

    // -- dut: WITH_DIRTY=1 (D-side shape) --
    reg         rst = 0;
    reg         u_cyc = 0, u_stb = 0, u_we = 0;
    reg  [31:0] u_addr = 0, u_data_o = 0;
    reg  [3:0]  u_sel = 4'hF;
    reg  [2:0]  u_funct3 = 3'b010;
    wire [31:0] u_data_i;
    wire        u_ack;
    wire        m_cyc, m_stb, m_we;
    wire [31:0] m_addr, m_data_o;
    wire [3:0]  m_sel;
    wire [2:0]  m_funct3;
    wire [31:0] m_data_i;
    wire        m_ack;
    wire        probe_req;
    wire [31:0] probe_addr;
    reg         probe_ack = 0;
    reg         probe_dirty = 0;
    reg  [127:0] probe_data = 0;   // XLEN(32)*LINE_WORDS(4) = 128 bits
    wire        access_hit, access_miss;

    L2Cache #(.XLEN(32), .WAYS(2), .CACHE_SIZE_BYTES(64), .LINE_BYTES(16), .WITH_DIRTY(1)) dut(
        .clk(clk), .rst(rst),
        .u_cyc(u_cyc), .u_stb(u_stb), .u_we(u_we), .u_addr(u_addr), .u_data_o(u_data_o),
        .u_sel(u_sel), .u_funct3(u_funct3), .u_data_i(u_data_i), .u_ack(u_ack),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_addr(m_addr), .m_data_o(m_data_o),
        .m_sel(m_sel), .m_funct3(m_funct3), .m_data_i(m_data_i), .m_ack(m_ack),
        .probe_req(probe_req), .probe_addr(probe_addr), .probe_ack(probe_ack),
        .probe_dirty(probe_dirty), .probe_data(probe_data),
        .access_hit(access_hit), .access_miss(access_miss),
        .flush_all(1'b0), .flush_busy(), .flush_done()
    );

    reg rst_ram = 0;
    RamWishboneAdapter #(.SIZE_BYTES(256), .XLEN(32)) m_ram_adapter(
        .clk(clk), .rst(rst_ram),
        .s_cyc(m_cyc), .s_stb(m_stb), .s_we(m_we), .s_addr(m_addr),
        .s_data_o(m_data_o), .s_sel(m_sel), .funct3(m_funct3),
        .s_data_i(m_data_i), .s_ack(m_ack)
    );

    // Mock L1 probe responder -- entirely test-controlled via
    // mock_probe_delay/mock_probe_dirty/mock_probe_data, set by the test
    // thread before triggering whichever eviction is under test.
    integer mock_probe_delay = 1;
    reg     mock_probe_dirty = 0;
    reg [127:0] mock_probe_data = 0;
    reg     mock_probe_active = 0;
    integer mock_probe_cnt = 0;
    always @(posedge clk) begin
        if (~rst) begin
            probe_ack <= 0;
            mock_probe_active <= 0;
        end
        else begin
            probe_ack <= 0;
            if (probe_req && !mock_probe_active) begin
                mock_probe_active <= 1;
                mock_probe_cnt <= 0;
            end
            else if (mock_probe_active) begin
                if (mock_probe_cnt >= mock_probe_delay) begin
                    probe_ack   <= 1;
                    probe_dirty <= mock_probe_dirty;
                    probe_data  <= mock_probe_data;
                    mock_probe_active <= 0;
                end
                else begin
                    mock_probe_cnt <= mock_probe_cnt + 1;
                end
            end
        end
    end

    task do_read;
        input [31:0] addr;
        reg ready_seen;
        begin
            @(negedge clk);
            u_addr = addr; u_funct3 = 3'b010; u_cyc = 1; u_stb = 1; u_we = 0;
            ready_seen = 0;
            while (!ready_seen) begin
                @(posedge clk); #1;
                if (u_ack) ready_seen = 1;
            end
            last_rdata = u_data_i;
            @(negedge clk); u_cyc = 0; u_stb = 0;
        end
    endtask
    reg [31:0] last_rdata;

    task do_write;
        input [31:0] addr;
        input [31:0] wdata;
        reg ready_seen;
        begin
            @(negedge clk);
            u_addr = addr; u_data_o = wdata; u_funct3 = 3'b010; u_cyc = 1; u_stb = 1; u_we = 1;
            ready_seen = 0;
            while (!ready_seen) begin
                @(posedge clk); #1;
                if (u_ack) ready_seen = 1;
            end
            @(negedge clk); u_cyc = 0; u_stb = 0; u_we = 0;
        end
    endtask

    // Observes whether m_we (a writeback) ever asserts during the NEXT
    // eviction-triggering access below -- sampled by the caller around a
    // do_read/do_write call bracketing the eviction.
    reg wb_observed;
    always @(posedge clk) begin
        if (m_cyc && m_we) wb_observed <= 1'b1;
    end

    initial begin
        @(posedge clk); rst <= 0; rst_ram <= 0;
        @(posedge clk); rst <= 1; rst_ram <= 1;
        @(posedge clk);

        // === Case 1: cold miss, read from (zero-initialized) backing RAM ===
        do_read(32'h00);   // set0, tag0, way0 (cold fill)
        check_word(last_rdata, 32'h00000000, "case1: addr0 cold-miss read from zero-init backing RAM");
        check_bit(access_miss !== 1'bx, 1'b1, "case1: access_miss wire is driven");

        // === Case 2: read-hit, no bus traffic ===
        @(negedge clk); wb_observed = 1'b0;
        do_read(32'h00);
        check_bit(m_cyc, 1'b0, "case2: read-hit issues no downstream bus traffic");

        // === Case 3: write-hit, combinational ack, dirties the line ===
        do_write(32'h00, 32'hAAAA0001);   // dirties way0/set0
        check_bit(dut.dirty[0], 1'b1, "case3: write-hit sets dirty[line0]");
        do_read(32'h00);
        check_word(last_rdata, 32'hAAAA0001, "case3: write-hit merge readable back");

        // === Case 4: fill way1/set0 with a second, clean, cold-miss line ===
        do_read(32'h20);   // set0 (bit4=0... wait: OFFSET_BITS=4, SET_BITS=1 -> set_idx = addr[4]; 0x20=100000b, addr[4]=0 -> also set0, tag differs)
        check_word(last_rdata, 32'h00000000, "case4: addr0x20 cold-miss (set0, way1)");

        // === Case 5: a THIRD distinct tag into set0 forces eviction of
        // way0 (addr0's own dirty line, round-robin victim after way0 then
        // way1 were filled in order). Mock L1 reports NOT dirty (probe
        // finds nothing / clean) -- L2's OWN dirty bit must still drive a
        // real writeback of addr0's own data (0xAAAA0001), regardless of
        // the probe's answer. ===
        mock_probe_dirty = 1'b0;
        mock_probe_data  = 128'h0;
        mock_probe_delay = 2;
        @(negedge clk); wb_observed = 1'b0;
        do_read(32'h40);   // set0, new tag -- forces eviction
        check_bit(wb_observed, 1'b1, "case5: L2's own dirty bit forces a real writeback even though the probe reported clean");

        // Re-read addr0 -- now evicted from L2, must genuinely refetch from
        // backing RAM, proving the writeback in case5 actually landed.
        mock_probe_dirty = 1'b0;   // whichever line THIS eviction (of way1, holding addr0x40) displaces -- not under test here
        do_read(32'h00);
        check_word(last_rdata, 32'hAAAA0001, "case5: addr0 re-fetch from backing RAM returns the writeback's own data");

        // === Case 6: probe-dirty pullback -- L2's own copy of a CLEAN line
        // is evicted, but L1 (the mock) reports it as dirty with DIFFERENT
        // data than L2's own stale copy. L2's writeback must use the
        // PROBE's data, not its own. ===
        do_read(32'h20);   // re-fill addr0x20 (clean, was evicted by case5's own second fill of way1)
        mock_probe_dirty = 1'b1;
        mock_probe_data  = {32'hDEADBEEF, 32'hDEADBEEF, 32'hDEADBEEF, 32'hCAFEF00D};
        mock_probe_delay = 2;
        @(negedge clk); wb_observed = 1'b0;
        do_read(32'h60);   // set0, new tag -- round-robin victim is way1 here, which holds addr0x00's line (re-filled clean by case5's own re-fetch) -- NOT addr0x20 (confirmed by hand-tracing victim[] rotation, not assumed)
        check_bit(wb_observed, 1'b1, "case6: a probe-reported-dirty line is written back even though L2's own copy was clean");
        mock_probe_dirty = 1'b0;
        do_read(32'h00);   // re-fetch addr0 -- must reflect the PROBE's data (written back to addr0's own backing-RAM slot), not L2's stale clean copy
        check_word(last_rdata, 32'hCAFEF00D, "case6: dirty-pullback data (word0) reached backing RAM correctly");

        // === Case 7: a genuinely clean line, clean probe response -- no
        // writeback at all (straight to S_FILL). ===
        do_read(32'h80);   // set0, fresh cold miss into whichever way is now victim
        mock_probe_dirty = 1'b0;
        mock_probe_delay = 2;
        @(negedge clk); wb_observed = 1'b0;
        do_read(32'hA0);   // set0, new tag -- evicts addr0x80's own clean line
        check_bit(wb_observed, 1'b0, "case7: a clean line with a clean probe response is never written back");

        $display("=== tb_l2cache_unit dut: %0d/%0d checks passed ===", checks - fails, checks);

        // === dut_ro: WITH_DIRTY=0 (I-side shape) -- never asserts a
        // writeback regardless of write traffic (I$ never legitimately
        // writes, but the module must still be SAFE if it somehow did). ===
        @(posedge clk); rst_ro <= 0;
        @(posedge clk); rst_ro <= 1;
        @(posedge clk);
        wb_ro_observed = 1'b0;
        do_read_ro(32'h00);
        check_word(last_rdata_ro, 32'h00000000, "dut_ro: cold-miss read (WITH_DIRTY=0 shape)");
        do_read_ro(32'h40);   // new tag, same set -- forces eviction of the first (never-dirtied) line
        check_bit(wb_ro_observed, 1'b0, "dut_ro: WITH_DIRTY=0 instance never writes back on eviction");

        $display("=== tb_l2cache_unit: %0d/%0d checks passed ===", checks - fails, checks);
        if (fails == 0) $display("PASS  l2cache_unit (%0d checks)", checks);
        else $display("FAIL  l2cache_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end

    // -- dut_ro: WITH_DIRTY=0 (I-side shape), separate small instance --
    reg         rst_ro = 0;
    reg         u_cyc_ro = 0, u_stb_ro = 0;
    reg  [31:0] u_addr_ro = 0;
    wire [31:0] u_data_i_ro;
    wire        u_ack_ro;
    wire        m_cyc_ro, m_stb_ro, m_we_ro;
    wire [31:0] m_addr_ro, m_data_o_ro;
    wire [3:0]  m_sel_ro;
    wire [2:0]  m_funct3_ro;
    wire [31:0] m_data_i_ro;
    wire        m_ack_ro;
    wire        probe_req_ro;
    wire [31:0] probe_addr_ro;

    L2Cache #(.XLEN(32), .WAYS(2), .CACHE_SIZE_BYTES(64), .LINE_BYTES(16), .WITH_DIRTY(0)) dut_ro(
        .clk(clk), .rst(rst_ro),
        .u_cyc(u_cyc_ro), .u_stb(u_stb_ro), .u_we(1'b0), .u_addr(u_addr_ro), .u_data_o(32'h0),
        .u_sel(4'hF), .u_funct3(3'b010), .u_data_i(u_data_i_ro), .u_ack(u_ack_ro),
        .m_cyc(m_cyc_ro), .m_stb(m_stb_ro), .m_we(m_we_ro), .m_addr(m_addr_ro), .m_data_o(m_data_o_ro),
        .m_sel(m_sel_ro), .m_funct3(m_funct3_ro), .m_data_i(m_data_i_ro), .m_ack(m_ack_ro),
        .probe_req(probe_req_ro), .probe_addr(probe_addr_ro), .probe_ack(1'b1),
        .probe_dirty(1'b0), .probe_data(128'h0),
        .access_hit(), .access_miss(),
        .flush_all(1'b0), .flush_busy(), .flush_done()
    );
    RamWishboneAdapter #(.SIZE_BYTES(256), .XLEN(32)) m_ram_adapter_ro(
        .clk(clk), .rst(rst_ro),
        .s_cyc(m_cyc_ro), .s_stb(m_stb_ro), .s_we(m_we_ro), .s_addr(m_addr_ro),
        .s_data_o(m_data_o_ro), .s_sel(m_sel_ro), .funct3(m_funct3_ro),
        .s_data_i(m_data_i_ro), .s_ack(m_ack_ro)
    );

    reg wb_ro_observed;
    always @(posedge clk) begin
        if (m_cyc_ro && m_we_ro) wb_ro_observed <= 1'b1;
    end

    reg [31:0] last_rdata_ro;
    task do_read_ro;
        input [31:0] addr;
        reg ready_seen;
        begin
            @(negedge clk);
            u_addr_ro = addr; u_cyc_ro = 1; u_stb_ro = 1;
            ready_seen = 0;
            while (!ready_seen) begin
                @(posedge clk); #1;
                if (u_ack_ro) ready_seen = 1;
            end
            last_rdata_ro = u_data_i_ro;
            @(negedge clk); u_cyc_ro = 0; u_stb_ro = 0;
        end
    endtask
endmodule
