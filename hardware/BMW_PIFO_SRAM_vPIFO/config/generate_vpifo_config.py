#!/usr/bin/env python3
"""Generate compile-time heterogeneous vPIFO layout artifacts.

The user-facing quantity is each logical PIFO's required capacity.  Every
physical shard remains a uniform binary BMW tree.  The production Stage15
configuration is four levels; capacity experiments may select four, five, or
six levels.  The generated mapping is continuous and deterministic; no
run-time reconfiguration is introduced.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = 1
SUPPORTED_SHARD_ORDER = 2
DEFAULT_SHARD_LEVEL = 4
SUPPORTED_SHARD_LEVELS = (4, 5, 6)
DEFAULT_MAX_LOGICAL_PIFOS = 64
DEFAULT_MAX_PHYSICAL_SHARDS = 64
HARD_MAX_LOGICAL_PIFOS = 256
HARD_MAX_PHYSICAL_SHARDS = 256
NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")


class ConfigError(ValueError):
    """A user configuration cannot be represented by this implementation."""


def _positive_integer(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ConfigError(f"{field} must be a positive integer; got {value!r}")
    return value


def _safe_id_width(item_count: int) -> int:
    return max(1, (item_count - 1).bit_length())


def structural_capacity(order: int, level: int) -> int:
    """Return M + M^2 + ... + M^L for a fixed-order BMW tree."""
    order = _positive_integer(order, "physical_shard.order")
    level = _positive_integer(level, "physical_shard.level")
    return sum(order**tree_level for tree_level in range(1, level + 1))


@dataclass(frozen=True)
class Layout:
    name: str
    required_capacity: tuple[int, ...]
    shard_order: int
    shard_level: int
    shard_capacity: int
    shard_count: tuple[int, ...]
    shard_offset: tuple[int, ...]
    physical_to_logical: tuple[int, ...]
    physical_tree_num: int
    logical_tree_num: int
    max_shards_per_logical: int
    logical_id_width: int
    physical_id_width: int
    max_logical_pifos: int
    max_physical_shards: int
    fingerprint: str

    @property
    def supplied_capacity(self) -> tuple[int, ...]:
        return tuple(count * self.shard_capacity for count in self.shard_count)


def _canonical_fingerprint(config: dict[str, Any]) -> str:
    canonical = json.dumps(
        config, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def build_layout(config: dict[str, Any]) -> Layout:
    if not isinstance(config, dict):
        raise ConfigError("top-level configuration must be a JSON object")

    allowed_keys = {
        "schema_version",
        "name",
        "required_capacity",
        "physical_shard",
        "resource_limits",
    }
    unknown_keys = sorted(set(config) - allowed_keys)
    if unknown_keys:
        raise ConfigError(f"unknown top-level field(s): {', '.join(unknown_keys)}")

    schema_version = config.get("schema_version", SCHEMA_VERSION)
    if schema_version != SCHEMA_VERSION:
        raise ConfigError(
            f"schema_version must be {SCHEMA_VERSION}; got {schema_version!r}"
        )

    name = config.get("name", "vpifo_config")
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        raise ConfigError("name may contain only letters, digits, and underscores")

    required = config.get("required_capacity")
    if not isinstance(required, list) or not required:
        raise ConfigError("required_capacity must be a non-empty JSON array")
    required_capacity = tuple(
        _positive_integer(value, f"required_capacity[{index}]")
        for index, value in enumerate(required)
    )

    shard_config = config.get("physical_shard", {})
    if not isinstance(shard_config, dict):
        raise ConfigError("physical_shard must be a JSON object")
    unknown_shard_keys = sorted(set(shard_config) - {"order", "level"})
    if unknown_shard_keys:
        raise ConfigError(
            f"unknown physical_shard field(s): {', '.join(unknown_shard_keys)}"
        )
    shard_order = _positive_integer(
        shard_config.get("order", SUPPORTED_SHARD_ORDER), "physical_shard.order"
    )
    shard_level = _positive_integer(
        shard_config.get("level", DEFAULT_SHARD_LEVEL), "physical_shard.level"
    )
    if (shard_order != SUPPORTED_SHARD_ORDER or
            shard_level not in SUPPORTED_SHARD_LEVELS):
        raise ConfigError(
            "this stage supports only uniform binary physical shards with "
            f"order={SUPPORTED_SHARD_ORDER} and level in "
            f"{SUPPORTED_SHARD_LEVELS}; "
            f"got order={shard_order}, level={shard_level}"
        )
    shard_capacity = structural_capacity(shard_order, shard_level)

    limits = config.get("resource_limits", {})
    if not isinstance(limits, dict):
        raise ConfigError("resource_limits must be a JSON object")
    unknown_limit_keys = sorted(
        set(limits) - {"max_logical_pifos", "max_physical_shards"}
    )
    if unknown_limit_keys:
        raise ConfigError(
            f"unknown resource_limits field(s): {', '.join(unknown_limit_keys)}"
        )
    max_logical_pifos = _positive_integer(
        limits.get("max_logical_pifos", DEFAULT_MAX_LOGICAL_PIFOS),
        "resource_limits.max_logical_pifos",
    )
    max_physical_shards = _positive_integer(
        limits.get("max_physical_shards", DEFAULT_MAX_PHYSICAL_SHARDS),
        "resource_limits.max_physical_shards",
    )
    if max_logical_pifos > HARD_MAX_LOGICAL_PIFOS:
        raise ConfigError(
            "resource_limits.max_logical_pifos exceeds the generator hard limit "
            f"of {HARD_MAX_LOGICAL_PIFOS}"
        )
    if max_physical_shards > HARD_MAX_PHYSICAL_SHARDS:
        raise ConfigError(
            "resource_limits.max_physical_shards exceeds the generator hard limit "
            f"of {HARD_MAX_PHYSICAL_SHARDS}"
        )

    logical_tree_num = len(required_capacity)
    if logical_tree_num > max_logical_pifos:
        raise ConfigError(
            f"configuration requires {logical_tree_num} logical PIFOs, exceeding "
            f"resource limit {max_logical_pifos}"
        )

    shard_count = tuple(
        (capacity + shard_capacity - 1) // shard_capacity
        for capacity in required_capacity
    )
    shard_offset_list: list[int] = []
    physical_to_logical_list: list[int] = []
    next_offset = 0
    for logical_id, count in enumerate(shard_count):
        shard_offset_list.append(next_offset)
        physical_to_logical_list.extend([logical_id] * count)
        next_offset += count

    physical_tree_num = next_offset
    # The inherited BMW engine declares tree IDs with $clog2(TREE_NUM)
    # throughout PIFO_SRAM_TOP, PIFO_SRAM, TaskFIFO, and TaskDistribute.
    # TREE_NUM=1 therefore creates zero-width packed ranges in the original
    # datapath.  Reject that unsupported original-engine corner explicitly
    # instead of emitting an apparently safe package that cannot elaborate.
    if physical_tree_num < 2:
        raise ConfigError(
            "configuration requires only 1 physical shard, but the inherited "
            "BMW engine requires at least 2 to avoid zero-width tree IDs"
        )
    if physical_tree_num > max_physical_shards:
        raise ConfigError(
            f"configuration requires {physical_tree_num} physical shards, exceeding "
            f"resource limit {max_physical_shards}"
        )
    if physical_tree_num > HARD_MAX_PHYSICAL_SHARDS:
        raise ConfigError(
            f"configuration exceeds the generator hard limit of "
            f"{HARD_MAX_PHYSICAL_SHARDS} physical shards"
        )

    shard_offset = tuple(shard_offset_list)
    physical_to_logical = tuple(physical_to_logical_list)
    max_shards_per_logical = max(shard_count)
    logical_id_width = _safe_id_width(logical_tree_num)
    physical_id_width = _safe_id_width(physical_tree_num)

    # These checks deliberately duplicate the construction invariants so a
    # future allocation-policy edit fails before emitting inconsistent RTL.
    covered: list[int] = []
    for logical_id, (offset, count) in enumerate(zip(shard_offset, shard_count)):
        if count < 1:
            raise ConfigError(f"logical PIFO {logical_id} has a zero shard count")
        if offset != len(covered):
            raise ConfigError("logical shard offsets are not contiguous")
        covered.extend(range(offset, offset + count))
    if covered != list(range(physical_tree_num)):
        raise ConfigError("logical shard ranges do not cover physical shards exactly")
    if len(physical_to_logical) != physical_tree_num:
        raise ConfigError("physical-to-logical reverse mapping has the wrong length")
    for logical_id, (offset, count) in enumerate(zip(shard_offset, shard_count)):
        if any(
            physical_to_logical[physical_id] != logical_id
            for physical_id in range(offset, offset + count)
        ):
            raise ConfigError("forward and reverse shard mappings are inconsistent")
    if logical_tree_num > (1 << logical_id_width):
        raise ConfigError("logical ID width cannot represent every logical PIFO")
    if physical_tree_num > (1 << physical_id_width):
        raise ConfigError("physical ID width cannot represent every physical shard")

    return Layout(
        name=name,
        required_capacity=required_capacity,
        shard_order=shard_order,
        shard_level=shard_level,
        shard_capacity=shard_capacity,
        shard_count=shard_count,
        shard_offset=shard_offset,
        physical_to_logical=physical_to_logical,
        physical_tree_num=physical_tree_num,
        logical_tree_num=logical_tree_num,
        max_shards_per_logical=max_shards_per_logical,
        logical_id_width=logical_id_width,
        physical_id_width=physical_id_width,
        max_logical_pifos=max_logical_pifos,
        max_physical_shards=max_physical_shards,
        fingerprint=_canonical_fingerprint(config),
    )


def _sv_array(values: Iterable[int]) -> str:
    return "'{" + ", ".join(str(value) for value in values) + "}"


def render_sv_package(layout: Layout, source_path: Path) -> str:
    identity_map = tuple(range(layout.physical_tree_num))
    return f"""`timescale 1ns / 1ps
// Generated by config/generate_vpifo_config.py.  Do not edit.
// Source: {source_path.as_posix()}
// Fingerprint: {layout.fingerprint}
package VpifoConfigPkg;
    localparam integer SHARD_ORDER = {layout.shard_order};
    localparam integer LEVEL = {layout.shard_level};
    localparam integer SHARD_CAPACITY = {layout.shard_capacity};
    localparam integer LOGICAL_TREE_NUM = {layout.logical_tree_num};
    localparam integer PHYSICAL_TREE_NUM = {layout.physical_tree_num};
    localparam integer MAX_SHARDS_PER_LOGICAL = {layout.max_shards_per_logical};
    localparam integer LOGICAL_ID_WIDTH = {layout.logical_id_width};
    localparam integer PHYSICAL_ID_WIDTH = {layout.physical_id_width};
    localparam integer USE_EXPLICIT_SHARD_MAP = 0;
    localparam integer REQUIRED_CAPACITY [0:LOGICAL_TREE_NUM-1] =
        {_sv_array(layout.required_capacity)};
    localparam integer SHARD_COUNTS [0:LOGICAL_TREE_NUM-1] =
        {_sv_array(layout.shard_count)};
    localparam integer SHARD_OFFSETS [0:LOGICAL_TREE_NUM-1] =
        {_sv_array(layout.shard_offset)};
    // Identity is retained only as the Stage15 explicit-map compatibility
    // parameter.  Production generated layouts use SHARD_OFFSETS directly.
    localparam integer EXPLICIT_SHARD_MAP [0:PHYSICAL_TREE_NUM-1] =
        {_sv_array(identity_map)};
endpackage
"""


def render_tcl(layout: Layout, source_path: Path) -> str:
    counts = " ".join(str(value) for value in layout.shard_count)
    offsets = " ".join(str(value) for value in layout.shard_offset)
    return f"""# Generated by config/generate_vpifo_config.py.  Do not edit.
# Source: {source_path.as_posix()}
set vpifo_config_name {layout.name}
set vpifo_config_fingerprint {layout.fingerprint}
set vpifo_shard_order {layout.shard_order}
set vpifo_level {layout.shard_level}
set vpifo_shard_capacity {layout.shard_capacity}
set vpifo_logical_tree_num {layout.logical_tree_num}
set vpifo_physical_tree_num {layout.physical_tree_num}
set vpifo_max_shards_per_logical {layout.max_shards_per_logical}
set vpifo_shard_counts {{{counts}}}
set vpifo_shard_offsets {{{offsets}}}
"""


def manifest_dict(layout: Layout, source_path: Path) -> dict[str, Any]:
    logical_layout = []
    for logical_id, (required, offset, count, supplied) in enumerate(
        zip(
            layout.required_capacity,
            layout.shard_offset,
            layout.shard_count,
            layout.supplied_capacity,
        )
    ):
        logical_layout.append(
            {
                "logical_id": logical_id,
                "required_capacity": required,
                "shard_offset": offset,
                "shard_count": count,
                "physical_shards": list(range(offset, offset + count)),
                "supplied_capacity": supplied,
            }
        )
    return {
        "schema_version": SCHEMA_VERSION,
        "source": source_path.as_posix(),
        "name": layout.name,
        "fingerprint": layout.fingerprint,
        "configuration_mode": "generation_time_compile_time",
        "physical_shard": {
            "order": layout.shard_order,
            "level": layout.shard_level,
            "structural_capacity": layout.shard_capacity,
        },
        "logical_tree_num": layout.logical_tree_num,
        "physical_tree_num": layout.physical_tree_num,
        "max_shards_per_logical": layout.max_shards_per_logical,
        "logical_id_width": layout.logical_id_width,
        "physical_id_width": layout.physical_id_width,
        "logical_layout": logical_layout,
        "physical_to_logical": list(layout.physical_to_logical),
        "resource_limits": {
            "max_logical_pifos": layout.max_logical_pifos,
            "max_physical_shards": layout.max_physical_shards,
        },
    }


def _write_if_changed(path: Path, content: str) -> bool:
    if path.exists() and path.read_text(encoding="utf-8") == content:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")
    return True


def generate(config_path: Path, output_dir: Path, check_only: bool = False) -> Layout:
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ConfigError(f"configuration file does not exist: {config_path}") from error
    except json.JSONDecodeError as error:
        raise ConfigError(
            f"invalid JSON in {config_path}: line {error.lineno}, column {error.colno}: "
            f"{error.msg}"
        ) from error

    layout = build_layout(config)
    source_path = config_path.resolve()
    outputs = {
        output_dir / "vpifo_config_pkg.sv": render_sv_package(layout, source_path),
        output_dir / "vpifo_config.tcl": render_tcl(layout, source_path),
        output_dir / "vpifo_config_manifest.json": json.dumps(
            manifest_dict(layout, source_path), indent=2, sort_keys=True
        )
        + "\n",
    }
    if check_only:
        stale = [
            str(path)
            for path, content in outputs.items()
            if not path.exists() or path.read_text(encoding="utf-8") != content
        ]
        if stale:
            raise ConfigError("generated output is stale: " + ", ".join(stale))
    else:
        for path, content in outputs.items():
            _write_if_changed(path, content)
    return layout


def _parse_args() -> argparse.Namespace:
    config_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(
        description="Generate heterogeneous vPIFO compile-time RTL configuration"
    )
    parser.add_argument(
        "--config",
        type=Path,
        default=config_dir / "vpifo_config.json",
        help="JSON configuration containing logical required_capacity",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=config_dir.parent / "generated",
        help="directory for the generated SV package, Tcl fragment, and manifest",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify that generated outputs are current without writing them",
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        layout = generate(args.config.resolve(), args.output_dir.resolve(), args.check)
    except (ConfigError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(
        f"generated {layout.name}: required_capacity={list(layout.required_capacity)} "
        f"shard_capacity={layout.shard_capacity} "
        f"shard_count={list(layout.shard_count)} "
        f"shard_offset={list(layout.shard_offset)} "
        f"physical_tree_num={layout.physical_tree_num}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
