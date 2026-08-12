#!/usr/bin/env python3
"""Generate charts from real Vivado report data under fpga/vivado/reports/.

Never invents a number -- every value plotted is parsed from a checked-in
.rpt/summary.txt file and printed to stdout for cross-checking against the
source report by eye.

Scope, honestly: only the `inorder` (PIPELINED) config has real routed
results (4 frequency points). `ooo`/`soc` synthesis never completed (see
fpga/vivado/AUDIT.md's addendum and fpga/vivado/reports/SWEEP_LOG.md) --
there is no second/third config's data to compare against, so this script
does NOT produce the "by architecture" comparison charts the original
workflow plan envisioned. It produces what real data actually supports:
inorder's own frequency sweep (slack, implied Fmax, power) and its
resource utilization at one operating point.

Usage: python fpga/vivado/scripts/generate_graphs.py
"""
import re
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

REPORTS = Path(__file__).resolve().parents[1] / "reports"
OUT = Path(__file__).resolve().parents[3] / "docs" / "images" / "vivado"
OUT.mkdir(parents=True, exist_ok=True)

# dataviz skill reference palette (references/palette.md), light mode.
BLUE = "#2a78d6"
ORANGE = "#eb6834"
INK = "#0b0b0b"
MUTED = "#52514e"
GRID = "#e3e2dc"
SURFACE = "#fcfcfb"

plt.rcParams.update({
    "figure.facecolor": SURFACE,
    "axes.facecolor": SURFACE,
    "axes.edgecolor": GRID,
    "axes.labelcolor": INK,
    "text.color": INK,
    "xtick.color": MUTED,
    "ytick.color": MUTED,
    "axes.grid": True,
    "grid.color": GRID,
    "grid.linewidth": 0.8,
    "axes.axisbelow": True,
    "font.size": 11,
})


def parse_summary(path):
    d = {}
    for line in path.read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            d[k.strip()] = v.strip()
    return d


def parse_utilization(path):
    """Pull Slice LUTs / Slice Registers / RAMB36+RAMB18 / DSPs 'Used' column
    from a Vivado report_utilization text report (post-implementation)."""
    text = path.read_text()
    out = {}
    for key, pattern in {
        "luts": r"\|\s*Slice LUTs\s*\|\s*(\d+)",
        "ffs": r"\|\s*Slice Registers\s*\|\s*(\d+)",
        "ramb36": r"\|\s*RAMB36[^|]*\|\s*(\d+)",
        "ramb18": r"\|\s*RAMB18[^|]*\|\s*(\d+)",
        "dsp": r"\|\s*DSPs\s*\|\s*(\d+)",
    }.items():
        m = re.search(pattern, text)
        out[key] = int(m.group(1)) if m else 0
    return out


def parse_power(path):
    text = path.read_text()
    m = re.search(r"Total On-Chip Power \(W\)\s*\|\s*([\d.]+)", text)
    return float(m.group(1)) if m else None


def discover(config):
    """Return [(label, target_mhz, dir)] sorted by target MHz, for every
    fpga/vivado/reports/<config>/<label>/summary.txt that actually exists."""
    points = []
    cfg_dir = REPORTS / config
    if not cfg_dir.is_dir():
        return points
    for label_dir in sorted(cfg_dir.iterdir()):
        summary = label_dir / "summary.txt"
        if not summary.exists():
            continue
        m = re.match(r"(\d+)mhz", label_dir.name)
        if not m:
            continue
        points.append((label_dir.name, int(m.group(1)), label_dir))
    points.sort(key=lambda p: p[1])
    return points


def main():
    points = discover("inorder")
    if not points:
        print("No inorder report data found under fpga/vivado/reports/inorder/ -- nothing to plot.")
        return

    labels, mhz_vals, wns_vals, power_vals = [], [], [], []
    util_at_100 = None
    for label, mhz, d in points:
        s = parse_summary(d / "summary.txt")
        wns = float(s["wns_ns"])
        pwr = parse_power(d / "power.rpt")
        labels.append(f"{mhz} MHz")
        mhz_vals.append(mhz)
        wns_vals.append(wns)
        power_vals.append(pwr)
        print(f"inorder {label}: target={mhz}MHz period={10**3/mhz:.3f}ns WNS={wns:+.3f}ns power={pwr}W")
        if mhz == 100:
            util_at_100 = parse_utilization(d / "impl_utilization.rpt")

    # ---- Chart 1: timing slack across the frequency sweep ----
    fig, ax = plt.subplots(figsize=(7, 4.2))
    colors = [BLUE if w >= 0 else ORANGE for w in wns_vals]
    bars = ax.bar(labels, wns_vals, color=colors, width=0.55)
    ax.axhline(0, color=MUTED, linewidth=1)
    ax.set_ylabel("Worst Negative Slack (ns)")
    ax.set_title("inorder (PIPELINED) -- timing slack by target frequency")
    for b, w in zip(bars, wns_vals):
        ax.annotate(f"{w:+.2f}", (b.get_x() + b.get_width() / 2, w),
                     textcoords="offset points", xytext=(0, 4 if w >= 0 else -12),
                     ha="center", fontsize=9, color=INK)
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    fig.savefig(OUT / "timing_slack_by_frequency.png", dpi=150)
    plt.close(fig)

    # ---- Chart 2: implied Fmax lower bound (1000/(period-WNS)) per point ----
    fig, ax = plt.subplots(figsize=(7, 4.2))
    implied = [1000.0 / (1000.0 / mhz - w) for mhz, w in zip(mhz_vals, wns_vals)]
    ax.plot(labels, implied, marker="o", color=BLUE, linewidth=2, markersize=7)
    for x, y in zip(labels, implied):
        ax.annotate(f"{y:.0f} MHz", (x, y), textcoords="offset points",
                     xytext=(0, 8), ha="center", fontsize=9, color=INK)
    ax.set_ylabel("Implied Fmax lower bound (MHz)")
    ax.set_title("inorder (PIPELINED) -- implied max frequency per sweep point")
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    fig.savefig(OUT / "fmax_by_config.png", dpi=150)
    plt.close(fig)
    print("NOTE: real Fmax boundary not located -- all 4 sweep points met timing "
          "(see fpga/vivado/reports/SWEEP_LOG.md). Each bar/point above is a lower "
          "bound implied by that specific run's own WNS, not a measured ceiling.")

    # ---- Chart 3: power across the frequency sweep ----
    fig, ax = plt.subplots(figsize=(7, 4.2))
    ax.bar(labels, power_vals, color=BLUE, width=0.55)
    ax.set_ylabel("Total on-chip power, vectorless estimate (W)")
    ax.set_title("inorder (PIPELINED) -- Vivado power estimate by target frequency")
    for i, p in enumerate(power_vals):
        ax.annotate(f"{p:.3f}", (i, p), textcoords="offset points", xytext=(0, 4),
                     ha="center", fontsize=9, color=INK)
    ax.spines[["top", "right"]].set_visible(False)
    fig.tight_layout()
    fig.savefig(OUT / "power_by_config.png", dpi=150)
    plt.close(fig)

    # ---- Chart 4: resource utilization at the 100 MHz baseline point ----
    if util_at_100:
        print(f"inorder 100mhz utilization: {util_at_100}")
        fig, ax = plt.subplots(figsize=(7, 4.2))
        names = ["LUTs", "FFs", "RAMB36", "RAMB18", "DSP"]
        vals = [util_at_100["luts"], util_at_100["ffs"], util_at_100["ramb36"],
                util_at_100["ramb18"], util_at_100["dsp"]]
        ax.bar(names, vals, color=BLUE, width=0.55)
        ax.set_ylabel("Used (count)")
        ax.set_title("inorder (PIPELINED) -- resource utilization @ 100 MHz, routed\nxc7k325tffg900-2 (203800 LUTs / 407600 FFs / 890 BRAM / 840 DSP available)")
        for i, v in enumerate(vals):
            ax.annotate(str(v), (i, v), textcoords="offset points", xytext=(0, 4),
                         ha="center", fontsize=9, color=INK)
        ax.spines[["top", "right"]].set_visible(False)
        fig.tight_layout()
        fig.savefig(OUT / "lut_ff_bram_dsp_by_config.png", dpi=150)
        plt.close(fig)

    print(f"\nCharts written to {OUT}")
    print("Only inorder has real data -- ooo/soc synthesis never completed "
          "(fpga/vivado/AUDIT.md). No 'by architecture' comparison charts are "
          "produced since there is only one working config to plot.")


if __name__ == "__main__":
    main()
