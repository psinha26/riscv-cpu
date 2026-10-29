#!/usr/bin/env python3
"""Branch-predictor design space: CPI and area for several BTB sizes.

Builds a pipelined simulator per BTB size, runs every benchmark (no golden check, for speed;
the sizes used in `make test` are checked), and optionally synthesizes each size for area and
clock. Writes docs/results/btb_sweep.json.

  python3 scripts/btb_sweep.py [--sizes 0,8,16,32,64] [--lib sky130_fd_sc_hd__tt_025C_1v80.lib]
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
PROGRAMS = ["coremark", "sort", "matmul", "crc32"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sizes", default="0,8,16,32,64")
    ap.add_argument("--jalr", type=int, default=1, help="1: also predict JALR targets")
    ap.add_argument("--lib", help="liberty file: also synthesize each size for area and clock")
    a = ap.parse_args()
    out = {}
    stats = ROOT / "build" / "sweep_stats.json"
    for n in map(int, a.sizes.split(",")):
        bdir = f"build/sweep_bp{n}_j{a.jalr}"
        subprocess.run(["make", "-s", "-C", str(ROOT), f"{bdir}/pipe_bp/Vsoc", f"BUILD={bdir}", f"BP_ENTRIES={n}", f"BP_JALR={a.jalr}"],
                       check=True, capture_output=True)
        row = {}
        for p in PROGRAMS:
            base = ROOT / "build" / "programs" / p
            subprocess.run([str(ROOT / bdir / "pipe_bp" / "Vsoc"), "--imem", f"{base}.imem.hex", "--dmem",
                            f"{base}.dmem.hex", "--quiet", "--no-check", "--max-cycles", "200000000",
                            "--stats-json", str(stats)], check=True, capture_output=True)
            s = json.loads(stats.read_text())
            row[p] = {"cpi": s["cycles"] / s["instret"],
                      "accuracy": (s["branches"] - s["flushes"]) / s["branches"] if s["branches"] else 0}
        if a.lib:
            import synth_estimate
            r = synth_estimate.synth("core_pipe", a.lib, 1000, bp_entries=n, bp_jalr=a.jalr)
            row["area_mm2"] = r["area_um2"] / 1e6
            row["delay_ns"] = r["abc_delay_ps"] / 1000
        out[n] = row
        cm = row["coremark"]
        extra = f"  area {row['area_mm2']:.3f} mm^2  clock {row['delay_ns']:.2f} ns" if a.lib else ""
        print(f"BTB {n:3} entries: CoreMark CPI {cm['cpi']:.3f} (prediction {100 * cm['accuracy']:.1f}%)  " +
              "  ".join(f"{p} {row[p]['cpi']:.3f}" for p in PROGRAMS[1:]) + extra, flush=True)
    path = ROOT / "docs/results/btb_sweep.json"
    data = json.loads(path.read_text()) if path.exists() else {}
    data[f"jalr={a.jalr}"] = out
    path.write_text(json.dumps(data, indent=2))


if __name__ == "__main__":
    main()
