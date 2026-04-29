#!/usr/bin/env python3
"""
Render a 4-panel performance chart from a SessionPerfSampler CSV.

The Aftertalk app writes one CSV per session under
`~/Documents/perf/<sessionId>.csv` on the iPhone (file-shared via the Files app).
Pull the file off the device — AirDrop, iCloud Drive, or Xcode → Window →
Devices and Simulators → "View Container" — into this directory, then run:

    python3 render_chart.py <session>.csv

Output is `<session>.png` next to the input. Used for the Day 6 / 7 perf
deliverable in the README and the submission packet.

CSV schema (matches `SessionPerfSampler.flushCSV`):
    elapsed_s, memory_mb, cpu_pct, thermal, battery_pct, event

`thermal` is `ProcessInfo.thermalState.rawValue`:
    0 = nominal, 1 = fair, 2 = serious, 3 = critical
"""

from __future__ import annotations

import argparse
import csv
import os
import sys
from dataclasses import dataclass
from typing import List

import matplotlib.pyplot as plt
from matplotlib.ticker import FuncFormatter


THERMAL_LABELS = {0: "nominal", 1: "fair", 2: "serious", 3: "critical"}
THERMAL_COLORS = {0: "#2ecc71", 1: "#f1c40f", 2: "#e67e22", 3: "#e74c3c"}


@dataclass
class Sample:
    t: float
    mem: float
    cpu: float
    thermal: int
    battery: float
    event: str


def load(path: str) -> List[Sample]:
    rows: List[Sample] = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        for r in reader:
            rows.append(
                Sample(
                    t=float(r["elapsed_s"]),
                    mem=float(r["memory_mb"]),
                    cpu=float(r["cpu_pct"]),
                    thermal=int(r["thermal"]),
                    battery=float(r["battery_pct"]),
                    event=(r.get("event") or "").strip(),
                )
            )
    return rows


def render(rows: List[Sample], out: str, title: str) -> None:
    if not rows:
        raise SystemExit("CSV had no rows")

    t = [r.t / 60.0 for r in rows]  # minutes on x-axis
    mem = [r.mem for r in rows]
    cpu = [r.cpu for r in rows]
    thermal = [r.thermal for r in rows]
    battery = [r.battery for r in rows]
    events = [(r.t / 60.0, r.event) for r in rows if r.event]

    fig, axes = plt.subplots(4, 1, figsize=(11, 9), sharex=True)
    fig.suptitle(title, fontsize=14, weight="bold")

    # --- Memory ---
    ax = axes[0]
    ax.plot(t, mem, color="#2c3e50", linewidth=1.4)
    ax.fill_between(t, mem, alpha=0.08, color="#2c3e50")
    peak = max(mem)
    ax.axhline(peak, color="#e74c3c", linestyle=":", linewidth=0.9)
    ax.text(
        t[-1],
        peak,
        f"  peak {peak:.0f} MB",
        va="center",
        ha="left",
        fontsize=9,
        color="#e74c3c",
    )
    ax.set_ylabel("Memory (MB)")
    ax.grid(True, alpha=0.2)

    # --- CPU ---
    ax = axes[1]
    ax.plot(t, cpu, color="#16a085", linewidth=1.0)
    ax.fill_between(t, cpu, alpha=0.10, color="#16a085")
    avg = sum(cpu) / len(cpu)
    ax.axhline(avg, color="#1abc9c", linestyle="--", linewidth=0.9)
    ax.text(
        t[-1],
        avg,
        f"  avg {avg:.0f}%",
        va="center",
        ha="left",
        fontsize=9,
        color="#16a085",
    )
    ax.set_ylabel("CPU (% of one core)")
    ax.grid(True, alpha=0.2)

    # --- Thermal ---
    ax = axes[2]
    # Plot as a step chart so transitions are crisp.
    ax.step(t, thermal, color="#7f8c8d", where="post", linewidth=1.2)
    for state, color in THERMAL_COLORS.items():
        ax.axhline(state, color=color, alpha=0.10, linewidth=8)
    ax.set_yticks(list(THERMAL_LABELS.keys()))
    ax.set_yticklabels([THERMAL_LABELS[k] for k in THERMAL_LABELS])
    ax.set_ylim(-0.3, 3.3)
    ax.set_ylabel("Thermal")
    ax.grid(True, alpha=0.2, axis="x")

    # --- Battery ---
    ax = axes[3]
    valid = [(x, y) for x, y in zip(t, battery) if y >= 0]
    if valid:
        bx, by = zip(*valid)
        ax.plot(bx, by, color="#9b59b6", linewidth=1.2)
        delta = by[0] - by[-1]
        ax.text(
            bx[-1],
            by[-1],
            f"  Δ {delta:+.1f}%",
            va="center",
            ha="left",
            fontsize=9,
            color="#9b59b6",
        )
    ax.set_ylabel("Battery (%)")
    ax.set_xlabel("Elapsed (minutes)")
    ax.grid(True, alpha=0.2)

    # Event markers on the bottom axis only (avoids clutter on every panel).
    for et, label in events:
        ax.axvline(et, color="#bdc3c7", linewidth=0.6, linestyle=":")
        ax.text(
            et,
            ax.get_ylim()[1],
            f" {label}",
            rotation=75,
            fontsize=7,
            color="#7f8c8d",
            va="bottom",
            ha="left",
        )

    fig.tight_layout(rect=[0, 0, 1, 0.97])
    fig.savefig(out, dpi=160)
    print(f"wrote {out}", file=sys.stderr)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("csv", help="Path to a session CSV produced by SessionPerfSampler")
    ap.add_argument(
        "--title",
        default=None,
        help="Optional chart title (defaults to the CSV filename)",
    )
    ap.add_argument(
        "--out",
        default=None,
        help="Output PNG path (defaults to <csv>.png)",
    )
    args = ap.parse_args()

    rows = load(args.csv)
    title = args.title or os.path.splitext(os.path.basename(args.csv))[0]
    out = args.out or os.path.splitext(args.csv)[0] + ".png"
    render(rows, out, title)


if __name__ == "__main__":
    main()
