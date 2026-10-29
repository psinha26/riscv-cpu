#!/usr/bin/env python3
"""Run the LibreLane (OpenLane 2) RTL-to-GDSII flow and summarize the results.

Must run inside LibreLane's nix-shell (see docs/GUIDE.md, "Chip layout"):

  python3 scripts/flow.py run    [--variant final|baseline] [--period 10]
  python3 scripts/flow.py report [--variant final|baseline]     # parse the latest run
  python3 scripts/flow.py layout [--variant final]              # open the GDS in KLayout

Variants:
  final     the design as it is (prefix adders, registered forwarding, 16-entry BTB)
  baseline  the same core with the timing optimizations undone (ripple adders, forwarding
            decided in EX, MEM forward muxed in MEM): the "before" for the critical path

The report reads final/metrics.json and the STA summary from the run directory and writes
docs/results/flow_<variant>.json: worst setup slack -> achieved clock, cell count, core area,
utilization and power at the typical corner.
"""
import argparse
import glob
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))


def variant_dir(variant: str) -> Path:
    """flow/<variant>/ with its own copy of the RTL (patched for baseline) and config.json."""
    d = ROOT / "flow" / variant
    if variant == "final":
        return ROOT / "flow"
    import timing_ladder
    if d.exists():
        shutil.rmtree(d)
    shutil.copytree(ROOT / "rtl", d / "rtl")
    for patch in (timing_ladder.ripple_adders, timing_ladder.forwarding_in_ex, timing_ladder.mem_forward_in_mem):
        patch(d / "rtl")
    cfg = json.loads((ROOT / "flow" / "config.json").read_text())
    cfg["VERILOG_FILES"] = [f.replace("dir::../rtl/", "dir::rtl/") for f in cfg["VERILOG_FILES"]]
    cfg["VERILOG_INCLUDE_DIRS"] = ["dir::rtl"]
    (d / "config.json").write_text(json.dumps(cfg, indent=2))
    return d


def latest_run(d: Path) -> Path:
    runs = sorted(glob.glob(str(d / "runs" / "RUN_*")))
    if not runs:
        sys.exit(f"no runs in {d / 'runs'}; run `python3 scripts/flow.py run` first")
    return Path(runs[-1])


def report(variant: str):
    d = ROOT / "flow" if variant == "final" else ROOT / "flow" / variant
    run = latest_run(d)
    metrics = json.loads((run / "final" / "metrics.json").read_text())
    period = json.loads((d / "config.json").read_text())["CLOCK_PERIOD"]

    def m(*keys):
        for k in keys:
            if k in metrics:
                return metrics[k]
        return None

    # Worst setup slack across corners, and at the typical corner.
    ws_all = m("timing__setup__ws")
    ws_tt = m("timing__setup__ws__corner:nom_tt_025C_1v80")
    out = {
        "run": run.name,
        "clock_period_ns": period,
        "setup_ws_ns_all_corners": ws_all,
        "setup_ws_ns_typical": ws_tt,
        "fmax_mhz_all_corners": 1000 / (period - ws_all) if ws_all is not None else None,
        "fmax_mhz_typical": 1000 / (period - ws_tt) if ws_tt is not None else None,
        "hold_ws_ns": m("timing__hold__ws"),
        "instance_count": m("design__instance__count"),
        "stdcell_area_um2": m("design__instance__area__stdcell", "design__instance__area"),
        "core_area_um2": m("design__core__area"),
        "die_area_um2": m("design__die__area"),
        "utilization": m("design__instance__utilization"),
        "power_total_w": m("power__total"),
        "drc_errors": m("route__drc_errors", "magic__drc_error__count", "klayout__drc_error__count"),
        "lvs_errors": m("design__lvs_error__count"),
    }
    gds = glob.glob(str(run / "final" / "gds" / "*.gds"))
    out["gds"] = gds[0] if gds else None
    dst = ROOT / "docs" / "results" / f"flow_{variant}.json"
    dst.write_text(json.dumps(out, indent=2))
    for k, v in out.items():
        print(f"{k:26} {v:.4g}" if isinstance(v, float) else f"{k:26} {v}")
    print(f"\nwritten to {dst.relative_to(ROOT)}")
    # Critical path, from the typical-corner STA report.
    sta = sorted(glob.glob(str(run / "*-openroad-stapostpnr" / "nom_tt_025C_1v80" / "max.rpt")))
    if sta:
        print(f"critical path report: {sta[-1]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["run", "report", "layout"])
    ap.add_argument("--variant", default="final", choices=["final", "baseline"])
    ap.add_argument("--period", type=float, help="override CLOCK_PERIOD (ns)")
    a = ap.parse_args()
    if shutil.which("librelane") is None:
        sys.exit("librelane not found: run this inside LibreLane's nix-shell (see docs/GUIDE.md)")
    d = variant_dir(a.variant)
    cfg = d / "config.json"
    if a.period:
        c = json.loads(cfg.read_text())
        c["CLOCK_PERIOD"] = a.period
        cfg.write_text(json.dumps(c, indent=2))
    if a.action == "run":
        subprocess.run(["librelane", str(cfg)], check=True)
        report(a.variant)
    elif a.action == "report":
        report(a.variant)
    else:
        subprocess.run(["librelane", "--last-run", "--flow", "openinklayout", str(cfg)], check=True)


if __name__ == "__main__":
    main()
