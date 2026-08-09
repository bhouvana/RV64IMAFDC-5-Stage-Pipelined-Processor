// docs/adr/0036-linux-boot-attempt-phase-t.md. Verilator C++ harness for a
// real Linux boot attempt -- Icarus Verilog's own event-driven interpreter
// is too slow for the tens-of-millions-of-instructions a real kernel needs
// just to reach its own first console line (confirmed via research, see
// the ADR). This is a plain cycle-driven harness, not a full UVM/DPI setup
// -- this project has never used Verilator before, so this stays minimal:
// toggle clk, drive `start` like every existing testbench's own reset
// convention, and decode uart_tx into real stdout output live (mirroring
// sim/tb/tb_uart_polled.v's own background-decoder-task approach, just
// re-expressed in cycles instead of simulated nanoseconds, since this
// harness has no notion of real time, only clock edges it drives itself).
#include "VPIPELINED.h"
#include "verilated.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>

// Must match whatever UART_CLKS_PER_BIT this build's own PIPELINED
// instantiation uses (build_kernel_boot.sh's own -GUART_CLKS_PER_BIT, see
// that script) -- a real, deliberate simplification already established
// project-wide (every existing directed/random test uses a small
// CLKS_PER_BIT for fast simulation, not a real-baud-accurate divisor;
// this core's own UART.v never made baud rate software-programmable in
// the first place, docs/adr/0034's own Phase R scope note).
static int g_clks_per_bit = 4;

// Mirrors sim/tb/tb_uart_unit.v's own sample_tx_byte task exactly, just in
// cycle units (one iteration of the main loop below = one clk period) --
// no real notion of nanoseconds/half-periods needed since this harness
// controls every clock edge itself.
struct UartDecoder {
    enum State { IDLE, START, DATA, STOP } state = IDLE;
    int wait_count = 0;
    int bit_index = 0;
    uint8_t shift = 0;
    bool prev_tx = true;

    void sample(bool tx, FILE *log) {
        switch (state) {
        case IDLE:
            if (prev_tx && !tx) {
                state = START;
                wait_count = 0;
            }
            break;
        case START:
            wait_count++;
            if (wait_count >= g_clks_per_bit / 2) {
                state = tx ? IDLE : DATA;  // spurious edge if tx went back high
                wait_count = 0;
                bit_index = 0;
                shift = 0;
            }
            break;
        case DATA:
            wait_count++;
            if (wait_count >= g_clks_per_bit) {
                wait_count = 0;
                if (tx) shift |= (1 << bit_index);
                bit_index++;
                if (bit_index == 8) state = STOP;
            }
            break;
        case STOP:
            wait_count++;
            if (wait_count >= g_clks_per_bit) {
                wait_count = 0;
                state = IDLE;
                putchar(shift);
                fflush(stdout);
                if (log) {
                    fputc(shift, log);
                    fflush(log);
                }
            }
            break;
        }
        prev_tx = tx;
    }
};

// Verilator's own runtime references this symbol unconditionally
// (verilated.cpp's trace-related code path) even when SystemC isn't in
// use at all -- the standard, documented fix for a plain non-SystemC
// integration like this one is a trivial definition here, not a real
// timestamp source (this harness has no notion of real simulated time,
// only the cycle count sim_main.cpp itself drives).
double sc_time_stamp() { return 0; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    uint64_t max_cycles = 0;      // 0 = unbounded (relies on external timeout/kill)
    uint64_t progress_every = 10000000ULL;
    uint64_t pc_trace_every = 0;  // docs/adr/0036: 0 = off; a real diagnostic aid, not a normal-run feature -- distinguishing "slow but real forward progress" from "stuck oscillating in a tight loop" needs a PC trajectory, not just a last-changed timestamp.
    uint32_t pc_trace_min = 0;  // Phase W: optional gate -- skip tracing until debug_pc first reaches this, so a targeted investigation doesn't have to wade through firmware-boot trace output to reach the kernel region of interest.
    const char *console_log_path = "sim/verilator/boot_console.log";

    for (int i = 1; i < argc; i++) {
        if (strncmp(argv[i], "+max-cycles=", 12) == 0)
            max_cycles = strtoull(argv[i] + 12, nullptr, 10);
        else if (strncmp(argv[i], "+clks-per-bit=", 14) == 0)
            g_clks_per_bit = atoi(argv[i] + 14);
        else if (strncmp(argv[i], "+console-log=", 13) == 0)
            console_log_path = argv[i] + 13;
        else if (strncmp(argv[i], "+pc-trace-every=", 16) == 0)
            pc_trace_every = strtoull(argv[i] + 16, nullptr, 10);
        else if (strncmp(argv[i], "+pc-trace-min=", 14) == 0)
            pc_trace_min = (uint32_t)strtoull(argv[i] + 14, nullptr, 16);
    }

    FILE *console_log = fopen(console_log_path, "ab");

    VPIPELINED *dut = new VPIPELINED;
    dut->clk = 0;
    dut->start = 0;
    dut->uart_rx = 1;
    dut->eval();

    UartDecoder uart;
    time_t start_time = time(nullptr);

    // docs/adr/0036: a real kernel boot has no other visible sign of forward
    // progress before its first console write, which can legitimately take
    // hundreds of millions of cycles -- debug_pc/debug_priv_mode (new,
    // "unconnected changes nothing" taps on riscvpipeline.v, same shape as
    // the existing debug_x10) let this harness distinguish "still doing real
    // work, just slow" from "stuck" without a full waveform dump.
    uint32_t last_pc = 0xFFFFFFFF;
    uint64_t last_pc_change_cycle = 0;
    bool warned_stuck = false;

    for (uint64_t cycle = 1; max_cycles == 0 || cycle <= max_cycles; cycle++) {
        dut->clk = 0;
        dut->eval();
        dut->clk = 1;
        dut->eval();

        if (cycle == 2) dut->start = 1;  // mirrors every existing testbench's own "#10 start=1" convention

        uart.sample(dut->uart_tx, console_log);

        uint32_t pc = (uint32_t)dut->debug_pc;
        if (pc != last_pc) {
            last_pc = pc;
            last_pc_change_cycle = cycle;
            warned_stuck = false;
        } else if (!warned_stuck && cycle - last_pc_change_cycle > 2000000) {
            fprintf(stderr, "[stall?] pc=%#x priv=%u unchanged for >2M cycles as of cycle=%llu\n",
                    pc, (unsigned)dut->debug_priv_mode, (unsigned long long)cycle);
            warned_stuck = true;
        }

        if (pc_trace_every != 0 && pc >= pc_trace_min && cycle % pc_trace_every == 0) {
            fprintf(stderr, "[pc] cycle=%llu pc=%#x priv=%u mcause=%#llx jump_regde=%u imm_sum=%#llx inst_regfd=%#x "
                    "inst_raw=%#x is_compressed=%u inst_final=%#x illegal_regde=%u inst_regde=%#x pc_o_regde=%#x trap_src=%#x\n",
                    (unsigned long long)cycle, pc, (unsigned)dut->debug_priv_mode,
                    (unsigned long long)dut->debug_mcause, (unsigned)dut->debug_jump_regde,
                    (unsigned long long)dut->debug_imm_sum, (unsigned)dut->debug_inst_regfd,
                    (unsigned)dut->debug_inst_raw, (unsigned)dut->debug_is_compressed, (unsigned)dut->debug_inst_final,
                    (unsigned)dut->debug_illegal_regde, (unsigned)dut->debug_inst_regde, (unsigned)dut->debug_pc_o_regde,
                    (unsigned)dut->debug_trap_src);
            fprintf(stderr, "    exception_taken=%u trap_cause_raw=%#llx x1=%#llx amo_active=%u amo_wp=%u amo_wd=%u amo_stall=%u amo_read=%#llx "
                    "x2(sp)=%#llx x4(tp)=%#llx x10(a0)=%#llx x11(a1)=%#llx x12(a2)=%#llx x13(a3)=%#llx\n",
                    (unsigned)dut->debug_exception_taken, (unsigned long long)dut->debug_trap_cause_raw,
                    (unsigned long long)dut->debug_x1, (unsigned)dut->debug_amo_active,
                    (unsigned)dut->debug_amo_write_phase, (unsigned)dut->debug_amo_write_done,
                    (unsigned)dut->debug_amo_stall, (unsigned long long)dut->debug_amo_captured_read,
                    (unsigned long long)dut->debug_x2, (unsigned long long)dut->debug_x4,
                    (unsigned long long)dut->debug_x10, (unsigned long long)dut->debug_x11,
                    (unsigned long long)dut->debug_x12, (unsigned long long)dut->debug_x13);
            fprintf(stderr, "    mtval=%#llx satp=%#llx translate_enable=%u itlb_hit=%u itlb_hit_fault=%u ptw_busy=%u ptw_done=%u ptw_fault=%u ptw_vaddr=%#llx ptw_m_addr=%#llx\n",
                    (unsigned long long)dut->debug_mtval, (unsigned long long)dut->debug_satp,
                    (unsigned)dut->debug_translate_enable, (unsigned)dut->debug_itlb_hit,
                    (unsigned)dut->debug_itlb_hit_fault, (unsigned)dut->debug_ptw_busy,
                    (unsigned)dut->debug_ptw_done, (unsigned)dut->debug_ptw_fault,
                    (unsigned long long)dut->debug_ptw_vaddr, (unsigned long long)dut->debug_ptw_m_addr);
        }

        if (cycle % progress_every == 0) {
            time_t elapsed = time(nullptr) - start_time;
            fprintf(stderr, "[progress] cycle=%llu elapsed=%llds (%.0f cycles/sec) pc=%#x priv=%u\n",
                    (unsigned long long)cycle, (long long)elapsed,
                    elapsed > 0 ? (double)cycle / (double)elapsed : 0.0,
                    pc, (unsigned)dut->debug_priv_mode);
        }
    }

    fprintf(stderr, "[final] pc=%#x priv=%u mcause=%#llx last_pc_change_cycle=%llu\n",
            last_pc, (unsigned)dut->debug_priv_mode, (unsigned long long)dut->debug_mcause,
            (unsigned long long)last_pc_change_cycle);

    if (console_log) fclose(console_log);
    dut->final();
    delete dut;
    return 0;
}
