// Standalone golden-model runner: execute a program on the ISA simulator alone.
//
//   rv32sim --imem p.imem.hex [--dmem p.dmem.hex] [--mode test|prog] [--trace out.txt]
//
// Used to validate the golden model itself against the official riscv-tests (independently of
// the RTL), and to produce reference commit traces.
#include <cstdio>
#include <fstream>
#include <string>

#include "iss.h"

int main(int argc, char** argv) {
    std::string imem, dmem, mode = "prog", trace_path;
    uint64_t max_insns = 100'000'000;
    for (int i = 1; i + 1 < argc; i += 2) {
        std::string k = argv[i], v = argv[i + 1];
        if (k == "--imem") imem = v;
        else if (k == "--dmem") dmem = v;
        else if (k == "--mode") mode = v;
        else if (k == "--trace") trace_path = v;
        else if (k == "--max-insns") max_insns = std::stoull(v);
        else { std::fprintf(stderr, "unknown option %s\n", k.c_str()); return 2; }
    }
    if (imem.empty()) { std::fprintf(stderr, "usage: rv32sim --imem f.hex [--dmem f.hex] [--mode test|prog]\n"); return 2; }

    rv::Iss iss(64 * 256, 64 * 256);
    iss.load_hex(imem, true);
    if (!dmem.empty()) iss.load_hex(dmem, false);
    std::ofstream trace;
    if (!trace_path.empty()) trace.open(trace_path);

    uint64_t n = 0;
    rv::Retire r;
    while (!iss.halted() && n < max_insns) {
        r = iss.step();
        ++n;
        if (trace.is_open()) {
            char buf[96];
            std::snprintf(buf, sizeof buf, "%08x %08x", r.pc, r.insn);
            trace << buf;
            if (r.rd) { std::snprintf(buf, sizeof buf, " x%-2d=%08x", r.rd, r.rd_wdata); trace << buf; }
            trace << "\n";
        }
    }
    std::fputs(iss.uart_out.c_str(), stdout);
    if (!iss.halted()) { std::fprintf(stderr, "timeout after %llu instructions\n", (unsigned long long)n); return 4; }
    if (r.trap != rv::TRAP_ECALL) { std::fprintf(stderr, "halted on trap %d at pc %08x\n", r.trap, r.pc); return 5; }
    const uint32_t result = mode == "test" ? iss.reg(3) : iss.reg(10);
    const bool ok = mode == "test" ? result == 1 : result == 0;
    if (!ok) std::fprintf(stderr, mode == "test" ? "FAIL: test case %u\n" : "exit code %u\n", mode == "test" ? result >> 1 : result);
    return ok ? 0 : 1;
}
