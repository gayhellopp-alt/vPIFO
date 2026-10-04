from __future__ import annotations

import argparse
import csv
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


CLOCK_PERIOD_US = 0.008
BASELINE_COLOR = "#c9483b"
SHAPED_COLOR = "#167d86"
TARGET_COLOR = "#333333"


def load_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="ascii") as stream:
        return list(csv.DictReader(stream))


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Plot the aggregate-Y shaping A/B experiment."
    )
    parser.add_argument(
        "--timeseries",
        type=Path,
        default=Path("non_conserving_ab_timeseries.csv"),
    )
    parser.add_argument(
        "--events",
        type=Path,
        default=Path("non_conserving_ab_events.csv"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("non_conserving_ab_comparison.png"),
    )
    args = parser.parse_args()

    bins = load_rows(args.timeseries)
    events = load_rows(args.events)
    if not bins or not events:
        raise SystemExit("A/B CSV input is empty")

    target_gbps = int(bins[0]["target_bps"]) / 1e9
    bin_edges_us = [
        int(row["bin_start_cycle"]) * CLOCK_PERIOD_US for row in bins
    ]
    bin_edges_us.append(int(bins[-1]["bin_end_cycle"]) * CLOCK_PERIOD_US)
    bypass_gbps = [int(row["bypass_bps"]) / 1e9 for row in bins]
    shaped_gbps = [int(row["shaped_bps"]) / 1e9 for row in bins]

    mode_events: dict[str, list[dict[str, str]]] = {
        "bypass": [],
        "token_bucket": [],
    }
    for row in events:
        mode_events[row["mode"]].append(row)

    fig, axes = plt.subplots(
        3,
        1,
        figsize=(10.5, 9.0),
        gridspec_kw={"height_ratios": [1.15, 1.0, 1.0]},
        constrained_layout=True,
    )

    axes[0].stairs(
        bypass_gbps,
        bin_edges_us,
        color=BASELINE_COLOR,
        linewidth=2.0,
        label="Scheduling bypass",
    )
    axes[0].stairs(
        shaped_gbps,
        bin_edges_us,
        color=SHAPED_COLOR,
        linewidth=2.2,
        label="Aggregate Y Token Bucket",
    )
    axes[0].axhline(
        target_gbps,
        color=TARGET_COLOR,
        linestyle="--",
        linewidth=1.2,
        label=f"Configured {target_gbps:g} Gbit/s",
    )
    axes[0].set_ylabel("Window throughput (Gbit/s)")
    axes[0].set_title("Same C/A/B burst offered to the Y subtree")
    axes[0].legend(frameon=False, ncol=3, loc="upper right")
    axes[0].grid(axis="y", color="#d5d5d5", linewidth=0.7)

    for mode, color, label in (
        ("bypass", BASELINE_COLOR, "Scheduling bypass"),
        ("token_bucket", SHAPED_COLOR, "Aggregate Y Token Bucket"),
    ):
        rows = mode_events[mode]
        event_x = [0.0] + [
            int(row["output_cycle"]) * CLOCK_PERIOD_US for row in rows
        ]
        cumulative = [0] + list(range(1, len(rows) + 1))
        axes[1].step(
            event_x,
            cumulative,
            where="post",
            color=color,
            linewidth=2.0,
            label=label,
        )
    axes[1].set_ylabel("Cumulative Y packets")
    axes[1].grid(axis="both", color="#e0e0e0", linewidth=0.7)

    for mode, color, label in (
        ("bypass", BASELINE_COLOR, "Scheduling bypass"),
        ("token_bucket", SHAPED_COLOR, "Aggregate Y Token Bucket"),
    ):
        rows = mode_events[mode][1:]
        packet_index = [int(row["output_index"]) for row in rows]
        gaps = [int(row["interdeparture_cycles"]) for row in rows]
        axes[2].plot(
            packet_index,
            gaps,
            color=color,
            linewidth=1.5,
            marker="o",
            markersize=2.8,
            label=label,
        )
    service_cycles = int(
        round(12000 * 125_000_000 / int(bins[0]["target_bps"]))
    )
    axes[2].axhline(
        service_cycles,
        color=TARGET_COLOR,
        linestyle="--",
        linewidth=1.2,
        label=f"Token Bucket interval ({service_cycles} cycles)",
    )
    axes[2].set_xlabel("Y packet output index")
    axes[2].set_ylabel("Interdeparture gap (cycles)")
    axes[2].grid(axis="y", color="#d5d5d5", linewidth=0.7)
    axes[2].legend(
        frameon=False,
        ncol=3,
        loc="lower center",
        bbox_to_anchor=(0.5, 1.01),
    )

    for axis in axes:
        axis.spines["top"].set_visible(False)
        axis.spines["right"].set_visible(False)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(args.output, dpi=180)
    fig.savefig(args.output.with_suffix(".pdf"))
    print(f"wrote {args.output}")
    print(f"wrote {args.output.with_suffix('.pdf')}")


if __name__ == "__main__":
    main()
