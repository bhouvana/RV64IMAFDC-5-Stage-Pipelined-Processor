`include "VALU.v"

// Generation 7, Pillar V backlog closure (docs/adr/0066). VALU.v's new
// mask-writing compare mode, proven standalone before wiring live --
// same precedent as tb_valu_unit.v itself. Checks the genuinely
// different completion shape: 1 bit per element at bit position elem_r
// (not a SEW-wide value at shift_r).
module tb_valu_cmp_unit;
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
    task check_bits;
        input [15:0] expected;
        input [255:0] label;
        reg [15:0] actual;
        begin
            actual = result[15:0];
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

        // vmseq.vv, SEW=32, 4 elements: {5,3,7,7} == {5,9,7,2} -> bits {1,0,1,0}
        vs2_data = {96'd0, 32'd7, 32'd7, 32'd3, 32'd5};
        vs1_data = {96'd0, 32'd2, 32'd7, 32'd9, 32'd5};
        vsew = 3'b010; vl = 4; funct6 = `VFUNCT6_MSEQ; use_scalar = 0; vm = 1;
        run_and_wait();
        check_bits(16'b0101, "vmseq.vv SEW32: elem0=elem0(5=5)->1, elem1(3!=9)->0, elem2(7=7)->1, elem3(7!=2)->0");

        // vmsne.vx, SEW=8, 4 elements vs scalar=5: {5,3,5,9} != 5 -> bits {0,1,0,1}
        vs2_data = {96'd0, 32'h09_05_03_05}; scalar_data = 64'd5;
        vsew = 3'b000; vl = 4; funct6 = `VFUNCT6_MSNE; use_scalar = 1; vm = 1;
        run_and_wait();
        check_bits(16'b1010, "vmsne.vx SEW8: elem0(5!=5)->0, elem1(3!=5)->1, elem2(5!=5)->0, elem3(9!=5)->1");

        // vmsltu.vv, SEW=32, unsigned: {1, 0xFFFFFFFF} vs {2, 1} -> {1<2=1, 0xFFFFFFFF<1(unsigned)=0}
        vs2_data = {32'hFFFFFFFF, 32'd1}; vs1_data = {32'd1, 32'd2};
        vsew = 3'b010; vl = 2; funct6 = `VFUNCT6_MSLTU; use_scalar = 0; vm = 1;
        run_and_wait();
        check_bits(16'b01, "vmsltu.vv SEW32: elem0(1<2 unsigned)=1, elem1(0xFFFFFFFF<1 unsigned)=0");

        // vmslt.vx, SEW=32, signed: vs2={-1(0xFFFFFFFF), 5} < scalar=0(signed) -> {1, 0}
        vs2_data = {32'd5, 32'hFFFFFFFF}; scalar_data = 64'd0;
        vsew = 3'b010; vl = 2; funct6 = `VFUNCT6_MSLT; use_scalar = 1; vm = 1;
        run_and_wait();
        check_bits(16'b01, "vmslt.vx SEW32 signed: elem0(-1<0)=1, elem1(5<0)=0");

        // vmsleu.vi, SEW=8, unsigned <=, imm=5: vs2={5,4,6,255} -> {1,1,0,0}
        vs2_data = {96'd0, 32'hFF_06_04_05}; scalar_data = 64'd5;   // OOOCore sign-extends simm5; unit test drives scalar_data directly
        vsew = 3'b000; vl = 4; funct6 = `VFUNCT6_MSLEU; use_scalar = 1; vm = 1;
        run_and_wait();
        check_bits(16'b0011, "vmsleu.vi SEW8: elem0(5<=5)=1, elem1(4<=5)=1, elem2(6<=5)=0, elem3(255<=5 unsigned)=0");

        // vmsgtu.vx, SEW=16, unsigned >, scalar=5: vs2={3,5,6,10} -> {0,0,1,1}
        vs2_data = {64'd0, 16'd10, 16'd6, 16'd5, 16'd3}; scalar_data = 64'd5;
        vsew = 3'b001; vl = 4; funct6 = `VFUNCT6_MSGTU; use_scalar = 1; vm = 1;
        run_and_wait();
        check_bits(16'b1100, "vmsgtu.vx SEW16: elem0(3>5)=0, elem1(5>5)=0, elem2(6>5)=1, elem3(10>5)=1");

        // v0.t masking still applies to compares: vmseq.vv SEW32, only elem0 active.
        vs2_data = {32'd9, 32'd9}; vs1_data = {32'd9, 32'd9};
        v0_data = 512'h0; v0_data[0] = 1'b1; v0_data[1] = 1'b0;
        vsew = 3'b010; vl = 2; funct6 = `VFUNCT6_MSEQ; use_scalar = 0; vm = 0;
        run_and_wait();
        check_bits(16'b01, "vmseq.vv masked: elem0 active(9=9)=1, elem1 masked off -> tail-agnostic 0");

        if (fails == 0) $display("PASS  valu_cmp_unit (%0d checks)", checks);
        else $display("FAIL  valu_cmp_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
