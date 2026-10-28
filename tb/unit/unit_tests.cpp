// Unit tests for the ALU, immediate generator, branch unit, register file and hazard unit.
// Each block is driven with directed corner cases plus random vectors and compared with a
// small C++ reference model written from the RISC-V spec.
#include <verilated.h>

#include <cstdint>
#include <cstdio>
#include <random>
#include <string>

#include "Vunit_top.h"

namespace {

int failures = 0, checks = 0;

void expect(bool ok, const std::string& what) {
    ++checks;
    if (!ok && failures++ < 20) std::printf("  FAIL %s\n", what.c_str());
}

std::string hex(uint32_t v) {
    char b[16];
    std::snprintf(b, sizeof b, "%08x", v);
    return b;
}

// ---- reference models ----
uint32_t ref_alu(int op, uint32_t a, uint32_t b) {
    const uint32_t sh = b & 31;
    switch (op) {
        case 0: return a + b;
        case 1: return a - b;
        case 2: return a << sh;
        case 3: return int32_t(a) < int32_t(b);
        case 4: return a < b;
        case 5: return a ^ b;
        case 6: return a >> sh;
        case 7: return uint32_t(int32_t(a) >> sh);
        case 8: return a | b;
        default: return a & b;
    }
}

uint32_t sext(uint32_t v, int bits) { return uint32_t(int32_t(v << (32 - bits)) >> (32 - bits)); }

uint32_t ref_imm(uint32_t in, int fmt) {
    switch (fmt) {
        case 0: return sext(in >> 20, 12);
        case 1: return sext(((in >> 25) << 5) | ((in >> 7) & 0x1f), 12);
        case 2: return sext((((in >> 31) & 1) << 12) | (((in >> 7) & 1) << 11) | (((in >> 25) & 0x3f) << 5) |
                                (((in >> 8) & 0xf) << 1), 13);
        case 3: return in & 0xfffff000u;
        default: return sext((((in >> 31) & 1) << 20) | (((in >> 12) & 0xff) << 12) | (((in >> 20) & 1) << 11) |
                                 (((in >> 21) & 0x3ff) << 1), 21);
    }
}

bool ref_branch(int f3, uint32_t a, uint32_t b) {
    switch (f3) {
        case 0: return a == b;
        case 1: return a != b;
        case 4: return int32_t(a) < int32_t(b);
        case 5: return int32_t(a) >= int32_t(b);
        case 6: return a < b;
        case 7: return a >= b;
        default: return false;
    }
}

const uint32_t kEdge[] = {0, 1, 2, 31, 32, 0x7fffffff, 0x80000000, 0x80000001, 0xffffffff, 0xfffffffe, 0x12345678};

}  // namespace

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vunit_top top;
    std::mt19937 rng(7);

    // ---- ALU: every op on all edge-value pairs, plus random ----
    for (int op = 0; op <= 9; ++op) {
        auto check = [&](uint32_t a, uint32_t b) {
            top.alu_op = op;
            top.alu_a = a;
            top.alu_b = b;
            top.eval();
            expect(top.alu_y == ref_alu(op, a, b),
                   "alu op " + std::to_string(op) + " a=" + hex(a) + " b=" + hex(b) + " got " + hex(top.alu_y));
        };
        for (uint32_t a : kEdge) for (uint32_t b : kEdge) check(a, b);
        for (int i = 0; i < 20000; ++i) check(rng(), rng());
    }
    int alu_checks = checks;

    // ---- immediate generator: random instruction words for every format ----
    for (int fmt = 0; fmt <= 4; ++fmt) {
        for (int i = 0; i < 20000; ++i) {
            uint32_t in = rng();
            if (i < 2) in = i ? 0xffffffffu : 0;
            top.imm_insn = in;
            top.imm_fmt = fmt;
            top.eval();
            expect(top.imm == ref_imm(in, fmt), "imm fmt " + std::to_string(fmt) + " insn=" + hex(in));
        }
    }
    int imm_checks = checks - alu_checks;

    // ---- branch unit ----
    for (int f3 : {0, 1, 4, 5, 6, 7}) {
        auto check = [&](uint32_t a, uint32_t b) {
            top.br_funct3 = f3;
            top.alu_a = a;
            top.alu_b = b;
            top.eval();
            expect(bool(top.br_taken) == ref_branch(f3, a, b), "branch f3=" + std::to_string(f3) + " a=" + hex(a) + " b=" + hex(b));
        };
        for (uint32_t a : kEdge) for (uint32_t b : kEdge) check(a, b);
        for (int i = 0; i < 5000; ++i) check(rng(), rng() & 0xff ? rng() : rng() & 3);
    }
    int br_checks = checks - alu_checks - imm_checks;

    // ---- register file: random writes and reads against a model, including x0 and bypass ----
    uint32_t model[32] = {};
    auto tick = [&] {
        top.clk = 0; top.eval();
        top.clk = 1; top.eval();
    };
    for (int r = 1; r < 32; ++r) {  // initialise
        top.rf_we = 1; top.rf_waddr = r; top.rf_wdata = model[r] = rng();
        tick();
    }
    for (int i = 0; i < 20000; ++i) {
        const bool we = rng() & 1;
        const uint32_t wa = rng() & 31, wd = rng(), r1 = rng() & 31, r2 = (i & 3) ? rng() & 31 : wa;
        top.rf_we = we; top.rf_waddr = wa; top.rf_wdata = wd; top.rf_raddr1 = r1; top.rf_raddr2 = r2;
        top.clk = 0;
        top.eval();
        // Combinational reads before the edge see the bypassed write data.
        auto expect_read = [&](uint32_t ra) -> uint32_t {
            if (ra == 0) return 0;
            if (we && wa == ra) return wd;
            return model[ra];
        };
        expect(top.rf_rdata1 == expect_read(r1), "regfile read1 x" + std::to_string(r1));
        expect(top.rf_rdata2 == expect_read(r2), "regfile read2 x" + std::to_string(r2) + " (bypass)");
        top.clk = 1;
        top.eval();
        if (we && wa != 0) model[wa] = wd;
    }
    top.rf_we = 1; top.rf_waddr = 0; top.rf_wdata = 0xdeadbeef; tick();
    top.rf_we = 0; top.rf_raddr1 = 0; top.eval();
    expect(top.rf_rdata1 == 0, "x0 stays zero after a write");
    int rf_checks = checks - alu_checks - imm_checks - br_checks;

    // ---- hazard unit: exhaustive over small register indices, against the textbook rules ----
    std::uniform_int_distribution<int> reg(0, 3);  // few registers => many collisions
    for (int i = 0; i < 200000; ++i) {
        const int id_rs1 = reg(rng), id_rs2 = reg(rng), ex_rs1 = reg(rng), ex_rs2 = reg(rng);
        const int ex_rd = reg(rng), mem_rd = reg(rng), wb_rd = reg(rng);
        const bool id_v = rng() & 1, u1 = rng() & 1, u2 = rng() & 1, ex_v = rng() & 1, ex_ld = rng() & 1;
        const bool redirect = (rng() & 7) == 0, trap = (rng() & 15) == 0;
        const bool mem_v = rng() & 1, mem_we = rng() & 1, wb_v = rng() & 1, wb_we = rng() & 1;
        top.hz_id_valid = id_v; top.hz_id_rs1 = id_rs1; top.hz_id_rs2 = id_rs2;
        top.hz_id_uses_rs1 = u1; top.hz_id_uses_rs2 = u2;
        top.hz_ex_valid = ex_v; top.hz_ex_rs1 = ex_rs1; top.hz_ex_rs2 = ex_rs2; top.hz_ex_rd = ex_rd;
        top.hz_ex_mem_re = ex_ld; top.hz_ex_redirect = redirect; top.hz_ex_trap = trap;
        top.hz_mem_valid = mem_v; top.hz_mem_rd = mem_rd; top.hz_mem_reg_we = mem_we;
        top.hz_wb_valid = wb_v; top.hz_wb_rd = wb_rd; top.hz_wb_reg_we = wb_we;
        top.eval();

        auto fwd = [&](int rs) {
            if (mem_v && mem_we && mem_rd != 0 && mem_rd == rs) return 1;
            if (wb_v && wb_we && wb_rd != 0 && wb_rd == rs) return 2;
            return 0;
        };
        const bool lu = ex_v && ex_ld && ex_rd != 0 && id_v && ((u1 && id_rs1 == ex_rd) || (u2 && id_rs2 == ex_rd));
        const bool kill = redirect || trap;
        expect(top.hz_fwd_a == fwd(ex_rs1), "hazard fwd_a");
        expect(top.hz_fwd_b == fwd(ex_rs2), "hazard fwd_b");
        expect(bool(top.hz_load_use) == lu, "hazard load_use");
        expect(bool(top.hz_stall) == (lu && !kill), "hazard stall");
        expect(bool(top.hz_bubble_ex) == (kill || lu), "hazard bubble_ex");
        expect(bool(top.hz_flush_id) == kill, "hazard flush_id");
    }
    int hz_checks = checks - alu_checks - imm_checks - br_checks - rf_checks;

    std::printf("ALU          %7d checks\n", alu_checks);
    std::printf("imm_gen      %7d checks\n", imm_checks);
    std::printf("branch_unit  %7d checks\n", br_checks);
    std::printf("regfile      %7d checks\n", rf_checks);
    std::printf("hazard_unit  %7d checks\n", hz_checks);
    std::printf("%s: %d checks, %d failures\n", failures ? "FAILED" : "all passed", checks, failures);
    return failures ? 1 : 0;
}
