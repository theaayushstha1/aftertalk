#!/usr/bin/env python3
"""
render_perf.py — turn an Aftertalk session perf CSV into an editorial chart.

Usage:
    python3 scripts/render_perf.py perf/<sessionId>.csv [-o out.png]

CSV columns (written by SessionPerfSampler at 1 Hz):
    elapsed_s, memory_mb, cpu_pct, thermal, battery_pct, event

Layout (top to bottom):
    1. Title strip — eyebrow + bold title + duration
    2. Stat band — peak mem, peak CPU, max thermal, battery delta
    3. Memory chart (filled area)
    4. CPU chart (line)
    5. Thermal strip (heatmap row, only if state ever > 0)
    6. Event timeline (markers along x-axis)

Battery is collapsed into the stat band when ≤2 % drift since a sub-15 %
range chart-line conveys nothing extra. Thermal becomes a colored strip
above CPU (skipped when nominal throughout).
"""
from __future__ import annotations

import argparse
import csv
import sys
from pathlib import Path

import matplotlib.pyplot as plt
import matplotlib.ticker as mticker
from matplotlib import patches
from matplotlib import rcParams


THERMAL_LABELS = {0: "nominal", 1: "fair", 2: "serious", 3: "critical"}
THERMAL_COLORS = {0: "#cfd8c8", 1: "#e8c87a", 2: "#d97a4a", 3: "#b53a3a"}

# Quiet Studio palette
BG = "#f6f1e7"
SURFACE = "#fbf7ed"
INK = "#1f1a14"
MUTE = "#857c6a"
FAINT = "#bbb19c"
ACCENT_MEM = "#3b6df0"
ACCENT_CPU = "#d97a4a"
GRID = "#e6dec9"


def load_csv(path: Path):
    rows = []
    with path.open() as f:
        reader = csv.DictReader(f)
        for r in reader:
            rows.append({
                "t": float(r["elapsed_s"]),
                "mem": float(r["memory_mb"]),
                "cpu": float(r["cpu_pct"]),
                "thermal": int(r["thermal"]),
                "battery": float(r["battery_pct"]),
                "event": r.get("event") or "",
            })
    return rows


def fmt_dur(seconds: float) -> str:
    if seconds < 60:
        return f"{seconds:.0f} s"
    m, s = divmod(int(seconds), 60)
    if m < 60:
        return f"{m} min {s:02d} s"
    h, m = divmod(m, 60)
    return f"{h} h {m:02d} m"


def render(rows, out_path: Path, title: str):
    if not rows:
        print("empty CSV, nothing to render", file=sys.stderr)
        sys.exit(1)

    rcParams.update({
        "font.family": "DejaVu Sans",
        "font.size": 10,
        "axes.edgecolor": FAINT,
        "axes.linewidth": 0.6,
        "axes.labelcolor": MUTE,
        "xtick.color": MUTE,
        "ytick.color": MUTE,
        "axes.spines.top": False,
        "axes.spines.right": False,
    })

    t = [r["t"] for r in rows]
    mem = [r["mem"] for r in rows]
    cpu = [r["cpu"] for r in rows]
    thermal = [r["thermal"] for r in rows]
    battery = [r["battery"] for r in rows]
    events = [(r["t"], r["event"]) for r in rows if r["event"]]

    duration = t[-1] if t else 0
    peak_mem = max(mem)
    delta_mem = peak_mem - mem[0]
    avg_cpu = sum(cpu) / len(cpu)
    peak_cpu = max(cpu)
    max_thermal = max(thermal)
    valid_battery = [b for b in battery if b >= 0]
    if valid_battery:
        battery_delta = valid_battery[0] - valid_battery[-1]  # drained
        battery_label = f"-{battery_delta:.1f} pp"
        battery_sub = f"start {valid_battery[0]:.0f}% → end {valid_battery[-1]:.0f}%"
    else:
        battery_label = "—"
        battery_sub = "monitoring off"

    show_thermal_strip = max_thermal > 0

    fig = plt.figure(figsize=(11, 7.2), facecolor=BG)
    gs = fig.add_gridspec(
        nrows=4 if show_thermal_strip else 3,
        ncols=1,
        height_ratios=([2.6, 0.35, 1.6, 1.4] if show_thermal_strip else [2.6, 1.6, 1.4]),
        hspace=0.55,
        left=0.08, right=0.96, top=0.86, bottom=0.10,
    )

    # ── Title strip ─────────────────────────────────────────────────────
    fig.text(0.08, 0.95, "AFTERTALK · SESSION PERF",
             fontsize=9, color=MUTE, weight="medium",
             family="DejaVu Sans Mono")
    fig.text(0.08, 0.91, title,
             fontsize=20, color=INK, weight="semibold")
    fig.text(0.96, 0.95, fmt_dur(duration),
             fontsize=12, color=MUTE, ha="right",
             family="DejaVu Sans Mono")
    fig.text(0.96, 0.917, f"{len(rows)} samples · 1 Hz",
             fontsize=9, color=FAINT, ha="right",
             family="DejaVu Sans Mono")

    # ── Stat band (overlaid on top of mem axis area) ───────────────────
    stat_y = 0.875
    stats = [
        ("PEAK MEMORY", f"{peak_mem:.0f} MB", f"+{delta_mem:.0f} MB since start"),
        ("AVG CPU", f"{avg_cpu:.0f} %", f"peak {peak_cpu:.0f}%"),
        ("THERMAL", THERMAL_LABELS[max_thermal].upper(), "highest reached"),
        ("BATTERY", battery_label, battery_sub),
    ]
    for i, (k, v, sub) in enumerate(stats):
        x = 0.08 + i * 0.225
        fig.text(x, stat_y, k, fontsize=8, color=FAINT,
                 family="DejaVu Sans Mono", weight="medium")
        fig.text(x, stat_y - 0.035, v, fontsize=15, color=INK, weight="semibold")
        fig.text(x, stat_y - 0.062, sub, fontsize=8, color=MUTE)

    # ── Memory ─────────────────────────────────────────────────────────
    ax_mem = fig.add_subplot(gs[0])
    ax_mem.set_facecolor(SURFACE)
    ax_mem.fill_between(t, mem, color=ACCENT_MEM, alpha=0.12)
    ax_mem.plot(t, mem, color=ACCENT_MEM, linewidth=1.6)
    ax_mem.set_ylabel("Memory  ·  MB", fontsize=9)
    ax_mem.grid(color=GRID, linewidth=0.5, axis="y")
    ax_mem.set_xlim(0, duration if duration > 0 else 1)
    ax_mem.set_ylim(0, peak_mem * 1.15)
    ax_mem.tick_params(labelbottom=False)

    # ── Thermal strip (optional) ────────────────────────────────────────
    if show_thermal_strip:
        ax_th = fig.add_subplot(gs[1], sharex=ax_mem)
        ax_th.set_facecolor(SURFACE)
        for i in range(len(t) - 1):
            ax_th.add_patch(patches.Rectangle(
                (t[i], 0), t[i + 1] - t[i], 1,
                facecolor=THERMAL_COLORS[thermal[i]], edgecolor="none"
            ))
        ax_th.set_ylim(0, 1)
        ax_th.set_yticks([])
        ax_th.set_ylabel("Thermal", fontsize=9)
        ax_th.tick_params(labelbottom=False, length=0)
        for spine in ax_th.spines.values():
            spine.set_visible(False)

    # ── CPU ────────────────────────────────────────────────────────────
    ax_cpu = fig.add_subplot(gs[2 if show_thermal_strip else 1], sharex=ax_mem)
    ax_cpu.set_facecolor(SURFACE)
    ax_cpu.fill_between(t, cpu, color=ACCENT_CPU, alpha=0.10)
    ax_cpu.plot(t, cpu, color=ACCENT_CPU, linewidth=1.3)
    ax_cpu.axhline(100, color=FAINT, linestyle=":", linewidth=0.7)
    ax_cpu.set_ylabel("CPU  ·  % of 1 core", fontsize=9)
    ax_cpu.grid(color=GRID, linewidth=0.5, axis="y")
    ax_cpu.tick_params(labelbottom=False)

    # ── Event timeline ─────────────────────────────────────────────────
    ax_ev = fig.add_subplot(gs[3 if show_thermal_strip else 2], sharex=ax_mem)
    ax_ev.set_facecolor(SURFACE)
    ax_ev.set_ylim(0, 1)
    ax_ev.set_yticks([])
    ax_ev.set_xlabel("Elapsed  ·  seconds", fontsize=9)
    ax_ev.xaxis.set_major_locator(mticker.MaxNLocator(8))
    for spine in ["left", "right", "top"]:
        ax_ev.spines[spine].set_visible(False)
    if events:
        for et, ev in events:
            ax_ev.axvline(et, color=INK, linewidth=0.6, alpha=0.55)
            ax_ev.text(et, 0.55, ev,
                       fontsize=8, color=INK, rotation=30,
                       ha="left", va="bottom",
                       family="DejaVu Sans Mono")
    else:
        ax_ev.text(0.5, 0.5, "no events recorded",
                   transform=ax_ev.transAxes, ha="center", va="center",
                   color=FAINT, fontsize=9)

    # vertical event lines on mem + cpu (subtle)
    for et, _ in events:
        ax_mem.axvline(et, color=INK, linewidth=0.5, alpha=0.18)
        ax_cpu.axvline(et, color=INK, linewidth=0.5, alpha=0.18)

    fig.savefig(out_path, dpi=180, facecolor=BG)
    print(f"wrote {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", type=Path)
    ap.add_argument("-o", "--out", type=Path, default=None)
    ap.add_argument("--title", default=None)
    args = ap.parse_args()

    if not args.csv.exists():
        print(f"not found: {args.csv}", file=sys.stderr)
        sys.exit(2)

    out = args.out or args.csv.with_suffix(".png")
    title = args.title or args.csv.stem
    rows = load_csv(args.csv)
    render(rows, out, title)


if __name__ == "__main__":
    main()
