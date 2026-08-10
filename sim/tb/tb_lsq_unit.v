`include "LoadStoreQueue.v"
`include "DataMemoryBRAM.v"

// Generation 6, Gen6-E. Standalone unit test for LoadStoreQueue.v,
// wired to a REAL DataMemoryBRAM.v (exactly how OOOCore.v eventually
// wires it) and a tiny fake register file standing in for
// PhysicalRegisterFile.v (mem_base_value/mem_store_data_value driven by
// looking up head_base_preg/head_store_data_preg -- the same pattern
// OOOCore.v's own real PRF read ports will use). LSQ_ENTRIES=4 (tiny) so
// full detection is reachable quickly.
//
// Timing model (derived by hand-tracing the RTL, not guessed): a
// dispatch commits AT the posedge it's presented. If BOTH operands are
// already ready that same cycle, mem_memRead/mem_memWrite go high
// COMBINATIONALLY during the very next cycle (the interval between that
// dispatch posedge and the one after it), get sampled by DataMemoryBRAM
// AND latch LoadStoreQueue.v's own mem_pending_r at that NEXT posedge,
// and complete_valid (== mem_pending_r) is then high for exactly the
// cycle after THAT -- one posedge later still. A not-ready-at-dispatch
// operand becoming ready via a CDB pulse follows the identical shape,
// just starting from whichever posedge the wakeup itself latches at
// instead of the dispatch posedge.
module tb_lsq_unit;
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
                $display("FAIL  %0s: %h, expected %h", label, actual, expected);
            end else begin
                $display("pass  %0s: %h", label, actual);
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

    reg rst = 0;

    reg        disp_en0 = 0, disp_is_store0 = 0;
    reg  [5:0] disp_base_preg0 = 0;
    reg        disp_base_ready0 = 0;
    reg [63:0] disp_imm0 = 0;
    reg  [2:0] disp_funct3_0 = 0;
    reg  [5:0] disp_store_data_preg0 = 0;
    reg        disp_store_data_ready0 = 0;
    reg  [5:0] disp_dest_preg0 = 0;
    reg  [3:0] disp_rob_tag0 = 0;

    reg        cdb_valid0 = 0, cdb_valid1 = 0, cdb_valid2 = 0;
    reg  [5:0] cdb_preg0 = 0, cdb_preg1 = 0, cdb_preg2 = 0;

    wire [5:0] head_base_preg, head_store_data_preg;

    reg [63:0] fake_prf [0:63];
    wire [63:0] mem_base_value       = fake_prf[head_base_preg];
    wire [63:0] mem_store_data_value = fake_prf[head_store_data_preg];

    wire        mem_memRead, mem_memWrite;
    wire [63:0] mem_address, mem_writeData;
    wire [2:0]  mem_funct3;
    wire [63:0] mem_readData;

    wire        complete_valid, complete_is_load;
    wire [5:0]  complete_dest_preg;
    wire [63:0] complete_data;
    wire [3:0]  complete_rob_tag;

    wire [2:0] lsq_count;
    wire       lsq_full;

    integer fi;
    initial for (fi = 0; fi < 64; fi = fi + 1) fake_prf[fi] = 64'd0;

    LoadStoreQueue #(.XLEN(64), .LSQ_ENTRIES(4), .PREG_BITS(6), .ROB_IDX_BITS(4)) dut(
        .clk(clk), .rst(rst),
        .disp_en0(disp_en0), .disp_is_store0(disp_is_store0),
        .disp_base_preg0(disp_base_preg0), .disp_base_ready0(disp_base_ready0),
        .disp_imm0(disp_imm0), .disp_funct3_0(disp_funct3_0),
        .disp_store_data_preg0(disp_store_data_preg0), .disp_store_data_ready0(disp_store_data_ready0),
        .disp_dest_preg0(disp_dest_preg0), .disp_rob_tag0(disp_rob_tag0),
        .disp_en1(1'b0), .disp_is_store1(1'b0),
        .disp_base_preg1(6'd0), .disp_base_ready1(1'b0),
        .disp_imm1(64'd0), .disp_funct3_1(3'd0),
        .disp_store_data_preg1(6'd0), .disp_store_data_ready1(1'b0),
        .disp_dest_preg1(6'd0), .disp_rob_tag1(4'd0),
        .cdb_valid0(cdb_valid0), .cdb_preg0(cdb_preg0),
        .cdb_valid1(cdb_valid1), .cdb_preg1(cdb_preg1),
        .cdb_valid2(cdb_valid2), .cdb_preg2(cdb_preg2),
        .head_base_preg(head_base_preg), .head_store_data_preg(head_store_data_preg),
        .mem_base_value(mem_base_value), .mem_store_data_value(mem_store_data_value),
        .mem_memRead(mem_memRead), .mem_memWrite(mem_memWrite),
        .mem_address(mem_address), .mem_writeData(mem_writeData), .mem_funct3(mem_funct3),
        .mem_readData(mem_readData),
        .complete_valid(complete_valid), .complete_is_load(complete_is_load),
        .complete_dest_preg(complete_dest_preg), .complete_data(complete_data),
        .complete_rob_tag(complete_rob_tag),
        .lsq_count(lsq_count), .lsq_full(lsq_full)
    );

    DataMemoryBRAM #(.SIZE_BYTES(256), .XLEN(64)) m_Mem(
        .clk(clk), .rst(rst),
        .memWrite(mem_memWrite), .memRead(mem_memRead),
        .address(mem_address), .writeData(mem_writeData), .funct3(mem_funct3),
        .readData(mem_readData)
    );

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // -- Case 1: reset state --
        #1;
        check_val(lsq_count, 64'd0, "case1: empty at reset");

        // -- Case 2: store then load, same address, both operands ready
        // at dispatch -- proves the basic memory round trip through a
        // real DataMemoryBRAM.v. Uses sd/ld (funct3=011, full 64-bit,
        // no sign-extension ambiguity to hand-verify). --
        fake_prf[6'd10] = 64'd100;                 // base (address)
        fake_prf[6'd11] = 64'hCAFEBABE_12345678;    // store data
        @(negedge clk);
        disp_en0 = 1; disp_is_store0 = 1;
        disp_base_preg0 = 6'd10; disp_base_ready0 = 1;
        disp_imm0 = 64'd0; disp_funct3_0 = 3'b011;
        disp_store_data_preg0 = 6'd11; disp_store_data_ready0 = 1;
        disp_rob_tag0 = 4'd1;
        #1;
        @(posedge clk); #1;   // dispatch commits here
        disp_en0 = 0;
        check_val(lsq_count, 64'd1, "case2: store enqueued");

        @(posedge clk); #1;   // memWrite fires during the interval that
                                // just ended (both operands were ready at
                                // dispatch); mem_pending_r latches AT
                                // this SAME edge, so complete_valid is
                                // already high right here -- no further
                                // posedge needed (the earlier version of
                                // this test waited one edge too many,
                                // found by hand-retracing the RTL against
                                // the actual failure).
        check_bit(complete_valid, 1'b1, "case2: store completes");
        check_bit(complete_is_load, 1'b0, "case2: store, not a load");
        check_val(complete_rob_tag, 64'd1, "case2: store's own rob_tag == 1");
        @(posedge clk); #1;   // retire settles (e_valid cleared, count--)
        check_val(lsq_count, 64'd0, "case2: empty again after the store retires");

        // Now the load, same address.
        fake_prf[6'd12] = 64'd100;
        @(negedge clk);
        disp_en0 = 1; disp_is_store0 = 0;
        disp_base_preg0 = 6'd12; disp_base_ready0 = 1;
        disp_imm0 = 64'd0; disp_funct3_0 = 3'b011;
        disp_dest_preg0 = 6'd20; disp_rob_tag0 = 4'd2;
        #1;
        @(posedge clk); #1;   // dispatch commits
        disp_en0 = 0;
        @(posedge clk); #1;   // memRead fires and mem_pending_r latches
                                // the same edge -- complete_valid already
                                // high right here.
        check_bit(complete_valid, 1'b1, "case3: load completes");
        check_bit(complete_is_load, 1'b1, "case3: is a load");
        check_val(complete_dest_preg, 64'd20, "case3: load's own dest_preg == 20");
        check_val(complete_data, 64'hCAFEBABE_12345678, "case3: load reads back exactly what the store wrote");
        check_val(complete_rob_tag, 64'd2, "case3: load's own rob_tag == 2");
        @(posedge clk); #1;   // retire settles

        // -- Case 4: dispatch with base NOT ready -- no memory access
        // fires until a CDB wakeup arrives. --
        @(negedge clk);
        disp_en0 = 1; disp_is_store0 = 0;
        disp_base_preg0 = 6'd13; disp_base_ready0 = 0;
        disp_imm0 = 64'd0; disp_funct3_0 = 3'b011;
        disp_dest_preg0 = 6'd21; disp_rob_tag0 = 4'd3;
        #1;
        @(posedge clk); #1;   // dispatch commits
        disp_en0 = 0;
        check_bit(mem_memRead, 1'b0, "case4: no memRead yet, base not ready");
        @(posedge clk); #1;
        check_bit(mem_memRead, 1'b0, "case4: still nothing, base still not ready");

        fake_prf[6'd13] = 64'd100;
        @(negedge clk);
        cdb_valid0 = 1; cdb_preg0 = 6'd13;
        #1;
        @(posedge clk); #1;   // wakeup latches HERE -- e_base_ready now 1,
                                // head_ready true for THIS interval, so
                                // mem_memRead is high RIGHT NOW, before
                                // any further posedge.
        cdb_valid0 = 0;
        check_bit(mem_memRead, 1'b1, "case4: memRead fires the same window its own CDB wakeup latches");
        @(posedge clk); #1;   // mem_pending_r latches this same edge --
                                // complete_valid already high right here.
        check_bit(complete_valid, 1'b1, "case4: completes normally after the wakeup");
        @(posedge clk); #1;   // retire settles

        // -- Case 5: in-order enforcement -- a store dispatched BEFORE a
        // load (store not yet ready) must block the load from executing
        // even though the load's own operand IS ready. The core property
        // this phase's own scope cut exists to guarantee. --
        @(negedge clk);
        disp_en0 = 1; disp_is_store0 = 1;
        disp_base_preg0 = 6'd14; disp_base_ready0 = 0;   // NOT ready
        disp_imm0 = 64'd0; disp_funct3_0 = 3'b011;
        disp_store_data_preg0 = 6'd15; disp_store_data_ready0 = 1;
        disp_rob_tag0 = 4'd4;
        #1;
        @(posedge clk); #1; disp_en0 = 0;   // store dispatch commits

        @(negedge clk);
        disp_en0 = 1; disp_is_store0 = 0;
        disp_base_preg0 = 6'd16; disp_base_ready0 = 1;   // ready, but queued BEHIND the store
        disp_imm0 = 64'd0; disp_funct3_0 = 3'b011;
        disp_dest_preg0 = 6'd22; disp_rob_tag0 = 4'd5;
        #1;
        @(posedge clk); #1; disp_en0 = 0;   // load dispatch commits

        check_bit(mem_memRead, 1'b0, "case5: the ready load does NOT jump ahead of the not-ready older store");
        check_bit(mem_memWrite, 1'b0, "case5: store itself also not firing yet (its own base isn't ready)");

        fake_prf[6'd14] = 64'd200;
        @(negedge clk);
        cdb_valid0 = 1; cdb_preg0 = 6'd14;
        #1;
        @(posedge clk); #1;   // store's own wakeup latches -- head_ready
                                // (for the STORE, still head-of-queue)
                                // true for this window
        cdb_valid0 = 0;
        check_bit(mem_memWrite, 1'b1, "case5: store issues first once its own operand wakes up");
        check_bit(mem_memRead, 1'b0, "case5: load still hasn't fired -- store hasn't even completed yet");
        @(posedge clk); #1;   // mem_pending_r latches (store's own
                                // completion now pending; complete_valid
                                // is high for the window that just opened)
        @(posedge clk); #1;   // store retires HERE: mem_pending_r clears,
                                // head_r advances to the load, and since
                                // the load's own base was already ready,
                                // head_ready is ALREADY true for the
                                // window this same edge just opened --
                                // mem_memRead reads 1 right now, no
                                // further posedge needed.
        check_bit(mem_memRead, 1'b1, "case5: load THEN issues, strictly after the store ahead of it");

        if (fails == 0) $display("PASS  lsq_unit (%0d checks)", checks);
        else $display("FAIL  lsq_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
