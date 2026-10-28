// Verilator testbench for the SoC.
//
//   ./obj_pipe/Vsoc --imem prog.imem.hex --dmem prog.dmem.hex [options]
//
// Every instruction the RTL retires is checked against the C++ golden model (sim/iss.cpp) in
// lockstep: same PC, same instruction, same register write, same memory access, same trap.
// The first mismatch stops the run and prints both sides.
//
// Exit status: 0 on success. "Success" for --mode test is the riscv-tests convention (ECALL with
// gp == 1); for --mode prog it is ECALL with a0 == 0 (main returned 0).
//
// Options:
//   --mode test|prog     how to interpret the halt (default prog)
//   --max-cycles N       give up after N cycles (default 10,000,000)
//   --no-check           don't run the golden model (faster)
//   --trace FILE         write the commit trace (one line per retired instruction)
//   --vcd FILE           dump waveforms (view with GTKWave)
//   --stats-json FILE    write cycle / instruction / hazard counters as JSON
//   --quiet              don't echo UART output
#include <verilated.h>
#include <verilated_vcd_c.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <memory>
#include <string>

#include "Vsoc.h"
#include "iss.h"

namespace {

struct Options {
    std::string imem, dmem, mode = "prog", trace, vcd, stats_json;
    uint64_t max_cycles = 10'000'000;
    bool check = true, quiet = false;
};

Options parse(int argc, char** argv) {
    Options o;
    for (int i = 1; i < argc; ++i) {
        std::string k = argv[i];
        auto val = [&]() -> std::string {
            if (i + 1 >= argc) { std::fprintf(stderr, "missing value for %s\n", k.c_str()); std::exit(2); }
            return argv[++i];
        };
        if (k == "--imem") o.imem = val();
        else if (k == "--dmem") o.dmem = val();
        else if (k == "--mode") o.mode = val();
        else if (k == "--max-cycles") o.max_cycles = std::stoull(val());
        else if (k == "--no-check") o.check = false;
        else if (k == "--trace") o.trace = val();
        else if (k == "--vcd") o.vcd = val();
        else if (k == "--stats-json") o.stats_json = val();
        else if (k == "--quiet") o.quiet = true;
        else if (k[0] == '+') continue;  // Verilator plusargs
        else { std::fprintf(stderr, "unknown option %s\n", k.c_str()); std::exit(2); }
    }
    if (o.imem.empty()) { std::fprintf(stderr, "usage: Vsoc --imem f.hex [--dmem f.hex] ...\n"); std::exit(2); }
    return o;
}

const char* trap_name(int t) {
    switch (t) {
        case 0: return "none";
        case 1: return "ecall";
        case 2: return "illegal";
        default: return "misaligned";
    }
}

// Compare only the byte lanes a store actually writes.
uint32_t lane_mask(uint8_t strb) {
    uint32_t m = 0;
    for (int b = 0; b < 4; ++b) if (strb & (1u << b)) m |= 0xffu << (8 * b);
    return m;
}

}  // namespace

int main(int argc, char** argv) {
    Options opt = parse(argc, argv);

    // Hand the hex paths to $readmemh through plusargs.
    std::string pa_imem = "+imem=" + opt.imem, pa_dmem = "+dmem=" + opt.dmem;
    const char* vargs[] = {argv[0], pa_imem.c_str(), pa_dmem.c_str()};
    auto ctx = std::make_unique<VerilatedContext>();
    ctx->commandArgs(opt.dmem.empty() ? 2 : 3, vargs);
    auto top = std::make_unique<Vsoc>(ctx.get());

    std::unique_ptr<VerilatedVcdC> vcd;
    if (!opt.vcd.empty()) {
        ctx->traceEverOn(true);
        vcd = std::make_unique<VerilatedVcdC>();
        top->trace(vcd.get(), 99);
        vcd->open(opt.vcd.c_str());
    }

    rv::Iss iss(64 * 256, 64 * 256);
    iss.load_hex(opt.imem, true);
    if (!opt.dmem.empty()) iss.load_hex(opt.dmem, false);

    std::ofstream trace;
    if (!opt.trace.empty()) trace.open(opt.trace);

    uint32_t shadow[32] = {};  // architectural registers, rebuilt from the trace
    uint64_t t = 0;
    auto tick = [&] {
        top->clk = 0;
        top->eval();
        if (vcd) vcd->dump(t++);
        top->clk = 1;
        top->eval();
        if (vcd) vcd->dump(t++);
    };

    top->rst = 1;
    for (int i = 0; i < 3; ++i) tick();
    top->rst = 0;

    int status = 0;
    bool done = false;
    uint64_t cycle = 0, retired = 0;
    int halt_trap = 0;
    for (; cycle < opt.max_cycles && !done; ++cycle) {
        // Sample everything retiring in this cycle (before the rising edge commits it).
        top->clk = 0;
        top->eval();
        if (top->uart_valid && !opt.quiet) {
            std::putchar(top->uart_data);
            std::fflush(stdout);
        }
        if (top->rvfi_valid) {
            ++retired;
            rv::Retire hw;
            hw.pc = top->rvfi_pc;
            hw.insn = top->rvfi_insn;
            hw.trap = top->rvfi_trap;
            hw.rd = top->rvfi_rd;
            hw.rd_wdata = top->rvfi_rd_wdata;
            hw.mem_addr = top->rvfi_mem_addr;
            hw.mem_re = top->rvfi_mem_re;
            hw.mem_wstrb = top->rvfi_mem_wstrb;
            hw.mem_wdata = top->rvfi_mem_wdata;
            if (hw.rd) shadow[hw.rd] = hw.rd_wdata;

            if (trace.is_open()) {
                char buf[160];
                std::snprintf(buf, sizeof buf, "%08x %08x", hw.pc, hw.insn);
                trace << buf;
                if (hw.rd) { std::snprintf(buf, sizeof buf, " x%-2d=%08x", hw.rd, hw.rd_wdata); trace << buf; }
                if (hw.mem_wstrb) { std::snprintf(buf, sizeof buf, " mem[%08x]<=%08x/%x", hw.mem_addr, hw.mem_wdata, hw.mem_wstrb); trace << buf; }
                if (hw.trap) trace << " trap=" << trap_name(hw.trap);
                trace << "\n";
            }

            if (opt.check) {
                const bool mmio = hw.mem_re && (hw.mem_addr & 0xffffff00u) == rv::kMmioBase;
                rv::Retire sw = iss.step(mmio ? &hw.rd_wdata : nullptr);
                const bool mem_op = sw.mem_re || sw.mem_wstrb || hw.mem_re || hw.mem_wstrb;
                const uint32_t m = lane_mask(sw.mem_wstrb);
                bool ok = hw.pc == sw.pc && hw.insn == sw.insn && hw.trap == sw.trap && hw.rd == sw.rd &&
                          hw.rd_wdata == sw.rd_wdata && hw.mem_re == sw.mem_re && hw.mem_wstrb == sw.mem_wstrb &&
                          (!mem_op || hw.mem_addr == sw.mem_addr) && (hw.mem_wdata & m) == (sw.mem_wdata & m);
                if (!ok) {
                    std::fprintf(stderr,
                                 "\nMISMATCH at instruction %llu (cycle %llu)\n"
                                 "  rtl: pc=%08x insn=%08x rd=x%d<=%08x mem=%08x re=%d wstrb=%x wdata=%08x trap=%s\n"
                                 "  iss: pc=%08x insn=%08x rd=x%d<=%08x mem=%08x re=%d wstrb=%x wdata=%08x trap=%s\n",
                                 (unsigned long long)retired, (unsigned long long)cycle, hw.pc, hw.insn, hw.rd,
                                 hw.rd_wdata, hw.mem_addr, hw.mem_re, hw.mem_wstrb, hw.mem_wdata, trap_name(hw.trap),
                                 sw.pc, sw.insn, sw.rd, sw.rd_wdata, sw.mem_addr, sw.mem_re, sw.mem_wstrb,
                                 sw.mem_wdata, trap_name(sw.trap));
                    status = 3;
                    done = true;
                }
            }
            if (hw.trap) {
                halt_trap = hw.trap;
                done = true;
            }
        }
        top->clk = 1;
        top->eval();
        if (vcd) { vcd->dump(t++); vcd->dump(t++); }
    }
    if (!opt.quiet) std::fflush(stdout);

    const uint64_t cycles = top->cycles, instret = top->instret;
    const uint32_t stalls = top->stall_cycles, flushes = top->flushes, branches = top->branches;
    if (status == 0) {
        if (!done) {
            std::fprintf(stderr, "\nTIMEOUT after %llu cycles\n", (unsigned long long)cycle);
            status = 4;
        } else if (halt_trap != 1) {
            std::fprintf(stderr, "\nHALT on %s trap at pc %08x\n", trap_name(halt_trap), top->rvfi_pc);
            status = 5;
        } else if (opt.mode == "test") {
            const uint32_t gp = shadow[3];
            if (gp != 1) {
                std::fprintf(stderr, "FAIL: test case %u failed\n", gp >> 1);
                status = 1;
            }
        } else if (shadow[10] != 0) {
            std::fprintf(stderr, "\nprogram exited with code %u\n", shadow[10]);
            status = 1;
        }
    }

    if (!opt.quiet || status != 0)
        std::fprintf(stderr,
                     "[%s] cycles %llu | instret %llu | CPI %.3f | load-use stall cycles %u (%.1f%%) | "
                     "flushes %u (%u cycles, %.1f%%) | branch/jump prediction %.1f%% of %u%s\n",
                     status == 0 ? "ok" : "FAILED", (unsigned long long)cycles, (unsigned long long)instret,
                     instret ? double(cycles) / instret : 0.0, stalls, cycles ? 100.0 * stalls / cycles : 0.0, flushes,
                     2 * flushes, cycles ? 200.0 * flushes / cycles : 0.0,
                     branches ? 100.0 * (branches - flushes) / branches : 0.0, branches,
                     opt.check ? ", golden model matched" : "");
    if (!opt.stats_json.empty()) {
        std::ofstream j(opt.stats_json);
        j << "{\"status\": " << status << ", \"cycles\": " << cycles << ", \"instret\": " << instret
          << ", \"stall_cycles\": " << stalls << ", \"flushes\": " << flushes
          << ", \"branches\": " << branches << "}\n";
    }
    if (vcd) vcd->close();
    top->final();
    return status;
}
