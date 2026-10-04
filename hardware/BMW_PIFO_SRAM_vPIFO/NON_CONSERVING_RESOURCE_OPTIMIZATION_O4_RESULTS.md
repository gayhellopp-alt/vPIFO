# Non-Conserving Resource Optimization O4 Results

## Decision

O4 is accepted as the next non-conserving resource candidate.  The timing
event sequence field used by the measured implementation is reduced from 32
bits to 16 bits, while a safe drain barrier prevents ranks from two sequence
epochs from coexisting.  The existing transaction, EventTable, timing BMW,
due-arbitration, ReleaseFIFO, and scheduling BMW flow is unchanged.

The final U200 150 MHz implementation is fully routed, has zero routing errors,
meets setup and hold timing, and reduces the O3 post-route design by 2,285 LUTs,
400 LUTRAMs, and 824 flip-flops.  A scheduling-only heterogeneous rebuild and
implementation remains exactly identical to the O3 isolation result.

## RTL change and wrap semantics

`MultiLogicalShapingPIFO` now has an opt-in `SAFE_SEQUENCE_WRAP` parameter.
Its default is zero, preserving every existing direct user of the generic
shaping block.  `ThreeTierTokenBucketVPIFO`, which is the non-conserving product
top used by this experiment, enables it by default.

With safe wrap enabled:

1. Normal events use the existing rank `{release_time, sequence_counter}`.
2. The event accepted with the maximum sequence value remains a normal event,
   and the counter holds at its maximum value.
3. The shaping input deasserts `o_event_ready` while the wrap is pending.
4. Existing events continue through EventTable, timing BMW, completion reorder,
   ReleaseFIFO, and scheduling admission.
5. After the timing core, EventTable, ReleaseFIFO, reservations, and completion
   slots all drain, the sequence counter resets to zero and input admission
   resumes.

Therefore two sequence epochs never coexist, and no modular comparison change
is required inside the BMW engine or directory.  The barrier is included in
`o_busy`, so the wrapper cannot report quiescence during the one-cycle epoch
reset boundary.

For a 16-bit sequence this barrier can occur once per 65,536 admitted shaping
events.  Its duration depends on the latest outstanding release time and
downstream readiness.  A far-future event can therefore cause a long admission
stall at the boundary; this is an explicit O4 tradeoff rather than a claim of
bounded wrap latency.

The Vivado implementation script now accepts an optional sixth Tcl argument for
`sequence_width`, defaults it to 16, validates it, and records both the selected
width and safe-wrap setting in the machine-readable summary.

## Dedicated wrap validation

`MultiLogicalShapingPIFO_sequence_wrap_tb.sv` sets `SEQUENCE_WIDTH=4` and forces
two complete wrap cycles.  During each barrier it holds a new input event valid,
fills and drains both physical shards, and applies ReleaseFIFO backpressure.

The test checks:

- the maximum sequence value is retained during the barrier;
- `o_event_ready` remains low while an old epoch is live;
- `o_busy` remains high for the complete barrier;
- equal-time events preserve sequence order;
- no event is released early, lost, or duplicated;
- the continuously valid event is accepted after the drain;
- EventTable, ReleaseFIFO, logical count, reservations, and completion state
  return to zero;
- `protocol_error` remains zero.

Result:

```text
PASS: safe sequence wrap/drain test
accepted=33 released=33 wraps=2
```

The regression driver exposes this test as `-Test shaping_sequence_wrap`.

## Integrated 16-bit wrap stress

The multistream sustained testbench now has a configurable
`TIMING_SEQUENCE_WIDTH`, and its eligibility log grows with the requested
measurement duration.  A 70,000-interval test at 150 MHz and 50 Gbit/s used
sequence width 16 and therefore crossed the 65,536-event boundary in the
integrated non-conserving top.

Configuration:

```text
schedule pending / pop track = 12 / 4
timing sequence width         = 16
clock                          = 150 MHz
target                         = 50 Gbit/s
PopWindow                      = 2
measurement intervals          = 70,000
```

Result:

```text
measurement_transaction_packets=70000
measurement_eligibility_timestamps=70000
measurement_root_admissions=70000
transaction_acceptance_window_bps=50000000000
eligibility_timestamp_window_bps=50000000000
root_admission_window_bps=50000000000
packet_output_window_bps=50000714285
max_timing_event_table=32
deferred_cycles=3
max_release_delay=19
total_accepted_packets=108313
total_output_packets=108313
shaped_accepted_packets=70096
shaped_output_packets=70096
protocol_error=0
PASS
```

This workload therefore crosses a real 16-bit wrap without throughput loss,
packet loss, duplication, or protocol failure.  The observed maximum release
delay is 19 cycles rather than the 11 cycles of the shorter non-wrap run, which
is consistent with the deliberately introduced boundary drain behavior.

## Existing functional and stress regression

The final O4 source passes the selected existing regression matrix:

- shaping transaction/state semantics;
- Stage28 multi-shard ordering, reservation-credit, and drain;
- Stage45 shaping-to-scheduling integration;
- Stage5 transaction-to-scheduling end-to-end integration;
- variable-depth recursive scheduling and split-Y boundary;
- directed three-tier Token Bucket at schedule depths 12/4;
- Node-Y visibility, arbitration, rate, and drain;
- 0.1--10 Gbit/s Node-Y rate sweep;
- six-flow 3/1/1/1 multistream test;
- generalized two-domain VPIFO and generalized forest;
- sustained 2 Gbit/s at 125 MHz, PopWindow 2, 3,000 intervals;
- sustained 50 Gbit/s at 150 MHz, PopWindow 2, 3,000 intervals;
- sustained 50 Gbit/s at 150 MHz, PopWindow 8, 1,000 intervals;
- finite 60-packet shaping-enabled/disabled A/B;
- 12-source hierarchical sustained A/B.

The directed event timings remain exact:

```text
D_ELIGIBILITY,12,20,28
D_ACTUAL_RELEASE,41,52,63
```

The standard 50 Gbit/s PopWindow-2 run also remains exact: all rate windows are
50,000,000,000 bit/s, accepted/output packets are 4,768/4,768, shaped
accepted/output packets are 3,096/3,096, maximum EventTable occupancy is 32/32,
maximum scheduling pending is 5/12, maximum recursive Pop outstanding is 2/4,
maximum release delay is 11 cycles, and `protocol_error=0`.

The finite A/B measurement exactly matches O3:

| Mode | Peak packets/bin | Minimum gap | Interval rate |
|---|---:|---:|---:|
| Shaping disabled | 60 | 23 cycles | 45.571575695 Gbit/s |
| Node-Y shaping enabled | 4 | 739 cycles | 1.999548124 Gbit/s |

The 12-source hierarchical A/B measurement also exactly matches O3:

| Mode | Mean Y throughput | Minimum | Maximum | MAD from 2 Gbit/s |
|---|---:|---:|---:|---:|
| Shaping disabled | 2.164763386 Gbit/s | 1.207692307 | 3.715384615 | 379 Mbit/s |
| Node-Y shaping enabled | 1.999454819 Gbit/s | 1.784615384 | 2.276923076 | 94 Mbit/s |

The enabled hierarchical run retains 37 deferred cycles and a maximum release
delay of 23 cycles.

## 150 MHz post-route comparison

O3 and O4 use Vivado 2019.2, `xcu200-fsgd2104-2-e`, a 6.666667 ns clock,
out-of-context implementation, unconstrained data I/O, schedule depths 12/4,
EventTable depth 32, ReleaseFIFO depth 16, and identical implementation
directives.  O3 uses a 32-bit timing sequence; O4 uses 16 bits plus safe wrap.

| Metric | O3 | O4 | O4 versus O3 |
|---|---:|---:|---:|
| CLB LUTs | 21,875 | 19,590 | -2,285 (-10.45%) |
| LUT as logic | 18,555 | 16,670 | -1,885 (-10.16%) |
| LUT as memory | 3,320 | 2,920 | -400 (-12.05%) |
| CLB registers | 7,726 | 6,902 | -824 (-10.67%) |
| BRAM / DSP | 0 / 0 | 0 / 0 | unchanged |
| Setup WNS | +0.600 ns | +0.927 ns | +0.327 ns |
| Hold WNS | +0.022 ns | +0.023 ns | +0.001 ns |

All 21,440 routable nets are fully routed and the routing-error count is zero.
DRC contains one `RTSTAT-10` no-routable-load warning and no error; this is the
expected unused-output warning pattern for the out-of-context top.

Relative to the original O0 32/32 implementation, the accepted O1b+O2a+O3+O4
stack reduces post-route LUTs from 28,402 to 19,590 (-8,812, -31.03%) and
registers from 16,345 to 6,902 (-9,443, -57.77%).

## Hierarchy attribution

| Hierarchy | O3 LUT / logic / LUTRAM / FF | O4 LUT / logic / LUTRAM / FF | Delta |
|---|---:|---:|---:|
| Scheduling domain | 8,299 / 7,147 / 1,152 / 3,190 | 8,315 / 7,163 / 1,152 / 3,190 | +16 / +16 / 0 / 0 |
| Timing domain | 13,084 / 10,916 / 2,168 / 4,220 | 10,783 / 9,015 / 1,768 / 3,396 | -2,301 / -1,901 / -400 / -824 |
| Timing shaping core | 12,397 / 10,309 / 2,088 / 3,995 | 10,162 / 8,474 / 1,688 / 3,218 | -2,235 / -1,835 / -400 / -777 |
| Timing BMW engine | 9,215 / 7,127 / 2,088 / 2,294 | 7,762 / 6,074 / 1,688 / 1,870 | -1,453 / -1,053 / -400 / -424 |
| Timing Directory | 1,547 / 1,547 / 0 / 164 | 1,141 / 1,141 / 0 / 131 | -406 / -406 / 0 / -33 |
| Timing PopResultFIFO | 439 / 439 / 0 / 563 | 184 / 184 / 0 / 435 | -255 / -255 / 0 / -128 |
| Timing LogicalRequestBuffer | 1,197 / 1,197 / 0 / 895 | 1,075 / 1,075 / 0 / 719 | -122 / -122 / 0 / -176 |
| Transaction engine | 473 / 473 / 0 / 100 | 473 / 473 / 0 / 100 | unchanged |

The 16-LUT scheduling-domain difference is placement/optimization variation;
no scheduling RTL or scheduling parameter changed.  All material reductions are
in the timing domain, as intended.

## Scheduling-only isolation

`UnbalancedHeterogeneousVPIFO4P6_tb` was rebuilt from the O4 worktree using a
source list that does not contain any non-conserving file.  Its functional result
is exactly unchanged:

```text
root shard counts = 4 / 4 / 4
packets = 18
compound operations = 6
cycles = 592
PASS
```

The independent 250 MHz O3 and O4 scheduling-only Vivado runs are also exactly
identical at every reported measurement point:

| Metric | O3 isolation | O4 isolation |
|---|---:|---:|
| Post-synth LUT / logic / LUTRAM / FF | 8,616 / 7,032 / 1,584 / 3,362 | 8,616 / 7,032 / 1,584 / 3,362 |
| Post-synth WNS | +0.817 ns | +0.817 ns |
| Post-route LUT / logic / LUTRAM / FF | 8,147 / 6,563 / 1,584 / 3,362 | 8,147 / 6,563 / 1,584 / 3,362 |
| Post-route setup WNS | +0.463 ns | +0.463 ns |
| Post-route hold WNS | +0.012 ns | +0.012 ns |
| Violating endpoints | 0 | 0 |

This confirms that O4 does not affect the function, resource measurement,
timing measurement, workload, counters, or definitions of the earlier
scheduling-only heterogeneous experiment.

## Reproducible artifacts

Generated artifacts remain untracked:

- O4 implementation reports:
  `vivado_three_tier_token_bucket_impl/o4_sequence16_wrapdrain_sched12_track4_150mhz_20260912/reports/`
- O4 16-bit integrated long-wrap build:
  `obj_dir_three_tier_node_y_multistream_sustained_sched12_track4_50000000000_150000000_w2_seq16_o4_wrap_long/`
- O4 scheduling-only functional build:
  `obj_dir_unbalanced_m2_l6_n4_p6_native_o4_isolation_20260912/`
- O4 scheduling-only Vivado reports:
  `../three_tier_experiments/runs/unbalanced_m2_l6_n4_p6_native_250mhz_o4_isolation_20260912/reports/`

The next resource experiment should keep the O4 timing sequence and O1b 12/4
scheduling depths fixed, then evaluate an opt-in single-logical/two-shard timing
PIFO fast path.  The generic multi-logical implementation must remain available
as the fallback.
