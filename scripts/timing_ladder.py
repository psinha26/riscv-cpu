#!/usr/bin/env python3
"""Critical-path ladder: synthesize each step of the timing optimization under identical settings.

Earlier design points are rebuilt from the current RTL by undoing later changes, so every row
is measured by the same tool run with the same ABC settings (delay-driven mapping, unreachable
1 ns target, Sky130 HD typical corner):

  1. baseline: ripple-carry adders, forwarding decided in EX, MEM forward value muxed in MEM
  2. + Kogge-Stone prefix adders (ALU, branch compare, branch target)
  3. + forwarding selects decided in ID and registered
  4. + MEM-stage forward value registered at the end of EX

ABC's technology mapping is heuristic: small structural differences move the result by
+-10-20%. So each design point is mapped at several delay targets (each yields a different
mapping) and the median and best critical path are reported; trust the trend, and take final
numbers from the real place-and-route flow (flow/).

  python3 scripts/timing_ladder.py --lib sky130_fd_sc_hd__tt_025C_1v80.lib
"""
import argparse
import json
import re
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import synth_estimate  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent


def sub(text, pattern, repl):
    new, n = re.subn(pattern, repl, text, flags=re.S)
    if n == 0:
        raise SystemExit(f"patch pattern not found: {pattern[:60]}")
    return new


def ripple_adders(rtl: Path):
    p = rtl / "prefix_adder.sv"
    s = p.read_text()
    s = sub(s, r"  localparam int LEVELS.*?\nendmodule", "  assign {cout, sum} = a + b + cin;  // ripple (synthesis default)\nendmodule")
    p.write_text(s)


def forwarding_in_ex(rtl: Path):
    p = rtl / "core_pipe.sv"
    s = p.read_text()
    s = sub(s, r"unique case \(ex_fwd_a\)", "unique case (ex_fwd_a_c)")
    s = sub(s, r"unique case \(ex_fwd_b\)", "unique case (ex_fwd_b_c)")
    s = sub(s, r"(  logic \[31:0\] rs1_fwd, rs2_fwd;\n)",
            "  logic [1:0] ex_fwd_a_c, ex_fwd_b_c;  // decided in EX from the MEM/WB registers\n"
            "  assign ex_fwd_a_c = (mem_valid && mem_reg_we && mem_rd != 5'd0 && mem_rd == ex_rs1) ? 2'd1 :\n"
            "                      (wb_valid && wb_reg_we && wb_rd != 5'd0 && wb_rd == ex_rs1) ? 2'd2 : 2'd0;\n"
            "  assign ex_fwd_b_c = (mem_valid && mem_reg_we && mem_rd != 5'd0 && mem_rd == ex_rs2) ? 2'd1 :\n"
            "                      (wb_valid && wb_reg_we && wb_rd != 5'd0 && wb_rd == ex_rs2) ? 2'd2 : 2'd0;\n\\1")
    p.write_text(s)


def mem_forward_in_mem(rtl: Path):
    p = rtl / "core_pipe.sv"
    s = p.read_text()
    s = sub(s, r"\n      // The value MEM forwards back to EX.*?\n      mem_fwd_val <= \(ex_wb_sel == WB_PC4\) \? ex_pc4 : alu_y;", "")
    s = sub(s, r"(  // =+\n  // MEM\n)", "  assign mem_fwd_val = (mem_wb_sel == WB_PC4) ? mem_pc4 : mem_alu;\n\n\\1")
    p.write_text(s)


STEPS = [
    ("1. baseline (ripple adders)", [ripple_adders, forwarding_in_ex, mem_forward_in_mem]),
    ("2. + prefix adders", [forwarding_in_ex, mem_forward_in_mem]),
    ("3. + forwarding decided in ID", [mem_forward_in_mem]),
    ("4. + registered MEM forward", []),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lib", required=True)
    ap.add_argument("--periods", default="1000,4000,6000,8000", help="ABC delay targets (ps) to sample")
    ap.add_argument("--out", default=str(ROOT / "docs/results/timing_ladder.json"))
    a = ap.parse_args()

    results = {}
    with tempfile.TemporaryDirectory() as td:
        for name, patches in STEPS:
            rtl = Path(td) / "rtl"
            if rtl.exists():
                shutil.rmtree(rtl)
            shutil.copytree(ROOT / "rtl", rtl)
            for fn in patches:
                fn(rtl)
            synth_estimate.ROOT = Path(td)
            row = {}
            for top in ("core_pipe", "core_single"):
                runs = [synth_estimate.synth(top, a.lib, int(d)) for d in a.periods.split(",")]
                delays = sorted(r["abc_delay_ps"] for r in runs)
                med = delays[len(delays) // 2] if len(delays) % 2 else (delays[len(delays) // 2 - 1] + delays[len(delays) // 2]) / 2
                best = min(runs, key=lambda r: r["abc_delay_ps"])
                row[top] = {"delays_ps": delays, "median_ps": med, "best_ps": delays[0],
                            "area_um2": best["area_um2"], "cells": best["cells"], "flops": best["flops"],
                            "start": best["start"], "end": best["end"]}
            results[name] = row
            p, s1 = row["core_pipe"], row["core_single"]
            print(f"{name:32} pipelined median {p['median_ps'] / 1000:5.2f} ns ({1e6 / p['median_ps']:4.0f} MHz), "
                  f"best {p['best_ps'] / 1000:5.2f} ns, area {p['area_um2'] / 1e6:.4f} mm^2 | single-cycle median "
                  f"{s1['median_ps'] / 1000:5.2f} ns | samples {[round(d / 1000, 2) for d in p['delays_ps']]}", flush=True)
    Path(a.out).write_text(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
