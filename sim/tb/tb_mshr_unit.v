`include "DCache.v"
`include "Prefetcher.v"
`include "L2Cache.v"
`include "InstructionMemory.v"
`include "InstructionMemoryWishboneAdapter.v"
`include "RamWishboneAdapter.v"
`include "DataMemoryBRAM.v"
`include "VictimCache.v"

// docs/adr/0044-non-blocking-dcache-mshr-phase-e.md (Generation 4, Phase E).
// Standalone unit test for DCache.v's own MSHR dispatch/bus-service split,
// independent of the pipeline (no Scoreboard.v/RegisterFile.v involved --
// those get their own standalone tests, Task 3/4). Drives req_read/
// req_write/req_addr/req_dest_reg directly, same harness shape
// tb_dcache_unit.v established, against a REAL RamWishboneAdapter.v +
// DataMemoryBRAM.v backing instance.
//
// dut_a: MSHR_ENTRIES(2), WAYS(2), CACHE_SIZE_BYTES(128), LINE_BYTES(16) ->
// 4 sets (addr bits [5:4]), 4 words/line -- a real multi-cycle fill
// (~4-5 cycles) gives genuine timing margin for the queue-full/reject
// tests below; LINE_BYTES(8)'s own 2-word fills proved too fast, a
// same-timestep race with the testbench's own request-presentation
// overhead (found by running, not anticipated).
// dut_b: MSHR_ENTRIES(1) (the default) -- proves the degenerate/disabled
// case never exercises the new busy-dispatch paths at all (mshr_accept
// stays permanently 0), same sizing as dut_a for a direct comparison.
module tb_mshr_unit;
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

    // -- dut_a: MSHR_ENTRIES=2 --
    reg         rst_a = 0;
    reg         req_read_a = 0, req_write_a = 0;
    reg  [31:0] req_addr_a = 0, req_wdata_a = 0;
    reg  [2:0]  req_funct3_a = 3'b010;
    reg  [4:0]  req_dest_reg_a = 0;
    wire [31:0] resp_rdata_a;
    wire        resp_ready_a;
    reg         flush_all_a = 0;
    wire        flush_busy_a, flush_done_a;
    wire        mshr_accept_a, mshr_complete_a;
    wire [4:0]  mshr_complete_reg_a;
    wire [31:0] mshr_complete_data_a;
    wire        m_cyc_a, m_stb_a, m_we_a;
    wire [31:0] m_addr_a, m_data_o_a;
    wire [3:0]  m_sel_a;
    wire [2:0]  m_funct3_a;
    wire [31:0] m_data_i_a;
    wire        m_ack_a;

    DCache #(.XLEN(32), .WAYS(2), .CACHE_SIZE_BYTES(128), .LINE_BYTES(16), .MSHR_ENTRIES(2)) dut_a(
        .clk(clk), .rst(rst_a),
        .req_read(req_read_a), .req_write(req_write_a), .req_addr(req_addr_a),
        .req_wdata(req_wdata_a), .req_funct3(req_funct3_a), .req_dest_reg(req_dest_reg_a), .req_int_load(1'b1),
        .resp_rdata(resp_rdata_a), .resp_ready(resp_ready_a),
        .flush_all(flush_all_a), .flush_busy(flush_busy_a), .flush_done(flush_done_a),
        .mshr_accept(mshr_accept_a), .mshr_complete(mshr_complete_a),
        .mshr_complete_reg(mshr_complete_reg_a), .mshr_complete_data(mshr_complete_data_a),
        .m_cyc(m_cyc_a), .m_stb(m_stb_a), .m_we(m_we_a), .m_addr(m_addr_a),
        .m_data_o(m_data_o_a), .m_sel(m_sel_a), .m_funct3(m_funct3_a),
        .m_data_i(m_data_i_a), .m_ack(m_ack_a)
    );
    // Deliberately a SEPARATE reset from rst_a: DataMemoryBRAM.v's own
    // reset zero-inits the WHOLE backing array (Phase Q's cost-bounded
    // zero-init), which would silently wipe out the setup phase's own
    // flushed-to-memory values if it shared rst_a's mid-test pulse (used
    // below purely to clear the CACHE's own valid bits) -- a real system's
    // cache and backing memory don't share a reset domain that wipes
    // memory content just to clear cache tags, and neither should this
    // testbench's.
    reg rst_ram_a = 0;
    RamWishboneAdapter #(.SIZE_BYTES(192), .XLEN(32)) m_ram_adapter_a(
        .clk(clk), .rst(rst_ram_a),
        .s_cyc(m_cyc_a), .s_stb(m_stb_a), .s_we(m_we_a), .s_addr(m_addr_a),
        .s_data_o(m_data_o_a), .s_sel(m_sel_a), .funct3(m_funct3_a),
        .s_data_i(m_data_i_a), .s_ack(m_ack_a)
    );

    // -- dut_b: MSHR_ENTRIES=1 (default), regression-equivalence check --
    reg         rst_b = 0;
    reg         req_read_b = 0, req_write_b = 0;
    reg  [31:0] req_addr_b = 0, req_wdata_b = 0;
    reg  [2:0]  req_funct3_b = 3'b010;
    reg  [4:0]  req_dest_reg_b = 0;
    wire [31:0] resp_rdata_b;
    wire        resp_ready_b;
    reg         flush_all_b = 0;
    wire        flush_busy_b, flush_done_b;
    wire        mshr_accept_b, mshr_complete_b;
    wire [4:0]  mshr_complete_reg_b;
    wire [31:0] mshr_complete_data_b;
    wire        m_cyc_b, m_stb_b, m_we_b;
    wire [31:0] m_addr_b, m_data_o_b;
    wire [3:0]  m_sel_b;
    wire [2:0]  m_funct3_b;
    wire [31:0] m_data_i_b;
    wire        m_ack_b;

    DCache #(.XLEN(32), .WAYS(2), .CACHE_SIZE_BYTES(64), .LINE_BYTES(8)) dut_b(   // MSHR_ENTRIES defaults to 1
        .clk(clk), .rst(rst_b),
        .req_read(req_read_b), .req_write(req_write_b), .req_addr(req_addr_b),
        .req_wdata(req_wdata_b), .req_funct3(req_funct3_b), .req_dest_reg(req_dest_reg_b), .req_int_load(1'b1),
        .resp_rdata(resp_rdata_b), .resp_ready(resp_ready_b),
        .flush_all(flush_all_b), .flush_busy(flush_busy_b), .flush_done(flush_done_b),
        .mshr_accept(mshr_accept_b), .mshr_complete(mshr_complete_b),
        .mshr_complete_reg(mshr_complete_reg_b), .mshr_complete_data(mshr_complete_data_b),
        .m_cyc(m_cyc_b), .m_stb(m_stb_b), .m_we(m_we_b), .m_addr(m_addr_b),
        .m_data_o(m_data_o_b), .m_sel(m_sel_b), .m_funct3(m_funct3_b),
        .m_data_i(m_data_i_b), .m_ack(m_ack_b)
    );
    RamWishboneAdapter #(.SIZE_BYTES(128), .XLEN(32)) m_ram_adapter_b(
        .clk(clk), .rst(rst_b),
        .s_cyc(m_cyc_b), .s_stb(m_stb_b), .s_we(m_we_b), .s_addr(m_addr_b),
        .s_data_o(m_data_o_b), .s_sel(m_sel_b), .funct3(m_funct3_b),
        .s_data_i(m_data_i_b), .s_ack(m_ack_b)
    );

    reg mshr_accept_b_monitor_active = 0;
    reg mshr_accept_b_ever_fired = 0;
    always @(posedge clk) begin
        if (mshr_accept_b_monitor_active && mshr_accept_b)
            mshr_accept_b_ever_fired <= 1'b1;
    end

    // -- dut_a helpers --
    reg [31:0] last_rdata_a;
    task do_read_a;
        input [31:0] addr;
        reg ready_seen;
        begin
            @(negedge clk);
            req_addr_a = addr; req_funct3_a = 3'b010; req_read_a = 1; req_write_a = 0;
            ready_seen = 0;
            while (!ready_seen) begin
                @(posedge clk); #1;
                if (resp_ready_a) begin
                    ready_seen = 1;
                    last_rdata_a = resp_rdata_a;
                end
            end
            @(negedge clk); req_read_a = 0;
        end
    endtask

    task do_write_a;
        input [31:0] addr;
        input [31:0] wdata;
        reg ready_seen;
        integer cyc;
        begin
            @(negedge clk);
            req_addr_a = addr; req_wdata_a = wdata; req_funct3_a = 3'b010; req_write_a = 1; req_read_a = 0;
            ready_seen = 0;
            cyc = 0;
            while (!ready_seen) begin
                @(posedge clk); #1;
                cyc = cyc + 1;
                if (resp_ready_a) ready_seen = 1;
            end
            last_wait_cycles_a = cyc;
            @(negedge clk); req_write_a = 0;
        end
    endtask
    integer last_wait_cycles_a;

    task do_flush_a;
        begin
            @(negedge clk);
            flush_all_a = 1;
            @(posedge clk); #1;
            @(negedge clk);
            flush_all_a = 0;
            while (!flush_done_a) @(posedge clk);
            #1;
        end
    endtask

    // The one flexible read task Task 2's design collapses every dispatch
    // outcome into: an ordinary S_IDLE hit, a hit-under-miss (hu_pending_r,
    // resolves 1 cycle later than an ordinary hit), a fresh or
    // busy-dispatch MSHR accept (mshr_accept, no data yet), or -- if
    // neither ever fires -- a genuinely rejected/must-keep-holding request
    // (queue full, or a same-line conflict, or MSHR_ENTRIES==1) that just
    // keeps looping exactly like a real blocking caller would, until it
    // eventually resolves via whichever path becomes available.
    // mshr_accept is PURELY combinational (matching mem_stall/hit/
    // access_miss's own existing shape in this codebase, the correct
    // architectural choice for what a real synchronous caller consumes
    // same-cycle, see docs/adr/0044) -- true only DURING the cycle a miss
    // is recognized, BEFORE the edge that transitions state away from
    // S_IDLE (or S_WB/S_FILL, for a busy-dispatch accept). A caller must
    // therefore sample it mid-cycle (negedge, well after the PRECEDING
    // edge's own updates settled, well before the NEXT one) -- NOT via the
    // do_read/do_write idiom's own `@(posedge clk); #1` (that idiom
    // deliberately samples AFTER the state-transitioning edge, correct for
    // resp_ready's own LATCHED/persists-through-the-cycle-it-fires shape,
    // but it would always miss mshr_accept's transient pre-edge window).
    reg [31:0] last_data_a;
    reg        last_accepted_a;
    integer    last_cycles_a;
    task req_read_flex_a;
        input [31:0] addr;
        input [4:0]  dreg;
        reg done;
        integer cyc;
        begin
            @(negedge clk);
            req_addr_a = addr; req_dest_reg_a = dreg; req_funct3_a = 3'b010;
            req_read_a = 1; req_write_a = 0;
            #1;
            done = 0;
            last_accepted_a = 0;
            cyc = 0;
            while (!done) begin
                cyc = cyc + 1;
                if (mshr_accept_a) begin
                    last_accepted_a = 1;
                    done = 1;
                end
                else if (resp_ready_a) begin
                    last_data_a = resp_rdata_a;
                    done = 1;
                end
                else begin
                    @(negedge clk); #1;
                end
            end
            last_cycles_a = cyc;
            @(negedge clk); req_read_a = 0;
        end
    endtask

    // A completion can pulse (and vanish -- it's a 1-cycle signal) at ANY
    // cycle, including while the sequential test thread below is busy
    // running some OTHER task (e.g. case2's own hit-under-miss check
    // in-flight while addr24's own fill finishes in the background) --
    // sequential polling alone can miss it. An always-on monitor catches
    // every pulse into a small FIFO queue regardless of what the main
    // thread is doing; wait_mshr_complete_a just pops from that queue.
    reg [4:0]  mc_queue_reg  [0:7];
    reg [31:0] mc_queue_data [0:7];
    integer    mc_queue_head = 0, mc_queue_tail = 0;
    always @(posedge clk) begin
        if (mshr_complete_a) begin
            mc_queue_reg[mc_queue_tail]  <= mshr_complete_reg_a;
            mc_queue_data[mc_queue_tail] <= mshr_complete_data_a;
            mc_queue_tail <= mc_queue_tail + 1;
        end
    end

    reg [4:0]  last_mc_reg_a;
    reg [31:0] last_mc_data_a;
    task wait_mshr_complete_a;
        begin
            while (mc_queue_head == mc_queue_tail) begin
                @(posedge clk); #1;
            end
            last_mc_reg_a  = mc_queue_reg[mc_queue_head];
            last_mc_data_a = mc_queue_data[mc_queue_head];
            mc_queue_head  = mc_queue_head + 1;
        end
    endtask

    initial begin
        @(posedge clk); rst_a <= 0; rst_ram_a <= 0;
        @(posedge clk); rst_a <= 1; rst_ram_a <= 1;

        // -- Setup: establish 4 distinct backing-memory values via
        // write-allocate + flush, then reset ONLY the CACHE (rst_a, not
        // rst_ram_a -- DataMemoryBRAM.v's own reset zero-inits its whole
        // backing array, which would silently wipe the just-flushed values
        // right back out) to clear valid bits, so the real MSHR tests below
        // see genuine cold misses fetching these values from backing
        // memory, not stale cache content.
        do_write_a(0,  32'hAAAA0000);   // set0
        do_write_a(16, 32'hBBBB0000);   // set1
        do_write_a(32, 32'hCCCC0000);   // set2
        do_write_a(48, 32'hDDDD0000);   // set3
        do_flush_a();
        @(negedge clk); rst_a <= 0;
        @(posedge clk); @(posedge clk); rst_a <= 1;
        @(posedge clk);

        // === Case 1: two independent cold-miss loads accepted back to
        // back, different sets, complete in FIFO order with correct data ===
        req_read_flex_a(0, 5'd10);
        check_bit(last_accepted_a, 1'b1, "case1: addr0 cold miss accepted as a non-blocking MSHR");
        req_read_flex_a(16, 5'd11);
        check_bit(last_accepted_a, 1'b1, "case1: addr16 cold miss ALSO accepted while addr0 still filling");

        wait_mshr_complete_a();
        check_bit(last_mc_reg_a == 5'd10, 1'b1, "case1: first completion is addr0's own entry (FIFO order)");
        check_word(last_mc_data_a, 32'hAAAA0000, "case1: addr0 fill data correct");
        wait_mshr_complete_a();
        check_bit(last_mc_reg_a == 5'd11, 1'b1, "case1: second completion is addr16's own entry (FIFO order)");
        check_word(last_mc_data_a, 32'hBBBB0000, "case1: addr16 fill data correct");

        // === Case 2: hit-under-miss -- a resident hit resolves without
        // waiting for an unrelated in-flight miss ===
        do_write_a(32, 32'hCCCC1111);   // fresh write-allocate (cache was
                                         // reset above, addr32's old valid
                                         // bit is gone) -- resident now,
                                         // dirty, DIFFERENT value than the
                                         // flushed 0xCCCC0000 so a stale
                                         // hu_pending_r data mux bug (e.g.
                                         // silently reading fill_value
                                         // instead of hit_data) would show
                                         // up as the wrong constant.
        req_read_flex_a(48, 5'd12);
        check_bit(last_accepted_a, 1'b1, "case2: addr48 cold miss accepted");
        check_bit((dut_a.state == dut_a.S_WB) || (dut_a.state == dut_a.S_FILL), 1'b1,
            "case2 precondition: addr48 still mid-service (bus genuinely busy)");
        req_read_flex_a(32, 5'd13);
        check_bit(last_accepted_a, 1'b0, "case2: addr32 resolved as a HIT (hu_pending_r), not queued");
        check_word(last_data_a, 32'hCCCC1111, "case2: hit-under-miss returned the correct resident data");
        wait_mshr_complete_a();
        check_bit(last_mc_reg_a == 5'd12, 1'b1, "case2: addr48's own MSHR still completes correctly afterward");
        check_word(last_mc_data_a, 32'hDDDD0000, "case2: addr48 fill data correct");

        // === Case 3: queue full (both slots outstanding) rejects a 3rd
        // miss -- it must wait, not get a 3rd concurrent MSHR ===
        req_read_flex_a(64, 5'd14);   // set0, new tag -- genuine miss
        check_bit(last_accepted_a, 1'b1, "case3: addr64 accepted (slot 1/2)");
        req_read_flex_a(80, 5'd15);   // set1, new tag -- genuine miss
        check_bit(last_accepted_a, 1'b1, "case3: addr80 accepted (slot 2/2, queue now full)");
        // A 3rd distinct-line miss, issued while both slots are still
        // outstanding: req_read_flex_a's own loop can't distinguish "took
        // a while because it was genuinely rejected then retried" from
        // "accepted after some cycles" by construction, so check directly:
        // one cycle after presenting it, neither mshr_accept nor
        // resp_ready may be true yet (both slots are still busy). A real
        // 4-word fill (~4-5 cycles) gives genuine margin here -- LINE_BYTES
        // (8)'s own 2-word fills proved too fast for this check's own
        // presentation overhead, found by running.
        req_addr_a = 96; req_dest_reg_a = 5'd16; req_funct3_a = 3'b010; req_read_a = 1; req_write_a = 0;
        #1;   // mid-cycle sample -- see req_read_flex_a's own header comment for why (mshr_accept is transient, pre-edge)
        check_bit(mshr_accept_a || resp_ready_a, 1'b0, "case3: addr96 correctly rejected while queue is full (2/2 outstanding)");
        // Let a manual mid-cycle poll loop (same shape as req_read_flex_a)
        // take over and confirm it eventually DOES resolve, once a slot
        // frees up.
        while (!(mshr_accept_a || resp_ready_a)) begin
            @(negedge clk); #1;
        end
        check_bit(mshr_accept_a, 1'b1, "case3: addr96 eventually accepted once a slot freed");
        @(negedge clk); req_read_a = 0;
        // Drain remaining completions (addr64, addr80, addr96 -- FIFO).
        wait_mshr_complete_a(); check_word(last_mc_data_a, 32'h00000000, "case3: addr64 fill data (never written, backing RAM default)");
        wait_mshr_complete_a(); check_word(last_mc_data_a, 32'h00000000, "case3: addr80 fill data (never written, backing RAM default)");
        wait_mshr_complete_a(); check_word(last_mc_data_a, 32'h00000000, "case3: addr96 fill data (never written, backing RAM default)");

        // === Case 4: two loads to the SAME missing line don't allocate a
        // second MSHR -- the second one waits, then both see correct data ===
        req_read_flex_a(112, 5'd17);   // set3, new tag -- genuine miss
        check_bit(last_accepted_a, 1'b1, "case4: addr112 accepted");
        @(negedge clk);
        req_addr_a = 116; req_dest_reg_a = 5'd18; req_funct3_a = 3'b010; req_read_a = 1; req_write_a = 0; // same line as 112 (112..127)
        #1;
        check_bit(mshr_accept_a, 1'b0, "case4: addr116 (same line as addr112) does NOT get a second concurrent MSHR");
        while (!(mshr_accept_a || resp_ready_a)) begin
            @(negedge clk); #1;
        end
        check_bit(resp_ready_a, 1'b1, "case4: addr116 eventually resolves as an ordinary hit once addr112's own fill lands");
        last_rdata_a = resp_rdata_a;
        check_word(last_rdata_a, 32'h00000000, "case4: addr116 (word1 of the same line, never written) reads correct data");
        @(negedge clk); req_read_a = 0;
        wait_mshr_complete_a();
        check_bit(last_mc_reg_a == 5'd17, 1'b1, "case4: addr112's own single MSHR completes exactly once");

        // === Case 5: a store never becomes non-blocking, even with free
        // MSHR slots -- it always waits for a full drain first ===
        req_read_flex_a(128, 5'd19);   // set0, new tag -- genuine miss, 1 slot in use, 1 free
        check_bit(last_accepted_a, 1'b1, "case5: addr128 accepted (1/2 slots busy, 1 free)");
        do_write_a(144, 32'hEEEEEEEE);   // set1, new tag -- a store while an MSHR is still outstanding
        check_bit(last_wait_cycles_a > 4, 1'b1, "case5: addr144 store genuinely waited for the outstanding MSHR to drain (not an immediate same-cycle hit-shaped ack)");
        wait_mshr_complete_a();
        check_bit(last_mc_reg_a == 5'd19, 1'b1, "case5: addr128's own MSHR still completes correctly");

        $display("=== tb_mshr_unit dut_a: %0d/%0d checks passed ===", checks - fails, checks);

        // === dut_b: MSHR_ENTRIES=1 (default) -- mshr_accept must never
        // fire, matching bit-identical pre-Phase-E blocking behavior. A
        // continuous monitor covers the whole fill; the read itself uses
        // the same do_read-style wait-for-resp_ready idiom as dut_a's setup
        // helper (mirrored inline here rather than adding a 3rd near-
        // duplicate task).
        @(posedge clk); rst_b <= 0;
        @(posedge clk); rst_b <= 1;
        @(posedge clk);

        mshr_accept_b_monitor_active = 1;
        @(negedge clk);
        req_addr_b = 0; req_dest_reg_b = 5'd20; req_funct3_b = 3'b010; req_read_b = 1; req_write_b = 0;
        begin : dut_b_wait
            reg ready_seen_b;
            ready_seen_b = 0;
            while (!ready_seen_b) begin
                @(posedge clk); #1;
                if (resp_ready_b) ready_seen_b = 1;
            end
        end
        @(negedge clk); req_read_b = 0;
        mshr_accept_b_monitor_active = 0;
        check_bit(mshr_accept_b_ever_fired, 1'b0, "dut_b (MSHR_ENTRIES=1): mshr_accept never fired during the whole fill");

        $display("=== tb_mshr_unit: %0d/%0d checks passed ===", checks - fails, checks);
        if (fails == 0) $display("PASS  mshr_unit (%0d checks)", checks);
        else $display("FAIL  mshr_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
