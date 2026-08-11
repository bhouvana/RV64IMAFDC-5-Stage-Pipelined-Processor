`include "ALUCtrl.v"

// Pillar K, Task 3 -- decode-only check, independent of ALU.v/the pipeline.
module tb_aluctrl_zbkc_zbkb_unit;
    reg  [1:0] ALUOp = 0;
    reg  [6:0] funct7_c = 0;
    reg  [2:0] funct3_c = 0;
    reg  [4:0] rs2_c = 0;
    wire [6:0] ALUCtl;

    ALUCtrl dut(.ALUOp(ALUOp), .funct7_c(funct7_c), .funct3_c(funct3_c), .rs2_c(rs2_c), .ALUCtl(ALUCtl));

    integer checks = 0;
    integer fails = 0;
    task check_ctl;
        input [6:0] expected;
        input [1023:0] label;
        begin
            checks = checks + 1;
            if (ALUCtl !== expected) begin
                fails = fails + 1;
                $display("FAIL  %0s: ALUCtl=%b, expected %b", label, ALUCtl, expected);
            end else $display("pass  %0s: ALUCtl=%b", label, ALUCtl);
        end
    endtask

    initial begin
        ALUOp = `ALUOP_RTYPE;
        funct7_c = `FUNCT7_ZBB_MINMAX; funct3_c = 3'b001;
        #1 check_ctl(`ALUCTL_CLMUL, "clmul");
        funct7_c = `FUNCT7_ZBB_MINMAX; funct3_c = 3'b011;
        #1 check_ctl(`ALUCTL_CLMULH, "clmulh");
        funct7_c = `FUNCT7_ZBKB_PACK; funct3_c = 3'b100;
        #1 check_ctl(`ALUCTL_PACK, "pack");
        funct7_c = `FUNCT7_ZBKB_PACK; funct3_c = 3'b111;
        #1 check_ctl(`ALUCTL_PACKH, "packh");
        funct7_c = `FUNCT7_ZBKX_XPERM; funct3_c = 3'b010;
        #1 check_ctl(`ALUCTL_XPERM4, "xperm4");
        funct7_c = `FUNCT7_ZBKX_XPERM; funct3_c = 3'b100;
        #1 check_ctl(`ALUCTL_XPERM8, "xperm8");
        // Regression: FUNCT7_ZBKX_XPERM shares its bit pattern with FUNCT7_ZBS_BSET
        // (funct3=001) -- must still decode correctly.
        funct7_c = `FUNCT7_ZBS_BSET; funct3_c = 3'b001;
        #1 check_ctl(`ALUCTL_BSET, "bset (regression: shares funct7 bit pattern with xperm4/8)");

        ALUOp = `ALUOP_ITYPE;
        funct7_c = {`FUNCT6_ZBB_REV8, 1'b0}; funct3_c = 3'b101; rs2_c = `RS2_BREV8;
        #1 check_ctl(`ALUCTL_BREV8, "brev8");
        rs2_c = 5'b11000;  // rev8's own rs2_c -- must NOT collide with brev8's decode
        #1 check_ctl(`ALUCTL_REV8, "rev8 (regression: shares funct6 with brev8, must still decode correctly)");

        if (fails == 0)
            $display("PASS  aluctrl_zbkc_zbkb_unit (%0d checks)", checks);
        else
            $display("FAIL  aluctrl_zbkc_zbkb_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
