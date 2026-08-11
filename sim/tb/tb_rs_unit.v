`include "ReservationStation.v"

// Generation 6, Gen6-C. Standalone unit test for ReservationStation.v,
// fully independent of PhysicalRegisterFile.v/ReorderBuffer.v/OOOCore.v
// -- drives dispatch/CDB/issue-ack ports directly with hand-picked
// physical register tags. RS_ENTRIES=4 (tiny) so full/priority-order are
// reachable in a handful of cycles.
module tb_rs_unit;
    reg clk = 0;
    always #5 clk = ~clk;

    integer fails = 0;
    integer checks = 0;

    task check_val;
        input [31:0] actual, expected;
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

    reg        rst = 0;
    reg        disp_en0 = 0, disp_en1 = 0;
    reg  [5:0] disp_src1_preg0 = 0, disp_src2_preg0 = 0, disp_dest_preg0 = 0;
    reg        disp_src1_ready0 = 0, disp_src2_ready0 = 0;
    reg  [2:0] disp_rob_tag0 = 0;
    reg  [3:0] disp_payload0 = 0;
    reg  [5:0] disp_src1_preg1 = 0, disp_src2_preg1 = 0, disp_dest_preg1 = 0;
    reg        disp_src1_ready1 = 0, disp_src2_ready1 = 0;
    reg  [2:0] disp_rob_tag1 = 0;
    reg  [3:0] disp_payload1 = 0;

    reg        cdb_valid0 = 0, cdb_valid1 = 0, cdb_valid2 = 0;
    reg  [5:0] cdb_preg0 = 0, cdb_preg1 = 0, cdb_preg2 = 0;

    wire       issue_valid;
    wire [5:0] issue_src1_preg, issue_src2_preg, issue_dest_preg;
    wire [2:0] issue_rob_tag;
    wire [3:0] issue_payload;
    reg        issue_ack = 0;

    wire [2:0] rs_count;
    wire       rs_full;

    ReservationStation #(.RS_ENTRIES(4), .PREG_BITS(6), .ROB_IDX_BITS(3), .PAYLOAD_BITS(4)) dut(
        .clk(clk), .rst(rst),
        .disp_en0(disp_en0),
        .disp_src1_preg0(disp_src1_preg0), .disp_src1_ready0(disp_src1_ready0),
        .disp_src2_preg0(disp_src2_preg0), .disp_src2_ready0(disp_src2_ready0),
        .disp_dest_preg0(disp_dest_preg0), .disp_rob_tag0(disp_rob_tag0), .disp_payload0(disp_payload0),
        .disp_en1(disp_en1),
        .disp_src1_preg1(disp_src1_preg1), .disp_src1_ready1(disp_src1_ready1),
        .disp_src2_preg1(disp_src2_preg1), .disp_src2_ready1(disp_src2_ready1),
        .disp_dest_preg1(disp_dest_preg1), .disp_rob_tag1(disp_rob_tag1), .disp_payload1(disp_payload1),
        .cdb_valid0(cdb_valid0), .cdb_preg0(cdb_preg0),
        .cdb_valid1(cdb_valid1), .cdb_preg1(cdb_preg1),
        .cdb_valid2(cdb_valid2), .cdb_preg2(cdb_preg2),
        .cdb_valid3(1'b0), .cdb_preg3(6'd0),   // Gen6-P6 (docs/adr/0057): new 4th port, untested here -- not this unit test's own scope
        .issue_valid(issue_valid),
        .issue_src1_preg(issue_src1_preg), .issue_src2_preg(issue_src2_preg), .issue_dest_preg(issue_dest_preg),
        .issue_rob_tag(issue_rob_tag), .issue_payload(issue_payload),
        .issue_ack(issue_ack),
        .rs_count(rs_count), .rs_full(rs_full)
    );

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // -- Case 1: reset state --
        #1;
        check_val(rs_count, 3'd0, "case1: rs_count == 0 at reset");
        check_bit(rs_full, 1'b0, "case1: not full at reset");

        // -- Case 2: dispatch one entry, both operands already ready --
        // issues the very next cycle. --
        @(negedge clk);
        disp_en0 = 1;
        disp_src1_preg0 = 6'd10; disp_src1_ready0 = 1;
        disp_src2_preg0 = 6'd11; disp_src2_ready0 = 1;
        disp_dest_preg0 = 6'd20; disp_rob_tag0 = 3'd1; disp_payload0 = 4'd5;
        #1;
        @(posedge clk); #1;
        disp_en0 = 0;
        check_bit(issue_valid, 1'b1, "case2: issues next cycle, both operands ready at dispatch");
        check_val(issue_dest_preg, 6'd20, "case2: issue_dest_preg == 20");
        check_val(issue_rob_tag, 3'd1, "case2: issue_rob_tag == 1");
        check_val(issue_payload, 4'd5, "case2: issue_payload == 5");

        // Consume it.
        @(negedge clk); issue_ack = 1; #1;
        @(posedge clk); #1; issue_ack = 0;
        check_bit(issue_valid, 1'b0, "case2: nothing left to issue after consuming the only entry");

        // -- Case 3: dispatch with src1 NOT ready -- waits for a CDB
        // match, does not issue prematurely. --
        @(negedge clk);
        disp_en0 = 1;
        disp_src1_preg0 = 6'd30; disp_src1_ready0 = 0;
        disp_src2_preg0 = 6'd11; disp_src2_ready0 = 1;
        disp_dest_preg0 = 6'd21; disp_rob_tag0 = 3'd2; disp_payload0 = 4'd6;
        #1;
        @(posedge clk); #1;
        disp_en0 = 0;
        check_bit(issue_valid, 1'b0, "case3: not issued yet, src1 not ready");

        // -- Case 4: a CDB broadcast on preg30 wakes it up -- issues the
        // cycle after the broadcast (registered wakeup, one-cycle
        // latency, the documented ponytail simplification). --
        @(negedge clk);
        cdb_valid0 = 1; cdb_preg0 = 6'd30;
        #1;
        @(posedge clk); #1;
        cdb_valid0 = 0;
        check_bit(issue_valid, 1'b1, "case4: issues the cycle after its CDB wakeup");
        check_val(issue_dest_preg, 6'd21, "case4: issue_dest_preg == 21");
        @(negedge clk); issue_ack = 1; #1;
        @(posedge clk); #1; issue_ack = 0;

        // -- Case 5: same-cycle dispatch + CDB match bypass -- an entry
        // dispatched the exact cycle its own source's producer
        // broadcasts sees ready=1 immediately (no extra wait beyond the
        // normal one-cycle registered latency to become issuable). --
        @(negedge clk);
        disp_en0 = 1;
        disp_src1_preg0 = 6'd40; disp_src1_ready0 = 0;   // not ready per the caller's own PRF query...
        disp_src2_preg0 = 6'd11; disp_src2_ready0 = 1;
        disp_dest_preg0 = 6'd22; disp_rob_tag0 = 3'd3; disp_payload0 = 4'd7;
        cdb_valid0 = 1; cdb_preg0 = 6'd40;               // ...but the producer broadcasts THIS SAME cycle
        #1;
        @(posedge clk); #1;
        disp_en0 = 0; cdb_valid0 = 0;
        check_bit(issue_valid, 1'b1, "case5: same-cycle dispatch+CDB bypass makes it issuable immediately");
        check_val(issue_dest_preg, 6'd22, "case5: issue_dest_preg == 22");
        @(negedge clk); issue_ack = 1; #1;
        @(posedge clk); #1; issue_ack = 0;

        // -- Case 6: two entries dispatched, only the LOWER-INDEX one
        // ready -- select must pick the ready one, correctly skipping
        // the not-yet-ready one even though it was allocated first. --
        @(negedge clk);
        disp_en0 = 1;
        disp_src1_preg0 = 6'd50; disp_src1_ready0 = 0;   // NOT ready
        disp_src2_preg0 = 6'd11; disp_src2_ready0 = 1;
        disp_dest_preg0 = 6'd23; disp_rob_tag0 = 3'd4; disp_payload0 = 4'd8;
        disp_en1 = 1;
        disp_src1_preg1 = 6'd12; disp_src1_ready1 = 1;   // ready
        disp_src2_preg1 = 6'd13; disp_src2_ready1 = 1;
        disp_dest_preg1 = 6'd24; disp_rob_tag1 = 3'd5; disp_payload1 = 4'd9;
        #1;
        @(posedge clk); #1;
        disp_en0 = 0; disp_en1 = 0;
        check_bit(issue_valid, 1'b1, "case6: the ready (2nd, index1) entry issues despite the 1st (index0) still pending");
        check_val(issue_dest_preg, 6'd24, "case6: issue_dest_preg == 24, the ready entry");
        @(negedge clk); issue_ack = 1; #1;
        @(posedge clk); #1; issue_ack = 0;

        // Wake and drain the remaining pending entry (preg50) so the RS
        // is empty again before the full-detection case.
        @(negedge clk);
        cdb_valid0 = 1; cdb_preg0 = 6'd50;
        #1;
        @(posedge clk); #1; cdb_valid0 = 0;
        check_bit(issue_valid, 1'b1, "case6 cleanup: preg50's entry now issuable");
        @(negedge clk); issue_ack = 1; #1;
        @(posedge clk); #1; issue_ack = 0;
        check_val(rs_count, 3'd0, "case6 cleanup: RS empty again");

        // -- Case 7: full detection -- 4 dispatches (RS_ENTRIES=4),
        // none consumed, fills the RS completely. --
        @(negedge clk);
        disp_en0 = 1; disp_src1_ready0 = 0; disp_src2_ready0 = 0;
        disp_src1_preg0 = 6'd60; disp_src2_preg0 = 6'd61; disp_dest_preg0 = 6'd25; disp_rob_tag0 = 3'd6;
        #1; @(posedge clk); #1; disp_en0 = 0;

        @(negedge clk);
        disp_en0 = 1; disp_src1_preg0 = 6'd62; disp_src2_preg0 = 6'd63; disp_dest_preg0 = 6'd26; disp_rob_tag0 = 3'd7;
        #1; @(posedge clk); #1; disp_en0 = 0;

        @(negedge clk);
        disp_en0 = 1; disp_src1_preg0 = 6'd0; disp_src1_ready0 = 1; disp_src2_preg0 = 6'd0; disp_src2_ready0 = 1;
        disp_dest_preg0 = 6'd27; disp_rob_tag0 = 3'd0;
        #1; check_bit(rs_full, 1'b0, "case7: not yet full, 3/4 occupied");
        @(posedge clk); #1; disp_en0 = 0;

        @(negedge clk);
        disp_en0 = 1; disp_dest_preg0 = 6'd28; disp_rob_tag0 = 3'd1;
        #1;
        @(posedge clk); #1; disp_en0 = 0;
        check_bit(rs_full, 1'b1, "case7: RS full at 4/4 entries");

        if (fails == 0) $display("PASS  rs_unit (%0d checks)", checks);
        else $display("FAIL  rs_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
