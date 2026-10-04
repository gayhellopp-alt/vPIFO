#!/usr/bin/env python3
"""Convert an original SDL compiler trace into a deterministic RTL fixture.

The open-source compiler emits node IDs 10, 20, ... while its committed
hardware traces use compact logical IDs 1, 2, ... .  The original repository
does not contain an executable bridge between those namespaces, so this tool
requires an explicit mapping instead of inferring one from creation order.

Ranks remain software-generated exactly as in the original vPIFO flow.  This
tool only normalizes IDs, selects the reference-covered trace prefix, and emits
SystemVerilog arrays consumed by the heterogeneous hierarchy regression.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SCHEMA_VERSION = 1
FIXTURE_PTW = 28
FIXTURE_MTW = 20
TRACE_PATTERNS = {
    0: re.compile(r"^type:0,\s*idle_cycle:(-?\d+)\s*$"),
    1: re.compile(
        r"^type:1,\s*tree_id:(-?\d+),\s*meta:(-?\d+),\s*"
        r"priority0:(-?\d+),\s*priority1:(-?\d+)\s*$"
    ),
    2: re.compile(r"^type:2\s*$"),
}
REFERENCE_RE = re.compile(r"^meta:(-?\d+),\s*(push_cyc|pop_cyc):(-?\d+)\s*$")


class FixtureError(ValueError):
    """An original trace cannot be represented by the regression fixture."""


@dataclass(frozen=True)
class Event:
    kind: int
    idle_cycle: int = 0
    tree_id: int = 0
    meta: int = 0
    priority0: int = 0
    priority1: int = 0


@dataclass(frozen=True)
class Fixture:
    name: str
    events: tuple[Event, ...]
    expected_meta: tuple[int, ...]
    expected_tree_id: tuple[int, ...]
    expected_priority0: tuple[int, ...]
    external_to_logical: tuple[tuple[int, int], ...]
    trace_path: Path
    reference_path: Path
    id_map_path: Path
    config_manifest_path: Path
    fingerprint: str
    replay_mode: str


def _load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise FixtureError(f"{label} does not exist: {path}") from error
    except json.JSONDecodeError as error:
        raise FixtureError(
            f"invalid JSON in {path}: line {error.lineno}, column {error.colno}: "
            f"{error.msg}"
        ) from error
    if not isinstance(value, dict):
        raise FixtureError(f"{label} must contain a JSON object")
    return value


def load_id_map(path: Path) -> tuple[str, dict[int, int]]:
    raw = _load_json(path, "tree ID map")
    allowed = {"schema_version", "name", "external_to_logical"}
    unknown = sorted(set(raw) - allowed)
    if unknown:
        raise FixtureError(f"unknown tree ID map field(s): {', '.join(unknown)}")
    if raw.get("schema_version", SCHEMA_VERSION) != SCHEMA_VERSION:
        raise FixtureError(f"tree ID map schema_version must be {SCHEMA_VERSION}")
    name = raw.get("name", "legacy_tree_id_map")
    if not isinstance(name, str) or not name:
        raise FixtureError("tree ID map name must be a non-empty string")
    mapping_raw = raw.get("external_to_logical")
    if not isinstance(mapping_raw, dict) or not mapping_raw:
        raise FixtureError("external_to_logical must be a non-empty JSON object")
    mapping: dict[int, int] = {}
    used_logical: set[int] = set()
    for external_text, logical_value in mapping_raw.items():
        try:
            external_id = int(external_text)
        except (TypeError, ValueError) as error:
            raise FixtureError(
                f"external tree ID {external_text!r} is not an integer"
            ) from error
        if isinstance(logical_value, bool) or not isinstance(logical_value, int):
            raise FixtureError(
                f"logical ID for external tree {external_id} must be an integer"
            )
        if external_id < 0 or logical_value <= 0:
            raise FixtureError("external IDs must be non-negative and leaf logical IDs positive")
        if external_id in mapping:
            raise FixtureError(f"duplicate external tree ID {external_id}")
        if logical_value in used_logical:
            raise FixtureError(f"duplicate target logical ID {logical_value}")
        mapping[external_id] = logical_value
        used_logical.add(logical_value)
    return name, mapping


def load_logical_tree_num(path: Path) -> int:
    raw = _load_json(path, "generated configuration manifest")
    logical_tree_num = raw.get("logical_tree_num")
    if (
        isinstance(logical_tree_num, bool)
        or not isinstance(logical_tree_num, int)
        or logical_tree_num < 2
    ):
        raise FixtureError("manifest logical_tree_num must be an integer of at least 2")
    return logical_tree_num


def parse_reference(path: Path) -> tuple[tuple[int, ...], tuple[int, ...]]:
    push_meta: list[int] = []
    pop_meta: list[int] = []
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except FileNotFoundError as error:
        raise FixtureError(f"reference does not exist: {path}") from error
    for line_number, raw_line in enumerate(lines, 1):
        line = raw_line.strip()
        if not line:
            continue
        match = REFERENCE_RE.fullmatch(line)
        if not match:
            raise FixtureError(f"malformed reference line {line_number}: {raw_line!r}")
        meta = int(match.group(1))
        cycle = int(match.group(3))
        if meta < 0 or cycle < 0:
            raise FixtureError(f"negative reference value on line {line_number}")
        if match.group(2) == "push_cyc":
            push_meta.append(meta)
        else:
            pop_meta.append(meta)
    if not push_meta or not pop_meta:
        raise FixtureError("reference must contain both push_cyc and pop_cyc entries")
    if len(push_meta) != len(pop_meta):
        raise FixtureError(
            f"reference has {len(push_meta)} Pushes but {len(pop_meta)} Pops"
        )
    if len(set(push_meta)) != len(push_meta):
        raise FixtureError("reference Push metadata must be unique for tree-ID checking")
    if sorted(push_meta) != sorted(pop_meta):
        raise FixtureError("reference Push and Pop metadata sets differ")
    return tuple(push_meta), tuple(pop_meta)


def parse_trace_prefix(
    path: Path,
    mapping: dict[int, int],
    expected_push_meta: tuple[int, ...],
    expected_pop_count: int,
) -> tuple[tuple[Event, ...], dict[int, int]]:
    events: list[Event] = []
    trace_push_meta: list[int] = []
    meta_to_tree: dict[int, int] = {}
    pop_count = 0
    try:
        trace_file = path.open("r", encoding="utf-8")
    except FileNotFoundError as error:
        raise FixtureError(f"trace does not exist: {path}") from error
    with trace_file:
        for line_number, raw_line in enumerate(trace_file, 1):
            line = raw_line.strip()
            if not line:
                continue
            type_match = re.match(r"^type:(-?\d+)", line)
            if not type_match:
                raise FixtureError(f"malformed trace line {line_number}: {raw_line.rstrip()!r}")
            kind = int(type_match.group(1))
            pattern = TRACE_PATTERNS.get(kind)
            match = pattern.fullmatch(line) if pattern else None
            if match is None:
                raise FixtureError(f"malformed trace line {line_number}: {raw_line.rstrip()!r}")
            if kind == 0:
                idle_cycle = int(match.group(1))
                if idle_cycle < 0:
                    raise FixtureError(f"negative idle cycle on trace line {line_number}")
                events.append(Event(kind=0, idle_cycle=idle_cycle))
            elif kind == 1:
                external_id, meta, priority0, priority1 = map(int, match.groups())
                if external_id not in mapping:
                    raise FixtureError(
                        f"trace line {line_number} uses unmapped external tree ID "
                        f"{external_id}"
                    )
                if min(meta, priority0, priority1) < 0:
                    raise FixtureError(f"negative Push field on trace line {line_number}")
                if meta >= (1 << FIXTURE_MTW):
                    raise FixtureError(
                        f"metadata on trace line {line_number} exceeds MTW={FIXTURE_MTW}"
                    )
                if max(priority0, priority1) >= (1 << FIXTURE_PTW):
                    raise FixtureError(
                        f"rank on trace line {line_number} exceeds PTW={FIXTURE_PTW}"
                    )
                if meta in meta_to_tree:
                    raise FixtureError(
                        f"trace prefix repeats packet metadata {meta} on line {line_number}"
                    )
                logical_id = mapping[external_id]
                trace_push_meta.append(meta)
                meta_to_tree[meta] = logical_id
                events.append(
                    Event(
                        kind=1,
                        tree_id=logical_id,
                        meta=meta,
                        priority0=priority0,
                        priority1=priority1,
                    )
                )
            else:
                events.append(Event(kind=2))
                pop_count += 1
                if pop_count == expected_pop_count:
                    break
    if pop_count != expected_pop_count:
        raise FixtureError(
            f"trace ended after {pop_count} Pops; reference requires {expected_pop_count}"
        )
    # vPIFO_trace writes push_cyc when its scheduled Push task executes, not
    # when the packet first appears in the input trace.  Its order can thus
    # differ from packet arrival order; the metadata set must still match.
    if sorted(trace_push_meta) != sorted(expected_push_meta):
        raise FixtureError(
            "trace Push metadata prefix does not match the reference push_cyc set"
        )
    return tuple(events), meta_to_tree


def parse_batch_reference(
    path: Path,
    mapping: dict[int, int],
    expected_push_meta: tuple[int, ...],
) -> tuple[tuple[Event, ...], dict[int, int]]:
    """Collect the reference packet set, then append a drain barrier and Pops.

    The committed .ref files describe scheduling order for an already-enqueued
    packet set.  They are not cycle references for the interleaved raw trace.
    Event kind 3 is a test-only barrier that waits for all Push tasks to retire.
    """
    target_meta = set(expected_push_meta)
    pushes: list[Event] = []
    meta_to_tree: dict[int, int] = {}
    try:
        trace_file = path.open("r", encoding="utf-8")
    except FileNotFoundError as error:
        raise FixtureError(f"trace does not exist: {path}") from error
    with trace_file:
        for line_number, raw_line in enumerate(trace_file, 1):
            line = raw_line.strip()
            if not line:
                continue
            type_match = re.match(r"^type:(-?\d+)", line)
            if not type_match:
                raise FixtureError(f"malformed trace line {line_number}: {raw_line.rstrip()!r}")
            kind = int(type_match.group(1))
            pattern = TRACE_PATTERNS.get(kind)
            match = pattern.fullmatch(line) if pattern else None
            if match is None:
                raise FixtureError(f"malformed trace line {line_number}: {raw_line.rstrip()!r}")
            if kind != 1:
                continue
            external_id, meta, priority0, priority1 = map(int, match.groups())
            if meta not in target_meta:
                continue
            if external_id not in mapping:
                raise FixtureError(
                    f"trace line {line_number} uses unmapped external tree ID "
                    f"{external_id}"
                )
            if min(meta, priority0, priority1) < 0:
                raise FixtureError(f"negative Push field on trace line {line_number}")
            if meta >= (1 << FIXTURE_MTW):
                raise FixtureError(
                    f"metadata on trace line {line_number} exceeds MTW={FIXTURE_MTW}"
                )
            if max(priority0, priority1) >= (1 << FIXTURE_PTW):
                raise FixtureError(
                    f"rank on trace line {line_number} exceeds PTW={FIXTURE_PTW}"
                )
            if meta in meta_to_tree:
                raise FixtureError(
                    f"trace repeats reference packet metadata {meta} on line {line_number}"
                )
            logical_id = mapping[external_id]
            meta_to_tree[meta] = logical_id
            pushes.append(
                Event(
                    kind=1,
                    tree_id=logical_id,
                    meta=meta,
                    priority0=priority0,
                    priority1=priority1,
                )
            )
            if len(meta_to_tree) == len(target_meta):
                break
    if set(meta_to_tree) != target_meta:
        missing = sorted(target_meta - set(meta_to_tree))
        raise FixtureError(f"trace is missing reference packet metadata {missing}")
    events = pushes + [Event(kind=3)] + [Event(kind=2)] * len(expected_push_meta)
    return tuple(events), meta_to_tree


def build_fixture(
    name: str,
    trace_path: Path,
    reference_path: Path,
    id_map_path: Path,
    config_manifest_path: Path,
    replay_mode: str = "trace_prefix",
) -> Fixture:
    map_name, mapping = load_id_map(id_map_path)
    logical_tree_num = load_logical_tree_num(config_manifest_path)
    for external_id, logical_id in mapping.items():
        if logical_id >= logical_tree_num:
            raise FixtureError(
                f"external tree {external_id} maps to logical {logical_id}, but the "
                f"generated configuration has only {logical_tree_num} logical PIFOs"
            )
    expected_push_meta, expected_pop_meta = parse_reference(reference_path)
    if replay_mode == "trace_prefix":
        events, meta_to_tree = parse_trace_prefix(
            trace_path, mapping, expected_push_meta, len(expected_pop_meta)
        )
    elif replay_mode == "batch_reference":
        events, meta_to_tree = parse_batch_reference(
            trace_path, mapping, expected_push_meta
        )
    else:
        raise FixtureError(f"unknown replay mode: {replay_mode}")
    expected_tree_id = tuple(meta_to_tree[meta] for meta in expected_pop_meta)
    event_by_meta = {
        event.meta: event for event in events if event.kind == 1
    }
    expected_priority0 = tuple(
        event_by_meta[meta].priority0 for meta in expected_pop_meta
    )
    canonical = {
        "schema_version": SCHEMA_VERSION,
        "name": name,
        "map_name": map_name,
        "mapping": sorted(mapping.items()),
        "events": [event.__dict__ for event in events],
        "expected_meta": expected_pop_meta,
        "expected_tree_id": expected_tree_id,
        "expected_priority0": expected_priority0,
        "replay_mode": replay_mode,
    }
    fingerprint = hashlib.sha256(
        json.dumps(canonical, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return Fixture(
        name=name,
        events=events,
        expected_meta=expected_pop_meta,
        expected_tree_id=expected_tree_id,
        expected_priority0=expected_priority0,
        external_to_logical=tuple(sorted(mapping.items())),
        trace_path=trace_path.resolve(),
        reference_path=reference_path.resolve(),
        id_map_path=id_map_path.resolve(),
        config_manifest_path=config_manifest_path.resolve(),
        fingerprint=fingerprint,
        replay_mode=replay_mode,
    )


def _sv_array(values: list[int] | tuple[int, ...]) -> str:
    return "'{" + ", ".join(str(value) for value in values) + "}"


def render_sv_package(fixture: Fixture) -> str:
    fields = {
        "EVENT_KIND": [event.kind for event in fixture.events],
        "EVENT_IDLE_CYCLE": [event.idle_cycle for event in fixture.events],
        "EVENT_TREE_ID": [event.tree_id for event in fixture.events],
        "EVENT_META": [event.meta for event in fixture.events],
        "EVENT_PRIORITY0": [event.priority0 for event in fixture.events],
        "EVENT_PRIORITY1": [event.priority1 for event in fixture.events],
    }
    arrays = "\n".join(
        f"    localparam integer {field} [0:EVENT_COUNT-1] =\n"
        f"        {_sv_array(values)};"
        for field, values in fields.items()
    )
    return f"""`timescale 1ns / 1ps
// Generated by config/generate_legacy_trace_fixture.py.  Do not edit.
// Original trace: {fixture.trace_path.as_posix()}
// Original reference: {fixture.reference_path.as_posix()}
// Explicit ID map: {fixture.id_map_path.as_posix()}
// Fingerprint: {fixture.fingerprint}
package LegacyTracePkg;
    localparam string WORKLOAD_NAME = \"{fixture.name}\";
    localparam string REPLAY_MODE = \"{fixture.replay_mode}\";
    localparam integer PTW = {FIXTURE_PTW};
    localparam integer MTW = {FIXTURE_MTW};
    localparam integer EVENT_COUNT = {len(fixture.events)};
    localparam integer EXPECTED_POP_COUNT = {len(fixture.expected_meta)};
{arrays}
    localparam integer EXPECTED_META [0:EXPECTED_POP_COUNT-1] =
        {_sv_array(fixture.expected_meta)};
    localparam integer EXPECTED_TREE_ID [0:EXPECTED_POP_COUNT-1] =
        {_sv_array(fixture.expected_tree_id)};
    localparam integer EXPECTED_PRIORITY0 [0:EXPECTED_POP_COUNT-1] =
        {_sv_array(fixture.expected_priority0)};
endpackage
"""


def manifest_dict(fixture: Fixture) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "name": fixture.name,
        "fingerprint": fixture.fingerprint,
        "source_trace": fixture.trace_path.as_posix(),
        "source_reference": fixture.reference_path.as_posix(),
        "tree_id_map": fixture.id_map_path.as_posix(),
        "config_manifest": fixture.config_manifest_path.as_posix(),
        "external_to_logical": dict(fixture.external_to_logical),
        "event_count": len(fixture.events),
        "expected_pop_count": len(fixture.expected_meta),
        "expected_meta": list(fixture.expected_meta),
        "expected_tree_id": list(fixture.expected_tree_id),
        "expected_priority0": list(fixture.expected_priority0),
        "replay_mode": fixture.replay_mode,
    }


def generate(fixture: Fixture, output_dir: Path) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    outputs = {
        output_dir / "legacy_trace_pkg.sv": render_sv_package(fixture),
        output_dir / "legacy_trace_manifest.json": json.dumps(
            manifest_dict(fixture), indent=2, sort_keys=True
        )
        + "\n",
    }
    for path, content in outputs.items():
        if not path.exists() or path.read_text(encoding="utf-8") != content:
            path.write_text(content, encoding="utf-8", newline="\n")


def _parse_args() -> argparse.Namespace:
    config_dir = Path(__file__).resolve().parent
    rtl_dir = config_dir.parent
    repo_dir = rtl_dir.parents[1]
    parser = argparse.ArgumentParser(
        description="Generate a heterogeneous RTL fixture from an original vPIFO trace"
    )
    parser.add_argument("--name", required=True)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument(
        "--replay-mode",
        choices=("trace_prefix", "batch_reference"),
        default="trace_prefix",
        help="raw prefix replay or reference scheduling-order comparison",
    )
    parser.add_argument(
        "--tree-id-map", type=Path, default=config_dir / "legacy_tree_id_map.json"
    )
    parser.add_argument(
        "--config-manifest",
        type=Path,
        default=rtl_dir / "generated" / "vpifo_config_manifest.json",
    )
    parser.add_argument(
        "--output-dir", type=Path, default=rtl_dir / "generated"
    )
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        fixture = build_fixture(
            args.name,
            args.trace,
            args.reference,
            args.tree_id_map,
            args.config_manifest,
            args.replay_mode,
        )
        generate(fixture, args.output_dir)
    except (FixtureError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(
        f"generated legacy fixture {fixture.name}: events={len(fixture.events)} "
        f"expected_pops={len(fixture.expected_meta)} "
        f"id_map={dict(fixture.external_to_logical)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
