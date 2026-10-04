#!/usr/bin/env python3
"""Plot the sustained aggregate Node-Y rate curve in PIEO Figure 11 style."""

from __future__ import annotations

import argparse
import csv
from pathlib import Path

import matplotlib.pyplot as plt


RATE_TICKS = [0.0, 0.1, 0.2, 0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0]
RATE_LABELS = ["0", "0.1", "0.2", "0.5", "1", "2", "5", "10", "20", "50"]
EXPECTED_LIMITS = RATE_TICKS[1:]


def rate_to_paper_axis(rate: float) -> float:
    """Map numeric rates onto the equal-spaced rate ticks used by Figure 11."""
    if rate <= RATE_TICKS[0]:
        return 0.0
    for index in range(1, len(RATE_TICKS)):
        lower = RATE_TICKS[index - 1]
        upper = RATE_TICKS[index]
        if rate <= upper:
            return (index - 1) + (rate - lower) / (upper - lower)
    final_span = RATE_TICKS[-1] - RATE_TICKS[-2]
    return (len(RATE_TICKS) - 1) + (rate - RATE_TICKS[-1]) / final_span


def load_results(csv_path: Path) -> list[dict[str, str]]:
    with csv_path.open(newline="", encoding="utf-8-sig") as handle:
        rows = list(csv.DictReader(handle))
    if len(rows) != len(EXPECTED_LIMITS):
        raise ValueError(
            f"expected {len(EXPECTED_LIMITS)} rate points, found {len(rows)}"
        )
    limits = [float(row["rate_limit_bps"]) / 1.0e9 for row in rows]
    if limits != EXPECTED_LIMITS:
        raise ValueError(f"unexpected rate limits: {limits}")
    for row in rows:
        if row["protocol_error"] != "0":
            raise ValueError(
                f"protocol_error at {row['rate_limit_bps']} bit/s"
            )
    return rows


def main() -> None:
    parser = argparse.ArgumentParser()
    default_csv = Path(__file__).with_name("node_y_rate_limit_curve.csv")
    parser.add_argument("--csv", type=Path, default=default_csv)
    parser.add_argument(
        "--output-prefix",
        type=Path,
        default=Path(__file__).with_name("node_y_rate_limit_curve"),
    )
    args = parser.parse_args()

    rows = load_results(args.csv)
    limits = [float(row["rate_limit_bps"]) / 1.0e9 for row in rows]
    achieved = [
        float(row["packet_output_window_bps"]) / 1.0e9 for row in rows
    ]

    x_positions = [rate_to_paper_axis(value) for value in limits]
    y_positions = [rate_to_paper_axis(value) for value in achieved]

    plt.rcParams.update(
        {
            "font.family": "serif",
            "font.serif": ["Times New Roman"],
            "font.size": 14,
            "axes.labelsize": 18,
            "xtick.labelsize": 15,
            "ytick.labelsize": 15,
            "legend.fontsize": 15.5,
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
        }
    )
    figure, axis = plt.subplots(figsize=(5.6, 4.35), constrained_layout=True)
    axis.plot(
        x_positions,
        y_positions,
        color="#2f6fb0",
        marker="s",
        markersize=5.8,
        markerfacecolor="#2f6fb0",
        markeredgecolor="#2f6fb0",
        linewidth=1.8,
        label="Node-Y Aggregate",
        zorder=3,
    )

    tick_positions = list(range(len(RATE_TICKS)))
    axis.set_xticks(tick_positions, RATE_LABELS)
    axis.set_yticks(tick_positions, RATE_LABELS)
    axis.set_xlim(-0.15, len(RATE_TICKS) - 0.65)
    axis.set_ylim(-0.15, len(RATE_TICKS) - 0.65)
    axis.set_xlabel("Rate Limit (Gbps)")
    axis.set_ylabel("Rate Achieved (Gbps)")
    axis.grid(True, color="#cfcfcf", linestyle=":", linewidth=0.65, zorder=0)
    axis.tick_params(direction="out", length=4.0, width=0.8)
    for spine in axis.spines.values():
        spine.set_color("#8a8a8a")
        spine.set_linewidth(0.75)
    axis.legend(
        loc="upper left",
        borderaxespad=0.65,
        frameon=True,
        fancybox=False,
        edgecolor="#999999",
    )
    axis.set_box_aspect(1.0)

    png_path = args.output_prefix.with_suffix(".png")
    pdf_path = args.output_prefix.with_suffix(".pdf")
    figure.savefig(png_path, dpi=300, bbox_inches="tight")
    figure.savefig(pdf_path, bbox_inches="tight")
    plt.close(figure)

    print("rate_limit_gbps,rate_achieved_gbps")
    for limit, actual in zip(limits, achieved):
        print(f"{limit:g},{actual:.9f}")
    print(f"wrote {png_path}")
    print(f"wrote {pdf_path}")


if __name__ == "__main__":
    main()
