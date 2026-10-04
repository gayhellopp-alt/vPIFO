#!/usr/bin/env python3

import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("generate_legacy_trace_fixture.py")
SPEC = importlib.util.spec_from_file_location("legacy_fixture_generator", MODULE_PATH)
assert SPEC and SPEC.loader
GEN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GEN
SPEC.loader.exec_module(GEN)


class LegacyTraceFixtureTests(unittest.TestCase):
    def setUp(self):
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.trace = self.root / "workload.trace"
        self.reference = self.root / "workload.ref"
        self.id_map = self.root / "id_map.json"
        self.manifest = self.root / "vpifo_config_manifest.json"
        self.trace.write_text(
            "type:0, idle_cycle:3\n"
            "type:1, tree_id:10, meta:0, priority0:7, priority1:2\n"
            "type:2\n"
            "type:1, tree_id:20, meta:1, priority0:5, priority1:1\n"
            "type:2\n",
            encoding="utf-8",
        )
        self.reference.write_text(
            "meta:0, push_cyc:0\n"
            "meta:1, push_cyc:1\n"
            "meta:1, pop_cyc:0\n"
            "meta:0, pop_cyc:1\n",
            encoding="utf-8",
        )
        self.id_map.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "name": "unit_map",
                    "external_to_logical": {"10": 1, "20": 2},
                }
            ),
            encoding="utf-8",
        )
        self.manifest.write_text(
            json.dumps({"logical_tree_num": 3}), encoding="utf-8"
        )

    def tearDown(self):
        self.temp_dir.cleanup()

    def build(self, mode="batch_reference"):
        return GEN.build_fixture(
            "unit_workload",
            self.trace,
            self.reference,
            self.id_map,
            self.manifest,
            mode,
        )

    def test_batch_reference_uses_explicit_ids_and_rank_reference(self):
        fixture = self.build()
        self.assertEqual([event.kind for event in fixture.events], [1, 1, 3, 2, 2])
        self.assertEqual([event.tree_id for event in fixture.events[:2]], [1, 2])
        self.assertEqual(fixture.expected_meta, (1, 0))
        self.assertEqual(fixture.expected_tree_id, (2, 1))
        self.assertEqual(fixture.expected_priority0, (5, 7))

    def test_trace_prefix_preserves_input_operations(self):
        fixture = self.build("trace_prefix")
        self.assertEqual([event.kind for event in fixture.events], [0, 1, 2, 1, 2])

    def test_unmapped_external_tree_is_rejected(self):
        self.trace.write_text(
            "type:1, tree_id:30, meta:0, priority0:7, priority1:2\n"
            "type:1, tree_id:20, meta:1, priority0:5, priority1:1\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(GEN.FixtureError, "unmapped external tree ID 30"):
            self.build()

    def test_mapping_outside_generated_logical_range_is_rejected(self):
        self.manifest.write_text(
            json.dumps({"logical_tree_num": 2}), encoding="utf-8"
        )
        with self.assertRaisesRegex(GEN.FixtureError, "only 2 logical PIFOs"):
            self.build()

    def test_duplicate_target_logical_id_is_rejected(self):
        self.id_map.write_text(
            json.dumps(
                {
                    "external_to_logical": {"10": 1, "20": 1},
                }
            ),
            encoding="utf-8",
        )
        with self.assertRaisesRegex(GEN.FixtureError, "duplicate target logical ID 1"):
            self.build()

    def test_width_overflow_is_rejected(self):
        self.trace.write_text(
            f"type:1, tree_id:10, meta:0, priority0:{1 << GEN.FIXTURE_PTW}, priority1:2\n"
            "type:1, tree_id:20, meta:1, priority0:5, priority1:1\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(GEN.FixtureError, "exceeds PTW"):
            self.build()

    def test_generated_package_is_deterministic(self):
        first = GEN.render_sv_package(self.build())
        second = GEN.render_sv_package(self.build())
        self.assertEqual(first, second)


if __name__ == "__main__":
    unittest.main()
