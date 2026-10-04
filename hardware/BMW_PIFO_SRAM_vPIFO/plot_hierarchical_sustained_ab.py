from __future__ import annotations

import argparse
import csv
from collections import defaultdict
from pathlib import Path
from statistics import mean, pstdev

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


CLOCK_PERIOD_US = 0.008
DISABLED_COLOR = "#d95f3d"
ENABLED_COLOR = "#168a91"
TARGET_COLOR = "#222222"
F_COLOR = "#7a5195"
X_COLOR = "#ef8354"
Y_COLOR = "#2f6690"
# Twice the typography used by the original comparison figure:
# axis labels 11 pt, tick labels 10 pt, and legend text 9.5 pt.
MAIN_AXIS_LABEL_SIZE = 22
MAIN_TICK_LABEL_SIZE = 20
MAIN_LEGEND_SIZE = 19


def load_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="ascii") as stream:
        return list(csv.DictReader(stream))


def mode_rows(
    rows: list[dict[str, str]], mode: str
) -> list[dict[str, str]]:
    selected = [row for row in rows if row["mode"] == mode]
    return sorted(selected, key=lambda row: int(row["window_index"]))


def save_figure(fig: plt.Figure, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=190)
    fig.savefig(path.with_suffix(".pdf"))
    print(f"wrote {path}")
    print(f"wrote {path.with_suffix('.pdf')}")


def row_center_ms(row: dict[str, str]) -> float:
    return (
        (int(row["window_start_cycle"]) + int(row["window_end_cycle"]))
        * 0.5
        * CLOCK_PERIOD_US
        / 1000.0
    )


def block_resample(
    x_values: list[float], y_values: list[float], block_points: int
) -> tuple[list[float], list[float]]:
    """Anti-alias by block averaging before low-frequency resampling."""
    sampled_x: list[float] = []
    sampled_y: list[float] = []
    for start in range(0, len(y_values), block_points):
        x_block = x_values[start : start + block_points]
        y_block = y_values[start : start + block_points]
        if len(y_block) < block_points // 2:
            continue
        sampled_x.append(mean(x_block))
        sampled_y.append(mean(y_block))
    return sampled_x, sampled_y


def main() -> None:
    plt.rcParams.update(
        {
            "font.family": "serif",
            "font.serif": ["Times New Roman"],
            "pdf.fonttype": 42,
            "ps.fonttype": 42,
        }
    )
    parser = argparse.ArgumentParser(
        description=(
            "Plot the multi-node, multi-flow sustained aggregate-Y "
            "Token Bucket A/B experiment."
        )
    )
    parser.add_argument(
        "--windows",
        type=Path,
        default=Path("hierarchical_sustained_ab_windows.csv"),
    )
    parser.add_argument(
        "--events",
        type=Path,
        default=Path("hierarchical_sustained_ab_events.csv"),
    )
    parser.add_argument(
        "--summary",
        type=Path,
        default=Path("hierarchical_sustained_ab_summary.csv"),
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("hierarchical_sustained_ab_comparison.png"),
    )
    parser.add_argument(
        "--legend-means",
        action="store_true",
        help="append measured mean throughput to the two A/B legend labels",
    )
    args = parser.parse_args()

    rows = load_rows(args.windows)
    events = load_rows(args.events)
    summaries = load_rows(args.summary)
    if not rows or not events or len(summaries) != 2:
        raise SystemExit("hierarchical sustained A/B CSV input is incomplete")

    source_start_ms = 2.0
    source_end_ms = 6.0
    disabled = [
        row
        for row in mode_rows(rows, "token_bucket_disabled")
        if source_start_ms <= row_center_ms(row) <= source_end_ms
    ]
    enabled = [
        row
        for row in mode_rows(rows, "token_bucket_enabled")
        if source_start_ms <= row_center_ms(row) <= source_end_ms
    ]
    if len(disabled) != len(enabled):
        raise SystemExit("enabled/disabled window counts differ")

    # Present the selected 2--7 ms experiment interval as a compact 0--5 ms
    # trace.  Only the time origin changes; the measured samples do not.
    x_ms = [row_center_ms(row) - source_start_ms for row in disabled]
    display_start_ms = 0.0
    display_end_ms = source_end_ms - source_start_ms
    disabled_gbps = [int(row["y_bps"]) / 1e9 for row in disabled]
    enabled_gbps = [int(row["y_bps"]) / 1e9 for row in enabled]
    resample_points = 40
    sampled_x_ms, disabled_display_gbps = block_resample(
        x_ms, disabled_gbps, resample_points
    )
    enabled_sampled_x_ms, enabled_display_gbps = block_resample(
        x_ms, enabled_gbps, resample_points
    )
    if sampled_x_ms != enabled_sampled_x_ms:
        raise SystemExit("enabled/disabled resampling grids differ")
    target_gbps = int(rows[0]["target_bps"]) / 1e9
    summary_by_mode = {row["mode"]: row for row in summaries}
    disabled_label = "Shaping Disabled"
    enabled_label = "Node-Y Token-Bucket Shaping"
    if args.legend_means:
        disabled_mean_gbps = (
            int(summary_by_mode["token_bucket_disabled"]["mean_y_bps"])
            / 1e9
        )
        enabled_mean_gbps = (
            int(summary_by_mode["token_bucket_enabled"]["mean_y_bps"])
            / 1e9
        )
        disabled_label = (
            f"Shaping Disabled (mean: {disabled_mean_gbps:.3f} Gbps)"
        )
        enabled_label = (
            f"Node-Y Shaping (mean: {enabled_mean_gbps:.3f} Gbps)"
        )
    minimum_packet_bytes = int(summaries[0]["min_packet_bytes"])
    maximum_packet_bytes = int(summaries[0]["max_packet_bytes"])
    window_cycles = int(summaries[0]["window_cycles"])
    burst_capacity_time = int(summaries[0]["burst_capacity_time"])

    fig, axis = plt.subplots(figsize=(11.2, 5.1), constrained_layout=True)
    axis.plot(
        x_ms,
        disabled_gbps,
        color=DISABLED_COLOR,
        linewidth=0.5,
        alpha=0.14,
        zorder=1,
    )
    axis.plot(
        x_ms,
        enabled_gbps,
        color=ENABLED_COLOR,
        linewidth=0.5,
        alpha=0.16,
        zorder=1,
    )
    axis.plot(
        sampled_x_ms,
        disabled_display_gbps,
        color=DISABLED_COLOR,
        linewidth=1.15,
        marker="s",
        markersize=3.8,
        markeredgewidth=0.0,
        label=disabled_label,
        zorder=4,
    )
    axis.plot(
        sampled_x_ms,
        enabled_display_gbps,
        color=ENABLED_COLOR,
        linewidth=1.25,
        marker="o",
        markersize=3.8,
        markeredgewidth=0.0,
        label=enabled_label,
        zorder=5,
    )
    axis.axhline(
        target_gbps,
        color=TARGET_COLOR,
        linewidth=1.0,
        linestyle="--",
        label=f"Configured Rate: {target_gbps:g} Gbps",
        zorder=3,
    )
    axis.set_xlim(display_start_ms, display_end_ms)
    axis.set_xlabel("Time (ms)", fontsize=MAIN_AXIS_LABEL_SIZE)
    axis.set_ylabel(
        "Aggregate Throughput (Gbps)", fontsize=MAIN_AXIS_LABEL_SIZE
    )
    axis.grid(color="#bdbdbd", linewidth=0.6, linestyle=":")
    axis.legend(
        frameon=True,
        facecolor="white",
        edgecolor="#aaaaaa",
        framealpha=0.95,
        loc="upper right",
        fontsize=MAIN_LEGEND_SIZE,
    )
    for spine in axis.spines.values():
        spine.set_color("#777777")
        spine.set_linewidth(0.8)
    axis.tick_params(
        labelsize=MAIN_TICK_LABEL_SIZE,
        width=0.8,
        color="#555555",
    )
    save_figure(fig, args.output)
    plt.close(fig)

    raw_output = args.output.with_name(
        args.output.stem + "_raw" + args.output.suffix
    )
    fig, axis = plt.subplots(figsize=(11.2, 5.1), constrained_layout=True)
    axis.plot(
        x_ms,
        disabled_gbps,
        color=DISABLED_COLOR,
        linewidth=0.7,
        alpha=0.75,
        label=disabled_label,
    )
    axis.plot(
        x_ms,
        enabled_gbps,
        color=ENABLED_COLOR,
        linewidth=0.85,
        alpha=0.9,
        label=enabled_label,
    )
    axis.axhline(
        target_gbps,
        color=TARGET_COLOR,
        linewidth=1.3,
        linestyle="--",
        label=f"Configured Rate: {target_gbps:g} Gbps",
    )
    axis.set_xlim(display_start_ms, display_end_ms)
    axis.set_xlabel("Time (ms)", fontsize=MAIN_AXIS_LABEL_SIZE)
    axis.set_ylabel(
        "Aggregate Throughput (Gbps)", fontsize=MAIN_AXIS_LABEL_SIZE
    )
    axis.grid(color="#bdbdbd", linewidth=0.6, linestyle=":")
    axis.legend(
        frameon=True,
        edgecolor="#aaaaaa",
        loc="upper right",
        fontsize=MAIN_LEGEND_SIZE,
    )
    axis.tick_params(labelsize=MAIN_TICK_LABEL_SIZE)
    for spine in axis.spines.values():
        spine.set_color("#777777")
        spine.set_linewidth(0.8)
    save_figure(fig, raw_output)
    plt.close(fig)

    fig, axes = plt.subplots(
        3,
        1,
        figsize=(19.0, 10.7),
        sharex=True,
        constrained_layout=True,
    )
    for mode_rows_value, linestyle, suffix in (
        (disabled, "--", "disabled"),
        (enabled, "-", "enabled"),
    ):
        for key, color, label in (
            ("root_f_active_fraction", F_COLOR, "Root F active"),
            ("root_x_active_fraction", X_COLOR, "Root X active"),
            ("root_y_active_fraction", Y_COLOR, "Root Y active"),
        ):
            axes[0].plot(
                x_ms,
                [float(row[key]) * 100.0 for row in mode_rows_value],
                color=color,
                linestyle=linestyle,
                linewidth=1.35,
                alpha=0.9,
                label=f"{label}, {suffix}",
            )
    axes[0].plot(
        x_ms,
        [float(row["root_multi_active_fraction"]) * 100.0 for row in enabled],
        color="#333333",
        linewidth=1.8,
        label="At least two Root subtrees active, enabled",
    )
    axes[0].set_ylabel("Active fraction per window (%)")
    axes[0].grid(color="#e1e1e1", linewidth=0.65)
    axes[0].legend(frameon=False, ncol=2, fontsize=8.5)

    for key, color, label in (
        ("x_local_active_fraction", X_COLOR, "X local PIFO active"),
        ("y_local_active_fraction", Y_COLOR, "Y local PIFO active"),
        ("z_local_active_fraction", "#55a868", "Z local PIFO active"),
        ("y_source_backlog_fraction", "#333333", "Y source backlog"),
    ):
        axes[1].plot(
            x_ms,
            [float(row[key]) * 100.0 for row in enabled],
            color=color,
            linewidth=1.4,
            label=f"{label}, enabled",
        )
    axes[1].set_ylabel("Local/backlog fraction (%)")
    axes[1].grid(color="#e1e1e1", linewidth=0.65)
    axes[1].legend(frameon=False, ncol=2, fontsize=8.5)

    for rows_value, color, label in (
        (disabled, DISABLED_COLOR, "Y served, disabled"),
        (enabled, ENABLED_COLOR, "Y served, enabled"),
    ):
        axes[2].plot(
            x_ms,
            [int(row["y_served"]) for row in rows_value],
            color=color,
            linewidth=1.7,
            label=label,
        )
    axes[2].plot(
        x_ms,
        [int(row["f_served"]) for row in enabled],
        color=F_COLOR,
        linewidth=1.1,
        alpha=0.8,
        label="F served, enabled",
    )
    axes[2].plot(
        x_ms,
        [int(row["x_served"]) for row in enabled],
        color=X_COLOR,
        linewidth=1.1,
        alpha=0.8,
        label="X served, enabled",
    )
    axes[2].set_xlabel("Measurement time (ms)")
    axes[2].set_ylabel("Packets served per sliding window")
    axes[2].grid(color="#e1e1e1", linewidth=0.65)
    axes[2].legend(frameon=False, ncol=2)
    for axis in axes:
        axis.spines["top"].set_visible(False)
        axis.spines["right"].set_visible(False)

    diagnostics = args.output.with_name(
        args.output.stem + "_diagnostics" + args.output.suffix
    )
    save_figure(fig, diagnostics)
    plt.close(fig)

    event_counts: dict[str, dict[str, int]] = defaultdict(
        lambda: defaultdict(int)
    )
    for row in events:
        event_counts[row["mode"]][row["subtree"]] += 1
    for summary in summaries:
        mode = summary["mode"]
        print(
            f"{mode}: mean={int(summary['mean_y_bps']) / 1e9:.6f} "
            f"Gbit/s, range={int(summary['min_y_bps']) / 1e9:.3f}-"
            f"{int(summary['max_y_bps']) / 1e9:.3f} Gbit/s, "
            f"window_std={pstdev([int(row['y_bps']) / 1e9 for row in mode_rows(rows, mode)]):.3f} Gbit/s, "
            f"Y_bytes={int(summary['measurement_y_bytes'])}, "
            f"events={dict(event_counts[mode])}"
        )
    print(
        f"packet_range={minimum_packet_bytes}-{maximum_packet_bytes} B, "
        f"bucket_capacity={burst_capacity_time} time-credit cycles, "
        f"window={window_cycles} cycles"
    )
    print(
        f"presentation_source=2-6 ms, display=0-4 ms, "
        f"block={resample_points} raw windows, "
        f"points={len(sampled_x_ms)}, "
        f"disabled_range={min(disabled_display_gbps):.3f}-"
        f"{max(disabled_display_gbps):.3f} Gbit/s, "
        f"enabled_range={min(enabled_display_gbps):.3f}-"
        f"{max(enabled_display_gbps):.3f} Gbit/s"
    )


if __name__ == "__main__":
    main()
