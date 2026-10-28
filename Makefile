# RV32I CPU: simulation, tests and software.
#
#   make              build both simulators (pipelined and single-cycle)
#   make test         run the rv32ui compliance suite on both cores (golden-model checked)
#   make run PROG=hello CORE=pipe   build and run sw/programs/hello on a core
#   make unit         RTL unit tests (ALU, register file, immediate generator, hazard unit)

RISCV_PREFIX ?= riscv64-unknown-elf-
CC      := $(RISCV_PREFIX)gcc
OBJDUMP := $(RISCV_PREFIX)objdump
ARCH    := -march=rv32i -mabi=ilp32
BUILD   := build

RTL := rtl/prefix_adder.sv rtl/branch_predictor.sv rtl/alu.sv rtl/imm_gen.sv rtl/branch_unit.sv rtl/regfile.sv rtl/lsu.sv \
       rtl/decoder.sv rtl/hazard_unit.sv rtl/core_single.sv rtl/core_pipe.sv rtl/soc.sv
TB  := tb/tb_soc.cpp sim/iss.cpp

VERILATOR       ?= verilator
VERILATOR_FLAGS := --cc --exe --build -j 0 -O3 --x-assign fast --x-initial fast --trace \
                   -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Irtl --top-module soc -CFLAGS "-O2 -I$(CURDIR)/sim"

.PHONY: all sims test run unit clean
.PRECIOUS: $(BUILD)/%.elf $(BUILD)/tests/%.elf $(BUILD)/hazards/%.elf $(BUILD)/programs/%.elf
all: sims
# Three simulators: single-cycle, pipelined with static not-taken prediction, pipelined + BTB.
BP_ENTRIES ?= 64
sims: $(BUILD)/pipe/Vsoc $(BUILD)/single/Vsoc $(BUILD)/pipe_bp/Vsoc $(BUILD)/rv32sim

# Standalone golden model (also validated on its own against the riscv-tests).
$(BUILD)/rv32sim: sim/rv32sim.cpp sim/iss.cpp sim/iss.h
	@mkdir -p $(BUILD)
	$(CXX) -O2 -std=c++17 -Wall -Wextra -o $@ sim/rv32sim.cpp sim/iss.cpp

$(BUILD)/pipe/Vsoc: $(RTL) rtl/rv32i_defs.svh $(TB)
	@mkdir -p $(BUILD)/pipe
	$(VERILATOR) $(VERILATOR_FLAGS) -GPIPELINED=1 --Mdir $(BUILD)/pipe $(RTL) $(abspath $(TB)) >/dev/null

$(BUILD)/pipe_bp/Vsoc: $(RTL) rtl/rv32i_defs.svh $(TB)
	@mkdir -p $(BUILD)/pipe_bp
	$(VERILATOR) $(VERILATOR_FLAGS) -GPIPELINED=1 -GBP_ENTRIES=$(BP_ENTRIES) --Mdir $(BUILD)/pipe_bp $(RTL) $(abspath $(TB)) >/dev/null

$(BUILD)/single/Vsoc: $(RTL) rtl/rv32i_defs.svh $(TB)
	@mkdir -p $(BUILD)/single
	$(VERILATOR) $(VERILATOR_FLAGS) -GPIPELINED=0 --Mdir $(BUILD)/single $(RTL) $(abspath $(TB)) >/dev/null

# ---- rv32ui compliance tests ----
# fence_i needs self-modifying code (impossible with separate instruction ROM) and ma_data
# needs a trap handler (CSRs are out of scope); every other rv32ui test is run.
RV_TEST_DIR := third_party/riscv-tests/isa/rv32ui
RV_TESTS    := $(filter-out fence_i ma_data,$(basename $(notdir $(wildcard $(RV_TEST_DIR)/*.S))))
TEST_HEX    := $(addprefix $(BUILD)/tests/,$(addsuffix .imem.hex,$(RV_TESTS)))

$(BUILD)/tests/%.elf: $(RV_TEST_DIR)/%.S sw/tests/env/riscv_test.h sw/common/link.ld
	@mkdir -p $(dir $@)
	$(CC) $(ARCH) -static -nostdlib -nostartfiles -T sw/common/link.ld \
	  -I sw/tests/env -I third_party/riscv-tests/isa/macros/scalar $< -o $@

$(BUILD)/%.imem.hex: $(BUILD)/%.elf scripts/elf2hex.py
	python3 scripts/elf2hex.py $< $(BUILD)/$*
	$(OBJDUMP) -d $< > $(BUILD)/$*.dis

test: sims $(TEST_HEX) hazards
	python3 scripts/run_tests.py --build $(BUILD) --cores single,pipe,pipe_bp $(RV_TESTS)

# ---- directed hazard tests (same protocol as rv32ui) ----
HAZARD_TESTS := $(basename $(notdir $(wildcard sw/tests/hazards/*.S)))
HAZARD_HEX   := $(addprefix $(BUILD)/hazards/,$(addsuffix .imem.hex,$(HAZARD_TESTS)))

$(BUILD)/hazards/%.elf: sw/tests/hazards/%.S sw/tests/env/riscv_test.h sw/common/link.ld
	@mkdir -p $(dir $@)
	$(CC) $(ARCH) -static -nostdlib -nostartfiles -T sw/common/link.ld -I sw/tests/env $< -o $@

.PHONY: hazards
hazards: sims $(HAZARD_HEX)
	python3 scripts/run_tests.py --build $(BUILD) --cores single,pipe,pipe_bp --dir hazards $(HAZARD_TESTS)

# ---- C programs ----
PROG ?= hello
CORE ?= pipe
CFLAGS_SW := $(ARCH) -O2 -ffreestanding -fno-builtin -nostdlib -nostartfiles -static -Wall \
             -T sw/common/link.ld -I sw/common
SW_COMMON := sw/common/crt0.S sw/common/lib.c

$(BUILD)/programs/%.elf: sw/programs/%.c $(SW_COMMON) sw/common/lib.h sw/common/link.ld
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_SW) $(SW_COMMON) $< -o $@ -lgcc

# CoreMark: upstream sources untouched (third_party/coremark), port in sw/coremark.
CM_ITERATIONS ?= 10
CM_SRC := $(addprefix third_party/coremark/,core_list_join.c core_main.c core_matrix.c core_state.c core_util.c) \
          sw/coremark/core_portme.c
$(BUILD)/programs/coremark.elf: $(CM_SRC) sw/coremark/core_portme.h $(SW_COMMON) sw/common/lib.h sw/common/link.ld
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_SW) -I sw/coremark -I third_party/coremark -DPERFORMANCE_RUN=1 -DITERATIONS=$(CM_ITERATIONS) \
	  -DCOMPILER_FLAGS='"-O2 -march=rv32i -mabi=ilp32"' $(SW_COMMON) $(CM_SRC) -o $@ -lgcc

run: $(BUILD)/$(CORE)/Vsoc $(BUILD)/programs/$(PROG).imem.hex
	$(BUILD)/$(CORE)/Vsoc --imem $(BUILD)/programs/$(PROG).imem.hex --dmem $(BUILD)/programs/$(PROG).dmem.hex

UNIT_RTL := rtl/prefix_adder.sv rtl/branch_predictor.sv rtl/alu.sv rtl/imm_gen.sv rtl/branch_unit.sv rtl/regfile.sv rtl/hazard_unit.sv \
            tb/unit/unit_top.sv

$(BUILD)/unit/Vunit_top: $(UNIT_RTL) tb/unit/unit_tests.cpp
	@mkdir -p $(BUILD)/unit
	$(VERILATOR) --cc --exe --build -j 0 -O2 -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Irtl --top-module unit_top \
	  --Mdir $(BUILD)/unit $(UNIT_RTL) $(abspath tb/unit/unit_tests.cpp) >/dev/null

unit: $(BUILD)/unit/Vunit_top
	$(BUILD)/unit/Vunit_top

clean:
	rm -rf $(BUILD)
