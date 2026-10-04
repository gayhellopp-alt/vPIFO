#!/usr/bin/env python3
"""Compile Java-like VPIFO annotations into schema-version-2 JSON IR.

The annotation is a compile-time type marker, not a runtime RTL tag.  The
resulting JSON is consumed by ``generate_generalized_vpifo_config.py``, which
creates two physical execution-domain layouts and their static connection
table.
"""

from __future__ import annotations

import argparse
import ast
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any


ANNOTATION_RE = re.compile(r"^@(ScheduleVPIFO|TimingVPIFO)\s*\((.*)\)\s*$")
DECLARATION_RE = re.compile(r"^vpifo\s+([A-Za-z_][A-Za-z0-9_]*)\s*;\s*$")
NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")
SUPPORTED_TIMING_PROGRAMS = {
    "immediate",
    "virtual_clock",
    "absolute",
    "token_bucket",
}


class AnnotationError(ValueError):
    """The source cannot be translated into the generalized VPIFO IR."""


def _literal(node: ast.AST, field: str) -> Any:
    if isinstance(node, ast.Constant) and isinstance(
        node.value, (str, int, bool)
    ):
        return node.value
    if isinstance(node, ast.Name) and node.id in ("true", "false"):
        return node.id == "true"
    raise AnnotationError(
        f"annotation argument {field} must be a string, integer, or boolean literal"
    )


def _parse_arguments(text: str, line_number: int) -> dict[str, Any]:
    try:
        expression = ast.parse(f"_annotation({text})", mode="eval").body
    except SyntaxError as error:
        raise AnnotationError(
            f"line {line_number}: invalid annotation arguments: {error.msg}"
        ) from error
    if not isinstance(expression, ast.Call) or expression.args:
        raise AnnotationError(
            f"line {line_number}: annotation accepts named arguments only"
        )
    result: dict[str, Any] = {}
    for keyword in expression.keywords:
        if keyword.arg is None:
            raise AnnotationError(
                f"line {line_number}: annotation expansion is not supported"
            )
        if keyword.arg in result:
            raise AnnotationError(
                f"line {line_number}: duplicate argument {keyword.arg}"
            )
        result[keyword.arg] = _literal(keyword.value, keyword.arg)
    return result


def _clean_lines(source: str) -> list[tuple[int, str]]:
    cleaned: list[tuple[int, str]] = []
    for line_number, original in enumerate(source.splitlines(), 1):
        line = original.split("//", 1)[0].strip()
        if line:
            cleaned.append((line_number, line))
    return cleaned


def compile_source(
    source: str,
    *,
    name: str = "annotated_vpifo",
    schedule_level: int = 4,
    timing_level: int = 4,
    schedule_shard_partition: str = "shared",
    max_logical_pifos: int = 64,
    max_physical_shards: int = 64,
) -> dict[str, Any]:
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        raise AnnotationError("configuration name is not a valid identifier")
    for value, field in (
        (schedule_level, "schedule_level"),
        (timing_level, "timing_level"),
        (max_logical_pifos, "max_logical_pifos"),
        (max_physical_shards, "max_physical_shards"),
    ):
        if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
            raise AnnotationError(f"{field} must be a positive integer")
    if schedule_shard_partition not in ("shared", "per_tree"):
        raise AnnotationError(
            "schedule_shard_partition must be 'shared' or 'per_tree'"
        )

    lines = _clean_lines(source)
    nodes: list[dict[str, Any]] = []
    index = 0
    while index < len(lines):
        annotation_line_number, annotation_line = lines[index]
        match = ANNOTATION_RE.fullmatch(annotation_line)
        if not match:
            raise AnnotationError(
                f"line {annotation_line_number}: expected @ScheduleVPIFO or "
                "@TimingVPIFO annotation"
            )
        if index + 1 >= len(lines):
            raise AnnotationError(
                f"line {annotation_line_number}: annotation has no vpifo declaration"
            )
        declaration_line_number, declaration_line = lines[index + 1]
        declaration = DECLARATION_RE.fullmatch(declaration_line)
        if not declaration:
            raise AnnotationError(
                f"line {declaration_line_number}: expected 'vpifo <name>;'"
            )

        annotation_type = match.group(1)
        arguments = _parse_arguments(match.group(2), annotation_line_number)
        declaration_name = declaration.group(1)
        common = {"id", "capacity"}
        if annotation_type == "ScheduleVPIFO":
            allowed = common | {"root", "parent"}
            kind = "schedule"
        else:
            allowed = common | {"releaseTo", "program"}
            kind = "timing"
        unknown = sorted(set(arguments) - allowed)
        if unknown:
            raise AnnotationError(
                f"line {annotation_line_number}: unknown {annotation_type} "
                f"argument(s): {', '.join(unknown)}"
            )
        if "capacity" not in arguments:
            raise AnnotationError(
                f"line {annotation_line_number}: capacity is required"
            )
        capacity = arguments["capacity"]
        if isinstance(capacity, bool) or not isinstance(capacity, int) or capacity <= 0:
            raise AnnotationError(
                f"line {annotation_line_number}: capacity must be a positive integer"
            )

        node: dict[str, Any] = {
            "name": declaration_name,
            "kind": kind,
            "capacity": capacity,
        }
        if "id" in arguments:
            node_id = arguments["id"]
            if isinstance(node_id, bool) or not isinstance(node_id, int) or node_id < 0:
                raise AnnotationError(
                    f"line {annotation_line_number}: id must be a non-negative integer"
                )
            node["id"] = node_id
        if annotation_type == "ScheduleVPIFO":
            if "root" in arguments:
                if not isinstance(arguments["root"], bool):
                    raise AnnotationError(
                        f"line {annotation_line_number}: root must be boolean"
                    )
                node["root"] = arguments["root"]
            if "parent" in arguments:
                node["parent"] = arguments["parent"]
        else:
            if "releaseTo" not in arguments:
                raise AnnotationError(
                    f"line {annotation_line_number}: releaseTo is required"
                )
            node["release_to"] = arguments["releaseTo"]
            if "program" in arguments:
                program = arguments["program"]
                if program not in SUPPORTED_TIMING_PROGRAMS:
                    supported = ", ".join(sorted(SUPPORTED_TIMING_PROGRAMS))
                    raise AnnotationError(
                        f"line {annotation_line_number}: program must be one of: "
                        f"{supported}"
                    )
                node["program"] = program
        nodes.append(node)
        index += 2

    if not nodes:
        raise AnnotationError("source declares no VPIFO nodes")
    names = [node["name"] for node in nodes]
    if len(names) != len(set(names)):
        raise AnnotationError("VPIFO declaration names must be unique")

    explicit_ids = [node["id"] for node in nodes if "id" in node]
    if len(explicit_ids) != len(set(explicit_ids)):
        raise AnnotationError("explicit VPIFO ids must be unique")
    used_ids = set(explicit_ids)
    next_id = 0
    for node in nodes:
        if "id" not in node:
            while next_id in used_ids:
                next_id += 1
            node["id"] = next_id
            used_ids.add(next_id)
            next_id += 1
    if sorted(used_ids) != list(range(len(nodes))):
        raise AnnotationError(
            "explicit and inferred VPIFO ids must form a contiguous range from zero"
        )

    nodes.sort(key=lambda node: node["id"])
    limits = {
        "max_logical_pifos": max_logical_pifos,
        "max_physical_shards": max_physical_shards,
    }
    return {
        "schema_version": 2,
        "name": name,
        "nodes": nodes,
        "domains": {
            "schedule": {
                "physical_shard": {"order": 2, "level": schedule_level},
                "shard_partition": schedule_shard_partition,
                "resource_limits": limits.copy(),
            },
            "timing": {
                "physical_shard": {"order": 2, "level": timing_level},
                "resource_limits": limits.copy(),
            },
        },
    }


def _parse_args() -> argparse.Namespace:
    repository = Path(__file__).resolve().parents[3]
    default_generator = repository / "hardware" / "BMW_PIFO_SRAM_vPIFO" / \
        "config" / "generate_generalized_vpifo_config.py"
    parser = argparse.ArgumentParser(
        description="Compile VPIFO subclass annotations into generalized JSON IR"
    )
    parser.add_argument("source", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--name", default="annotated_vpifo")
    parser.add_argument("--schedule-level", type=int, default=4)
    parser.add_argument("--timing-level", type=int, default=4)
    parser.add_argument(
        "--schedule-shard-partition",
        choices=("shared", "per_tree"),
        default="shared",
        help="group each semantic schedule tree into its own contiguous shard range",
    )
    parser.add_argument("--max-logical-pifos", type=int, default=64)
    parser.add_argument("--max-physical-shards", type=int, default=64)
    parser.add_argument(
        "--rtl-output-dir", type=Path,
        help="also invoke the RTL generator into this directory",
    )
    parser.add_argument("--generator", type=Path, default=default_generator)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    try:
        source = args.source.read_text(encoding="utf-8")
        config = compile_source(
            source,
            name=args.name,
            schedule_level=args.schedule_level,
            timing_level=args.timing_level,
            schedule_shard_partition=args.schedule_shard_partition,
            max_logical_pifos=args.max_logical_pifos,
            max_physical_shards=args.max_physical_shards,
        )
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            json.dumps(config, indent=2) + "\n", encoding="utf-8", newline="\n"
        )
        if args.rtl_output_dir is not None:
            completed = subprocess.run(
                [
                    sys.executable,
                    str(args.generator.resolve()),
                    "--config", str(args.output.resolve()),
                    "--output-dir", str(args.rtl_output_dir.resolve()),
                ],
                check=False,
            )
            if completed.returncode != 0:
                return completed.returncode
    except (AnnotationError, OSError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2
    print(f"compiled {len(config['nodes'])} VPIFO annotations to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
