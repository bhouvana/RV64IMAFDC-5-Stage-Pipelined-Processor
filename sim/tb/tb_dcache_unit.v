`include "DCache.v"
`include "RamWishboneAdapter.v"
`include "DataMemoryBRAM.v"

// docs/adr/0023-caches.md (Phase G4). Standalone unit test for DCache.v,
// independent of the pipeline, against a REAL RamWishboneAdapter.v +
// DataMemoryBRAM.v backing instance (not a fake bus stub -- fill/writeback
// timing needs to be checked against the real slave's actual ack behavior,
// same discipline tb_ptw_unit.v's own mock-but-timing-accurate slave used).
// Deliberately instantiated SMALL (2-way, 32B total, 8B lines -> 2 sets, 2
// ways/set, 2 words/line), same rationale as tb_icache_unit.v: forces real
// conflict misses/eviction/dirty-writeback rather than relying on the real
// 4-way/4KB default, which this test's small address range would never
// evict from.
module tb_dcache_unit;
    reg clk = 0;
    reg rst = 0;

    reg         req_read = 0;
    reg         req_write = 0;
    reg  [31:0] req_addr = 0;
    reg  [31:0] req_wdata = 0;
    reg  [2:0]  req_funct3 = 3'b010;
    wire [31:0] resp_rdata;
    wire        resp_ready;
    reg         flush_all = 0;
    wire        flush_busy, flush_done;

    wire        m_cyc, m_stb, m_we;
    wire [31:0] m_addr, m_data_o;
    wire [3:0]  m_sel;
    wire [2:0]  m_funct3;
    wire [31:0] m_data_i;
    wire        m_ack;

    DCache #(.XLEN(32), .WAYS(2), .CACHE_SIZE_BYTES(32), .LINE_BYTES(8)) dut(
        .clk(clk), .rst(rst),
        .req_read(req_read), .req_write(req_write), .req_addr(req_addr),
        .req_wdata(req_wdata), .req_funct3(req_funct3),
        .resp_rdata(resp_rdata), .resp_ready(resp_ready),
        .flush_all(flush_all), .flush_busy(flush_busy), .flush_done(flush_done),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_addr(m_addr),
        .m_data_o(m_data_o), .m_sel(m_sel), .m_funct3(m_funct3),
        .m_data_i(m_data_i), .m_ack(m_ack)
    );

    // Real backing memory, 64 bytes -- room for several distinct tags'
    // worth of lines at this cache's own small sizing.
    RamWishboneAdapter #(.SIZE_BYTES(64), .XLEN(32)) m_ram_adapter(
        .clk(clk), .rst(rst),
        .s_cyc(m_cyc), .s_stb(m_stb), .s_we(m_we), .s_addr(m_addr),
        .s_data_o(m_data_o), .s_sel(m_sel), .funct3(m_funct3),
        .s_data_i(m_data_i), .s_ack(m_ack)
    );

    // docs/adr/0041-cache-replacement-policy-phase-b.md. A second, fully
    // independent DUT: 4-way/2-set (64B cache, 8B lines -> 8 lines / 4 ways
    // = 2 sets), REPLACEMENT_POLICY=2 (POLICY_LRU) -- same worked example
    // tb_icache_unit.v's own dut3 proves, adapted for D-side read/write.
    // Test addresses all share bit3=0 (set0), same routing-around of the
    // pre-existing SET_BITS==0 part-select bug (docs/adr/0041) dut3 uses.
    reg rst2 = 0;
    reg         req_read2 = 0;
    reg         req_write2 = 0;
    reg  [31:0] req_addr2 = 0;
    reg  [31:0] req_wdata2 = 0;
    reg  [2:0]  req_funct32 = 3'b010;
    wire [31:0] resp_rdata2;
    wire        resp_ready2;
    reg         flush_all2 = 0;
    wire        flush_busy2, flush_done2;
    wire        m_cyc2, m_stb2, m_we2;
    wire [31:0] m_addr2, m_data_o2;
    wire [3:0]  m_sel2;
    wire [2:0]  m_funct32;
    wire [31:0] m_data_i2;
    wire        m_ack2;

    DCache #(.XLEN(32), .WAYS(4), .CACHE_SIZE_BYTES(64), .LINE_BYTES(8),
             .REPLACEMENT_POLICY(2)) dut2(
        .clk(clk), .rst(rst2),
        .req_read(req_read2), .req_write(req_write2), .req_addr(req_addr2),
        .req_wdata(req_wdata2), .req_funct3(req_funct32),
        .resp_rdata(resp_rdata2), .resp_ready(resp_ready2),
        .flush_all(flush_all2), .flush_busy(flush_busy2), .flush_done(flush_done2),
        .m_cyc(m_cyc2), .m_stb(m_stb2), .m_we(m_we2), .m_addr(m_addr2),
        .m_data_o(m_data_o2), .m_sel(m_sel2), .m_funct3(m_funct32),
        .m_data_i(m_data_i2), .m_ack(m_ack2)
    );
    RamWishboneAdapter #(.SIZE_BYTES(96), .XLEN(32)) m_ram_adapter2(
        .clk(clk), .rst(rst2),
        .s_cyc(m_cyc2), .s_stb(m_stb2), .s_we(m_we2), .s_addr(m_addr2),
        .s_data_o(m_data_o2), .s_sel(m_sel2), .funct3(m_funct32),
        .s_data_i(m_data_i2), .s_ack(m_ack2)
    );

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

    // Issues a request and waits for resp_ready, CAPTURING resp_rdata at the
    // exact delta it's valid -- resp_ready/resp_rdata are only valid for one
    // simulation delta (combinational, tied to a transient FSM state), so a
    // caller that samples them even one statement later after further time
    // has passed will see them already reverted.
    reg [31:0] last_rdata;
    task do_read;
        input [31:0] addr;
        input [2:0] funct3;
        reg ready_seen;
        begin
            @(negedge clk);
            req_addr = addr; req_funct3 = funct3; req_read = 1; req_write = 0;
            ready_seen = 0;
            while (!ready_seen) begin
                @(posedge clk);
                #1;
                if (resp_ready) begin
                    ready_seen = 1;
                    last_rdata = resp_rdata;
                end
            end
            @(negedge clk);
            req_read = 0;
        end
    endtask

    task do_write;
        input [31:0] addr;
        input [31:0] wdata;
        input [2:0] funct3;
        reg ready_seen;
        begin
            @(negedge clk);
            req_addr = addr; req_wdata = wdata; req_funct3 = funct3; req_write = 1; req_read = 0;
            ready_seen = 0;
            while (!ready_seen) begin
                @(posedge clk);
                #1;
                if (resp_ready) ready_seen = 1;
            end
            @(negedge clk);
            req_write = 0;
        end
    endtask

    task do_flush;
        begin
            @(negedge clk);
            flush_all = 1;
            @(posedge clk);
            #1;
            @(negedge clk);
            flush_all = 0;
            while (!flush_done) @(posedge clk);
            #1;
        end
    endtask

    reg [31:0] last_rdata2;
    // docs/adr/0041. Cycle-count-based hit/miss differentiator (mirrors
    // tb_icache_unit.v's own MEM_LATENCY timing check) -- a genuine hit
    // resolves in exactly 1 posedge (S_IDLE->S_HIT_RD, resp_ready fires);
    // a genuine miss takes many more (S_WB and/or S_FILL's own multi-word
    // transfer).
    reg        last_was_miss2;
    // docs/adr/0041. A read-hit's own access_hit clause (state==S_HIT_RD &&
    // req_read && ...) is evaluated on the S_HIT_RD->S_IDLE registering
    // edge itself -- req_read2 has to stay asserted THROUGH that edge, one
    // full cycle later than resp_ready2 first goes high (which fires
    // combinationally the SAME cycle S_HIT_RD is entered, not the cycle it
    // exits). Dropping req_read2 right after seeing resp_ready2 (as the
    // pre-existing do_read/do_write above do, harmless for THEIR own
    // purposes since they only ever need resp_ready/resp_rdata's own
    // single-instant value) silently starves lru_touch's own read-hit call
    // of ever seeing req_read=1 at the edge that needs it -- a real bug in
    // this NEW helper task, not in access_hit's own design (a real pipeline
    // caller naturally holds req_read asserted until mem_stall lets it
    // advance, which is always at least this long). Found and fixed while
    // debugging this exact sub-test showing content correct but hit/miss
    // wrong (round-robin's own eviction choice, not LRU's).
    task do_read2;
        input [31:0] addr;
        input [2:0] funct3;
        reg ready_seen;
        integer cyc;
        begin
            @(negedge clk);
            req_addr2 = addr; req_funct32 = funct3; req_read2 = 1; req_write2 = 0;
            ready_seen = 0;
            cyc = 0;
            while (!ready_seen) begin
                @(posedge clk);
                cyc = cyc + 1;
                #1;
                if (resp_ready2) begin
                    ready_seen = 1;
                    last_rdata2 = resp_rdata2;
                end
            end
            last_was_miss2 = (cyc > 1);   // a hit resolves in exactly 1 cycle
            // Only a HIT needs the extra cycle (see this task's own header
            // comment) -- a MISS's own touch already happened via the
            // registered miss_set_r/miss_way_r path inside S_FILL, and
            // state is back at S_IDLE THIS same cycle, so holding req_read2
            // one cycle longer here would look like a brand-new request and
            // spuriously double-access the line just filled.
            if (!last_was_miss2)
                @(posedge clk);
            @(negedge clk);
            req_read2 = 0;
        end
    endtask

    task do_write2;
        input [31:0] addr;
        input [31:0] wdata;
        input [2:0] funct3;
        reg ready_seen;
        begin
            @(negedge clk);
            req_addr2 = addr; req_wdata2 = wdata; req_funct32 = funct3; req_write2 = 1; req_read2 = 0;
            ready_seen = 0;
            while (!ready_seen) begin
                @(posedge clk);
                #1;
                if (resp_ready2) ready_seen = 1;
            end
            @(negedge clk);
            req_write2 = 0;
        end
    endtask

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // -- Read miss/fill (clean line), then hit --
        do_read(0, 3'b010);
        check_word(last_rdata, 32'h0, "addr0 read-miss/fill: initial content is 0 (backing RAM reset)");
        do_read(0, 3'b010);
        check_word(last_rdata, 32'h0, "addr0 hit-read (1-cycle path) returns same content");

        // -- Write hit (same line, word 1 = addr4): combinational ack, no stall --
        @(negedge clk);
        req_addr = 4; req_wdata = 32'hCAFEBABE; req_funct3 = 3'b010; req_write = 1;
        #1;
        check_bit(resp_ready, 1'b1, "write-hit acks combinationally, same cycle (no stall)");
        @(negedge clk); req_write = 0;
        do_read(4, 3'b010);
        check_word(last_rdata, 32'hCAFEBABE, "addr4 read-back reflects the hit-write");

        // -- Write miss (write-allocate): different set (addr8, set1) --
        do_write(8, 32'hDEADBEEF, 3'b010);
        do_read(8, 3'b010);
        check_word(last_rdata, 32'hDEADBEEF, "addr8 read-back reflects the write-allocate merge");

        // -- Sub-word store/load round trip (sb at byte offset 1 of addr16, set0/tag1) --
        do_write(17, 32'h000000AB, 3'b000);   // sb: only byte 0 of wdata (0xAB) used
        do_read(16, 3'b010);
        check_word(last_rdata, 32'h0000AB00, "sb at byte-offset 1 merges into the correct lane, rest zero");
        do_read(17, 3'b100);   // lbu at the same byte
        check_word(last_rdata, 32'h000000AB, "lbu round-trips the sb'd byte");

        // -- Dirty eviction: addr16 (set0/tag1, way1) is dirty from the sb above.
        // addr32 is set0/tag2 -- the 3rd distinct tag in this 2-way set, forces
        // round-robin eviction (victim[0] progressed 0->1 after addr0's fill,
        // 1->0 after addr16's fill -- so addr32 lands in way0, evicting addr0's
        // clean line, NOT addr16's dirty one, on this first eviction).
        do_write(32, 32'h11111111, 3'b010);
        do_read(0, 3'b010);
        check_word(last_rdata, 32'h0, "addr0's clean content survived its own (writeback-free) eviction correctly");

        // Now force a SECOND eviction in set0 -- victim[0] is at way1 next
        // (wrapped after addr32's fill landed in way0), so refilling addr0
        // again evicts addr16's DIRTY line (way1), which MUST write back to
        // the real backing RAM before the new fill proceeds.
        do_read(0, 3'b010);
        checks = checks + 1;
        if (m_ram_adapter.m_ram.data_memory[16] !== 8'h00 || m_ram_adapter.m_ram.data_memory[17] !== 8'hAB) begin
            fails = fails + 1;
            $display("FAIL  addr16's dirty sb (0xAB at byte 1) landed in backing RAM after eviction-writeback: got [%02h,%02h], expected [00,AB]",
                m_ram_adapter.m_ram.data_memory[16], m_ram_adapter.m_ram.data_memory[17]);
        end else $display("pass  addr16's dirty sb (0xAB at byte 1) landed in backing RAM after eviction-writeback");

        // -- flush_all: write a fresh dirty word, flush, confirm backing RAM sees it --
        do_write(40, 32'h5A5A5A5A, 3'b010);   // set1/tag2 (addr40: bit3=1 -> set1)
        checks = checks + 1;
        if (m_ram_adapter.m_ram.data_memory[40] === 8'h5A) begin
            fails = fails + 1;
            $display("FAIL  addr40 landed in backing RAM BEFORE flush -- write-back cache should hold it dirty, not write through");
        end else $display("pass  addr40 NOT yet in backing RAM before flush (genuinely write-back, not write-through)");

        do_flush;
        check_bit(flush_busy, 1'b0, "flush_busy clears once flush completes");
        checks = checks + 1;
        if (m_ram_adapter.m_ram.data_memory[40] !== 8'h5A || m_ram_adapter.m_ram.data_memory[41] !== 8'h5A
            || m_ram_adapter.m_ram.data_memory[42] !== 8'h5A || m_ram_adapter.m_ram.data_memory[43] !== 8'h5A) begin
            fails = fails + 1;
            $display("FAIL  addr40's dirty word (0x5A5A5A5A) not correctly in backing RAM after flush_all: got [%02h,%02h,%02h,%02h]",
                m_ram_adapter.m_ram.data_memory[40], m_ram_adapter.m_ram.data_memory[41],
                m_ram_adapter.m_ram.data_memory[42], m_ram_adapter.m_ram.data_memory[43]);
        end else $display("pass  addr40's dirty word correctly landed in backing RAM after flush_all");

        // Cache still hits after flush (data stays cached, only becomes clean).
        do_read(40, 3'b010);
        check_word(last_rdata, 32'h5A5A5A5A, "addr40 still hits (cached, clean) after flush -- flush doesn't invalidate");

        // -- POLICY_LRU sub-test (dut2): same worked example as
        // tb_icache_unit.v's own dut3 -- fill A(0),B(16),C(32),D(48) (one
        // per way, all sharing bit3=0/set0), re-touch A and B (hits), miss
        // on E(64) forces eviction. Round-robin's blind pointer would evict
        // A; true LRU evicts C. Uses do_read2's own cycle-count-based
        // last_was_miss2 (not content comparison) for the differentiator
        // checks: C's own dirty write gets correctly written back to
        // backing RAM on eviction, so a post-eviction read-back would show
        // the SAME content whether it hit or genuinely missed-then-refilled
        // -- only real hit/miss timing disambiguates.
        @(posedge clk); rst2 <= 0;
        @(posedge clk); rst2 <= 1;

        do_write2(0,  32'hAAAA0000, 3'b010);
        do_write2(16, 32'hBBBB0000, 3'b010);
        do_write2(32, 32'hCCCC0000, 3'b010);
        do_write2(48, 32'hDDDD0000, 3'b010);   // all 4 ways of set0 now full

        do_read2(0, 3'b010);
        check_word(last_rdata2, 32'hAAAA0000, "LRU-D: addr0 (A) re-touch hit, correct data");
        do_read2(16, 3'b010);
        check_word(last_rdata2, 32'hBBBB0000, "LRU-D: addr16 (B) re-touch hit, correct data");

        do_write2(64, 32'hEEEE0000, 3'b010);   // 5th distinct tag: forces eviction
        do_read2(64, 3'b010);
        check_word(last_rdata2, 32'hEEEE0000, "LRU-D: addr64 (E) fill/read-back correct");

        // docs/adr/0041: check D and A (both still genuinely cached) BEFORE
        // re-reading C -- C's own re-read is itself a fresh miss (its line
        // was just evicted), which correctly forces ANOTHER real eviction
        // (of whichever way is now LRU-tail) to make room for its refill.
        // Checking C first would cascade into a second, unplanned eviction
        // before D/A's own checks ran, corrupting the very thing they're
        // meant to prove. Real LRU behavior, not a bug -- reordered instead
        // of "fixing" the RTL to match a wrong test expectation.
        do_read2(48, 3'b010);
        check_bit(last_was_miss2, 1'b0, "LRU-D: addr48 (D) still HITS -- LRU correctly spared it over C");
        check_word(last_rdata2, 32'hDDDD0000, "LRU-D: addr48 (D) content undisturbed");
        do_read2(0, 3'b010);
        check_bit(last_was_miss2, 1'b0, "LRU-D: addr0 (A) still HITS -- round-robin's blind choice (evict A) would have failed this");
        check_word(last_rdata2, 32'hAAAA0000, "LRU-D: addr0 (A) content undisturbed");
        do_read2(32, 3'b010);
        check_bit(last_was_miss2, 1'b1, "LRU-D: addr32 (C) genuinely MISSES -- true LRU evicted the actual least-recently-used way");
        check_word(last_rdata2, 32'hCCCC0000, "LRU-D: addr32 (C) refill content correct (its own dirty writeback landed before the new fill)");

        if (fails == 0)
            $display("PASS  dcache_unit (%0d checks)", checks);
        else
            $display("FAIL  dcache_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
