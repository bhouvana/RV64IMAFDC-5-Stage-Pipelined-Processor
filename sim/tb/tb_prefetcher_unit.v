`include "Prefetcher.v"

// docs/adr/0046-hardware-prefetchers-phase-g.md (Generation 4, Phase G).
// Standalone unit test for Prefetcher.v's own table-of-1 address predictor,
// independent of either cache (no bus port on this module at all -- drives
// update_valid/update_addr directly, checks pf_valid/pf_addr). One instance
// per MODE, same "one DUT per axis value" convention tb_mshr_unit.v's own
// dut_a/dut_b split establishes.
module tb_prefetcher_unit;
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

    localparam PF_OFF       = 0;
    localparam PF_NEXT_LINE = 1;
    localparam PF_STRIDE    = 2;
    localparam PF_STREAM    = 3;

    // -- dut_off: MODE=PF_OFF --
    reg rst_off = 0, upd_valid_off = 0;
    reg [31:0] upd_addr_off = 0;
    wire pf_valid_off; wire [31:0] pf_addr_off;
    Prefetcher #(.XLEN(32), .LINE_BYTES(16), .MODE(PF_OFF)) dut_off(
        .clk(clk), .rst(rst_off), .update_valid(upd_valid_off), .update_addr(upd_addr_off),
        .pf_valid(pf_valid_off), .pf_addr(pf_addr_off)
    );

    // -- dut_nl: MODE=PF_NEXT_LINE --
    reg rst_nl = 0, upd_valid_nl = 0;
    reg [31:0] upd_addr_nl = 0;
    wire pf_valid_nl; wire [31:0] pf_addr_nl;
    Prefetcher #(.XLEN(32), .LINE_BYTES(16), .MODE(PF_NEXT_LINE)) dut_nl(
        .clk(clk), .rst(rst_nl), .update_valid(upd_valid_nl), .update_addr(upd_addr_nl),
        .pf_valid(pf_valid_nl), .pf_addr(pf_addr_nl)
    );

    // -- dut_st: MODE=PF_STRIDE --
    reg rst_st = 0, upd_valid_st = 0;
    reg [31:0] upd_addr_st = 0;
    wire pf_valid_st; wire [31:0] pf_addr_st;
    Prefetcher #(.XLEN(32), .LINE_BYTES(16), .MODE(PF_STRIDE)) dut_st(
        .clk(clk), .rst(rst_st), .update_valid(upd_valid_st), .update_addr(upd_addr_st),
        .pf_valid(pf_valid_st), .pf_addr(pf_addr_st)
    );

    // -- dut_sm: MODE=PF_STREAM --
    reg rst_sm = 0, upd_valid_sm = 0;
    reg [31:0] upd_addr_sm = 0;
    wire pf_valid_sm; wire [31:0] pf_addr_sm;
    Prefetcher #(.XLEN(32), .LINE_BYTES(16), .MODE(PF_STREAM)) dut_sm(
        .clk(clk), .rst(rst_sm), .update_valid(upd_valid_sm), .update_addr(upd_addr_sm),
        .pf_valid(pf_valid_sm), .pf_addr(pf_addr_sm)
    );

    // One pulse of update_valid on the given DUT's inputs, sampled a cycle
    // later once pf_valid/pf_addr have settled to their new registered value.
    task pulse_nl;
        input [31:0] addr;
        begin
            @(negedge clk); upd_addr_nl = addr; upd_valid_nl = 1;
            @(posedge clk); #1;
            @(negedge clk); upd_valid_nl = 0;
        end
    endtask
    task pulse_st;
        input [31:0] addr;
        begin
            @(negedge clk); upd_addr_st = addr; upd_valid_st = 1;
            @(posedge clk); #1;
            @(negedge clk); upd_valid_st = 0;
        end
    endtask
    task pulse_sm;
        input [31:0] addr;
        begin
            @(negedge clk); upd_addr_sm = addr; upd_valid_sm = 1;
            @(posedge clk); #1;
            @(negedge clk); upd_valid_sm = 0;
        end
    endtask
    task pulse_off;
        input [31:0] addr;
        begin
            @(negedge clk); upd_addr_off = addr; upd_valid_off = 1;
            @(posedge clk); #1;
            @(negedge clk); upd_valid_off = 0;
        end
    endtask

    initial begin
        @(posedge clk); rst_off <= 0; rst_nl <= 0; rst_st <= 0; rst_sm <= 0;
        @(posedge clk); rst_off <= 1; rst_nl <= 1; rst_st <= 1; rst_sm <= 1;
        @(posedge clk);

        // === MODE=PF_OFF: pf_valid stays 0 regardless of update pulses ===
        check_bit(pf_valid_off, 1'b0, "off: pf_valid starts 0");
        pulse_off(32'h1000);
        check_bit(pf_valid_off, 1'b0, "off: pf_valid still 0 after a real update pulse");
        pulse_off(32'h2000);
        check_bit(pf_valid_off, 1'b0, "off: pf_valid still 0 after a second update pulse");

        // === MODE=PF_NEXT_LINE: fires after the very first pulse, tracks
        // the LAST address seen regardless of stride ===
        check_bit(pf_valid_nl, 1'b0, "next_line: pf_valid starts 0 (no update yet)");
        pulse_nl(32'h1000);
        check_bit(pf_valid_nl, 1'b1, "next_line: pf_valid=1 after one pulse");
        check_word(pf_addr_nl, 32'h1010, "next_line: pf_addr = last_addr + LINE_BYTES(16)");
        pulse_nl(32'h2000);   // unrelated jump -- next-line needs no stride
        check_bit(pf_valid_nl, 1'b1, "next_line: pf_valid stays 1 after an unrelated jump");
        check_word(pf_addr_nl, 32'h2010, "next_line: pf_addr tracks the newest address, stride-agnostic");

        // === MODE=PF_STRIDE: needs the SECOND repeat of a stride (3
        // pulses total) before it trusts it; predicts one stride ahead of
        // the newest address once confirmed ===
        check_bit(pf_valid_st, 1'b0, "stride: pf_valid starts 0");
        pulse_st(32'h3000);
        check_bit(pf_valid_st, 1'b0, "stride: still 0 after pulse 1 (no stride estimate yet)");
        pulse_st(32'h3020);   // stride = 0x20
        check_bit(pf_valid_st, 1'b0, "stride: still 0 after pulse 2 (one stride OBSERVED, not yet confirmed)");
        pulse_st(32'h3040);   // same stride (0x20) repeats -- CONFIRMED
        check_bit(pf_valid_st, 1'b1, "stride: pf_valid=1 after pulse 3 (stride confirmed)");
        check_word(pf_addr_st, 32'h3060, "stride: pf_addr = newest addr + confirmed stride");
        // Break the stride -- an unrelated jump resets confirmation. The
        // break pulse itself records a (huge, one-off) candidate stride --
        // 0x3040->0x9000 -- which is NOT the pattern about to start at
        // 0x9000, so establishing a genuinely new stride from here needs
        // the same two-pulse (candidate, then confirm) cadence a cold start
        // needs, not just one.
        pulse_st(32'h9000);
        check_bit(pf_valid_st, 1'b0, "stride: pf_valid drops to 0 the instant a break is observed");
        pulse_st(32'h9010);   // candidate stride 0x10 (replaces the break's own throwaway candidate)
        check_bit(pf_valid_st, 1'b0, "stride: still 0 -- new candidate observed, not yet confirmed");
        pulse_st(32'h9020);   // confirms 0x10
        check_bit(pf_valid_st, 1'b1, "stride: re-confirms once the new stride repeats");
        check_word(pf_addr_st, 32'h9030, "stride: pf_addr reflects the NEW confirmed stride");

        // === MODE=PF_STREAM: same confirmation as stride, but needs
        // STREAM_CONFIRM_RUN(2) consecutive confirmations, not just one ===
        check_bit(pf_valid_sm, 1'b0, "stream: pf_valid starts 0");
        pulse_sm(32'h4000);
        pulse_sm(32'h4020);   // stride observed, not confirmed
        pulse_sm(32'h4040);   // 1st confirmation (run_count=1) -- stride mode would fire here, stream does not yet
        check_bit(pf_valid_sm, 1'b0, "stream: still 0 after only 1 confirmation (needs 2)");
        pulse_sm(32'h4060);   // 2nd confirmation (run_count=2) -- now trusted
        check_bit(pf_valid_sm, 1'b1, "stream: pf_valid=1 after 2 consecutive confirmations");
        check_word(pf_addr_sm, 32'h4080, "stream: pf_addr = newest addr + confirmed stride");

        // === Reset mid-sequence: cold-starts cleanly ===
        @(negedge clk); rst_nl <= 0;
        @(posedge clk); #1;
        check_bit(pf_valid_nl, 1'b0, "next_line: pf_valid drops to 0 immediately on reset");
        @(negedge clk); rst_nl <= 1;
        @(posedge clk);
        check_bit(pf_valid_nl, 1'b0, "next_line: still 0 right after de-reset, no update yet");
        pulse_nl(32'h5000);
        check_bit(pf_valid_nl, 1'b1, "next_line: fires again after reset + one fresh pulse");
        check_word(pf_addr_nl, 32'h5010, "next_line: predicts correctly from the fresh cold start");

        $display("=== tb_prefetcher_unit: %0d/%0d checks passed ===", checks - fails, checks);
        if (fails == 0) $display("PASS  prefetcher_unit (%0d checks)", checks);
        else $display("FAIL  prefetcher_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
