#!/usr/bin/env python3
"""Render the README charts from docs/results/*.json (matplotlib).

  docs/cpi.png           cycles per instruction per benchmark, for each core
  docs/timing_ladder.png critical-path delay after each timing optimization
"""
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
SURFACE, INK, INK2, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#e4e3df"
COLORS = ["#2a78d6", "#eb6834", "#1baf7a"]  # categorical slots 1-3, validated for colour-blind separation

plt.rcParams.update({"font.size": 11, "axes.edgecolor": GRID, "axes.labelcolor": INK2, "xtick.color": INK2,
                     "ytick.color": INK2, "figure.facecolor": SURFACE, "axes.facecolor": SURFACE})


def style(ax, title):
    ax.set_title(title, loc="left", color=INK, fontsize=13)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    ax.set_axisbelow(True)


def cpi_chart():
    data = json.loads((ROOT / "docs/results/bench.json").read_text())["results"]
    progs = list(data)
    cores = [("single", "single-cycle"), ("pipe", "5-stage, predict not-taken"), ("pipe_bp", "5-stage + 16-entry BTB")]
    fig, ax = plt.subplots(figsize=(8, 3.8))
    w = 0.26
    for k, (core, label) in enumerate(cores):
        xs = [i + (k - 1) * (w + 0.02) for i in range(len(progs))]
        ys = [data[p][core]["cycles"] / data[p][core]["instret"] for p in progs]
        ax.bar(xs, ys, width=w, color=COLORS[k], label=label)
        for x, y in zip(xs, ys):
            ax.text(x, y + 0.01, f"{y:.2f}", ha="center", va="bottom", fontsize=8.5, color=INK)
    ax.set_xticks(range(len(progs)))
    ax.set_xticklabels(progs)
    ax.set_ylim(0, 1.8)
    ax.set_ylabel("cycles per instruction")
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.legend(frameon=False, ncol=3, loc="upper left", labelcolor=INK, fontsize=9.5)
    style(ax, "CPI by benchmark (lower is better)")
    fig.tight_layout()
    fig.savefig(ROOT / "docs/cpi.png", dpi=160)


def ladder_chart():
    data = json.loads((ROOT / "docs/results/timing_ladder.json").read_text())
    names = list(data)
    vals = [data[n]["core_pipe"]["median_ps"] / 1000 for n in names]
    fig, ax = plt.subplots(figsize=(8, 3.2))
    labels = [n.split(". ", 1)[1].replace("+ ", "+ ") for n in names][::-1]
    v = vals[::-1]
    ax.barh(labels, v, color=COLORS[0], height=0.6)
    for i, x in enumerate(v):
        ax.text(x + 0.12, i, f"{x:.2f} ns  ({1000 / x:.0f} MHz)", va="center", color=INK, fontsize=10)
    ax.set_xlim(0, max(v) * 1.45)
    ax.set_xlabel("critical path, pre-layout estimate (Sky130 HD, typical corner)")
    ax.grid(axis="x", color=GRID, linewidth=0.8)
    style(ax, "Pipelined core critical path, step by step")
    fig.tight_layout()
    fig.savefig(ROOT / "docs/timing_ladder.png", dpi=160)


if __name__ == "__main__":
    cpi_chart()
    ladder_chart()
    print("wrote docs/cpi.png, docs/timing_ladder.png")
