`include "VictimCache.v"

// docs/adr/0042-victim-cache-phase-c.md (Generation 4, Phase C). Standalone
// unit test for VictimCache.v, independent of ICache.v/DCache.v. Two DUT
// instances: `dut` (ENTRIES=4/WITH_DIRTY=1) exercises cold-miss, insert,
// and swap-promote; `dut2` (a fresh, independently-reset instance, same
// sizing) exercises FIFO wraparound eviction on its own, avoiding state
// bleed between scenarios (mirrors tb_icache_unit.v's own multi-dut
// convention for exactly this reason).
//
// Sizing: TAG_WIDTH=20 (an arbitrary combined set+tag width, this module
// never interprets it), LINE_WORDS=2/XLEN=32 -> 64-bit lines.
module tb_victimcache_unit;
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

    task check_data64;
        input [63:0] actual, expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: 0x%016h, expected 0x%016h", label, actual, expected);
            end else begin
                $display("pass  %0s: 0x%016h", label, actual);
            end
        end
    endtask

    task check_tag20;
        input [19:0] actual, expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: 0x%05h, expected 0x%05h", label, actual, expected);
            end else begin
                $display("pass  %0s: 0x%05h", label, actual);
            end
        end
    endtask

    // --- dut: cold-miss / insert / swap-promote ---
    reg rst = 0;
    reg [19:0] lookup_tag = 0;
    wire lookup_hit;
    wire [63:0] lookup_data;
    wire lookup_dirty;
    reg do_swap = 0;
    reg [19:0] swap_in_tag = 0;
    reg [63:0] swap_in_data = 0;
    reg swap_in_dirty = 0;
    reg do_insert = 0;
    reg [19:0] insert_tag = 0;
    reg [63:0] insert_data = 0;
    reg insert_dirty = 0;
    wire evict_out_valid;
    wire [19:0] evict_out_tag;
    wire [63:0] evict_out_data;
    wire evict_out_dirty;

    VictimCache #(.ENTRIES(4), .WITH_DIRTY(1), .TAG_WIDTH(20), .LINE_WORDS(2), .XLEN(32)) dut(
        .clk(clk), .rst(rst),
        .lookup_tag(lookup_tag), .lookup_hit(lookup_hit), .lookup_data(lookup_data), .lookup_dirty(lookup_dirty),
        .do_swap(do_swap), .swap_in_tag(swap_in_tag), .swap_in_data(swap_in_data), .swap_in_dirty(swap_in_dirty),
        .do_insert(do_insert), .insert_tag(insert_tag), .insert_data(insert_data), .insert_dirty(insert_dirty),
        .evict_out_valid(evict_out_valid), .evict_out_tag(evict_out_tag),
        .evict_out_data(evict_out_data), .evict_out_dirty(evict_out_dirty)
    );

    // --- dut2: FIFO wraparound eviction, its own fresh reset ---
    reg rst2 = 0;
    reg [19:0] lookup_tag2 = 0;
    wire lookup_hit2;
    reg do_insert2 = 0;
    reg [19:0] insert_tag2 = 0;
    reg [63:0] insert_data2 = 0;
    reg insert_dirty2 = 0;
    wire evict_out_valid2;
    wire [19:0] evict_out_tag2;
    wire [63:0] evict_out_data2;
    wire evict_out_dirty2;

    VictimCache #(.ENTRIES(4), .WITH_DIRTY(1), .TAG_WIDTH(20), .LINE_WORDS(2), .XLEN(32)) dut2(
        .clk(clk), .rst(rst2),
        .lookup_tag(lookup_tag2), .lookup_hit(lookup_hit2), .lookup_data(), .lookup_dirty(),
        .do_swap(1'b0), .swap_in_tag(20'b0), .swap_in_data(64'b0), .swap_in_dirty(1'b0),
        .do_insert(do_insert2), .insert_tag(insert_tag2), .insert_data(insert_data2), .insert_dirty(insert_dirty2),
        .evict_out_valid(evict_out_valid2), .evict_out_tag(evict_out_tag2),
        .evict_out_data(evict_out_data2), .evict_out_dirty(evict_out_dirty2)
    );

    initial begin
        // --- Case 1: cold miss ---
        rst = 0;
        @(posedge clk); @(posedge clk);
        rst = 1;
        @(negedge clk);
        lookup_tag = 20'hAAAAA;
        #1;
        check_bit(lookup_hit, 1'b0, "cold: lookup before any insert misses");

        // --- Case 2: insert + lookup roundtrip (clean) ---
        @(negedge clk);
        do_insert = 1'b1;
        insert_tag = 20'h00001;
        insert_data = 64'hDEAD_BEEF_1111_2222;
        insert_dirty = 1'b0;
        @(posedge clk);
        #1;
        do_insert = 1'b0;
        @(negedge clk);
        lookup_tag = 20'h00001;
        #1;
        check_bit(lookup_hit, 1'b1, "insert: freshly-inserted tag hits");
        check_data64(lookup_data, 64'hDEAD_BEEF_1111_2222, "insert: freshly-inserted data matches");
        check_bit(lookup_dirty, 1'b0, "insert: freshly-inserted clean entry reads dirty=0");

        // --- Case 3: swap-promote roundtrip ---
        // lookup_tag is still 20'h00001 (still hits) from Case 2 -- pulse
        // do_swap now. Capture lookup_data BEFORE the clock edge: that's
        // exactly what a real caller would promote into its main array.
        do_swap = 1'b1;
        swap_in_tag = 20'h00002;
        swap_in_data = 64'hCAFE_F00D_3333_4444;
        swap_in_dirty = 1'b1;
        #1;
        check_data64(lookup_data, 64'hDEAD_BEEF_1111_2222, "swap: pre-edge lookup_data is still the OLD entry -- what the caller promotes");
        @(posedge clk);
        #1;
        do_swap = 1'b0;
        @(negedge clk);
        lookup_tag = 20'h00002;
        #1;
        check_bit(lookup_hit, 1'b1, "swap: NEW swap_in_tag now hits in the same slot");
        check_data64(lookup_data, 64'hCAFE_F00D_3333_4444, "swap: NEW swap_in_data resident");
        check_bit(lookup_dirty, 1'b1, "swap: NEW swap_in_dirty carried through");
        @(negedge clk);
        lookup_tag = 20'h00001;
        #1;
        check_bit(lookup_hit, 1'b0, "swap: OLD tag no longer hits -- slot was overwritten, not duplicated");

        // --- Case 4: FIFO wraparound eviction (dut2, independent reset) ---
        rst2 = 0;
        @(posedge clk); @(posedge clk);
        rst2 = 1;

        // Insert 4 distinct dirty lines, filling all 4 entries. None should
        // evict anything yet (buffer starts empty). evict_out_valid2 is
        // checked BEFORE each clock edge -- it's combinational against the
        // CURRENT (pre-edge) fifo_next_r, per the module's own documented
        // contract ("surfaced THIS SAME CYCLE, before being overwritten").
        @(negedge clk);
        do_insert2 = 1'b1; insert_tag2 = 20'h00010; insert_data2 = 64'hA0A0_A0A0_0000_0001; insert_dirty2 = 1'b1;
        #1;
        check_bit(evict_out_valid2, 1'b0, "fifo: insert #1 (empty slot0) evicts nothing");
        @(posedge clk);

        @(negedge clk);
        insert_tag2 = 20'h00011; insert_data2 = 64'hB0B0_B0B0_0000_0002; insert_dirty2 = 1'b1;
        #1;
        check_bit(evict_out_valid2, 1'b0, "fifo: insert #2 (empty slot1) evicts nothing");
        @(posedge clk);

        @(negedge clk);
        insert_tag2 = 20'h00012; insert_data2 = 64'hC0C0_C0C0_0000_0003; insert_dirty2 = 1'b1;
        #1;
        check_bit(evict_out_valid2, 1'b0, "fifo: insert #3 (empty slot2) evicts nothing");
        @(posedge clk);

        @(negedge clk);
        insert_tag2 = 20'h00013; insert_data2 = 64'hD0D0_D0D0_0000_0004; insert_dirty2 = 1'b1;
        #1;
        check_bit(evict_out_valid2, 1'b0, "fifo: insert #4 (empty slot3, buffer now full) evicts nothing");
        @(posedge clk);

        // Insert #5: FIFO wraps back to slot0, which holds insert #1's own
        // line (tag 0x00010) -- must be surfaced combinationally THIS SAME
        // cycle before being overwritten.
        @(negedge clk);
        insert_tag2 = 20'h00014; insert_data2 = 64'hE0E0_E0E0_0000_0005; insert_dirty2 = 1'b1;
        #1;
        check_bit(evict_out_valid2, 1'b1, "fifo: insert #5 (wraparound to slot0) surfaces an eviction");
        check_tag20(evict_out_tag2, 20'h00010, "fifo: evicted tag is #1's own tag -- true FIFO order, not LRU/round-robin");
        check_data64(evict_out_data2, 64'hA0A0_A0A0_0000_0001, "fifo: evicted data matches what #1 originally inserted");
        check_bit(evict_out_dirty2, 1'b1, "fifo: evicted entry's own dirty bit is surfaced -- caller must write it back, not drop it");
        @(posedge clk); #1;
        do_insert2 = 1'b0;

        @(negedge clk);
        lookup_tag2 = 20'h00010;
        #1;
        check_bit(lookup_hit2, 1'b0, "fifo: #1's old tag no longer resident after being evicted");
        @(negedge clk);
        lookup_tag2 = 20'h00014;
        #1;
        check_bit(lookup_hit2, 1'b1, "fifo: #5's new tag now resident in the reused slot0");

        if (fails == 0)
            $display("PASS  victimcache_unit (%0d checks)", checks);
        else
            $display("FAIL  victimcache_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
