`include "MemoryController.v"

// docs/adr/0043-memory-controller-phase-d.md (Generation 4, Phase D).
// Standalone unit test for MemoryController.v, independent of the
// pipeline -- mirrors tb_wbdecoder_unit.v's own shape (dummy-driven
// requester inputs, `check` task, sequential initial-block scenarios).
// Purely combinational DUT, so every check is a plain #1-settle-then-
// assert, no clock needed for the DUT itself (a clk is still declared,
// used only to pace the scenario sequence for readability).
module tb_memorycontroller_unit;
    localparam XLEN = 32;

    reg clk = 0;
    always #5 clk = ~clk;

    reg lsu_cyc = 0, lsu_stb = 0, lsu_we = 0;
    reg [XLEN-1:0] lsu_addr = 0, lsu_data_o = 0;
    reg [3:0] lsu_sel = 0;
    reg [2:0] lsu_funct3 = 0;

    reg ptw_busy = 0;
    reg ptw_cyc = 0, ptw_stb = 0, ptw_we = 0;
    reg [XLEN-1:0] ptw_addr = 0, ptw_data_o = 0;
    reg [3:0] ptw_sel = 0;
    reg [2:0] ptw_funct3 = 0;

    reg dcache_cyc = 0, dcache_stb = 0, dcache_we = 0;
    reg [XLEN-1:0] dcache_addr = 0, dcache_data_o = 0;
    reg [3:0] dcache_sel = 0;
    reg [2:0] dcache_funct3 = 0;
    reg [2:0] dcache_cti = 0;

    wire m_cyc, m_stb, m_we;
    wire [XLEN-1:0] m_addr, m_data_o;
    wire [3:0] m_sel;
    wire [2:0] m_funct3;
    wire [2:0] m_cti;

    MemoryController #(.XLEN(XLEN)) dut(
        .lsu_cyc(lsu_cyc), .lsu_stb(lsu_stb), .lsu_we(lsu_we),
        .lsu_addr(lsu_addr), .lsu_data_o(lsu_data_o), .lsu_sel(lsu_sel), .lsu_funct3(lsu_funct3),
        .ptw_busy(ptw_busy), .ptw_cyc(ptw_cyc), .ptw_stb(ptw_stb), .ptw_we(ptw_we),
        .ptw_addr(ptw_addr), .ptw_data_o(ptw_data_o), .ptw_sel(ptw_sel), .ptw_funct3(ptw_funct3),
        .dcache_cyc(dcache_cyc), .dcache_stb(dcache_stb), .dcache_we(dcache_we),
        .dcache_addr(dcache_addr), .dcache_data_o(dcache_data_o), .dcache_sel(dcache_sel),
        .dcache_funct3(dcache_funct3), .dcache_cti(dcache_cti),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_addr(m_addr), .m_data_o(m_data_o),
        .m_sel(m_sel), .m_funct3(m_funct3), .m_cti(m_cti)
    );

    integer fails = 0;
    integer checks = 0;

    task check;
        input cond;
        input [511:0] label;
        begin
            checks = checks + 1;
            if (!cond) begin
                fails = fails + 1;
                $display("FAIL  %0s", label);
            end else begin
                $display("pass  %0s", label);
            end
        end
    endtask

    initial begin
        @(posedge clk); #1;

        // -- LSU alone (CACHE_NONE shape: ptw_busy=0, dcache_cyc=0) --
        lsu_cyc = 1; lsu_stb = 1; lsu_we = 0; lsu_addr = 32'h100; lsu_sel = 4'hF;
        #1;
        check(m_cyc && m_stb && !m_we && (m_addr == 32'h100), "lsu alone: routes through unchanged");
        check(m_cti == `CTI_CLASSIC, "lsu alone: m_cti is CTI_CLASSIC (lsu never bursts)");
        lsu_cyc = 0; lsu_stb = 0;

        // -- PTW beats LSU when both want the bus --
        lsu_cyc = 1; lsu_stb = 1; lsu_addr = 32'h200;
        ptw_busy = 1; ptw_cyc = 1; ptw_stb = 1; ptw_addr = 32'h300;
        #1;
        check(m_cyc && (m_addr == 32'h300), "ptw beats lsu when both want the bus (ptw_busy selects)");
        check(m_cti == `CTI_CLASSIC, "ptw arm: m_cti is CTI_CLASSIC (ptw never bursts)");

        // -- Starvation-freedom: once ptw_busy drops, lsu's own still-live
        // request (never actually serviced above) gets through next --
        ptw_busy = 0; ptw_cyc = 0; ptw_stb = 0;
        #1;
        check(m_cyc && (m_addr == 32'h200), "ptw releasing the bus lets lsu's own pending request through");
        lsu_cyc = 0; lsu_stb = 0;

        // -- DCache beats PTW (cached mode's own priority) --
        ptw_busy = 1; ptw_cyc = 1; ptw_stb = 1; ptw_addr = 32'h400;
        dcache_cyc = 1; dcache_stb = 1; dcache_we = 1; dcache_addr = 32'h500; dcache_data_o = 32'hDEAD0000;
        #1;
        check(m_cyc && m_we && (m_addr == 32'h500) && (m_data_o == 32'hDEAD0000),
              "dcache beats ptw when both want the bus");

        // -- CTI passthrough: dcache's own cti value reaches m_cti only
        // while dcache owns the bus --
        dcache_cti = `CTI_INCR_BURST;
        #1;
        check(m_cti == `CTI_INCR_BURST, "dcache owns the bus: its own CTI_INCR_BURST passes through");
        dcache_cti = `CTI_END_OF_BURST;
        #1;
        check(m_cti == `CTI_END_OF_BURST, "dcache owns the bus: its own CTI_END_OF_BURST passes through");

        // -- Once dcache releases, ptw's own still-pending request (never
        // actually serviced above, since dcache had priority) gets through
        // -- the same starvation-freedom shape, one level up the priority
        // chain --
        dcache_cyc = 0; dcache_stb = 0;
        #1;
        check(m_cyc && (m_addr == 32'h400), "dcache releasing the bus lets ptw's own pending request through");
        check(m_cti == `CTI_CLASSIC, "ptw now owns the bus: m_cti reverts to CTI_CLASSIC, no stale dcache CTI leaks through");
        ptw_busy = 0; ptw_cyc = 0; ptw_stb = 0;

        // -- Idle: nobody wants the bus --
        #1;
        check(!m_cyc, "idle: no requester wants the bus, m_cyc low");
        check(m_cti == `CTI_CLASSIC, "idle: m_cti defaults to CTI_CLASSIC");

        if (fails == 0)
            $display("PASS  memorycontroller_unit (%0d checks)", checks);
        else
            $display("FAIL  memorycontroller_unit (%0d/%0d checks failed)", fails, checks);
        $finish;
    end
endmodule
