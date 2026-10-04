#!/usr/bin/env python3
"""Collect full heterogeneous synthesis and route reports into CSV/Markdown."""

from __future__ import annotations

import argparse
import csv
import json
import re
from pathlib import Path
from typing import Any


def key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def utilization_values(path: Path) -> dict[str, int]:
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8", errors="replace")
    patterns = {
        "lut": r"\|\s*CLB LUTs\*?\s*\|\s*(\d+)",
        "logic_lut": r"\|\s*LUT as Logic\s*\|\s*(\d+)",
        "lutram": r"\|\s*LUT as Memory\s*\|\s*(\d+)",
        "ff": r"\|\s*CLB Registers\s*\|\s*(\d+)",
        "carry8": r"\|\s*CARRY8\s*\|\s*(\d+)",
        "f7": r"\|\s*F7 Muxes\s*\|\s*(\d+)",
        "f8": r"\|\s*F8 Muxes\s*\|\s*(\d+)",
    }
    result: dict[str, int] = {}
    for key, pattern in patterns.items():
        match = re.search(pattern, text)
        if match:
            result[key] = int(match.group(1))
    return result


def hierarchy_values(path: Path) -> dict[str, int]:
    if not path.exists():
        return {}
    wanted = {
        "directory": "directory_lut",
        "engine": "engine_lut",
        "logical_pending": "lrb_lut",
        "pop_result_fifo": "pop_fifo_lut",
    }
    result: dict[str, int] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line.startswith("|"):
            continue
        fields = [field.strip() for field in line.split("|")[1:-1]]
        if len(fields) >= 3 and fields[0] in wanted and fields[2].isdigit():
            result[wanted[fields[0]]] = int(fields[2])
    return result


def formatted_float(value: str, digits: int = 3) -> str:
    """Return stable, compact report formatting without binary-float tails."""
    if not value:
        return ""
    return f"{float(value):.{digits}f}"


def estimated_fmax_mhz(clock_period_ns: str, wns_ns: str) -> str:
    """Estimate Fmax from the constrained period and the reported worst slack."""
    if not clock_period_ns or not wns_ns:
        return ""
    limiting_period_ns = float(clock_period_ns) - float(wns_ns)
    if limiting_period_ns <= 0.0:
        return ""
    return f"{1000.0 / limiting_period_ns:.1f}"


def stage_row(point: dict[str, Any], root: Path, stage: str) -> dict[str, Any] | None:
    name = point["name"]
    if stage == "synth":
        report_dir = root / name / "vivado_synth" / "reports"
        prefix = f"{name}_synth"
        summary_path = report_dir / f"{prefix}_machine_summary.txt"
        util_path = report_dir / f"{prefix}_utilization.rpt"
        hierarchy_path = report_dir / f"{prefix}_utilization_hierarchical.rpt"
    else:
        report_dir = root / name / "vivado_impl" / "reports"
        prefix = f"{name}_post_route"
        summary_path = report_dir / f"{prefix}_machine_summary.txt"
        util_path = report_dir / f"{prefix}_utilization.rpt"
        hierarchy_path = report_dir / f"{prefix}_utilization_hierarchical.rpt"
    summary = key_values(summary_path)
    if not summary:
        return None
    row: dict[str, Any] = {
        "point": name,
        "stage": stage,
        "level": point["level"],
        "physical_tree_num": point["physical_tree_num"],
        "shard_capacity": point["shard_capacity"],
        "total_capacity": point["physical_tree_num"] * point["shard_capacity"],
        "shard_counts": " ".join(str(value) for value in point["shard_counts"]),
        "wns_ns": formatted_float(summary.get("WNS", "")),
        "tns_ns": formatted_float(summary.get("TNS", "")),
        "estimated_fmax_mhz": estimated_fmax_mhz(
            summary.get("CLOCK_PERIOD_NS", ""), summary.get("WNS", "")
        ),
        "violating_endpoints": summary.get("VIOLATING_ENDPOINTS", ""),
        "datapath_delay_ns": summary.get("DATAPATH_DELAY", ""),
        "logic_levels": summary.get("LOGIC_LEVELS", ""),
        "startpoint": summary.get("STARTPOINT", ""),
        "endpoint": summary.get("ENDPOINT", ""),
    }
    row.update(utilization_values(util_path))
    row.update(hierarchy_values(hierarchy_path))
    return row


def parse_args() -> argparse.Namespace:
    config_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--run-root",
        type=Path,
        default=config_dir.parent / "heterogeneous_capacity_runs",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    root = args.run_root.resolve()
    manifest = json.loads((root / "matrix_manifest.json").read_text(encoding="utf-8"))
    rows = [
        row
        for point in manifest["points"]
        for stage in ("synth", "route")
        if (row := stage_row(point, root, stage)) is not None
    ]
    fieldnames = [
        "point", "stage", "level", "physical_tree_num", "shard_capacity",
        "total_capacity", "shard_counts", "lut", "logic_lut", "lutram", "ff",
        "carry8", "f7", "f8", "directory_lut", "engine_lut", "lrb_lut",
        "pop_fifo_lut", "wns_ns", "tns_ns", "estimated_fmax_mhz",
        "violating_endpoints",
        "datapath_delay_ns", "logic_levels", "startpoint", "endpoint",
    ]
    csv_path = root / "heterogeneous_capacity_results.csv"
    with csv_path.open("w", encoding="utf-8", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)

    markdown_path = root / "heterogeneous_capacity_results.md"
    headers = [
        "Point", "Stage", "L", "N", "Capacity", "LUT", "Logic", "LUTRAM",
        "FF", "Directory", "Engine", "LRB", "WNS(ns)", "TNS(ns)",
        "Est. Fmax(MHz)", "Endpoints",
    ]
    lines = [
        "# Full heterogeneous 4:2:1:1 capacity matrix",
        "",
        "| " + " | ".join(headers) + " |",
        "| " + " | ".join(["---"] * len(headers)) + " |",
    ]
    for row in rows:
        values = [
            row.get("point", ""), row.get("stage", ""), row.get("level", ""),
            row.get("physical_tree_num", ""), row.get("total_capacity", ""),
            row.get("lut", ""), row.get("logic_lut", ""), row.get("lutram", ""),
            row.get("ff", ""), row.get("directory_lut", ""),
            row.get("engine_lut", ""), row.get("lrb_lut", ""),
            row.get("wns_ns", ""), row.get("tns_ns", ""),
            row.get("estimated_fmax_mhz", ""),
            row.get("violating_endpoints", ""),
        ]
        lines.append("| " + " | ".join(str(value) for value in values) + " |")
    markdown_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"collected {len(rows)} report rows into {csv_path} and {markdown_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
