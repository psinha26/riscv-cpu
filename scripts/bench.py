#!/usr/bin/env python3
"""Run the benchmarks on every core and tabulate CPI, hazard losses and branch prediction.

  python3 scripts/bench.py [--out docs/results/bench.json]

Each run is golden-model checked. Cycle counts come from the SoC's hardware counters for the
whole program (startup included). If docs/results/synth_estimates.json exists, the table also
converts cycles to time using each core's estimated clock, which is what actually matters:
a pipeline wins only if its higher clock outweighs its higher CPI.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PROGRAMS = ["coremark", "sort", "matmul", "crc32"]
CORES = [("single", "single-cycle"), ("pipe", "5-stage, predict not-taken"), ("pipe_bp", "5-stage + 16-entry BTB")]
SYNTH_TOP = {"single": "core_single", "pipe": "core_pipe", "pipe_bp": "core_pipe_bp"}


def run(core, prog, stats):
    base = ROOT / "build" / "programs" / prog
    r = subprocess.run([str(ROOT / "build" / core / "Vsoc"), "--imem", f"{base}.imem.hex", "--dmem",
                        f"{base}.dmem.hex", "--quiet", "--stats-json", str(stats), "--max-cycles", "200000000"],
                       capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"{prog} failed on {core}:\n{r.stderr}")
    return json.loads(stats.read_text())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "docs/results/bench.json"))
    a = ap.parse_args()
    for p in PROGRAMS:
        subprocess.run(["make", "-s", "-C", str(ROOT), f"build/programs/{p}.imem.hex"], check=True,
                       capture_output=True)

    synth = {}
    sp = ROOT / "docs/results/synth_estimates.json"
    if sp.exists():
        data = json.loads(sp.read_text())
        latest = data[sorted(data)[-1]]
        synth = {c: latest[t]["abc_delay_ps"] for c, t in SYNTH_TOP.items() if t in latest}

    results = {}
    tmp = ROOT / "build" / "bench_stats.json"
    for prog in PROGRAMS:
        results[prog] = {core: run(core, prog, tmp) for core, _ in CORES}
    Path(a.out).parent.mkdir(parents=True, exist_ok=True)
    Path(a.out).write_text(json.dumps({"results": results, "clock_ps": synth}, indent=2))

    print(f"{'program':9} {'core':28} {'cycles':>11} {'CPI':>6} {'load-use':>9} {'flush':>7} {'predict':>8} "
          f"{'time @ est. clock':>18}")
    for prog in PROGRAMS:
        for core, label in CORES:
            s = results[prog][core]
            cyc, ins = s["cycles"], s["instret"]
            stall = 100 * s["stall_cycles"] / cyc
            flush = 200 * s["flushes"] / cyc
            pred = 100 * (s["branches"] - s["flushes"]) / s["branches"] if s["branches"] else 0
            t = f"{cyc * synth[core] / 1e6:10.0f} us" if core in synth else ""
            print(f"{prog:9} {label:28} {cyc:11,} {cyc / ins:6.3f} {stall:8.1f}% {flush:6.1f}% "
                  f"{pred if core != 'single' else 0:7.1f}% {t:>18}")
        print()


if __name__ == "__main__":
    main()
