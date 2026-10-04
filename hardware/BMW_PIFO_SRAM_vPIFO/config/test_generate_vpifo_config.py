import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("generate_vpifo_config.py")
SPEC = importlib.util.spec_from_file_location("generate_vpifo_config", SCRIPT)
assert SPEC and SPEC.loader
GEN = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = GEN
SPEC.loader.exec_module(GEN)


def config(
    required_capacity, *, name="test", level=4, max_physical_shards=64
):
    return {
        "schema_version": 1,
        "name": name,
        "required_capacity": required_capacity,
        "physical_shard": {"order": 2, "level": level},
        "resource_limits": {
            "max_logical_pifos": 64,
            "max_physical_shards": max_physical_shards,
        },
    }


class LayoutTest(unittest.TestCase):
    def assert_layout(self, required, counts, offsets):
        layout = GEN.build_layout(config(required))
        self.assertEqual(layout.shard_capacity, 30)
        self.assertEqual(layout.shard_count, tuple(counts))
        self.assertEqual(layout.shard_offset, tuple(offsets))
        self.assertEqual(layout.physical_tree_num, sum(counts))
        self.assertEqual(
            sorted(
                physical
                for offset, count in zip(offsets, counts)
                for physical in range(offset, offset + count)
            ),
            list(range(sum(counts))),
        )
        for logical_id, (offset, count) in enumerate(zip(offsets, counts)):
            self.assertEqual(
                layout.physical_to_logical[offset : offset + count],
                (logical_id,) * count,
            )

    def test_structural_capacity(self):
        self.assertEqual(GEN.structural_capacity(2, 4), 30)
        self.assertEqual(GEN.structural_capacity(2, 5), 62)
        self.assertEqual(GEN.structural_capacity(2, 6), 126)
        self.assertEqual(GEN.structural_capacity(4, 4), 340)
        self.assertEqual(GEN.structural_capacity(8, 4), 4680)

    def test_supported_level_layouts(self):
        level5 = GEN.build_layout(config([310, 186, 62, 62], level=5))
        self.assertEqual(level5.shard_capacity, 62)
        self.assertEqual(level5.shard_count, (5, 3, 1, 1))
        self.assertEqual(level5.physical_tree_num, 10)

        level6 = GEN.build_layout(config([756, 378, 252, 126], level=6))
        self.assertEqual(level6.shard_capacity, 126)
        self.assertEqual(level6.shard_count, (6, 3, 2, 1))
        self.assertEqual(level6.physical_tree_num, 12)

    def test_required_capacity_matrix(self):
        self.assert_layout([100, 20, 30, 25], [4, 1, 1, 1], [0, 4, 5, 6])
        self.assert_layout([30, 20, 1, 25], [1, 1, 1, 1], [0, 1, 2, 3])
        self.assert_layout([60, 90, 30, 60], [2, 3, 1, 2], [0, 2, 5, 6])
        self.assert_layout(
            [30, 60, 90, 30, 60], [1, 2, 3, 1, 2], [0, 1, 3, 6, 7]
        )

    def test_deterministic_artifacts(self):
        user_config = config([60, 90, 30, 60], name="deterministic")
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            first_config = Path(first) / "config.json"
            second_config = Path(second) / "config.json"
            text = json.dumps(user_config, sort_keys=True)
            first_config.write_text(text, encoding="utf-8")
            second_config.write_text(text, encoding="utf-8")
            first_layout = GEN.build_layout(copy.deepcopy(user_config))
            second_layout = GEN.build_layout(copy.deepcopy(user_config))
            self.assertEqual(first_layout, second_layout)
            self.assertEqual(
                GEN.render_sv_package(first_layout, Path("config.json")),
                GEN.render_sv_package(second_layout, Path("config.json")),
            )
            self.assertEqual(
                GEN.manifest_dict(first_layout, Path("config.json")),
                GEN.manifest_dict(second_layout, Path("config.json")),
            )

    def test_rejects_non_positive_and_non_integer_capacity(self):
        for invalid in (0, -1, 1.5, True, "30"):
            with self.subTest(invalid=invalid), self.assertRaises(GEN.ConfigError):
                GEN.build_layout(config([30, invalid]))

    def test_rejects_resource_overflow(self):
        with self.assertRaisesRegex(GEN.ConfigError, "requires 7 physical shards"):
            GEN.build_layout(
                config([100, 20, 30, 25], max_physical_shards=6)
            )

    def test_rejects_mixed_or_different_physical_geometry(self):
        invalid = config([30])
        invalid["physical_shard"] = {"order": 4, "level": 4}
        with self.assertRaisesRegex(GEN.ConfigError, "only uniform binary"):
            GEN.build_layout(invalid)

        for invalid_level in (3, 7):
            with self.subTest(level=invalid_level), self.assertRaisesRegex(
                GEN.ConfigError, "level in"
            ):
                GEN.build_layout(config([30, 30], level=invalid_level))

    def test_safe_width_for_single_logical_with_two_physical_ids(self):
        layout = GEN.build_layout(config([31]))
        self.assertEqual(layout.logical_id_width, 1)
        self.assertEqual(layout.physical_id_width, 1)

    def test_rejects_single_physical_zero_width_engine_corner(self):
        with self.assertRaisesRegex(GEN.ConfigError, "requires at least 2"):
            GEN.build_layout(config([1]))


if __name__ == "__main__":
    unittest.main()
