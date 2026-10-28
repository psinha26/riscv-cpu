// RV32I instruction-set simulator: the golden model.
//
// Executes one instruction per step() and reports exactly what retired (pc, register write,
// memory access, trap), in the same form as the RTL's rvfi_* trace, so the Verilator testbench
// can compare the two instruction by instruction. Written independently of the RTL: a plain
// switch over opcodes, no shared code or tables.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace rv {

constexpr uint32_t kImemBase = 0x00000000;
constexpr uint32_t kDmemBase = 0x10000000;
constexpr uint32_t kMmioBase = 0x20000000;

enum Trap : uint8_t { TRAP_NONE = 0, TRAP_ECALL = 1, TRAP_ILLEGAL = 2, TRAP_MISALIGNED = 3 };

struct Retire {
    uint32_t pc = 0, insn = 0;
    uint8_t trap = TRAP_NONE;
    uint8_t rd = 0;          // 0 if no register was written
    uint32_t rd_wdata = 0;
    uint32_t mem_addr = 0;
    bool mem_re = false;
    uint8_t mem_wstrb = 0;   // byte enables of a store, 0 if none
    uint32_t mem_wdata = 0;  // lane-replicated store data, as on the bus
};

class Iss {
public:
    Iss(size_t imem_words, size_t dmem_words);

    // Load a $readmemh-style file (one 32-bit hex word per line, optional @addr lines).
    void load_hex(const std::string& path, bool into_imem);

    // Execute one instruction. A load from the MMIO region can't be predicted (counters), so
    // the caller supplies the value the hardware observed via mmio_load_result.
    Retire step(const uint32_t* mmio_load_result = nullptr);

    bool halted() const { return halted_; }
    uint32_t pc() const { return pc_; }
    uint32_t reg(int i) const { return x_[i]; }

    // Side effects visible to a standalone run.
    std::string uart_out;

private:
    uint32_t load_word(uint32_t addr, bool* ok) const;
    void store(uint32_t addr, uint8_t strb, uint32_t data);

    uint32_t x_[32] = {};
    uint32_t pc_ = kImemBase;
    bool halted_ = false;
    std::vector<uint32_t> imem_, dmem_;
};

}  // namespace rv
