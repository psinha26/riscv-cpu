#!/usr/bin/env python3
"""Pre-layout estimate: synthesize a core to SkyWater 130nm standard cells with Yosys + ABC.

Reports cell count, cell area and the critical (register-to-register) path delay that ABC
computes from the Sky130 HD liberty timing tables, plus the longest path in cells (Yosys ltp)
so you can see *which* logic is critical. Wire delay, clock skew, setup time and placement are
not modelled, so the real post-layout clock (from LibreLane/OpenLane, see flow/) will be lower.

  python3 scripts/synth_estimate.py --lib sky130_fd_sc_hd__tt_025C_1v80.lib [--top core_pipe]
"""
import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RTL = ["prefix_adder.sv", "branch_predictor.sv", "alu.sv", "imm_gen.sv", "branch_unit.sv", "regfile.sv", "lsu.sv", "decoder.sv",
       "hazard_unit.sv", "core_single.sv", "core_pipe.sv", "synth/timing_wrap.sv"]
# Cells the OpenROAD/OpenLane flows don't use for sky130hd (too weak or for special purposes).
DONT_USE = ["*probe*", "*lpflow*", "*clkdly*", "*dlygate*", "*dlymetal*", "*_1"]


def synth(top: str, lib: str, period_ps: int, defines=()):
    # core_pipe / core_single are timed inside timing_wrap so paths through memory are closed.
    top_mod = "timing_wrap"
    params = (f"-chparam PIPELINED {0 if top == 'core_single' else 1} "
              f"-chparam BP_ENTRIES {64 if top == 'core_pipe_bp' else 0}")
    files = " ".join(str(ROOT / "rtl" / f) for f in RTL)
    # (Yosys 0.33 has no -dont_use for dfflibmap/abc; the real flow excludes these cells itself.)
    script = f"""
read_verilog -sv -I{ROOT / 'rtl'} {' '.join('-D' + d for d in defines)} {files}
hierarchy -check -top {top_mod} {params}
synth -flatten -top {top_mod}
dfflibmap -liberty {lib}
abc -D {period_ps} -liberty {lib} -script "+strash;&get,-n;&fraig,-x;&put;scorr;dc2;strash;&get,-n;&dch,-f;&nf,-D,{period_ps};&put;buffer,-p;upsize,-D,{period_ps};dnsize,-D,{period_ps};stime,-p"
opt_clean -purge
tee -o {{stat}} stat -liberty {lib}
"""
    with tempfile.TemporaryDirectory() as td:
        stat_file = Path(td) / "stat.txt"
        script = script.replace("{stat}", str(stat_file))
        (Path(td) / "s.ys").write_text(script)
        r = subprocess.run(["yosys", "-q", "-l", str(Path(td) / "log.txt"), "-s", str(Path(td) / "s.ys")],
                           capture_output=True, text=True)
        log = (Path(td) / "log.txt").read_text() if (Path(td) / "log.txt").exists() else ""
        if r.returncode != 0:
            sys.exit(r.stderr[-3000:] + log[-3000:])
        stat = stat_file.read_text()
    delays = [float(x) for x in re.findall(r"Delay\s*=\s*([\d.]+)\s*ps", log)]
    se = re.findall(r"Start-point = \S+ \((.*?)\)\.\s+End-point = \S+ \((.*?)\)", log)
    path_cells = re.findall(r"ABC: Path\s+\d+ --\s+\d+ : \d+\s+\d+ (\S+)", log)
    cells = int(re.search(r"Number of cells:\s+(\d+)", stat).group(1))
    area = float(re.search(r"Chip area for (?:top )?module.*?:\s+([\d.]+)", stat).group(1))
    flops = sum(int(n) for n in re.findall(r"sky130_fd_sc_hd__df\w+\s+(\d+)", stat))
    # The wrapper adds ~100 XOR gates of stand-in memory; negligible next to the core.
    return {"start": se[-1][0] if se else "?", "end": se[-1][1] if se else "?",
            "path_cells": [c for c in path_cells if c != "pi"],
            "cells": cells, "area_um2": area, "flops": flops, "abc_delay_ps": max(delays) if delays else None}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True)
    ap.add_argument("--top", default="core_single,core_pipe,core_pipe_bp")
    ap.add_argument("--period", type=int, default=10000, help="ABC target period in ps")
    ap.add_argument("--show-path", action="store_true")
    ap.add_argument("--json", help="append results to this JSON file under --label")
    ap.add_argument("--label", default="current")
    a = ap.parse_args()
    results = {}
    for top in a.top.split(","):
        r = synth(top, a.lib, a.period)
        results[top] = {k: v for k, v in r.items() if k != "path_cells"}
        d = r["abc_delay_ps"]
        print(f"{top:12} cells {r['cells']:6}  flops {r['flops']:5}  area {r['area_um2'] / 1e6:.4f} mm^2  "
              f"critical path {d / 1000:.2f} ns  (~{1e6 / d:.0f} MHz before layout)  "
              f"({len(r['path_cells'])} cells deep)")
        print(f"{'':12} critical path: {r['start']}  ->  {r['end']}")
        if a.show_path:
            from collections import Counter
            print(f"{'':12} cells on it: " + ", ".join(f"{n}x {c.replace('sky130_fd_sc_hd__', '')}"
                                                     for c, n in Counter(r['path_cells']).most_common()))
    if a.json:
        p = Path(a.json)
        data = json.loads(p.read_text()) if p.exists() else {}
        data[a.label] = results
        p.write_text(json.dumps(data, indent=2))


if __name__ == "__main__":
    main()
