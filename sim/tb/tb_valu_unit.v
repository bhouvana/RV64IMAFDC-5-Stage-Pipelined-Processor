`include "VALU.v"

// Generation 7, Pillar V, Phase 2a (docs/adr/0062). VALU.v proven
// standalone before wiring it live into OOOCore.v -- mirrors
// tb_freelist_unit.v's own "new module, own testbench, before any real
// caller" precedent.
module tb_valu_unit;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 0;

    reg         start;
    reg [511:0] vs2_data, vs1_data, v0_data;
    reg [63:0]  scalar_data;
    reg         use_scalar, vm;
    reg [2:0]   vsew;
    reg [6:0]   vl;
    reg [5:0]   funct6;
    wire        busy, done;
    wire [511:0] result;

    VALU #(.VLEN(512)) dut(
        .clk(clk), .rst(rst), .start(start),
        .vs2_data(vs2_data), .vs1_data(vs1_data), .scalar_data(scalar_data),
        .use_scalar(use_scalar), .v0_data(v0_data), .vm(vm), .vsew(vsew), .vl(vl),
        .funct6(funct6), .busy(busy), .done(done), .result(result)
    );

    integer fails = 0, checks = 0;
    task run_and_wait;
        begin
            @(posedge clk); start <= 1'b1;
            @(posedge clk); start <= 1'b0;
            while (!done) @(posedge clk);
            @(negedge clk);
        end
    endtask
    task check_elem;
        input [63:0] expected;
        input [255:0] label;
        reg [63:0] actual;
        begin
            actual = result[63:0];
            checks = checks + 1;
            if (actual !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: %h, expected %h", label, actual, expected);
            end else
                $display("pass  %0s: %h", label, actual);
        end
    endtask

    initial begin
        rst = 0; start = 0; use_scalar = 0; vm = 1;
        @(posedge clk); rst <= 1;

        // vadd.vv, SEW=32, 16 elements, unmasked, full vl.
        vs2_data = {16{32'd5}}; vs1_data = {16{32'd3}}; vsew = 3'b010; vl = 16;
        funct6 = `VFUNCT6_ADD; use_scalar = 0; vm = 1;
        run_and_wait();
        check_elem(64'h0000000800000008, "vadd.vv SEW32 elem0/1 = 5+3=8");

        // vand.vx, SEW=8, 64 elements, vl=4 (tail-agnostic-zero check).
        vs2_data = {64{8'hFF}}; scalar_data = 64'h000000000000000F; vsew = 3'b000; vl = 4;
        funct6 = `VFUNCT6_AND; use_scalar = 1; vm = 1;
        run_and_wait();
        checks = checks + 1;
        if (result[63:32] !== 32'd0) begin fails = fails + 1; $display("FAIL  vand.vx tail elements 4-7 not zero: %h", result[63:32]); end
        else $display("pass  vand.vx tail elements 4-7 correctly zero: %h", result[63:32]);
        check_elem(64'h000000000F0F0F0F, "vand.vx SEW8 elem0-3 = 0xFF&0xF=0xF each (4 bytes)");

        // vmin.vv, SEW=16, signed: -1 (0xFFFF) vs 3 -> -1 is less.
        vs2_data = {32{16'hFFFF}}; vs1_data = {32{16'h0003}}; vsew = 3'b001; vl = 32;
        funct6 = `VFUNCT6_MIN; use_scalar = 0; vm = 1;
        run_and_wait();
        check_elem(64'hFFFFFFFFFFFFFFFF, "vmin.vv SEW16 signed: min(-1,3)=-1 each");

        // vxor.vv with v0.t masking: only even elements active.
        vs2_data = {16{32'hFFFFFFFF}}; vs1_data = {16{32'h0F0F0F0F}};
        v0_data = 512'h0; v0_data[0] = 1'b1; v0_data[1] = 1'b0;
        vsew = 3'b010; vl = 16; funct6 = `VFUNCT6_XOR; use_scalar = 0; vm = 0;
        run_and_wait();
        checks = checks + 1;
        if (result[31:0] !== 32'hF0F0F0F0) begin fails=fails+1; $display("FAIL vxor.vv masked elem0 (active): %h", result[31:0]); end
        else $display("pass  vxor.vv masked elem0 (active, v0[0]=1): %h", result[31:0]);
        checks = checks + 1;
        if (result[63:32] !== 32'd0) begin fails=fails+1; $display("FAIL vxor.vv masked elem1 (inactive, should be 0): %h", result[63:32]); end
        else $display("pass  vxor.vv masked elem1 (inactive, v0[1]=0, tail-agnostic zero): %h", result[63:32]);

        // vrsub.vi: scalar(imm) - vs2.
        vs2_data = {16{32'd5}}; scalar_data = 64'd10; vsew = 3'b010; vl = 16;
        funct6 = `VFUNCT6_RSUB; use_scalar = 1; vm = 1;
        run_and_wait();
        check_elem(64'h0000000500000005, "vrsub.vi SEW32 = 10-5=5 each");

        if (fails == 0) $display("PASS  valu_unit (%0d checks)", checks);
        else $display("FAIL  valu_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
