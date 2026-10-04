#!/usr/bin/env python3
"""Generate the two-domain VPIFO node layout and static connection table.

Schema version 2 describes schedule and timing VPIFOs as two specializations
of one compile-time node model.  They deliberately remain separate execution
domains: each domain gets an independent heterogeneous BMW layout, while a
timing node's ``release_to`` edge becomes a static timing-to-schedule table.

The existing schema-version-1 generator is reused for each physical domain so
its shard-capacity rules and safety checks remain the single source of truth.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from generate_vpifo_config import (
    ConfigError,
    Layout,
    NAME_RE,
    build_layout,
)


SCHEMA_VERSION = 2
KIND_SCHEDULE = 0
KIND_TIMING = 1
SUPPORTED_PROGRAMS = {
    "immediate",
    "virtual_clock",
    "absolute",
    "token_bucket",
}
PROGRAM_MODE = {
    "immediate": 0,
    "virtual_clock": 1,
    "absolute": 3,
    "token_bucket": 4,
}


def _non_negative_integer(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ConfigError(f"{field} must be a non-negative integer; got {value!r}")
    return value


def _positive_integer(value: Any, field: str) -> int:
    value = _non_negative_integer(value, field)
    if value == 0:
        raise ConfigError(f"{field} must be a positive integer; got {value!r}")
    return value


def _safe_id_width(item_count: int) -> int:
    return max(1, (item_count - 1).bit_length())


@dataclass(frozen=True)
class GeneralizedNode:
    global_id: int
    name: str
    kind: str
    capacity: int
    domain_local_id: int
    root: bool = False
    parent_global_id: int | None = None
    release_to_global_id: int | None = None
    program: str = "immediate"


@dataclass(frozen=True)
class GeneralizedLayout:
    name: str
    nodes: tuple[GeneralizedNode, ...]
    schedule_layout: Layout
    timing_layout: Layout
    schedule_to_global: tuple[int, ...]
    timing_to_global: tuple[int, ...]
    global_kind: tuple[int, ...]
    global_to_schedule: tuple[int, ...]
    global_to_timing: tuple[int, ...]
    timing_release_to_schedule: tuple[int, ...]
    timing_program_mode: tuple[int, ...]
    schedule_tree_roots: tuple[int, ...]
    schedule_node_parent: tuple[int, ...]
    schedule_node_tree_id: tuple[int, ...]
    schedule_node_is_root: tuple[int, ...]
    schedule_root_of_node: tuple[int, ...]
    schedule_tree_shard_offset: tuple[int, ...]
    schedule_tree_shard_count: tuple[int, ...]
    schedule_shard_partitioned: bool
    global_id_width: int

    @property
    def global_node_num(self) -> int:
        return len(self.nodes)


def _resolve_reference(
    value: Any,
    field: str,
    by_id: dict[int, dict[str, Any]],
    by_name: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    if isinstance(value, bool):
        raise ConfigError(f"{field} must name a VPIFO node")
    if isinstance(value, int):
        if value not in by_id:
            raise ConfigError(f"{field} references unknown node id {value}")
        return by_id[value]
    if isinstance(value, str):
        if value not in by_name:
            raise ConfigError(f"{field} references unknown node {value!r}")
        return by_name[value]
    raise ConfigError(f"{field} must be a node name or integer id")


def _domain_config(
    name: str,
    capacities: Iterable[int],
    domain_config: dict[str, Any],
) -> dict[str, Any]:
    if not isinstance(domain_config, dict):
        raise ConfigError(f"domains.{name} must be a JSON object")
    unknown = sorted(
        set(domain_config) -
        {"physical_shard", "resource_limits", "shard_partition"}
    )
    if unknown:
        raise ConfigError(
            f"unknown domains.{name} field(s): {', '.join(unknown)}"
        )
    return {
        "schema_version": 1,
        "name": name,
        "required_capacity": list(capacities),
        "physical_shard": domain_config.get("physical_shard", {}),
        "resource_limits": domain_config.get("resource_limits", {}),
    }


def build_generalized_layout(config: dict[str, Any]) -> GeneralizedLayout:
    if not isinstance(config, dict):
        raise ConfigError("top-level configuration must be a JSON object")
    allowed = {"schema_version", "name", "nodes", "domains"}
    unknown = sorted(set(config) - allowed)
    if unknown:
        raise ConfigError(f"unknown top-level field(s): {', '.join(unknown)}")
    if config.get("schema_version") != SCHEMA_VERSION:
        raise ConfigError(
            f"schema_version must be {SCHEMA_VERSION}; "
            f"got {config.get('schema_version')!r}"
        )

    name = config.get("name", "generalized_vpifo")
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        raise ConfigError("name may contain only letters, digits, and underscores")

    raw_nodes = config.get("nodes")
    if not isinstance(raw_nodes, list) or not raw_nodes:
        raise ConfigError("nodes must be a non-empty JSON array")

    normalized: list[dict[str, Any]] = []
    by_id: dict[int, dict[str, Any]] = {}
    by_name: dict[str, dict[str, Any]] = {}
    allowed_node = {
        "id", "name", "kind", "capacity", "root", "parent",
        "release_to", "program",
    }
    for index, raw in enumerate(raw_nodes):
        if not isinstance(raw, dict):
            raise ConfigError(f"nodes[{index}] must be a JSON object")
        unknown_node = sorted(set(raw) - allowed_node)
        if unknown_node:
            raise ConfigError(
                f"unknown nodes[{index}] field(s): {', '.join(unknown_node)}"
            )
        node_id = _non_negative_integer(raw.get("id"), f"nodes[{index}].id")
        node_name = raw.get("name")
        if not isinstance(node_name, str) or not NAME_RE.fullmatch(node_name):
            raise ConfigError(
                f"nodes[{index}].name may contain only letters, digits, and underscores"
            )
        kind = raw.get("kind")
        if kind not in ("schedule", "timing"):
            raise ConfigError(
                f"nodes[{index}].kind must be 'schedule' or 'timing'"
            )
        capacity = _positive_integer(raw.get("capacity"), f"nodes[{index}].capacity")
        if node_id in by_id:
            raise ConfigError(f"duplicate node id {node_id}")
        if node_name in by_name:
            raise ConfigError(f"duplicate node name {node_name!r}")
        node = dict(raw)
        node.update(id=node_id, name=node_name, kind=kind, capacity=capacity)
        normalized.append(node)
        by_id[node_id] = node
        by_name[node_name] = node

    expected_ids = list(range(len(normalized)))
    if sorted(by_id) != expected_ids:
        raise ConfigError(
            "node ids must be contiguous from 0 through "
            f"{len(normalized) - 1}"
        )
    # Global IDs, rather than JSON declaration order, define semantic tree
    # numbering and all generated local namespaces.
    normalized.sort(key=lambda node: node["id"])

    domains = config.get("domains", {})
    if not isinstance(domains, dict):
        raise ConfigError("domains must be a JSON object")
    unknown_domains = sorted(set(domains) - {"schedule", "timing"})
    if unknown_domains:
        raise ConfigError(f"unknown domain(s): {', '.join(unknown_domains)}")
    schedule_domain = domains.get("schedule", {})
    if not isinstance(schedule_domain, dict):
        raise ConfigError("domains.schedule must be a JSON object")
    schedule_partition_mode = schedule_domain.get(
        "shard_partition", "shared"
    )
    if schedule_partition_mode not in ("shared", "per_tree"):
        raise ConfigError(
            "domains.schedule.shard_partition must be 'shared' or 'per_tree'"
        )
    timing_domain = domains.get("timing", {})
    if (isinstance(timing_domain, dict) and
            "shard_partition" in timing_domain):
        raise ConfigError(
            "domains.timing.shard_partition is unsupported; timing logical "
            "VPIFOs share one timing execution domain"
        )

    roots = [
        node for node in normalized
        if node.get("root") is True and node["kind"] == "schedule"
    ]
    non_schedule_roots = [
        node for node in normalized
        if node.get("root") is True and node["kind"] != "schedule"
    ]
    if non_schedule_roots:
        raise ConfigError("only schedule nodes may have root=true")
    if not roots:
        raise ConfigError("at least one schedule node must have root=true")

    root_by_global = {node["id"]: node for node in roots}
    root_tree_id = {node["id"]: index for index, node in enumerate(roots)}
    schedule_nonroots = [
        node for node in normalized
        if node["kind"] == "schedule" and node not in roots
    ]
    parent_by_global: dict[int, dict[str, Any]] = {}
    children_by_root: dict[int, list[dict[str, Any]]] = {
        root["id"]: [] for root in roots
    }
    for node in schedule_nonroots:
        path = f"nodes[{node['id']}]"
        if "parent" not in node:
            raise ConfigError(f"{path}: schedule leaf requires parent")
        parent = _resolve_reference(
            node["parent"], f"{path}.parent", by_id, by_name
        )
        if parent["id"] not in root_by_global:
            raise ConfigError(
                f"{path}.parent must be a schedule root; the current RTL "
                "implements a forest of root-plus-leaf scheduling trees"
            )
        parent_by_global[node["id"]] = parent
        children_by_root[parent["id"]].append(node)
    for root in roots:
        if "parent" in root:
            raise ConfigError(
                f"nodes[{root['id']}]: root schedule node cannot have a parent"
            )
        if not children_by_root[root["id"]]:
            raise ConfigError(
                f"schedule root {root['name']!r} must have at least one leaf"
            )

    if schedule_partition_mode == "per_tree":
        schedule_raw = []
        for root in roots:
            schedule_raw.append(root)
            schedule_raw.extend(children_by_root[root["id"]])
    else:
        # Preserve the original single-root ordering and keep roots easy to
        # identify without imposing a physical per-tree shard partition.
        schedule_raw = roots + schedule_nonroots
    timing_raw = [node for node in normalized if node["kind"] == "timing"]
    if not timing_raw:
        raise ConfigError("the timing execution domain requires at least one node")

    schedule_local = {node["id"]: index for index, node in enumerate(schedule_raw)}
    timing_local = {node["id"]: index for index, node in enumerate(timing_raw)}
    schedule_tree_roots = tuple(schedule_local[root["id"]] for root in roots)
    schedule_node_parent_list: list[int] = []
    schedule_node_tree_id_list: list[int] = []
    schedule_node_is_root_list: list[int] = []
    schedule_root_of_node_list: list[int] = []
    for schedule_node in schedule_raw:
        if schedule_node["id"] in root_by_global:
            parent_local = schedule_local[schedule_node["id"]]
            tree_id = root_tree_id[schedule_node["id"]]
            is_root = 1
        else:
            parent = parent_by_global[schedule_node["id"]]
            parent_local = schedule_local[parent["id"]]
            tree_id = root_tree_id[parent["id"]]
            is_root = 0
        schedule_node_parent_list.append(parent_local)
        schedule_node_tree_id_list.append(tree_id)
        schedule_node_is_root_list.append(is_root)
        schedule_root_of_node_list.append(schedule_tree_roots[tree_id])

    nodes_by_global: list[GeneralizedNode | None] = [None] * len(normalized)
    release_targets: list[int] = []
    timing_program_modes: list[int] = []
    for node in normalized:
        path = f"nodes[{node['id']}]"
        is_root = node["id"] in root_by_global
        if node["kind"] == "schedule":
            if "release_to" in node:
                raise ConfigError(f"{path}.release_to is valid only for timing nodes")
            if "program" in node and node["program"] != "immediate":
                raise ConfigError(
                    f"{path}.program is a shaping-transaction property"
                )
            parent_id = None if is_root else parent_by_global[node["id"]]["id"]
            generalized = GeneralizedNode(
                node["id"], node["name"], node["kind"], node["capacity"],
                schedule_local[node["id"]], is_root, parent_id,
            )
        else:
            if node.get("root"):
                raise ConfigError(f"{path}: timing node cannot be the schedule root")
            if "parent" in node:
                raise ConfigError(
                    f"{path}.parent is ambiguous for timing nodes; use release_to"
                )
            if "release_to" not in node:
                raise ConfigError(f"{path}: timing node requires release_to")
            target = _resolve_reference(
                node["release_to"], f"{path}.release_to", by_id, by_name
            )
            if (target["kind"] != "schedule" or
                    target["id"] in root_by_global):
                raise ConfigError(
                    f"{path}.release_to must reference a non-root schedule leaf"
                )
            program = node.get("program", "immediate")
            if program not in SUPPORTED_PROGRAMS:
                raise ConfigError(
                    f"{path}.program must be one of {sorted(SUPPORTED_PROGRAMS)}"
                )
            target_local = schedule_local[target["id"]]
            release_targets.append(target_local)
            timing_program_modes.append(PROGRAM_MODE[program])
            generalized = GeneralizedNode(
                node["id"], node["name"], node["kind"], node["capacity"],
                timing_local[node["id"]], False, None, target["id"], program,
            )
        nodes_by_global[node["id"]] = generalized

    schedule_layout = build_layout(_domain_config(
        f"{name}_schedule",
        (node["capacity"] for node in schedule_raw),
        domains.get("schedule", {}),
    ))
    timing_layout = build_layout(_domain_config(
        f"{name}_timing",
        (node["capacity"] for node in timing_raw),
        domains.get("timing", {}),
    ))

    schedule_tree_shard_offset: list[int] = []
    schedule_tree_shard_count: list[int] = []
    for tree_id, root in enumerate(roots):
        local_nodes = [
            local_id for local_id, node in enumerate(schedule_raw)
            if schedule_node_tree_id_list[local_id] == tree_id
        ]
        physical_ids: list[int] = []
        for local_id in local_nodes:
            offset = schedule_layout.shard_offset[local_id]
            count = schedule_layout.shard_count[local_id]
            physical_ids.extend(range(offset, offset + count))
        schedule_tree_shard_offset.append(min(physical_ids))
        schedule_tree_shard_count.append(len(physical_ids))
        if schedule_partition_mode == "per_tree":
            expected = list(range(min(physical_ids), max(physical_ids) + 1))
            if physical_ids != expected:
                raise ConfigError(
                    f"per_tree shard partition for schedule tree {tree_id} "
                    "is not contiguous"
                )

    global_kind = tuple(
        KIND_SCHEDULE if node["kind"] == "schedule" else KIND_TIMING
        for node in sorted(normalized, key=lambda item: item["id"])
    )
    global_to_schedule = tuple(
        schedule_local.get(global_id, 0) for global_id in range(len(normalized))
    )
    global_to_timing = tuple(
        timing_local.get(global_id, 0) for global_id in range(len(normalized))
    )
    final_nodes = tuple(node for node in nodes_by_global if node is not None)

    return GeneralizedLayout(
        name=name,
        nodes=final_nodes,
        schedule_layout=schedule_layout,
        timing_layout=timing_layout,
        schedule_to_global=tuple(node["id"] for node in schedule_raw),
        timing_to_global=tuple(node["id"] for node in timing_raw),
        global_kind=global_kind,
        global_to_schedule=global_to_schedule,
        global_to_timing=global_to_timing,
        timing_release_to_schedule=tuple(release_targets),
        timing_program_mode=tuple(timing_program_modes),
        schedule_tree_roots=schedule_tree_roots,
        schedule_node_parent=tuple(schedule_node_parent_list),
        schedule_node_tree_id=tuple(schedule_node_tree_id_list),
        schedule_node_is_root=tuple(schedule_node_is_root_list),
        schedule_root_of_node=tuple(schedule_root_of_node_list),
        schedule_tree_shard_offset=tuple(schedule_tree_shard_offset),
        schedule_tree_shard_count=tuple(schedule_tree_shard_count),
        schedule_shard_partitioned=(schedule_partition_mode == "per_tree"),
        global_id_width=_safe_id_width(len(normalized)),
    )


def _sv_array(values: Iterable[int]) -> str:
    return "'{" + ", ".join(str(value) for value in values) + "}"


def render_sv_package(layout: GeneralizedLayout, source_path: Path) -> str:
    schedule = layout.schedule_layout
    timing = layout.timing_layout
    return f"""`timescale 1ns / 1ps
// Generated by config/generate_generalized_vpifo_config.py.  Do not edit.
// Source: {source_path.as_posix()}
package GeneralizedVpifoConfigPkg;
    localparam integer VPIFO_KIND_SCHEDULE = {KIND_SCHEDULE};
    localparam integer VPIFO_KIND_TIMING = {KIND_TIMING};
    localparam integer GLOBAL_NODE_NUM = {layout.global_node_num};
    localparam integer GLOBAL_ID_WIDTH = {layout.global_id_width};

    localparam integer SCHEDULE_LOGICAL_TREE_NUM = {schedule.logical_tree_num};
    // A semantic schedule tree is a root plus its direct child PIFOs.  All
    // semantic trees below share this schedule domain's physical BMW engine.
    localparam integer SCHEDULE_SEMANTIC_TREE_NUM = {len(layout.schedule_tree_roots)};
    localparam integer SCHEDULE_TREE_ID_WIDTH = {_safe_id_width(len(layout.schedule_tree_roots))};
    // When set, each semantic tree owns one contiguous, non-overlapping range
    // of physical shard IDs.  This partitions storage, not the shared RPUs.
    localparam integer SCHEDULE_SHARD_PARTITIONED = {int(layout.schedule_shard_partitioned)};
    localparam integer SCHEDULE_PHYSICAL_TREE_NUM = {schedule.physical_tree_num};
    localparam integer SCHEDULE_LEVEL = {schedule.shard_level};
    localparam integer SCHEDULE_SHARD_CAPACITY = {schedule.shard_capacity};
    localparam integer SCHEDULE_MAX_SHARDS_PER_LOGICAL = {schedule.max_shards_per_logical};
    localparam integer SCHEDULE_SHARD_COUNTS [0:SCHEDULE_LOGICAL_TREE_NUM-1] =
        {_sv_array(schedule.shard_count)};
    localparam integer SCHEDULE_SHARD_OFFSETS [0:SCHEDULE_LOGICAL_TREE_NUM-1] =
        {_sv_array(schedule.shard_offset)};
    localparam integer SCHEDULE_EXPLICIT_SHARD_MAP [0:SCHEDULE_PHYSICAL_TREE_NUM-1] =
        {_sv_array(range(schedule.physical_tree_num))};
    localparam integer SCHEDULE_TREE_ROOTS [0:SCHEDULE_SEMANTIC_TREE_NUM-1] =
        {_sv_array(layout.schedule_tree_roots)};
    localparam integer SCHEDULE_NODE_PARENT [0:SCHEDULE_LOGICAL_TREE_NUM-1] =
        {_sv_array(layout.schedule_node_parent)};
    localparam integer SCHEDULE_NODE_TREE_ID [0:SCHEDULE_LOGICAL_TREE_NUM-1] =
        {_sv_array(layout.schedule_node_tree_id)};
    localparam integer SCHEDULE_NODE_IS_ROOT [0:SCHEDULE_LOGICAL_TREE_NUM-1] =
        {_sv_array(layout.schedule_node_is_root)};
    localparam integer SCHEDULE_ROOT_OF_NODE [0:SCHEDULE_LOGICAL_TREE_NUM-1] =
        {_sv_array(layout.schedule_root_of_node)};
    localparam integer SCHEDULE_TREE_SHARD_OFFSETS [0:SCHEDULE_SEMANTIC_TREE_NUM-1] =
        {_sv_array(layout.schedule_tree_shard_offset)};
    localparam integer SCHEDULE_TREE_SHARD_COUNTS [0:SCHEDULE_SEMANTIC_TREE_NUM-1] =
        {_sv_array(layout.schedule_tree_shard_count)};

    localparam integer TIMING_LOGICAL_TREE_NUM = {timing.logical_tree_num};
    localparam integer TIMING_PHYSICAL_TREE_NUM = {timing.physical_tree_num};
    localparam integer TIMING_LEVEL = {timing.shard_level};
    localparam integer TIMING_SHARD_CAPACITY = {timing.shard_capacity};
    localparam integer TIMING_MAX_SHARDS_PER_LOGICAL = {timing.max_shards_per_logical};
    localparam integer TIMING_SHARD_COUNTS [0:TIMING_LOGICAL_TREE_NUM-1] =
        {_sv_array(timing.shard_count)};
    localparam integer TIMING_SHARD_OFFSETS [0:TIMING_LOGICAL_TREE_NUM-1] =
        {_sv_array(timing.shard_offset)};
    localparam integer TIMING_EXPLICIT_SHARD_MAP [0:TIMING_PHYSICAL_TREE_NUM-1] =
        {_sv_array(range(timing.physical_tree_num))};

    localparam integer GLOBAL_NODE_KIND [0:GLOBAL_NODE_NUM-1] =
        {_sv_array(layout.global_kind)};
    localparam integer GLOBAL_TO_SCHEDULE [0:GLOBAL_NODE_NUM-1] =
        {_sv_array(layout.global_to_schedule)};
    localparam integer GLOBAL_TO_TIMING [0:GLOBAL_NODE_NUM-1] =
        {_sv_array(layout.global_to_timing)};
    localparam integer SCHEDULE_TO_GLOBAL [0:SCHEDULE_LOGICAL_TREE_NUM-1] =
        {_sv_array(layout.schedule_to_global)};
    localparam integer TIMING_TO_GLOBAL [0:TIMING_LOGICAL_TREE_NUM-1] =
        {_sv_array(layout.timing_to_global)};
    localparam integer TIMING_RELEASE_TO_SCHEDULE [0:TIMING_LOGICAL_TREE_NUM-1] =
        {_sv_array(layout.timing_release_to_schedule)};
    localparam integer TIMING_PROGRAM_MODE [0:TIMING_LOGICAL_TREE_NUM-1] =
        {_sv_array(layout.timing_program_mode)};
endpackage
"""


def _domain_manifest(layout: Layout) -> dict[str, Any]:
    return {
        "logical_tree_num": layout.logical_tree_num,
        "physical_tree_num": layout.physical_tree_num,
        "level": layout.shard_level,
        "shard_capacity": layout.shard_capacity,
        "required_capacity": list(layout.required_capacity),
        "shard_counts": list(layout.shard_count),
        "shard_offsets": list(layout.shard_offset),
        "physical_to_logical": list(layout.physical_to_logical),
    }


def manifest_dict(layout: GeneralizedLayout, source_path: Path) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "source": source_path.as_posix(),
        "name": layout.name,
        "execution_model": "two_independent_domains_with_static_release_edges",
        "schedule_topology": "root_plus_leaf_forest",
        "global_node_num": layout.global_node_num,
        "global_id_width": layout.global_id_width,
        "nodes": [
            {
                "id": node.global_id,
                "name": node.name,
                "kind": node.kind,
                "capacity": node.capacity,
                "domain_local_id": node.domain_local_id,
                "root": node.root,
                "parent": node.parent_global_id,
                "release_to": node.release_to_global_id,
                "program": node.program,
            }
            for node in layout.nodes
        ],
        "schedule_domain": {
            **_domain_manifest(layout.schedule_layout),
            "shard_partition": (
                "per_tree" if layout.schedule_shard_partitioned else "shared"
            ),
            "shard_partition_scope": "storage_only_shared_rpus",
        },
        "timing_domain": _domain_manifest(layout.timing_layout),
        "schedule_forest": {
            "semantic_tree_num": len(layout.schedule_tree_roots),
            "tree_roots": list(layout.schedule_tree_roots),
            "node_parent": list(layout.schedule_node_parent),
            "node_tree_id": list(layout.schedule_node_tree_id),
            "node_is_root": list(layout.schedule_node_is_root),
            "root_of_node": list(layout.schedule_root_of_node),
            "tree_shard_offsets": list(layout.schedule_tree_shard_offset),
            "tree_shard_counts": list(layout.schedule_tree_shard_count),
        },
        "connection_table": [
            {
                "timing_local_id": timing_local,
                "timing_global_id": layout.timing_to_global[timing_local],
                "schedule_local_id": schedule_local,
                "schedule_global_id": layout.schedule_to_global[schedule_local],
                "program_mode": layout.timing_program_mode[timing_local],
            }
            for timing_local, schedule_local in enumerate(
                layout.timing_release_to_schedule
            )
        ],
    }


def render_tcl(layout: GeneralizedLayout, source_path: Path) -> str:
    return f"""# Generated by config/generate_generalized_vpifo_config.py.  Do not edit.
# Source: {source_path.as_posix()}
set generalized_vpifo_name {layout.name}
set generalized_vpifo_global_node_num {layout.global_node_num}
set generalized_vpifo_schedule_logical_num {layout.schedule_layout.logical_tree_num}
set generalized_vpifo_schedule_semantic_tree_num {len(layout.schedule_tree_roots)}
set generalized_vpifo_schedule_shard_partitioned {int(layout.schedule_shard_partitioned)}
set generalized_vpifo_schedule_physical_num {layout.schedule_layout.physical_tree_num}
set generalized_vpifo_timing_logical_num {layout.timing_layout.logical_tree_num}
set generalized_vpifo_timing_physical_num {layout.timing_layout.physical_tree_num}
"""


def _write_if_changed(path: Path, content: str) -> None:
    if path.exists() and path.read_text(encoding="utf-8") == content:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")


def generate(
    config_path: Path, output_dir: Path, check_only: bool = False
) -> GeneralizedLayout:
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ConfigError(f"configuration file does not exist: {config_path}") from error
    except json.JSONDecodeError as error:
        raise ConfigError(
            f"invalid JSON in {config_path}: line {error.lineno}, "
            f"column {error.colno}: {error.msg}"
        ) from error

    layout = build_generalized_layout(config)
    source_path = config_path.resolve()
    outputs = {
        output_dir / "generalized_vpifo_config_pkg.sv":
            render_sv_package(layout, source_path),
        output_dir / "generalized_vpifo_config.tcl":
            render_tcl(layout, source_path),
        output_dir / "generalized_vpifo_config_manifest.json":
            json.dumps(manifest_dict(layout, source_path), indent=2, sort_keys=True)
            + "\n",
    }
    stale = [
        str(path) for path, content in outputs.items()
        if not path.exists() or path.read_text(encoding="utf-8") != content
    ]
    if check_only and stale:
        raise ConfigError("generated output is stale: " + ", ".join(stale))
    if not check_only:
        for path, content in outputs.items():
            _write_if_changed(path, content)
    return layout


def _parse_args() -> argparse.Namespace:
    config_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(
        description="Generate generalized schedule/timing VPIFO RTL configuration"
    )
    parser.add_argument(
        "--config", type=Path,
        default=config_dir / "generalized_vpifo_config.json",
    )
    parser.add_argument(
        "--output-dir", type=Path,
        default=config_dir.parent / "generated",
    )
    parser.add_argument("--check", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        layout = generate(args.config.resolve(), args.output_dir.resolve(), args.check)
    except (ConfigError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(
        f"generated {layout.name}: nodes={layout.global_node_num} "
        f"schedule={layout.schedule_layout.logical_tree_num}/"
        f"{layout.schedule_layout.physical_tree_num} "
        f"timing={layout.timing_layout.logical_tree_num}/"
        f"{layout.timing_layout.physical_tree_num}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
