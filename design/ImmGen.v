`default_nettype none

// Immediate extraction: RV32I's five immediate encodings (I/S/B/U/J-type,
// plus the CSR/SYSTEM zero-extended case) decoded from the raw instruction
// word and sign-extended (or, for CSR addresses, zero-extended) per RV32I's
// spec.
module ImmGen#(parameter Width = 32) (
    input wire [Width-1:0] inst,
    output reg signed [Width-1:0] imm
);

    wire [6:0] opcode = inst[6:0];

    // Generation 2 (Phase M, docs/adr/0028-rv64-migration-phase-m.md) fix:
    // every arm below used to hardcode a 20-bit (or 11-bit, for J-type)
    // sign/zero-extension count sized for a 32-bit result. A concatenation's
    // width is self-determined by its own operands, not by the `signed`
    // keyword on the `imm` output port -- assigning that fixed-32-bit result
    // into a wider-than-32 `imm` zero-extends the top bits instead of
    // sign-extending them, silently wrong at Width=64. Replacing every
    // hardcoded `20`/`11` replication count with `Width-12`/`Width-21`
    // (the actual "how many bits are left after the real field width") is
    // bit-exact at Width=32 (reduces to the original literal) and correct
    // at any wider Width.
    //
    // The shift-immediate case (shamt) has a second, independent width
    // dependency: RV32's slli/srli/srai take a 5-bit shamt (inst[24:20]);
    // RV64's full-width versions need 6 bits (inst[25:20]) to reach 63 --
    // see riscv_defs.vh's FUNCT6_ALT comment and ALUCtrl.v's matching fix.
    // SHAMT_BITS/the inst[19+SHAMT_BITS:20] slice below is written so it
    // reduces to today's exact `inst[24:20]` at Width=32.
    localparam SHAMT_BITS = (Width >= 64) ? 6 : 5;

    always @(*)
    begin
        // Default prevents latch inference for opcodes with no immediate
        // field (R-type, the custom op) that fall through this case.
        imm = {Width{1'b0}};
        case(opcode)
            7'b0010011: //addi subi ori slti andi lw all I type instructions
            begin
                if(inst[14:12] == 3'b101 || inst[14:12] == 3'b001)
                    begin
                    imm = {{(Width-SHAMT_BITS){1'b0}}, inst[19+SHAMT_BITS:20]};
                    end
                else if(inst[14:12] == 3'b011)
                    begin
                    imm = $unsigned({{(Width-12){inst[31]}},inst[31:20]});
                    end
                else
                    begin
                    imm = {{(Width-12){inst[31]}},inst[31:20]};
                    end
            end

            7'b0011011: //addiw/slliw/srliw/sraiw (OPCODE_OP_IMM_32, Generation 2,
                        //docs/adr/0028-rv64-migration-phase-m.md) -- same I-type
                        //shape as OPCODE_I above, but the shift-immediate shamt is
                        //ALWAYS exactly 5 bits (inst[24:20]) regardless of Width --
                        //unlike OPCODE_I's SHAMT_BITS, which widens to 6 at
                        //Width>=64. This opcode is only ever real at Width>=64
                        //(Control.v traps it illegal below that), but ImmGen.v
                        //itself doesn't need to know that -- the same "decode
                        //correctly regardless of whether the caller ends up using
                        //it" discipline as every other arm here.
            begin
                // Pillar K random-test finding (Gen7-K7): slli.uw shares this
                // SAME opcode+funct3(001) but genuinely needs a 6-bit shamt
                // (inst[25:20], one bit wider than slliw's -- see riscv_defs.vh's
                // FUNCT6_ZBA_SLLIUW comment, docs/adr/0060) -- a real,
                // pre-existing gap since Pillar B added slli.uw: this arm never
                // special-cased it, silently dropping inst[25] (the shamt's own
                // top bit) for any slli.uw with shamt>=32. Never triggered by
                // any prior random seed until Pillar K's own random_gen.py
                // additions happened to produce shamt>=32 with a nonzero high
                // bit in play. Distinguished from plain slliw by inst[31:26]
                // (funct6) == FUNCT6_ZBA_SLLIUW(000010) -- slliw's own funct7
                // is always 0000000, so bits[31:26]=000000 there.
                if (inst[14:12] == 3'b001 && inst[31:26] == 6'b000010)
                    begin
                    imm = {{(Width-6){1'b0}}, inst[25:20]};
                    end
                else if(inst[14:12] == 3'b101 || inst[14:12] == 3'b001)
                    begin
                    imm = {{(Width-5){1'b0}}, inst[24:20]};
                    end
                else
                    begin
                    imm = {{(Width-12){inst[31]}},inst[31:20]};
                    end
            end


            7'b1100011: //beq
            begin
                //imm[12] = inst[31];
                //imm[11] = inst[7];
                //imm[10:5] = inst[30:25];
                //imm[4:1] = inst[11:8]
                // Leading 1'b0 is a pure width-filler -- riscvpipeline.v's
                // ShiftLeftOne left-shifts this raw immediate by 1 before use
                // (branch/jal targets are always even), which drops this top
                // bit entirely and promotes the sign-extension block's own
                // top bit into its place. Its value never affects the result
                // at any Width.
                imm = {1'b0,{(Width-12){inst[31]}}, inst[7], inst[30:25], inst[11:8]};

            end
            7'b0000011,   //lw
            7'b0000111:   //flw -- same I-type immediate shape as lw (docs/adr/0019-f-extension.md)
            begin
                imm = {{(Width-12){inst[31]}},inst[31:20]};
            end


            7'b0100011,   //sw
            7'b0100111:   //fsw -- same S-type immediate shape as sw (docs/adr/0019-f-extension.md)
            begin
                //imm[11:5] = inst[31:25];
                  //imm[4:0] =inst[11:7];
                imm = {{(Width-12){inst[31]}},inst[31:25],inst[11:7]};
            end


            7'b1101111://jal
            begin
                //imm[20] = inst[31];
                //imm[19:12] = inst[19:11];
                 //imm[11] = inst[20];
                //imm[10:1] = inst[30:21];
                // Same leading-1'b0-is-a-filler reasoning as the branch arm
                // above -- ShiftLeftOne drops it.
                imm ={1'b0,{(Width-21){inst[31]}},inst[31],inst[19:12],inst[20],inst[30:21]};
            end

            7'b1100111://jalr -- plain I-type immediate (NOT the shifted branch/jal
            begin                //convention: jalr's target is rs1+imm, computed directly, no ShiftLeftOne)
                imm = {{(Width-12){inst[31]}},inst[31:20]};
            end

            7'b0110111, //lui
            7'b0010111: //auipc -- both U-type: imm = inst[31:12] in the top 20 bits, low 12 zero.
                        //Spec: "the 32-bit result is sign-extended to XLEN
                        //bits" -- inst[31] (the top bit of the 32-bit
                        //intermediate result) is the sign source.
            begin
                imm = {{(Width-32){inst[31]}}, inst[31:12], 12'b0};
            end

            7'b1110011: //SYSTEM (csrrw/csrrs/csrrc+i, ecall, ebreak, mret) --
                        //inst[31:20] is the CSR address for real csrrX ops
            begin      //(riscvpipeline.v takes imm[11:0] as csr_addr); zero-
                       //extended since a CSR address isn't sign-extended
                imm = {{(Width-12){1'b0}}, inst[31:20]};
            end

	endcase
    end
            
endmodule

`default_nettype wire
