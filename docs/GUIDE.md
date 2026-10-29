# Guide: understanding, finishing and presenting the RISC-V CPU

The README is for recruiters; this is for you. Read it until you can explain every block and
every number without notes.

## 1. What's left to do

Everything is built and verified, and the timing and performance analysis is done. What
remains needs your Mac or your accounts.

### a. Put it on GitHub

The repo uses two git submodules (`third_party/riscv-tests`, `third_party/coremark`), already
included in the zip with full history.

```bash
cd ~/Parth/Projects/riscv-cpu
git status                      # should be clean
gh repo create riscv-cpu --public --source=. --push      # or create on github.com, then:
# git remote add origin https://github.com/psinha26/riscv-cpu.git && git push -u origin main
```

Then open the repo's **Actions** tab. CI installs Verilator and the RISC-V compiler on a fresh
Ubuntu machine and runs everything: unit tests, compliance, hazard, random, benchmarks and
mutation testing (~10 minutes).

### b. Run the chip layout (the one big remaining piece, ~1 hour mostly waiting)

LibreLane (the new name of OpenLane 2) needs Nix. I couldn't run it from my workspace, but it
officially supports macOS on Apple Silicon. Official steps:
https://librelane.readthedocs.io/en/latest/installation/nix_installation/installation_macos.html

```bash
# 1. Install Nix with LibreLane's binary cache (one time, ~5 min)
curl --proto '=https' --tlsv1.2 -fsSL https://artifacts.nixos.org/nix-installer | sh -s -- install --no-confirm --extra-conf "
    extra-substituters = https://nix-cache.fossi-foundation.org
    extra-trusted-public-keys = nix-cache.fossi-foundation.org:3+K59iFwXqKsL7BNu6Guy0v+uTlwsxYQxjspXzqLYQs=
    extra-experimental-features = nix-command flakes
"
# open a new terminal, then:
git clone https://github.com/librelane/librelane ~/librelane
cd ~/librelane && git checkout 3.0.17 && nix-shell     # first time downloads the tools (~10 min)

# 2. Inside the nix-shell:
cd ~/Parth/Projects/riscv-cpu
python3 scripts/flow.py run                       # final design at 10 ns (100 MHz)
python3 scripts/flow.py run --variant baseline    # the "before" (ripple adders)
python3 scripts/flow.py layout                    # opens KLayout: screenshot -> docs/layout.png
```

Each run prints worst slack, achieved clock (`fmax_mhz_typical`), cell count, area and power,
and saves `docs/results/flow_final.json` / `flow_baseline.json`. Then:

1. If the final design has positive slack at 10 ns, try a tighter clock:
   `python3 scripts/flow.py run --period 7`. Keep the fastest period that still closes (slack ≥ 0).
2. Put the numbers in the README's headline table and the Chip layout section (replace
   "pre-layout" with the post-layout figures; keep the pre-layout ladder as the analysis).
3. Add the screenshot: `![Chip layout](docs/layout.png)` where the README comment says.
4. Open the STA report (`flow.py report` prints its path) and read the critical path. You'll
   be asked about it.

If the flow fails, the run directory has numbered step folders with logs. Paste the last error
into a chat and I can help.

### c. Record the demo GIF

`docs/demo.cast` is a real recording of the CPU printing hello world and CoreMark over the
simulated UART, then passing the test suite. Convert it:

```bash
brew install agg
agg docs/demo.cast docs/demo.gif --font-size 14
```

and replace the comment at the top of the README with `![demo](docs/demo.gif)`.

### d. (Optional) Run the simulation on your Mac

```bash
brew install verilator
brew tap riscv-software-src/riscv && brew install riscv-gnu-toolchain   # large, ~30 min
make test RISCV_PREFIX=riscv64-unknown-elf-
```

## 2. Reading order

1. `rtl/rv32i_defs.svh`, `rtl/decoder.sv`, `rtl/imm_gen.sv`: how 32 bits become control signals.
2. `rtl/core_single.sv`: the whole ISA in one cycle. If you understand this file, you
   understand RV32I.
3. `rtl/core_pipe.sv` top to bottom, one stage at a time, with `rtl/hazard_unit.sv` open next to it.
4. `rtl/branch_predictor.sv`, then the "Check the prediction" block in EX of `core_pipe.sv`.
5. `rtl/prefix_adder.sv`: draw the Kogge-Stone tree for 8 bits on paper.
6. `sim/iss.cpp` (the golden model) and `tb/tb_soc.cpp` (lockstep checking).
7. `sw/common/crt0.S`, `sw/common/link.ld`, `sw/common/lib.c`: how C runs with no OS.
8. `scripts/mutation_test.py` and `scripts/random_test.py`.

## 3. Concepts you must be able to explain

**Why pipeline at all.** A single-cycle CPU's clock must fit fetch + decode + execute + memory +
writeback. Pipelining overlaps instructions so the clock only fits the slowest stage. The cost
is hazards: an instruction can need a result that isn't written yet (data hazard), or the next
PC isn't known yet (control hazard).

**Forwarding.** In `add x1,..; sub x2,x1,..` the `add` result exists at the end of its EX stage,
but would only reach the register file two cycles later. Forwarding muxes in front of the ALU
take it straight from the EX/MEM register (distance 1) or MEM/WB (distance 2). Distance 3 is
covered by the register file writing before it reads.

**Load-use stall.** A load's data exists only at the end of MEM. The instruction right behind
it is already in EX by then, so it must wait one cycle: freeze PC and IF/ID, insert a bubble.

**Branch prediction.** Branches resolve in EX, two stages after fetch. Guessing "not taken" is
free but wrong for every loop back-edge, costing 2 cycles each: 28% of all CoreMark cycles. The
BTB remembers, per branch PC, the target and a 2-bit confidence counter, so IF can fetch the
predicted target immediately. EX checks every prediction; a wrong one costs the same 2 cycles
as before. A 2-bit counter needs two wrong guesses in a row to flip, so a loop exit doesn't
untrain a loop branch.

**Kogge-Stone adder.** Carry into bit i depends on all lower bits. Ripple: compute carries one
bit at a time (32 gate delays). Prefix: each bit summarizes a group as (generate, propagate),
and groups combine pairwise (1, 2, 4, 8, 16 bits) in log₂32 = 5 levels. More gates, far shorter
path. It took the critical path from 10.3 to 6.4 ns.

**Golden-model (lockstep) verification.** Run the RTL and an independent ISA simulator side by
side; every time the RTL retires an instruction, the simulator executes one, and PC, register
write and memory access must match. A bug shows up at the exact instruction where it happens,
not thousands of cycles later as a wrong final answer.

**Mutation testing.** Inject a realistic bug, rerun the tests: if nothing fails, the tests
have a hole. It's how you know the verification is good, not just green.

## 4. The real stories (for "tell me about a hard bug / tough problem")

All of these happened while building this, with numbers.

1. **The pipeline that lost to single-cycle.** The 5-stage pipeline clocks 1.22× faster than
   the single-cycle core (6.10 vs 7.42 ns estimated), but its CoreMark CPI is 1.43, so with
   ideal memories it is ~15% *slower*. The hardware counters showed why: 28% of cycles were
   branch flushes. That data drove the branch predictor (CPI 1.43 → 1.19, now on par with
   ideal memories), and the analysis showing the pipeline's real advantage appears once memory
   access time is counted (1.55× faster with 2 ns memory).
2. **Timing numbers I couldn't trust.** The single-cycle core's estimated critical path changed
   from 9.75 to 8.74 ns with no logic change. Two causes: ABC was mapping for *area* once a loose
   10 ns target was met, so the delay it reported was arbitrary; and Yosys had re-encoded a
   pipeline register as an FSM, changing the logic around it. Fix: delay-driven mapping with an
   unreachable target, `-nofsm`, and rebuilding every design point from the same RTL under
   identical settings. Lesson: validate a measurement before optimizing against it.
3. **The official tests have a hole.** All 40 rv32ui tests passed with a JALR that didn't clear
   bit 0 of the target. Mutation testing found it; a directed test closed it.
4. **A predictor bug no test could see.** "Never check the predicted target" survived every
   test, because with tags it only matters when two taken branches 16 KB apart share a BTB
   entry. I wrote `btb_alias.S`, which places two branches exactly 16 KB apart; now the bug is
   caught. A different mutation, "no tag check", *correctly* survives: it only causes extra
   mispredictions, which the pipeline recovers from. Performance bug, not correctness bug.
5. **The branch predictor lengthened the critical path.** It added a 32-bit "is the predicted
   target right?" compare after the adder in EX. For branches and JAL the target is just
   pc + imm, so I moved that add and compare into ID and register a 1-bit result. For JALR the
   target depends on a register, so I stopped predicting JALR: 1% CPI cost, compare gone.

## 5. Interview questions to rehearse

- Walk me through `lw x1, 0(x2); add x3, x1, x1` cycle by cycle in your pipeline.
- Which forwarding paths exist and why isn't there one from MEM for loads?
- Why resolve branches in EX and not ID? What would moving it to ID cost? (a compare in ID
  needs forwarded operands too, so the path gets longer)
- How does your BTB know a prediction was wrong, and what happens then?
- Why a 2-bit counter rather than 1-bit?
- What's on your critical path now, and what would you do next? (forwarding mux → ALU/compare
  → redirect → PC mux; next: split EX, or a faster mux structure)
- Single-cycle vs pipelined: is pipelining always faster? (no; see the memory-time table)
- How do you know your golden model is right? (it passes the official tests on its own, and
  it's written independently of the RTL)
- How do you know your tests are good? (mutation testing: 19/19 injected bugs caught)
- What would you need to run Linux on it? (M, A, Zicsr, privileged modes, MMU, interrupts)

## 6. Resume bullets

Pre-layout numbers below; swap in the post-layout clock/area after running the flow.

- Designed a 5-stage pipelined RV32I CPU in SystemVerilog with full forwarding, load-use stalls
  and a 16-entry BTB branch predictor; passes all 40 official rv32ui compliance tests and runs
  GCC-compiled C and CoreMark (1.12 CoreMark/MHz) over a simulated UART
- Built lockstep verification against a self-written C++ ISA golden model, plus directed hazard,
  random-program and mutation testing (19/19 injected bugs caught); found and closed two gaps
  in the official test suite
- Cut the critical path 1.7× (10.3 → 6.1 ns, Sky130) with Kogge-Stone adders and registered
  forwarding, and cut CoreMark CPI 1.43 → 1.19 with branch prediction; taken through the
  open-source LibreLane flow to a GDSII layout

## 7. Chip layout notes

- `rtl/synth/chip_top.sv` is what gets laid out: the pipelined core with 16-entry BTB. Memories
  are external ports (an SRAM macro would sit there), and the simulation-only retirement trace
  is left unconnected so it synthesizes away.
- The register file is 992 flip-flops, the BTB another ~700. In a real chip both would be SRAM
  or latch arrays; flip-flops keep the flow simple.
- I/O timing uses LibreLane's default I/O delay constraint (a fixed fraction of the clock period
  for each port), standing in for the memory's timing.
