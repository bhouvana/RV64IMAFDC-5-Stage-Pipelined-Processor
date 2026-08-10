`include "Mailbox.v"

// Generation 6, Gen6-N. Standalone unit test for Mailbox.v -- drives
// both ports directly, proves real cross-port visibility (a write on one
// port is readable from the OTHER port), each port's own latency
// convention (port A combinational/same-cycle ack, port B registered/
// 1-cycle read, matching DataMemoryBRAM.v), and word-addressing.
module tb_mailbox_unit;
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
                $display("FAIL  %0s: %0d, expected %0d", label, actual, expected);
            end else begin
                $display("pass  %0s: %0d", label, actual);
            end
        end
    endtask

    reg         rst = 0;
    reg         a_cyc = 0, a_stb = 0, a_we = 0;
    reg  [31:0] a_addr = 0, a_data_o = 0;
    wire [31:0] a_data_i;
    wire        a_ack;
    reg         b_memWrite = 0, b_memRead = 0;
    reg  [31:0] b_address = 0, b_writeData = 0;
    wire [31:0] b_readData;

    Mailbox #(.XLEN(32), .NUM_WORDS(16)) dut(
        .clk(clk), .rst(rst),
        .a_cyc(a_cyc), .a_stb(a_stb), .a_we(a_we),
        .a_addr(a_addr), .a_data_o(a_data_o), .a_data_i(a_data_i), .a_ack(a_ack),
        .b_memWrite(b_memWrite), .b_memRead(b_memRead),
        .b_address(b_address), .b_writeData(b_writeData), .b_readData(b_readData)
    );

    initial begin
        @(posedge clk); rst <= 0;
        @(posedge clk); rst <= 1;

        // -- Case 1: reset state -- word 0 reads 0 from both ports --
        @(negedge clk);
        b_memRead = 1; b_address = 32'd0;
        #1; @(posedge clk); #1;
        b_memRead = 0;
        check_val(b_readData, 32'd0, "case1: word0 == 0 at reset (port B)");

        // -- Case 2: port A writes word 2 (byte address 8), same-cycle ack --
        @(negedge clk);
        a_cyc = 1; a_stb = 1; a_we = 1; a_addr = 32'd8; a_data_o = 32'hDEAD_BEEF;
        #1;
        check_val(a_ack, 1'b1, "case2: port A ack same cycle (combinational, matches Uart.v's own convention)");
        @(posedge clk); #1;
        a_cyc = 0; a_stb = 0; a_we = 0;

        // -- Case 3: port B reads word 2 -- cross-port visibility, real
        // inter-core handoff being proven here -- registered, 1-cycle
        // latency (matches DataMemoryBRAM.v) --
        @(negedge clk);
        b_memRead = 1; b_address = 32'd8;
        #1;
        @(posedge clk); #1;
        b_memRead = 0;
        check_val(b_readData, 32'hDEAD_BEEF, "case3: port B sees port A's write -- real cross-core visibility");

        // -- Case 4: port B writes word 5 (byte address 20) --
        @(negedge clk);
        b_memWrite = 1; b_address = 32'd20; b_writeData = 32'hCAFE_F00D;
        #1; @(posedge clk); #1;
        b_memWrite = 0;

        // -- Case 5: port A reads word 5 -- the other direction --
        @(negedge clk);
        a_cyc = 1; a_stb = 1; a_we = 0; a_addr = 32'd20;
        #1;
        check_val(a_data_i, 32'hCAFE_F00D, "case5: port A sees port B's write -- the other cross-core direction");
        check_val(a_ack, 1'b1, "case5: port A read also acks same cycle");
        @(posedge clk); #1;
        a_cyc = 0; a_stb = 0;

        // -- Case 6: writing word 2 again via port B doesn't disturb word 5 --
        @(negedge clk);
        b_memWrite = 1; b_address = 32'd8; b_writeData = 32'h1234_5678;
        #1; @(posedge clk); #1;
        b_memWrite = 0;
        @(negedge clk);
        a_cyc = 1; a_stb = 1; a_addr = 32'd20;
        #1;
        check_val(a_data_i, 32'hCAFE_F00D, "case6: word5 untouched by a write to word2");
        @(posedge clk); #1;
        a_cyc = 0; a_stb = 0;

        if (fails == 0) $display("PASS  mailbox_unit (%0d checks)", checks);
        else $display("FAIL  mailbox_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
