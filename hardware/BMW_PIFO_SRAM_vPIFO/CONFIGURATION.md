# Heterogeneous vPIFO generated configuration

This directory uses generation-time and compile-time configuration.  It does
not create, delete, migrate, or resize logical PIFOs while the hardware is
running.

## User input

Edit only `config/vpifo_config.json`.  `required_capacity` contains logical
PIFO demand, not physical BMW-Tree structural capacity:

```json
{
  "schema_version": 1,
  "name": "stage15_baseline",
  "required_capacity": [100, 20, 30, 25],
  "physical_shard": {"order": 2, "level": 4},
  "resource_limits": {
    "max_logical_pifos": 64,
    "max_physical_shards": 64
  }
}
```

All physical shards remain uniform binary, four-level BMW-Trees.  Their
structural capacity is

```text
C(2, 4) = 2 + 4 + 8 + 16 = 30
```

For logical demand `d[i]`, the generator computes
`shard_count[i] = ceil(d[i] / 30)` and assigns a continuous physical range
starting at the prefix-sum `shard_offset[i]`.  The example above therefore
produces counts `[4,1,1,1]`, offsets `[0,4,5,6]`, and seven physical shards.

## Generate and build

From the repository root:

```powershell
python hardware\BMW_PIFO_SRAM_vPIFO\config\generate_vpifo_config.py
python hardware\BMW_PIFO_SRAM_vPIFO\config\generate_vpifo_config.py --check
```

The generator writes exactly three artifacts:

- `generated/vpifo_config_pkg.sv`: RTL dimensions, ID widths, counts, and
  offsets;
- `generated/vpifo_config.tcl`: synthesis/report metadata;
- `generated/vpifo_config_manifest.json`: readable forward and reverse layout.

The SV package is compiled before `ShardDirectory.sv`,
`HeterogeneousPIFO.sv`, and `HierarchicalHeterogeneousPIFO.sv`.  A changed
configuration therefore requires RTL recompilation or synthesis, just as the
original vPIFO's `TREE_NUM` and `LEVEL` parameters did.

Run the flat or hierarchical smoke test for the current generated package:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& hardware\BMW_PIFO_SRAM_vPIFO\sim_heterogeneous.ps1 -Test generated_flat
& hardware\BMW_PIFO_SRAM_vPIFO\sim_heterogeneous.ps1 -Test generated_hierarchical
```

Run the complete required-capacity matrix (the script restores the main
configuration's generated artifacts even if a test fails):

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& hardware\BMW_PIFO_SRAM_vPIFO\config\run_generated_config_regression.ps1
```

The existing `impl_heterogeneous_300mhz*.tcl` and
`synth_heterogeneous_300mhz_ooc_debug.tcl` flows consume the same package; the
OOC flows also record the generated fingerprint, counts, and offsets in their
machine-readable summary.

## Validation and boundaries

Generation rejects an empty capacity list, non-integer or non-positive
demand, unknown fields, non-binary/non-four-level shards, configured or hard
resource-limit overflow, inconsistent coverage, and a single physical shard.
The last case is rejected because the inherited BMW engine uses
`$clog2(TREE_NUM)` directly and cannot elaborate a zero-width tree ID.

The hierarchy retains Stage15's existing meaning: logical PIFO 0 is the root
and logical PIFOs 1 through N-1 are leaves.  Flat mode can use any generated
logical count; hierarchical mode requires at least a root and one leaf.

`USE_EXPLICIT_SHARD_MAP` remains only for Stage15 compatibility and its
directed non-contiguous-map regression.  Normal generated deployments use the
continuous `SHARD_OFFSETS`/`SHARD_COUNTS` layout and do not maintain a second
variable-length mapping table in RTL.

## Original vPIFO workload compatibility

The original SDL compiler remains the owner of scheduling algorithms and rank
calculation.  `HierarchicalHeterogeneousPIFO` consumes the same packet-level
contract as the original `TASK_GENERATOR`: a leaf PIFO ID, the leaf rank in
the low `PTW` bits of packet data, and the root rank on the priority input.
SP, WFQ, and pFabric are therefore not duplicated in RTL.

One original-source inconsistency is handled explicitly.  The compiler emits
node IDs `10`, `20`, ... while the committed hardware traces and `.tb` tables
use compact IDs `1`, `2`, ... .  The repository contains no original program
that performs that conversion.  `config/legacy_tree_id_map.json` declares the
mapping; `generate_legacy_trace_fixture.py` rejects every unmapped or
out-of-range ID rather than inferring a mapping from node creation order.

Run all three original reference workload regressions with:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
& hardware\BMW_PIFO_SRAM_vPIFO\config\run_legacy_workload_regression.ps1
```

The script temporarily selects `config/examples/original_workloads.json`.
Its demands `[120,60,60,30]` generate shard counts `[4,2,2,1]`, so both the
root and the two exercised leaves span multiple physical shards.  It converts
the reference-covered 120-packet prefixes of `test2_1` (SP), `test2_2` (WFQ),
and `test2_3` (WFQ root plus pFabric leaves), runs Verilator, and restores the
main configuration in a `finally` block.

The committed BMW RTL compares only the low `PTW` rank bits; metadata is not a
tie breaker.  Consequently, this regression checks the original reference's
rank/leaf class at every output position and checks every metadata value for
exactly-once delivery.  It deliberately does not demand the `.ref` file's
metadata ordering among equal-rank packets, because the original RTL itself
does not guarantee that total order.  `batch_reference` also waits until all
Push tasks retire before Pop, matching what those `.ref` scheduling-order
files test; it is not a cycle comparison against the interleaved raw trace.
