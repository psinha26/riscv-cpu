#!/usr/bin/env python3
"""Run the rv32ui compliance tests on both cores and print a pass/fail table.

  run_tests.py --build build add addi ... [--cores pipe,single]

Each test runs with the golden model checking every retired instruction. Exit status is
non-zero if any test fails on any core.
"""
import argparse
import subprocess
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--build", default="build")
    ap.add_argument("--cores", default="single,pipe")
    ap.add_argument("--dir", default="tests", help="subdirectory of --build holding the test images")
    ap.add_argument("tests", nargs="+")
    a = ap.parse_args()
    cores = a.cores.split(",")

    failures = 0
    results = {c: {} for c in cores}
    for core in cores:
        for t in a.tests:
            hexbase = f"{a.build}/{a.dir}/{t}"
            r = subprocess.run([f"{a.build}/{core}/Vsoc", "--imem", f"{hexbase}.imem.hex", "--dmem",
                                f"{hexbase}.dmem.hex", "--mode", "test", "--quiet", "--max-cycles", "100000"],
                               capture_output=True, text=True)
            ok = r.returncode == 0
            results[core][t] = ok
            if not ok:
                failures += 1
                print(f"FAIL {core:6} {t}\n{r.stderr.strip()}\n")

    width = max(len(t) for t in a.tests)
    print(f"{'test':{width}}  " + "  ".join(f"{c:6}" for c in cores))
    for t in a.tests:
        print(f"{t:{width}}  " + "  ".join(f"{'pass' if results[c][t] else 'FAIL':6}" for c in cores))
    for c in cores:
        n = sum(results[c].values())
        print(f"{c}: {n}/{len(a.tests)} {'rv32ui' if a.dir == 'tests' else a.dir} tests pass (golden-model checked)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
