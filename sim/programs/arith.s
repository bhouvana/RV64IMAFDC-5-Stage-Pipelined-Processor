# One of every R-type/I-type ALU op this core implements, plus the custom
# ctz op. Producer/consumer gaps are kept wide (>2 instructions) so this test
# is meant as a pure ISA-coverage check, not a hazard-timing check (see
# forward_*.s and load_use_stall.s for those) -- but the 2-nop gap between
# the two addi's and the first add (a gap of exactly 3 instructions) turned
# out to incidentally regression-test docs/adr/0002-register-file-write-first-bypass.md.
addi x1, x0, 5
addi x2, x0, 3
nop
nop
add   x3,  x1, x2      # 5+3=8
sub   x4,  x1, x2      # 5-3=2
sll   x5,  x1, x2      # 5<<3=40
slt   x6,  x2, x1      # 3<5 -> 1
sltu  x7,  x1, x2      # 5<3u -> 0
xor   x8,  x1, x2      # 5^3=6
srl   x9,  x5, x2      # 40>>3=5
sra   x10, x5, x2      # 40>>>3=5 (positive operand, same as srl)
or    x11, x1, x2      # 5|3=7
and   x12, x1, x2      # 5&3=1
addi  x13, x0, -1      # 0xFFFFFFFF
srli  x14, x13, 4      # logical: 0x0FFFFFFF
srai  x15, x13, 4      # arithmetic: stays 0xFFFFFFFF
slli  x16, x1, 2       # 5<<2=20
slti  x17, x2, 10      # 3<10 -> 1
sltiu x18, x1, 3       # 5<3u -> 0
xori  x19, x1, 3       # 5^3=6
ori   x20, x1, 3       # 5|3=7
andi  x21, x1, 3       # 5&3=1
ctz   x22, x23         # x23 was never written (=0): loop scans bits[0:31],
                        # all zero, `done` never sets -> count=32 (real ctz(0),
                        # docs/adr/0041 fixed ALU.v's prior XLEN-1 off-by-one).

fence
halt:
jal x0, halt   # spin here forever instead of running off the end of the
               # program into instruction memory's zero-filled remainder --
               # opcode 0000000 is not a valid instruction and (correctly,
               # after docs/adr/0011) now traps. See docs/adr/0011-csr-and-exceptions.md.
