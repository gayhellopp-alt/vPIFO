# VPIFO schedule/timing generalization

## Scope and execution model

This implementation uses one compile-time VPIFO node model with two concrete
node kinds, but keeps two independent RTL execution domains:

- `schedule`: one or more two-tier semantic trees execute in one schedule
  domain. `ScheduleForestHeterogeneousPIFO` gives all roots/leaves a unified
  logical-node namespace and maps them onto one heterogeneous BMW engine;
  rank selects among packets that are already eligible.
- `timing`: executes in `MultiLogicalShapingPIFO`; the BMW rank is
  `{release_time, insertion_sequence}` and a timer Pop happens only when the
  logical head is due.

The common "parent class" is therefore the schema-version-2 node contract, not
an attempt to make SystemVerilog modules inherit from one another.  The node
kind is resolved at generation time.  Runtime packets do not carry a mutable
type tag.

The timing and schedule domains instantiate different `HeterogeneousPIFO ->
PIFO_SRAM_TOP -> TaskDistribute/RPU` hierarchies.  Timing traffic therefore
does not share the schedule RPU set.  Semantic trees inside the schedule
domain do share its RPU set.

The only cross-domain edge is `timing.release_to -> schedule leaf`.  It is
compiled into `TIMING_RELEASE_TO_SCHEDULE`; `VPIFOConnectionTable` supplies the
local parent ID to the existing Stage-5 release bridge.  An ingress packet can
no longer choose or spoof its scheduling parent.

## Implemented stages

### Stage 1: common IR and two layouts

`config/generate_generalized_vpifo_config.py` validates schema version 2 and
builds two independent heterogeneous layouts by reusing the original
`generate_vpifo_config.build_layout` function.  It emits:

- global node kind and global/domain-local ID maps;
- separate schedule/timing shard count and offset arrays;
- schedule forest tables (`TREE_ROOTS`, `NODE_PARENT`, `NODE_TREE_ID`, and
  `NODE_IS_ROOT`);
- optional per-semantic-tree contiguous schedule shard ranges;
- timing-to-schedule release edges;
- the declared shaping-program mode;
- a JSON manifest retaining node names and topology.

The existing schema-version-1 generator and artifacts are unchanged and its
unit tests continue to pass.

The generator accepts multiple schedule roots, but deliberately rejects depth
greater than root plus leaf.  The implemented structure is a forest of
two-tier trees; accepting a deeper graph would overstate the RTL capability.

`domains.schedule.shard_partition` has two modes:

- `shared` (default): all schedule nodes use one unified shard-ID space and
  one shared execution fabric;
- `per_tree`: nodes are reordered at generation time so each semantic tree
  owns a contiguous, non-overlapping physical shard-ID interval.

Current heterogeneous allocation remains static: each logical node owns its
generated shard subset.  `per_tree` is therefore an address/storage partition,
not an RPU partition.  Strict execution isolation requires multiple schedule
engine banks and is intentionally not claimed by this stage.

### Stage 2: generalized top with two execution domains

`GeneralizedVPIFO.sv` is the external typed-node interface.  It instantiates
the proven `NonWorkConservingPIFOStage5` implementation, whose Stage-4.5 layer
contains the physically separate timing BMW domain and scheduling BMW domain.
The existing arbitration, backpressure, and release FIFO remain unchanged.
For a single semantic tree the legacy root-to-leaf wrapper is retained; for a
forest, Stage 4.5 selects `ScheduleForestHeterogeneousPIFO`.

### Stage 3: table-driven cross-domain connection

`VPIFOConnectionTable.sv` converts:

- a global timing node ID into a timing local ID, its schedule local release
  target, and declared shaping-program mode;
- a global schedule leaf ID into a schedule local ID;
- a global schedule root ID into a semantic tree ID for Pop selection;
- a schedule local packet-output ID back into a global ID.

Wrong-kind, root-as-leaf, and leaf-as-Pop-root requests are consumed as explicit rejects
without entering either execution domain.  Such input errors do not set the
internal protocol-error flag.

### Stage 4: multiple timing nodes and contention

The checked-in configuration has two timing logical VPIFOs on three physical
BMW shards.  `GeneralizedVPIFO_tb.sv` verifies:

- both timing nodes expire at the same wall-clock time;
- neither releases before eligibility;
- each static release edge reaches its configured schedule leaf;
- a normal schedule Push wins when a timing release is pending;
- the deferred release stays queued and is eventually admitted;
- root-to-leaf Pop returns global schedule IDs and all domain counts drain.

### Stage 5: annotation frontend

`software/SDL_compiler/generalization/compile_vpifo_annotations.py` accepts a
small Java-style declaration form:

```text
@ScheduleVPIFO(capacity=60, root=true)
vpifo root;

@ScheduleVPIFO(capacity=30, parent="root")
vpifo leaf;

@TimingVPIFO(capacity=60, releaseTo="leaf", program="token_bucket")
vpifo shaper;
```

Multiple `@ScheduleVPIFO(root=true)` declarations create multiple semantic
schedule trees. `--schedule-shard-partition per_tree` requests contiguous
per-tree shard ranges in the generated schedule domain.

The checked-in two-tree example is
`config/examples/generalized_schedule_forest_per_tree.json`; it generates into
`generated_forest/` during the generalized regression.

It emits the exact schema-version-2 JSON consumed by the hardware generator.
With `--rtl-output-dir`, compilation continues directly through RTL package
generation.

The declared program is emitted as a three-bit expected mode (`immediate=0`,
`virtual_clock=1`, `absolute=3`, `token_bucket=4`).  It is visible on
`o_transaction_declared_program_mode`.  Per-flow configuration and mutable
virtual-clock/token-bucket state intentionally remain in
`ShapingTransactionEngine`; the
control plane must configure a flow consistently with the selected timing
node.  Enforcing that consistency in RTL is a possible next step, not silently
claimed here.

For `token_bucket`, the runtime flow configuration supplies bucket capacity,
optional restored credit/state time, and each packet supplies a time-normalized
service cost. The annotation selects the transaction program; it does not
hard-code per-flow mutable bucket state into the generated node table.

## Build and verification

From PowerShell:

```powershell
python hardware/BMW_PIFO_SRAM_vPIFO/config/generate_generalized_vpifo_config.py
& .\hardware\BMW_PIFO_SRAM_vPIFO\config\run_generalized_vpifo_regression.ps1
```

The annotation-to-RTL path is:

```powershell
python software/SDL_compiler/generalization/compile_vpifo_annotations.py `
  software/SDL_compiler/generalization/examples/two_domain.vpifo `
  --output build/annotated_vpifo.json `
  --rtl-output-dir build/generated
```

Vivado 2019.2 RTL elaboration uses:

```powershell
& 'D:\Xilinx_U200\Vivado\2019.2\bin\vivado.bat' -mode batch `
  -source hardware/BMW_PIFO_SRAM_vPIFO/elaborate_generalized_vpifo_vivado.tcl
```

The checked-in two-tree/per-tree-shard configuration uses:

```powershell
& 'D:\Xilinx_U200\Vivado\2019.2\bin\vivado.bat' -mode batch `
  -source hardware/BMW_PIFO_SRAM_vPIFO/elaborate_generalized_vpifo_forest_vivado.tcl
```

## Current boundaries

- The schedule domain supports multiple semantic two-tier root-plus-leaf
  trees. Arbitrary-depth schedule trees are not added by this change.
- Multiple semantic schedule trees share one schedule RPU set. `per_tree`
  shard partitioning isolates physical shard IDs and capacity, but does not
  provide RPU bandwidth isolation.
- A timing node releases directly to a non-root schedule leaf.  Timing-to-
  timing chains are rejected.
- Node kinds and release topology are compile-time static.  Per-flow shaping
  state is runtime programmable.
- `NonWorkConservingPIFOStage5` remains available for backward-compatible
  tests that provide domain-local and parent IDs explicitly.
