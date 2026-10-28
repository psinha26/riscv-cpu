#!/usr/bin/env python3
"""Random instruction testing: generate random valid RV32I programs and run each on both cores
with the golden model checking every retired instruction.

Programs are built to stress the pipeline, not just the ISA: sources are biased toward
registers written in the last few instructions (so forwarding paths and load-use stalls fire
constantly), loads and stores hit a shared buffer (store-to-load dependencies), and short
forward branches and jumps are mixed in (flushes, including back-to-back ones).

  python3 scripts/random_test.py [--count 200] [--length 400] [--seed 1]
"""
import argparse
import random
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CC = "riscv64-unknown-elf-gcc"

BASE = "s0"  # x8 points at the data buffer and is never overwritten
LOOP = "s1"  # x9 is the loop counter of counted loops, never a random destination
DESTS = ["zero", "ra", "t0", "t1", "t2", "a0", "a1", "a2", "a3", "a4", "a5"]
SRCS = DESTS[1:] + ["zero", BASE]
R_OPS = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and"]
I_OPS = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SH_OPS = ["slli", "srli", "srai"]
BRANCHES = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOADS = [("lb", 1), ("lh", 2), ("lw", 4), ("lbu", 1), ("lhu", 2)]
STORES = [("sb", 1), ("sh", 2), ("sw", 4)]
BUF = 256


def gen_program(rng: random.Random, length: int) -> str:
    recent = ["t0"]
    lines = []
    label = 0

    def src():
        # 70% of the time read something written in the last 3 instructions
        if recent and rng.random() < 0.7:
            return rng.choice(recent[-3:])
        return rng.choice(SRCS)

    def dst():
        d = rng.choice(DESTS)
        if d != "zero":
            recent.append(d)
        return d

    # seed registers with random values
    for r in DESTS[1:]:
        lines.append(f"  li {r}, {rng.randint(-2**31, 2**31 - 1)}")
    lines.append(f"  la {BASE}, buf")

    pending = []  # labels to place a few instructions later (forward branch targets)
    loop_end = None  # (instruction index, label) closing the counted loop we're in
    i = 0
    while i < length:
        if loop_end and loop_end[0] <= i:
            lines += [f"  addi {LOOP}, {LOOP}, -1", f"  bnez {LOOP}, {loop_end[1]}"]
            loop_end = None
        # Counted loops: backward branches taken several times, then not taken, so the branch
        # predictor trains, predicts correctly, and mispredicts on exit. Forward branches
        # inside never jump past the loop end (their targets are placed within 4 instructions,
        # and the loop is closed only after pending labels inside it are emitted).
        if loop_end is None and not pending and rng.random() < 0.04:
            label += 1
            name = f"LOOP{label}"
            lines += [f"  li {LOOP}, {rng.randint(2, 6)}", f"{name}:"]
            loop_end = (i + rng.randint(4, 12), name)
        for p in [p for p in pending if p[0] <= i]:
            lines.append(f"{p[1]}:")
            pending.remove(p)
        if loop_end and pending and loop_end[0] <= i + 1:
            loop_end = (max(p[0] for p in pending) + 1, loop_end[1])  # keep targets inside
        k = rng.random()
        if k < 0.30:
            lines.append(f"  {rng.choice(R_OPS)} {dst()}, {src()}, {src()}")
        elif k < 0.48:
            lines.append(f"  {rng.choice(I_OPS)} {dst()}, {src()}, {rng.randint(-2048, 2047)}")
        elif k < 0.55:
            lines.append(f"  {rng.choice(SH_OPS)} {dst()}, {src()}, {rng.randint(0, 31)}")
        elif k < 0.58:
            lines.append(f"  {rng.choice(['lui', 'auipc'])} {dst()}, {rng.randint(0, 0xfffff)}")
        elif k < 0.70:
            op, size = rng.choice(LOADS)
            lines.append(f"  {op} {dst()}, {rng.randrange(0, BUF, size)}({BASE})")
        elif k < 0.80:
            op, size = rng.choice(STORES)
            lines.append(f"  {op} {src()}, {rng.randrange(0, BUF, size)}({BASE})")
        elif k < 0.92:
            label += 1
            name = f"L{label}"
            lines.append(f"  {rng.choice(BRANCHES)} {src()}, {src()}, {name}")
            pending.append((i + rng.randint(1, 4), name))
        elif k < 0.96:
            label += 1
            name = f"L{label}"
            lines.append(f"  jal {dst()}, {name}")
            pending.append((i + rng.randint(1, 3), name))
        else:
            # JALR through a just-computed address, sometimes with bit 0 set (must be ignored)
            label += 1
            name = f"L{label}"
            tmp = rng.choice(["t1", "t2", "a5"])
            lines.append(f"  la {tmp}, {name}")
            lines.append(f"  jalr {dst()}, {rng.choice([0, 1])}({tmp})")
            pending.append((i + rng.randint(1, 3), name))
        i += 1
    for _, name in pending:
        lines.append(f"{name}:")
    if loop_end:
        lines += [f"  addi {LOOP}, {LOOP}, -1", f"  bnez {LOOP}, {loop_end[1]}"]
    lines += ["  li a0, 0", "  ecall"]

    data = [f"  .word {rng.getrandbits(32)}" for _ in range(BUF // 4)]
    return ("  .section .text.init\n  .globl _start\n_start:\n" + "\n".join(lines) +
            "\n\n  .data\n  .align 4\nbuf:\n" + "\n".join(data) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=200)
    ap.add_argument("--length", type=int, default=400)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--cores", default="pipe_bp,pipe,single")
    ap.add_argument("--keep", help="directory to keep the generated programs in")
    a = ap.parse_args()

    total_insns = 0
    with tempfile.TemporaryDirectory() as td:
        out = Path(a.keep) if a.keep else Path(td)
        out.mkdir(parents=True, exist_ok=True)
        for n in range(a.count):
            seed = a.seed * 100000 + n
            src = out / f"rand_{seed}.S"
            src.write_text(gen_program(random.Random(seed), a.length))
            elf = out / f"rand_{seed}.elf"
            subprocess.run([CC, "-march=rv32i", "-mabi=ilp32", "-static", "-nostdlib", "-nostartfiles",
                            "-T", str(ROOT / "sw/common/link.ld"), str(src), "-o", str(elf)], check=True)
            subprocess.run([sys.executable, str(ROOT / "scripts/elf2hex.py"), str(elf), str(out / f"rand_{seed}")],
                           check=True)
            for core in a.cores.split(","):
                r = subprocess.run([str(ROOT / f"build/{core}/Vsoc"), "--imem", str(out / f"rand_{seed}.imem.hex"),
                                    "--dmem", str(out / f"rand_{seed}.dmem.hex"), "--quiet", "--stats-json",
                                    str(out / "stats.json"), "--max-cycles", "100000"],
                                   capture_output=True, text=True)
                if r.returncode != 0:
                    keep = ROOT / "build" / "random_failures"
                    keep.mkdir(parents=True, exist_ok=True)
                    (keep / src.name).write_text(src.read_text())
                    print(f"FAIL seed {seed} on {core}: {r.stderr.strip()}\n  program saved to {keep / src.name}")
                    sys.exit(1)
                if core == a.cores.split(",")[0]:
                    import json
                    total_insns += json.loads((out / "stats.json").read_text())["instret"]
            if (n + 1) % 50 == 0:
                print(f"  {n + 1}/{a.count} programs pass")
    print(f"{a.count} random programs, {total_insns:,} instructions retired on each core, "
          f"all matching the golden model")


if __name__ == "__main__":
    main()
