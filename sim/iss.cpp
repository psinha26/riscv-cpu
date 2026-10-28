#include "iss.h"

#include <fstream>
#include <sstream>
#include <stdexcept>

namespace rv {

namespace {

int32_t sext(uint32_t v, int bits) { return int32_t(v << (32 - bits)) >> (32 - bits); }

uint32_t imm_i(uint32_t in) { return uint32_t(int32_t(in) >> 20); }
uint32_t imm_s(uint32_t in) { return uint32_t(sext(((in >> 25) << 5) | ((in >> 7) & 0x1f), 12)); }
uint32_t imm_b(uint32_t in) {
    uint32_t v = (((in >> 31) & 1) << 12) | (((in >> 7) & 1) << 11) | (((in >> 25) & 0x3f) << 5) |
                 (((in >> 8) & 0xf) << 1);
    return uint32_t(sext(v, 13));
}
uint32_t imm_u(uint32_t in) { return in & 0xfffff000u; }
uint32_t imm_j(uint32_t in) {
    uint32_t v = (((in >> 31) & 1) << 20) | (((in >> 12) & 0xff) << 12) | (((in >> 20) & 1) << 11) |
                 (((in >> 21) & 0x3ff) << 1);
    return uint32_t(sext(v, 21));
}

}  // namespace

Iss::Iss(size_t imem_words, size_t dmem_words) : imem_(imem_words, 0x00000013u), dmem_(dmem_words, 0) {}

void Iss::load_hex(const std::string& path, bool into_imem) {
    std::ifstream f(path);
    if (!f) throw std::runtime_error("cannot open " + path);
    auto& mem = into_imem ? imem_ : dmem_;
    size_t idx = 0;
    std::string tok;
    while (f >> tok) {
        if (tok[0] == '@') {
            idx = std::stoul(tok.substr(1), nullptr, 16);
            continue;
        }
        if (tok.rfind("//", 0) == 0) {
            std::getline(f, tok);
            continue;
        }
        if (idx >= mem.size()) throw std::runtime_error(path + " does not fit in memory");
        mem[idx++] = uint32_t(std::stoul(tok, nullptr, 16));
    }
}

uint32_t Iss::load_word(uint32_t addr, bool* ok) const {
    *ok = true;
    if (addr >= kDmemBase && addr < kDmemBase + 4 * dmem_.size()) return dmem_[(addr - kDmemBase) >> 2];
    if ((addr & 0xffffff00u) == kMmioBase) return (addr & 0xff) <= 4 ? 1u : 0u;  // UART ready
    return 0;  // unmapped reads return zero, as in the SoC
}

void Iss::store(uint32_t addr, uint8_t strb, uint32_t data) {
    if (addr >= kDmemBase && addr < kDmemBase + 4 * dmem_.size()) {
        uint32_t& w = dmem_[(addr - kDmemBase) >> 2];
        for (int b = 0; b < 4; ++b)
            if (strb & (1u << b)) w = (w & ~(0xffu << (8 * b))) | (data & (0xffu << (8 * b)));
    } else if (addr == kMmioBase && (strb & 1)) {
        uart_out += char(data & 0xff);
    }
}

Retire Iss::step(const uint32_t* mmio_load_result) {
    Retire r;
    r.pc = pc_;
    const uint32_t idx = pc_ >> 2;
    const uint32_t in = (pc_ < 4 * imem_.size()) ? imem_[idx] : 0;
    r.insn = in;

    const uint32_t opcode = in & 0x7f, rd = (in >> 7) & 0x1f, f3 = (in >> 12) & 7;
    const uint32_t rs1 = (in >> 15) & 0x1f, rs2 = (in >> 20) & 0x1f, f7 = in >> 25;
    const uint32_t a = x_[rs1], b = x_[rs2];
    uint32_t next = pc_ + 4;
    bool wr = false;
    uint32_t val = 0;

    auto illegal = [&] { r.trap = TRAP_ILLEGAL; };
    auto jump = [&](uint32_t t) {
        if (t & 3) r.trap = TRAP_MISALIGNED;
        else next = t;
    };

    if ((in & 3) != 3) {
        illegal();
    } else {
        switch (opcode) {
            case 0x37: wr = true; val = imm_u(in); break;                 // LUI
            case 0x17: wr = true; val = pc_ + imm_u(in); break;           // AUIPC
            case 0x6f: wr = true; val = pc_ + 4; jump(pc_ + imm_j(in)); break;  // JAL
            case 0x67:                                                       // JALR
                if (f3 != 0) { illegal(); break; }
                wr = true; val = pc_ + 4; jump((a + imm_i(in)) & ~1u);
                break;
            case 0x63: {                                                     // branches
                bool t;
                switch (f3) {
                    case 0: t = a == b; break;
                    case 1: t = a != b; break;
                    case 4: t = int32_t(a) < int32_t(b); break;
                    case 5: t = int32_t(a) >= int32_t(b); break;
                    case 6: t = a < b; break;
                    case 7: t = a >= b; break;
                    default: illegal(); t = false;
                }
                if (r.trap == TRAP_NONE && t) jump(pc_ + imm_b(in));
                break;
            }
            case 0x03: {                                                     // loads
                const uint32_t addr = a + imm_i(in);
                r.mem_addr = addr;
                const uint32_t size = f3 & 3;
                if (f3 == 3 || f3 >= 6) { illegal(); break; }
                if ((size == 1 && (addr & 1)) || (size == 2 && (addr & 3))) { r.trap = TRAP_MISALIGNED; break; }
                bool ok;
                uint32_t w = load_word(addr & ~3u, &ok);
                const uint32_t sh = (addr & 3) * 8;
                switch (f3) {
                    case 0: val = uint32_t(sext((w >> sh) & 0xff, 8)); break;
                    case 1: val = uint32_t(sext((w >> sh) & 0xffff, 16)); break;
                    case 2: val = w; break;
                    case 4: val = (w >> sh) & 0xff; break;
                    case 5: val = (w >> sh) & 0xffff; break;
                }
                if ((addr & 0xffffff00u) == kMmioBase && mmio_load_result) val = *mmio_load_result;
                r.mem_re = true;
                wr = true;
                break;
            }
            case 0x23: {                                                     // stores
                const uint32_t addr = a + imm_s(in);
                r.mem_addr = addr;
                if (f3 > 2) { illegal(); break; }
                if ((f3 == 1 && (addr & 1)) || (f3 == 2 && (addr & 3))) { r.trap = TRAP_MISALIGNED; break; }
                uint8_t strb;
                uint32_t data;
                if (f3 == 0) { strb = uint8_t(1u << (addr & 3)); data = (b & 0xff) * 0x01010101u; }
                else if (f3 == 1) { strb = (addr & 2) ? 0xc : 0x3; data = (b & 0xffff) * 0x00010001u; }
                else { strb = 0xf; data = b; }
                r.mem_wstrb = strb;
                r.mem_wdata = data;
                store(addr & ~3u, strb, data);
                break;
            }
            case 0x13: {                                                     // OP-IMM
                const uint32_t imm = imm_i(in), sh = (in >> 20) & 0x1f;
                wr = true;
                switch (f3) {
                    case 0: val = a + imm; break;
                    case 1: if (f7) illegal(); val = a << sh; break;
                    case 2: val = int32_t(a) < int32_t(imm); break;
                    case 3: val = a < imm; break;
                    case 4: val = a ^ imm; break;
                    case 5:
                        if (f7 == 0) val = a >> sh;
                        else if (f7 == 0x20) val = uint32_t(int32_t(a) >> sh);
                        else illegal();
                        break;
                    case 6: val = a | imm; break;
                    case 7: val = a & imm; break;
                }
                break;
            }
            case 0x33: {                                                     // OP
                wr = true;
                const bool alt = f7 == 0x20;
                if (f7 != 0 && !(alt && (f3 == 0 || f3 == 5))) { illegal(); break; }
                switch (f3) {
                    case 0: val = alt ? a - b : a + b; break;
                    case 1: val = a << (b & 31); break;
                    case 2: val = int32_t(a) < int32_t(b); break;
                    case 3: val = a < b; break;
                    case 4: val = a ^ b; break;
                    case 5: val = alt ? uint32_t(int32_t(a) >> (b & 31)) : a >> (b & 31); break;
                    case 6: val = a | b; break;
                    case 7: val = a & b; break;
                }
                break;
            }
            case 0x0f:                                                       // FENCE
                if (f3 != 0) illegal();
                break;
            case 0x73:                                                       // ECALL / EBREAK
                if (in == 0x00000073 || in == 0x00100073) r.trap = TRAP_ECALL;
                else illegal();
                break;
            default:
                illegal();
        }
    }

    if (r.trap != TRAP_NONE) {
        // A trapping instruction has no side effects; the core halts.
        r.mem_re = false;
        r.mem_wstrb = 0;
        halted_ = true;
        return r;
    }
    if (wr && rd != 0) {
        x_[rd] = val;
        r.rd = uint8_t(rd);
        r.rd_wdata = val;
    }
    pc_ = next;
    return r;
}

}  // namespace rv
