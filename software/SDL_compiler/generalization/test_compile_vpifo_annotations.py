import importlib.util
import sys
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("compile_vpifo_annotations.py")
SPEC = importlib.util.spec_from_file_location("compile_vpifo_annotations", SCRIPT)
assert SPEC and SPEC.loader
COMPILER = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = COMPILER
SPEC.loader.exec_module(COMPILER)


SOURCE = """
// One common VPIFO declaration form, two compile-time specializations.
@ScheduleVPIFO(capacity=60, root=true)
vpifo root;

@ScheduleVPIFO(capacity=30, parent="root")
vpifo leaf_a;

@ScheduleVPIFO(capacity=30, parent="root")
vpifo leaf_b;

@TimingVPIFO(capacity=60, releaseTo="leaf_a", program="virtual_clock")
vpifo shape_a;

@TimingVPIFO(capacity=30, releaseTo="leaf_b", program="absolute")
vpifo shape_b;
"""


class AnnotationCompilerTest(unittest.TestCase):
    def test_compiles_two_subclasses_and_edges(self):
        config = COMPILER.compile_source(SOURCE, name="annotation_test")
        self.assertEqual(config["schema_version"], 2)
        self.assertEqual([node["id"] for node in config["nodes"]], list(range(5)))
        self.assertEqual(config["nodes"][3]["kind"], "timing")
        self.assertEqual(config["nodes"][3]["release_to"], "leaf_a")
        self.assertEqual(config["nodes"][4]["program"], "absolute")

    def test_explicit_ids_may_reorder_declarations(self):
        source = """
@TimingVPIFO(id=2, capacity=31, releaseTo="leaf")
vpifo shape;
@ScheduleVPIFO(id=1, capacity=30, parent="root")
vpifo leaf;
@ScheduleVPIFO(id=0, capacity=60, root=true)
vpifo root;
"""
        config = COMPILER.compile_source(source)
        self.assertEqual([node["name"] for node in config["nodes"]],
                         ["root", "leaf", "shape"])

    def test_multiple_schedule_roots_and_per_tree_partition(self):
        source = """
@ScheduleVPIFO(capacity=60, root=true)
vpifo root_a;
@ScheduleVPIFO(capacity=30, parent="root_a")
vpifo leaf_a;
@ScheduleVPIFO(capacity=30, root=true)
vpifo root_b;
@ScheduleVPIFO(capacity=60, parent="root_b")
vpifo leaf_b;
@TimingVPIFO(capacity=31, releaseTo="leaf_a")
vpifo shape_a;
@TimingVPIFO(capacity=30, releaseTo="leaf_b")
vpifo shape_b;
"""
        config = COMPILER.compile_source(
            source, schedule_shard_partition="per_tree"
        )
        self.assertEqual(
            [node["name"] for node in config["nodes"] if node.get("root")],
            ["root_a", "root_b"],
        )
        self.assertEqual(
            config["domains"]["schedule"]["shard_partition"],
            "per_tree",
        )

    def test_rejects_wrong_subclass_fields(self):
        with self.assertRaisesRegex(COMPILER.AnnotationError, "unknown"):
            COMPILER.compile_source("""
@ScheduleVPIFO(capacity=60, root=true, releaseTo="leaf")
vpifo root;
""")

    def test_rejects_missing_release_edge(self):
        with self.assertRaisesRegex(COMPILER.AnnotationError, "releaseTo is required"):
            COMPILER.compile_source("""
@TimingVPIFO(capacity=31)
vpifo shape;
""")

    def test_rejects_non_literal_code(self):
        with self.assertRaisesRegex(COMPILER.AnnotationError, "literal"):
            COMPILER.compile_source("""
@ScheduleVPIFO(capacity=getCapacity(), root=true)
vpifo root;
""")

    def test_preserves_token_bucket_program_annotation(self):
        source = """
@ScheduleVPIFO(capacity=60, root=true)
vpifo root;
@ScheduleVPIFO(capacity=30, parent="root")
vpifo leaf;
@TimingVPIFO(capacity=31, releaseTo="leaf", program="token_bucket")
vpifo shaper;
"""
        config = COMPILER.compile_source(source)
        self.assertEqual(config["nodes"][2]["program"], "token_bucket")

    def test_rejects_unknown_timing_program(self):
        with self.assertRaisesRegex(COMPILER.AnnotationError, "program must be"):
            COMPILER.compile_source("""
@ScheduleVPIFO(capacity=60, root=true)
vpifo root;
@ScheduleVPIFO(capacity=30, parent="root")
vpifo leaf;
@TimingVPIFO(capacity=31, releaseTo="leaf", program="mystery")
vpifo shaper;
""")


if __name__ == "__main__":
    unittest.main()
