import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


CONFIG_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(CONFIG_DIR))
SCRIPT = CONFIG_DIR / "generate_generalized_vpifo_config.py"
SPEC = importlib.util.spec_from_file_location("generate_generalized_vpifo_config", SCRIPT)
assert SPEC and SPEC.loader
GEN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GEN
SPEC.loader.exec_module(GEN)


def valid_config():
    return {
        "schema_version": 2,
        "name": "unit",
        "nodes": [
            {"id": 0, "name": "leaf_b", "kind": "schedule", "capacity": 30,
             "parent": "root"},
            {"id": 1, "name": "shape_a", "kind": "timing", "capacity": 31,
             "release_to": "leaf_a", "program": "virtual_clock"},
            {"id": 2, "name": "root", "kind": "schedule", "capacity": 60,
             "root": True},
            {"id": 3, "name": "leaf_a", "kind": "schedule", "capacity": 30,
             "parent": 2},
            {"id": 4, "name": "shape_b", "kind": "timing", "capacity": 30,
             "release_to": 0, "program": "absolute"},
        ],
        "domains": {
            "schedule": {"physical_shard": {"order": 2, "level": 4}},
            "timing": {"physical_shard": {"order": 2, "level": 4}},
        },
    }


def forest_config(partition="per_tree"):
    return {
        "schema_version": 2,
        "name": "forest_unit",
        "nodes": [
            {"id": 0, "name": "root_a", "kind": "schedule",
             "capacity": 60, "root": True},
            {"id": 1, "name": "leaf_a", "kind": "schedule",
             "capacity": 30, "parent": "root_a"},
            {"id": 2, "name": "root_b", "kind": "schedule",
             "capacity": 30, "root": True},
            {"id": 3, "name": "leaf_b", "kind": "schedule",
             "capacity": 60, "parent": "root_b"},
            {"id": 4, "name": "shape_a", "kind": "timing",
             "capacity": 31, "release_to": "leaf_a"},
            {"id": 5, "name": "shape_b", "kind": "timing",
             "capacity": 30, "release_to": "leaf_b"},
        ],
        "domains": {
            "schedule": {
                "physical_shard": {"order": 2, "level": 4},
                "shard_partition": partition,
            },
            "timing": {"physical_shard": {"order": 2, "level": 4}},
        },
    }


class GeneralizedLayoutTest(unittest.TestCase):
    def test_root_is_schedule_local_zero_and_edges_are_localized(self):
        layout = GEN.build_generalized_layout(valid_config())
        self.assertEqual(layout.schedule_to_global, (2, 0, 3))
        self.assertEqual(layout.timing_to_global, (1, 4))
        self.assertEqual(layout.global_to_schedule, (1, 0, 0, 2, 0))
        self.assertEqual(layout.global_to_timing, (0, 0, 0, 0, 1))
        self.assertEqual(layout.timing_release_to_schedule, (2, 1))
        self.assertEqual(layout.timing_program_mode, (1, 3))
        self.assertEqual(layout.schedule_layout.shard_count, (2, 1, 1))
        self.assertEqual(layout.timing_layout.shard_count, (2, 1))
        self.assertEqual(layout.schedule_tree_roots, (0,))
        self.assertEqual(layout.schedule_node_parent, (0, 0, 0))
        self.assertEqual(layout.schedule_node_tree_id, (0, 0, 0))
        self.assertEqual(layout.schedule_node_is_root, (1, 0, 0))

    def test_multiple_schedule_trees_with_contiguous_shard_partition(self):
        layout = GEN.build_generalized_layout(forest_config())
        self.assertEqual(layout.schedule_to_global, (0, 1, 2, 3))
        self.assertEqual(layout.schedule_tree_roots, (0, 2))
        self.assertEqual(layout.schedule_node_parent, (0, 0, 2, 2))
        self.assertEqual(layout.schedule_node_tree_id, (0, 0, 1, 1))
        self.assertEqual(layout.schedule_node_is_root, (1, 0, 1, 0))
        self.assertEqual(layout.schedule_root_of_node, (0, 0, 2, 2))
        self.assertEqual(layout.schedule_layout.shard_count, (2, 1, 1, 2))
        self.assertEqual(layout.schedule_tree_shard_offset, (0, 3))
        self.assertEqual(layout.schedule_tree_shard_count, (3, 3))
        self.assertTrue(layout.schedule_shard_partitioned)
        manifest = GEN.manifest_dict(layout, Path("forest.json"))
        self.assertEqual(manifest["schedule_domain"]["shard_partition"],
                         "per_tree")
        self.assertEqual(manifest["schedule_forest"]["tree_roots"], [0, 2])

    def test_shared_shards_preserve_unified_node_namespace(self):
        layout = GEN.build_generalized_layout(forest_config("shared"))
        self.assertEqual(layout.schedule_to_global, (0, 2, 1, 3))
        self.assertEqual(layout.schedule_tree_roots, (0, 1))
        self.assertEqual(layout.schedule_node_parent, (0, 1, 0, 1))
        self.assertEqual(layout.schedule_node_tree_id, (0, 1, 0, 1))
        self.assertEqual(layout.schedule_layout.shard_count, (2, 1, 1, 2))
        self.assertFalse(layout.schedule_shard_partitioned)

    def test_deterministic_generation_and_manifest(self):
        first = GEN.build_generalized_layout(valid_config())
        second = GEN.build_generalized_layout(copy.deepcopy(valid_config()))
        self.assertEqual(first, second)
        self.assertEqual(
            GEN.render_sv_package(first, Path("input.json")),
            GEN.render_sv_package(second, Path("input.json")),
        )
        manifest = GEN.manifest_dict(first, Path("input.json"))
        self.assertEqual(manifest["execution_model"],
                         "two_independent_domains_with_static_release_edges")
        self.assertEqual(manifest["connection_table"][0]["schedule_global_id"], 3)

    def test_generate_and_check(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config_path = root / "config.json"
            output = root / "generated"
            config_path.write_text(json.dumps(valid_config()), encoding="utf-8")
            GEN.generate(config_path, output)
            GEN.generate(config_path, output, check_only=True)
            self.assertTrue((output / "generalized_vpifo_config_pkg.sv").exists())

    def test_rejects_non_contiguous_or_duplicate_ids(self):
        invalid = valid_config()
        invalid["nodes"][4]["id"] = 7
        with self.assertRaisesRegex(GEN.ConfigError, "contiguous"):
            GEN.build_generalized_layout(invalid)

        invalid = valid_config()
        invalid["nodes"][4]["id"] = 3
        with self.assertRaisesRegex(GEN.ConfigError, "duplicate node id"):
            GEN.build_generalized_layout(invalid)

    def test_rejects_unsupported_schedule_depth(self):
        invalid = valid_config()
        invalid["nodes"].append({
            "id": 5, "name": "grandchild", "kind": "schedule",
            "capacity": 30, "parent": "leaf_a",
        })
        with self.assertRaisesRegex(GEN.ConfigError, "root-plus-leaf"):
            GEN.build_generalized_layout(invalid)

    def test_rejects_parent_to_another_leaf_in_forest(self):
        invalid = forest_config()
        invalid["nodes"][3]["parent"] = "leaf_a"
        with self.assertRaisesRegex(GEN.ConfigError, "schedule root"):
            GEN.build_generalized_layout(invalid)

    def test_rejects_unknown_partition_mode(self):
        invalid = forest_config("exclusive_magic")
        with self.assertRaisesRegex(GEN.ConfigError, "shared.*per_tree"):
            GEN.build_generalized_layout(invalid)

    def test_rejects_schedule_partition_field_in_timing_domain(self):
        invalid = forest_config()
        invalid["domains"]["timing"]["shard_partition"] = "per_tree"
        with self.assertRaisesRegex(GEN.ConfigError, "domains.timing"):
            GEN.build_generalized_layout(invalid)

    def test_tree_ids_are_determined_by_global_id_not_json_order(self):
        first = GEN.build_generalized_layout(forest_config())
        reordered = forest_config()
        reordered["nodes"] = list(reversed(reordered["nodes"]))
        second = GEN.build_generalized_layout(reordered)
        self.assertEqual(first.schedule_to_global, second.schedule_to_global)
        self.assertEqual(first.schedule_tree_roots, second.schedule_tree_roots)

    def test_rejects_timing_edge_to_root_or_timing(self):
        for target in ("root", "shape_b"):
            invalid = valid_config()
            invalid["nodes"][1]["release_to"] = target
            with self.subTest(target=target), self.assertRaisesRegex(
                GEN.ConfigError, "non-root schedule leaf"
            ):
                GEN.build_generalized_layout(invalid)

    def test_rejects_unknown_program(self):
        invalid = valid_config()
        invalid["nodes"][1]["program"] = "mystery"
        with self.assertRaisesRegex(GEN.ConfigError, "program must be one of"):
            GEN.build_generalized_layout(invalid)

    def test_token_bucket_program_mode(self):
        token_bucket = valid_config()
        token_bucket["nodes"][1]["program"] = "token_bucket"
        layout = GEN.build_generalized_layout(token_bucket)
        self.assertEqual(layout.timing_program_mode, (4, 3))


if __name__ == "__main__":
    unittest.main()
