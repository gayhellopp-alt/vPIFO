#!/usr/bin/env python3
"""Generate isolated compile-time packages for the full heterogeneous matrix."""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path
from typing import Any


CONFIG_DIR = Path(__file__).resolve().parent
GENERATOR_PATH = CONFIG_DIR / "generate_vpifo_config.py"
SPEC = importlib.util.spec_from_file_location("generate_vpifo_config", GENERATOR_PATH)
assert SPEC and SPEC.loader
GEN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GEN
SPEC.loader.exec_module(GEN)


class MatrixError(ValueError):
    """The experiment matrix is internally inconsistent."""


def _positive_integer(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise MatrixError(f"{field} must be a positive integer; got {value!r}")
    return value


def load_matrix(path: Path) -> dict[str, Any]:
    try:
        matrix = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise MatrixError(f"cannot read matrix {path}: {error}") from error
    if not isinstance(matrix, dict):
        raise MatrixError("matrix must be a JSON object")
    if matrix.get("schema_version") != 1:
        raise MatrixError("matrix schema_version must be 1")
    fixed = matrix.get("fixed_parameters")
    points = matrix.get("points")
    if not isinstance(fixed, dict) or not isinstance(points, list) or not points:
        raise MatrixError("matrix requires fixed_parameters and a non-empty points list")
    return matrix


def select_points(
    matrix: dict[str, Any], requested: set[str], pilot: bool
) -> list[dict[str, Any]]:
    points = matrix["points"]
    point_names = [point.get("name") for point in points]
    if any(not isinstance(name, str) for name in point_names):
        raise MatrixError("every point requires a string name")
    if len(set(point_names)) != len(point_names):
        raise MatrixError("point names must be unique")
    selected = requested
    if pilot:
        pilot_names = matrix.get("pilot_points")
        if not isinstance(pilot_names, list) or not pilot_names:
            raise MatrixError("pilot_points must be a non-empty list")
        selected = selected | set(pilot_names) if selected else set(pilot_names)
    missing = selected - set(point_names)
    if missing:
        raise MatrixError(f"unknown point(s): {', '.join(sorted(missing))}")
    return [point for point in points if not selected or point["name"] in selected]


def generate_point(
    fixed: dict[str, Any], point: dict[str, Any], output_root: Path
) -> dict[str, Any]:
    name = point.get("name")
    if not isinstance(name, str) or not GEN.NAME_RE.fullmatch(name):
        raise MatrixError(f"invalid point name {name!r}")
    order = _positive_integer(fixed.get("order"), "fixed_parameters.order")
    logical_tree_num = _positive_integer(
        fixed.get("logical_tree_num"), "fixed_parameters.logical_tree_num"
    )
    level = _positive_integer(point.get("level"), f"{name}.level")
    physical_tree_num = _positive_integer(
        point.get("physical_tree_num"), f"{name}.physical_tree_num"
    )
    shard_counts = point.get("shard_counts")
    if not isinstance(shard_counts, list) or len(shard_counts) != logical_tree_num:
        raise MatrixError(
            f"{name}.shard_counts must contain {logical_tree_num} entries"
        )
    shard_counts = [
        _positive_integer(value, f"{name}.shard_counts[{index}]")
        for index, value in enumerate(shard_counts)
    ]
    if sum(shard_counts) != physical_tree_num:
        raise MatrixError(
            f"{name}: shard-count sum {sum(shard_counts)} != "
            f"physical_tree_num {physical_tree_num}"
        )
    shard_capacity = GEN.structural_capacity(order, level)
    required_capacity = [count * shard_capacity for count in shard_counts]
    point_config = {
        "schema_version": 1,
        "name": f"heterogeneous_4211_{name}",
        "required_capacity": required_capacity,
        "physical_shard": {"order": order, "level": level},
        "resource_limits": {
            "max_logical_pifos": max(64, logical_tree_num),
            "max_physical_shards": max(64, physical_tree_num),
        },
    }

    point_dir = output_root / name
    config_path = point_dir / "vpifo_config.json"
    generated_dir = point_dir / "generated"
    point_dir.mkdir(parents=True, exist_ok=True)
    config_path.write_text(
        json.dumps(point_config, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    layout = GEN.generate(config_path, generated_dir)
    if list(layout.shard_count) != shard_counts:
        raise MatrixError(f"{name}: generated shard counts differ from matrix")
    return {
        "name": name,
        "level": level,
        "shard_capacity": shard_capacity,
        "physical_tree_num": physical_tree_num,
        "shard_counts": shard_counts,
        "required_capacity": required_capacity,
        "config": config_path.resolve().as_posix(),
        "generated_dir": generated_dir.resolve().as_posix(),
        "fingerprint": layout.fingerprint,
    }


def parse_args() -> argparse.Namespace:
    rtl_dir = CONFIG_DIR.parent
    parser = argparse.ArgumentParser(
        description="Generate the fixed-four-logical heterogeneous capacity matrix"
    )
    parser.add_argument(
        "--matrix",
        type=Path,
        default=CONFIG_DIR / "experiments" / "heterogeneous_4211_matrix.json",
    )
    parser.add_argument(
        "--output-root",
        type=Path,
        default=rtl_dir / "heterogeneous_capacity_runs",
    )
    parser.add_argument("--point", action="append", default=[])
    parser.add_argument("--pilot", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        matrix = load_matrix(args.matrix.resolve())
        points = select_points(matrix, set(args.point), args.pilot)
        output_root = args.output_root.resolve()
        generated_points = [
            generate_point(matrix["fixed_parameters"], point, output_root)
            for point in points
        ]
        manifest = {
            "schema_version": 1,
            "name": matrix["name"],
            "matrix_source": args.matrix.resolve().as_posix(),
            "fixed_parameters": matrix["fixed_parameters"],
            "points": generated_points,
        }
        output_root.mkdir(parents=True, exist_ok=True)
        (output_root / "matrix_manifest.json").write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
            newline="\n",
        )
    except (MatrixError, GEN.ConfigError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    for point in generated_points:
        print(
            f"generated {point['name']}: level={point['level']} "
            f"physical={point['physical_tree_num']} "
            f"shard_counts={point['shard_counts']} "
            f"required_capacity={point['required_capacity']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
