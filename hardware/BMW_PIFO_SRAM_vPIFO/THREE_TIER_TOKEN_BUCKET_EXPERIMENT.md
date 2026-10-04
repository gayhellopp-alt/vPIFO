# Root/X/Y/Z Token-Bucket experiment

## Implemented topology

The scheduling execution domain contains four logical PIFOs in one namespace:

| Local ID | Node | Policy represented by supplied ranks | Parent | Physical shards |
|---:|---|---|---:|---:|
| 0 | Root | SP over F/X/Y | 0 | 0, 1, 2 |
| 1 | X | WFQ over D/E | 0 | 3 |
| 2 | Y | WFQ over C/Z | 0 | 4 |
| 3 | Z | SP over A/B | 2 | 5 |

Every physical shard is an M=2, L=6 BMW tree with capacity 126.  A-F are
packet flows, not extra logical PIFOs.  A packet is stored at its lowest
scheduling node, while one child-reference element is inserted at every
ancestor.  The complete paths are:

- F: Root
- D/E: X -> Root
- C: Y -> Root
- A/B: Z -> Y -> Root

`RecursiveScheduleTreeHeterogeneousPIFO.sv` generates the leaf-to-root vector
Push and performs tagged root-to-leaf recursive Pop.  It uses native complete
operations, so a Push and Pop at the same logical node can enter the core as
one P/P descriptor.  Multiple Pop chains use per-node context queues and a
tag reorder buffer to preserve external root-Pop order.

SP/WFQ rank calculation remains an upstream scheduling-transaction function.
The wrapper consumes one rank per logical node on the packet path; it does not
implement a WFQ finish-time calculator internally.

## D shaping path

`ThreeTierTokenBucketVPIFO.sv` connects an independent timing domain to X:

```text
D arrival
  -> per-flow time-credit Token Bucket
  -> timing logical PIFO (two M=2/L=6 physical shards)
  -> due Pop and ReleaseFIFO
  -> scheduling-first release arbiter
  -> Push(D at X, reference-to-X at Root)
  -> normal Root-to-X scheduling Pop
```

The timing event stores the packet data, target node, and the complete
scheduling rank vector.  Direct A/B/C/E/F Pushes and scheduling Pops have
priority over a due D release.  A delayed release retains its original
eligibility time, and the top reports the actual eligibility-to-admission
delay.

The Token Bucket operates in normalized time-credit units.  For fixed packet
size, software/testbench should use:

```text
service_time_cycles = ceil(packet_bits * clock_hz / target_rate_bps)
bucket_capacity_time = burst_packets * service_time_cycles
```

This is eligibility-time shaping.  Scheduling backpressure may produce a
catch-up burst after several already-eligible D packets have accumulated.  A
strict sliding-window bound at physical egress would require token debit or
revalidation at actual schedule admission.

## Aggregate Y shaping with split Push

The Y experiment enables `SPLIT_SHAPING=1` and uses Y (logical node 2) as an
aggregate shaping boundary for both the direct C path and the Z subtree
(A/B).  The shaped transaction does not use one complete leaf-to-root Push.
Instead, `ThreeTierTokenBucketVPIFO.sv` holds one descriptor and issues two
independent scheduling operations:

```text
accepted transaction
  -> LOCAL Push(target=C or Z, boundary=Y)
       C: Y <- packet
       A/B: Z <- packet and Y <- REF(Z)
  -> timing BMW event keyed by eligibility time
  -> due release
  -> PARENT_REF Push(boundary=Y)
       Root <- REF(Y)
```

The three Push modes are implemented by
`RecursiveScheduleTreeHeterogeneousPIFO.sv`: `FULL` preserves the original
complete path, `LOCAL` stops after the boundary, and `PARENT_REF` resumes at
the boundary's parent using references only.  The one-entry split transaction
buffer prevents a ready/valid loop between the timing and scheduling domains;
the Token-Bucket state is committed when the descriptor is accepted, while
the local Push and timing event are subsequently retried independently.

Direct scheduling Pushes have priority over both the local split Push and a
due shaping release.  Thus an already eligible release can be delayed by
downstream admission backpressure, but it remains in the timing release FIFO
and cannot be duplicated or exposed at Root early.

`ThreeTierNodeYTokenBucket_tb.sv` checks this aggregate path with four 1500B
packets at a modeled 125 MHz/10 Gbit/s service time (150 cycles), followed by
a fifth packet while direct Root Pushes deliberately hold its due release.
The run verifies exact eligibility spacing, no Root count before release,
direct-priority deferral, exactly-once release, recursive output order, and
zero final occupancy in both domains.  It is invoked with:

```powershell
./sim_heterogeneous.ps1 -Test three_tier_node_y
```

The current Verilator result is:

```text
Y_RATE,packet_bytes=1500,target_bps=10000000000,
        eligibility_bps=10000000000,actual_bps=10000000000
Y_ELIGIBILITY,156,306,456,606
Y_ACTUAL_RELEASE,167,317,467,617
Y_ARBITRATION,direct_blockers=63,deferred_cycles=8,
              contended_eligibility=901,contended_release=920
```

The first four releases retain their 150-cycle spacing despite the fixed
11-cycle Timing/BMW pipeline delay.  In the second phase, Root receives no
Y reference before cycle 920; the 901-cycle eligibility event remains pending
while direct work is accepted, then one parent reference is admitted after
the direct source stops.

## 3/1/1/1 mixed-stream aggregate test

`ThreeTierNodeYMultiStream_tb.sv` drives all six traffic classes through the
configured scheduling tree.  F, D, and E use the direct scheduling ingress;
C, A, and B use the shaped ingress and share one aggregate Y Token Bucket.
The direct and shaped generators run concurrently, while packet metadata
identifies the traffic class and sequence number for an exactly-once
scoreboard.

The first phase sends eight packets per traffic class with a long 2000-cycle
service time.  It waits for every LOCAL Push to settle before the first Y
release and checks the pre-release occupancy:

```text
Root = 24 direct elements, distributed 8/8/8 over shards 0/1/2
X    = 16 elements on shard 3
Y    = 24 elements on shard 4
Z    = 16 elements on shard 5
Timing event table = 24 events
Y releases admitted to Root = 0
```

After all 24 Y events become eligible, Root contains 48 elements and its
three shards contain 16 elements each.  The test then drains the tree and
requires all logical, physical, timing, pending, and Pop-chain counts to
return to zero.

The sustained phase resets the design and sends 40 packets per traffic class:

```text
total packets  = 240
shaped packets = 120
X maximum      = D + E     = 80  < 126
Y maximum      = C + A + B = 120 < 126
Z maximum      = A + B     = 80  < 126
Root maximum   = 240 < 3 * 126
```

The per-flow count is deliberately bounded by the one-shard X/Y/Z capacities.
For example, 64 packets per traffic class would put 128 elements in X and 192
elements in Y when Root SP delays those subtrees, so that workload is not a
valid no-drop capacity test for the current `3/1/1/1` allocation.

At 125 MHz, 1500-byte packets, and a 150-cycle aggregate service time, the
current Verilator result is:

```text
MULTISTREAM_PHASE1,per_flow=8,
    root_shard_pushes=16,16,16,x=16,y=24,z=16
MULTISTREAM_PHASE2,per_flow=40,total_packets=240,shaped_packets=120
MULTISTREAM_RATE,target_bps=10000000000,
    eligibility_bps=10000000000,
    root_admission_interval_bps=10191846522,
    packet_output_interval_bps=11779068232,
    packet_output_envelope_bps=9972299168
MULTISTREAM_SHARDS,root=82,79,79,x=80,y=120,z=80
MULTISTREAM_ARBITRATION,deferred_cycles=341,last_delay=11,max_delay=347
```

Every Y packet exits at or after its corresponding aggregate eligibility time,
all 240 packets appear exactly once, all six physical shards are exercised,
and all counts drain to zero.  The Root shard Push totals differ by only three
operations across 240 Root Pushes; concurrent Push/Pop occupancy affects shard
selection, so this is load-balanced coverage rather than strict static
round-robin equality.

The 11.779 Gbit/s first-to-last packet-output interval is the expected catch-up
effect after delayed eligible references accumulate.  The end-to-end envelope,
measured from the first eligibility opportunity through the final shaped
packet plus one service interval, is 9.972 Gbit/s and remains below the
configured 10 Gbit/s rate.  This test therefore confirms the current
eligibility-time aggregate contract, not a strict sliding-window egress rate.

Run the test with:

```powershell
./sim_heterogeneous.ps1 -Test three_tier_node_y_multistream
```

## 3/1/1/1 multi-stream rate sweep

The same six-flow mixed workload was repeated with the aggregate Y shaping
rate set to 0.1, 0.2, 0.5, 1.0, 2.0, and 5.0 Gbit/s.  The script accepts the
rate in bit/s and derives the integer 1500-byte service time for the modeled
125 MHz clock:

```powershell
./sim_heterogeneous.ps1 -Test three_tier_node_y_multistream -TargetBps 100000000
./sim_heterogeneous.ps1 -Test three_tier_node_y_multistream -TargetBps 200000000
./sim_heterogeneous.ps1 -Test three_tier_node_y_multistream -TargetBps 500000000
./sim_heterogeneous.ps1 -Test three_tier_node_y_multistream -TargetBps 1000000000
./sim_heterogeneous.ps1 -Test three_tier_node_y_multistream -TargetBps 2000000000
./sim_heterogeneous.ps1 -Test three_tier_node_y_multistream -TargetBps 5000000000
```

Each case sends 40 packets per flow (240 total, 120 shaped) and passes the
same exactly-once, path, shard, and final-drain checks as the 10 Gbit/s
baseline.  Results are:

| Target | Service cycles | Eligibility rate | Root admission rate | Packet-output interval | Packet-output envelope | Deferred cycles | Max delay |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.1 Gbit/s | 15000 | 0.100000 Gbit/s | 0.100000 Gbit/s | 0.099999 Gbit/s | 0.099997 Gbit/s | 0 | 11 |
| 0.2 Gbit/s | 7500 | 0.200000 Gbit/s | 0.200000 Gbit/s | 0.199998 Gbit/s | 0.199989 Gbit/s | 0 | 11 |
| 0.5 Gbit/s | 3000 | 0.500000 Gbit/s | 0.500000 Gbit/s | 0.499986 Gbit/s | 0.499931 Gbit/s | 0 | 11 |
| 1.0 Gbit/s | 1500 | 1.000000 Gbit/s | 1.000000 Gbit/s | 1.007382 Gbit/s | 0.999722 Gbit/s | 0 | 11 |
| 2.0 Gbit/s | 750 | 2.000000 Gbit/s | 2.000000 Gbit/s | 2.047300 Gbit/s | 1.998890 Gbit/s | 0 | 11 |
| 5.0 Gbit/s | 300 | 5.000000 Gbit/s | 5.026187 Gbit/s | 5.380233 Gbit/s | 4.993065 Gbit/s | 186 | 197 |

The packet-output interval can exceed the configured rate when the Root is
temporarily occupied by direct traffic and deferred eligible references catch
up.  The end-to-end packet-output envelope remains below the configured rate
in every case.  At 5 Gbit/s the run exercises this behavior explicitly; the
other rates have no deferred release cycles in this workload.

The 10 Gbit/s baseline remains the previously recorded result: 10.000 Gbit/s
eligibility, 10.192 Gbit/s Root-admission interval, 11.779 Gbit/s packet-output
interval, 9.972 Gbit/s packet-output envelope, 341 deferred cycles, and 347
maximum release delay.  These are RTL model-clock results for the current
eligibility-time aggregate contract, not a strict sliding-window physical
egress rate or a post-route line-rate measurement.

## Sustained six-flow steady-state rate sweep

`ThreeTierNodeYMultiStream_tb.sv` also has a sustained mode for a Figure-11-
style workload.  The six producers run concurrently for the whole test:
F/D/E use the direct ingress and C/A/B use the shaped ingress.  A producer
keeps `valid` asserted until `valid && ready`; it advances its per-flow
sequence number only on that handshake, so ingress backpressure cannot drop
or duplicate a packet.  Packet IDs wrap in a 4096-entry testbench namespace,
while accepted/output counters provide the exactly-once check.

The sustained test keeps one recursive Pop outstanding at a time.  This is a
testbench flow-control choice: it prevents speculative Root Pops from filling
the scheduling pending buffer while a released Y reference is waiting for
admission.  Producers also stop offering new packets when the observed X/Y/Z
logical counts approach their single-shard capacity.  The direct and shaped
offer gaps (64 and 16 cycles) keep the scheduler contended without allowing a
transient full shard to become an unrecoverable condition.  No datapath RTL is
changed by sustained mode.

Each case has three phases:

1. Warm-up: `8 * service_cycles + 2000` cycles, excluded from the rate.
2. Measurement: `3000 * service_cycles` cycles, with all six producers and
   the Pop consumer still active.  The measurement gate changes on `negedge`
   and the monitors sample on `posedge`, giving a deterministic half-open
   `[start_time,end_time)` window in both Verilator and XSim.  The primary
   metric is shaped packet output (C/A/B only) during this fixed window.
3. Drain: injection stops, Pop continues, and the test waits for timing,
   scheduling, logical, physical, pending, and release-FIFO state to reach
   zero before checking exactly-once output.

The refined rate telemetry separates four distinct points in the pipeline:

```text
transaction acceptance
    d_transaction_fire inside the measurement window
eligibility timestamp
    computed release_time lies inside [start_time,end_time)
Root admission
    PARENT_REF(Y) handshake lies inside the measurement window
packet output
    C/A/B packet_out lies inside the measurement window
```

Each point has a fixed-window byte rate.  Eligibility, Root admission, and
packet output also have a first-to-last interval rate when at least two samples
exist.  Eligibility classification is deliberately performed after drain: an
event accepted during warm-up is included when its timestamp falls in the
window, while an event accepted during measurement is excluded if its
timestamp lies beyond the window.  The test requires exactly
`SUSTAINED_MEASUREMENT_SERVICE_INTERVALS` eligibility timestamps, Root
admissions, and shaped outputs, and requires the eligibility interval rate to
equal the configured integer-cycle rate.

Backlog is no longer represented by one ambiguous Y predicate:

| Metric | Predicate sampled during the measurement window | Interpretation |
|---|---|---|
| `source_valid_fraction` | `d_valid` | shaped producer is presenting work |
| `source_stalled_fraction` | `d_valid && !d_ready` | presented work is backpressured |
| `work_backlogged_fraction` | accepted shaped count exceeds output count, or `d_valid` | aggregate offered/accepted shaped work has not drained |
| `local_subtree_backlogged_fraction` | Y or Z logical count is nonzero | shaped work is resident in the Scheduling subtree |
| `timing_backlogged_fraction` | Timing event table or release FIFO is nonempty | combined Timing-domain occupancy |
| `event_table_backlogged_fraction` | Timing event table is nonempty | future/in-flight timing work exists |
| `eligible_release_backlogged_fraction` | release FIFO/head is valid | an already eligible release is waiting or being admitted |

The self-check requires `work_backlogged_fraction >= 99%`; the 100% result
therefore cannot be inferred merely from a warm-up sample.  The much smaller
eligible-release fraction in the uncontended sustained test is also important:
it shows that the measured rate is not produced by draining a large queue of
already-due releases.  The auxiliary envelope metric is calculated over the
entire run from the first shaped eligibility time to the last shaped packet-out
and includes startup/drain effects.  `packet_output_interval_bps` is retained
to expose catch-up bursts; this implementation is not a strict sliding-window
egress pacer.

Run one case with:

```powershell
./sim_heterogeneous.ps1 -Test three_tier_node_y_multistream_sustained `
  -TargetBps 2000000000 -SustainedIntervals 3000
```

The complete 3000-interval, 125 MHz Verilator sweep of the strengthened
testbench is:

| Configured | Service cycles | Measurement cycles | Transaction window | Eligibility window / interval | Root window / interval | Output window | Output interval | Eligible-release backlog | Work backlog | Max delay | Protocol |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.1 Gbit/s | 15000 | 45000000 | 0.100000 | 0.100000 / 0.100000 | 0.100000 / 0.100000 | 0.100000 | 0.100000006 | 0.00% | 100.00% | 11 | 0 |
| 0.2 Gbit/s | 7500 | 22500000 | 0.200000 | 0.200000 / 0.200000 | 0.200000 / 0.200000 | 0.200000 | 0.200000151 | 0.01% | 100.00% | 11 | 0 |
| 0.5 Gbit/s | 3000 | 9000000 | 0.500000 | 0.500000 / 0.500000 | 0.500000 / 0.500000 | 0.500000 | 0.500000444 | 0.03% | 100.00% | 11 | 0 |
| 1.0 Gbit/s | 1500 | 4500000 | 1.000000 | 1.000000 / 1.000000 | 1.000000 / 1.000000 | 1.000000 | 0.999997777 | 0.06% | 100.00% | 11 | 0 |
| 2.0 Gbit/s | 750 | 2250000 | 2.000000 | 2.000000 / 2.000000 | 2.000000 / 2.000000 | 2.000000 | 2.000022229 | 0.13% | 100.00% | 11 | 0 |
| 5.0 Gbit/s | 300 | 900000 | 5.000000 | 5.000000 / 5.000000 | 5.000000 / 5.000000 | 5.000000 | 4.999927754 | 0.33% | 100.00% | 11 | 0 |
| 10.0 Gbit/s | 150 | 450000 | 10.000000 | 10.000000 / 10.000000 | 10.000000 / 10.000000 | 10.000000 | 10.000377918 | 0.66% | 100.00% | 16 | 0 |

All rate columns are in Gbit/s.  Every row contains exactly 3000 transaction
acceptances, eligibility timestamps, Root admissions, and shaped packet
outputs in the measurement window.  `deferred_cycles=0` in all rows.  Source
valid/stalled fractions range from 99.88/99.88% at 0.1 Gbit/s to 88.66/88.00%
at 10 Gbit/s; the independent aggregate-work predicate remains 100% in every
case.

Every case measured 3000 shaped packets (4,500,000 shaped bytes) in the
steady-state window.  Eligibility and Root-admission rates matched the
effective configured rate in all seven runs.  The long-run primary result is
therefore a one-to-one rate curve from 0.1 through 10 Gbit/s under a
continuously backlogged six-flow workload.  The small output interval-rate
differences are first/last-sample and Scheduling-pipeline phase effects; the
fixed-window byte count remains exact and is the primary rate metric.

The per-run packet and physical-dispatch counters were:

| Configured rate | Total accepted/output | Shaped accepted/output | Root shard pushes | X pushes | Y pushes | Z pushes |
|---:|---:|---:|---:|---:|---:|---:|
| 0.1 Gbit/s | 686708 / 686708 | 3041 / 3041 | 228903,228903,228902 | 455778 | 3041 | 2027 |
| 0.2 Gbit/s | 344890 / 344890 | 3041 / 3041 | 114964,114963,114963 | 227899 | 3041 | 2027 |
| 0.5 Gbit/s | 139799 / 139799 | 3041 / 3041 | 46600,46600,46599 | 91172 | 3041 | 2027 |
| 1.0 Gbit/s | 71436 / 71436 | 3042 / 3042 | 23812,23812,23812 | 45596 | 3042 | 2028 |
| 2.0 Gbit/s | 37256 / 37256 | 3043 / 3043 | 12419,12419,12418 | 22808 | 3043 | 2028 |
| 5.0 Gbit/s | 16751 / 16751 | 3047 / 3047 | 5584,5584,5583 | 9136 | 3047 | 2031 |
| 10.0 Gbit/s | 9921 / 9921 | 3054 / 3054 | 3307,3307,3307 | 4578 | 3054 | 2036 |

All seven rows ended with `protocol_error=0`; the drain checks also verified
zero logical/physical/timing/pending occupancy and an empty release FIFO.

The sustained runs also report total accepted/output packets, shaped
accepted/output packets, Root/X/Y/Z physical push counts, and all protocol and
drain counters.  For example, the 10 Gbit/s run accepted and output 9,921
packets in total (3,054 shaped), exercised all three Root shards, and ended
with `protocol_error=0` and all queues empty.

An earlier long run with the default 8-bit timing-event sequence identifier
failed after more than 256 outstanding timing events with
`timing_protocol_error=1`.  That was an identifier-space limit, not a shaping
algorithm failure.  Sustained mode now instantiates the unchanged DUT with
`SEQUENCE_WIDTH=32`; the packet metadata sequence namespace remains a
testbench-only 4096-entry space.  A previous version also allowed 32
speculative Pops, which filled the pending buffer and deadlocked the release
path; the one-outstanding Pop policy removes that testbench artifact.

The refined telemetry was cross-checked independently with Verilator 5.032
and Vivado 2019.2 XSim using 2 Gbit/s and 100 measurement intervals.  Both
simulators produced the same values:

```text
service_cycles=750
measurement_cycles=75000
measurement_transaction_packets=100
measurement_eligibility_timestamps=100
measurement_root_admissions=100
measurement_shaped_packets=100

transaction_acceptance_window_bps=2000000000
eligibility_timestamp_window_bps=2000000000
eligibility_timestamp_interval_bps=2000000000
root_admission_window_bps=2000000000
root_admission_interval_bps=2000000000
packet_output_window_bps=2000000000
packet_output_interval_bps=2000000000

source_valid_fraction=97.73
source_stalled_fraction=97.60
work_backlogged_fraction=100.00
local_subtree_backlogged_fraction=100.00
timing_backlogged_fraction=100.00
event_table_backlogged_fraction=100.00
eligible_release_backlogged_fraction=0.13
deferred_cycles=0
max_release_delay=11
total accepted/output=1401/1401
shaped accepted/output=143/143
protocol_error=0
```

The XSim log is
`vivado_non_conserving_xsim_sustained_metrics_v2_20260820.log`.  The only XSim
diagnostics are the generic being harmlessly offered to `glbl` and three wave
objects exceeding the GUI display limit; compilation, elaboration, simulation,
scoreboarding, and drain all pass.

The same strengthened fixed-window assertions were also run with Verilator at
0.1 and 10 Gbit/s for 100 intervals.  Both endpoints reported exactly 100
eligibility timestamps, 100 Root admissions, and 100 shaped packet outputs;
all window and interval rates matched their configured rate, aggregate work
backlog was 100%, and both cases drained with `protocol_error=0`.

## Aggregate-Y burst-response A/B experiment

`ThreeTierNodeYShapingAB_tb.sv` makes the smoothing effect visible with two
sequential, independently reset cases.  Both sources start the same finite
60-packet C/A/B round-robin sequence immediately and use identical packet IDs,
per-node ranks, 1500-byte packet size, and one-outstanding recursive Pop
consumer.  The only functional difference is the ingress path:

```text
bypass:
    C/A/B -> FULL Scheduling Push -> Root-visible immediately

aggregate Y Token Bucket:
    C/A/B -> LOCAL Y/Z Push -> eligibility event
          -> PARENT_REF(Y) -> Root-visible only when due
```

The measured event is the final C/A/B `packet_out`, not merely eligibility or
the `PARENT_REF(Y)` handshake.  C returns from Y, while A and B recurse through
Z; all three are counted as Y-subtree output.  A 2 Gbit/s target at 125 MHz and
1500 bytes gives a 750-cycle service interval.  Throughput bins span four
service intervals (3000 cycles or 24 us).

Run the experiment and plot its two CSV traces with:

```powershell
./sim_heterogeneous.ps1 -Test three_tier_node_y_ab `
  -TargetBps 2000000000
python ./plot_non_conserving_ab.py
```

The current Verilator result is:

| Metric | Scheduling bypass | Aggregate Y Token Bucket |
|---|---:|---:|
| Packets output exactly once | 60 | 60 |
| Peak packets in one 3000-cycle bin | 60 | 4 |
| Peak fixed-window throughput | 30.000 Gbit/s | 2.000 Gbit/s |
| First-to-last interval rate | 45.548121 Gbit/s | 1.999548 Gbit/s |
| Minimum packet-out gap | 23 cycles | 739 cycles |
| Maximum packet-out gap | n/a | 760 cycles |
| Non-final outputs with shaped work backlogged | n/a | 59 / 59 |
| First / last packet-out | 111 / 2054 cycles | 791 / 45051 cycles |

The bypass drains the complete burst in about 1943 cycles, producing a sharp
30 Gbit/s fixed-window peak.  The Token Bucket case has three outputs in its
startup bin, four in every full interior bin, and one in the final partial
tail bin.  Its 739-to-760-cycle packet-out jitter around the 750-cycle target
comes from alternating `Root -> Y` and `Root -> Y -> Z` recursive depths; the
eligibility spacing itself remains 750 cycles.  The test requires the shaped
first-to-last rate to be within 1% of the configured rate, bounds the output-gap
jitter to +/-32 cycles, checks no release precedes its eligibility time, and
drains every Timing, Scheduling, pending, logical, and FIFO count to zero.
At each of the first 59 shaped outputs it also requires another accepted or
currently presented shaped packet, proving that the plotted 2 Gbit/s output is
not caused by an underloaded source.
Vivado 2019.2 XSim independently produced the same summary and semantically
identical event and time-series CSV rows; its batch log is
`vivado_non_conserving_xsim_ab_20260820.log`.

The source packet sequence is identical, but ingress handshake cycles are not
forced to match: Timing event-table capacity and normal DUT backpressure may
delay shaped acceptance.  This is intentional for a backlogged offered-load
experiment.  A separate trace-replay experiment would be needed to require an
identical accepted-ingress timestamp sequence.

`non_conserving_ab_timeseries.csv` contains the fixed-window rates and
cumulative counts.  `non_conserving_ab_events.csv` contains every final output
cycle and interdeparture gap.  `plot_non_conserving_ab.py` produces
`non_conserving_ab_comparison.png` and PDF, showing the throughput step,
cumulative curve, and per-packet gaps.

This result proves burst smoothing for the tested aggregate-Y, continuously
backlogged, uncongested Root-admission case.  It does not strengthen the RTL
into a strict physical-egress pacer: if already-due releases accumulate behind
downstream backpressure, the existing ReleaseFIFO can still produce a catch-up
burst after the blockage clears.

## Multi-node, multi-flow hierarchical sustained A/B experiment

`ThreeTierNodeYHierarchicalSustainedAB_tb.sv` extends the A/B comparison beyond
the C/A/B-only finite burst.  It models twelve continuously backlogged software
sources mapped onto all six leaves:

```text
F0/F1       -> F -> Root
D0/D1       -> D -> X -> Root
E0/E1       -> E -> X -> Root
C0/C1       -> C -> Y -> Root
A0/A1       -> A -> Z -> Y -> Root
B0/B1       -> B -> Z -> Y -> Root
```

The source demand is continuous, while a deterministic arrival-slot trace
controls which source presents the next packet.  The trace is generated once
from relative case time and is replayed after reset in both modes.  Each
source's final arrival count must match between the disabled and enabled cases.
Normal DUT backpressure may change acceptance time, but cannot change the
offered source/packet sequence.

At the default 2 Gbit/s Y target:

```text
packet size                  = 1200 to 1500 bytes, deterministic 50-byte steps
average packet size          = approximately 1350 bytes
clock                        = 125 MHz
per-packet service cost      = ceil(packet_bytes * 750 / 1500) cycles
reference service interval   = 750 cycles for 1500 bytes
bucket capacity/initial credit = 2250 time-credit cycles (3 reference packets)
aggregate arrival-slot gap   = 120 cycles on average
aggregate offered capacity   = approximately 11.25 Gbit/s in actual bytes
arrival batch                = 16 packets, 12-cycle intra-batch gap
Y share                      = 16% to 24%, slowly modulated
warm-up                      = 256 service intervals
measurement                  = 2000 service intervals / 1,500,000 cycles
sliding window               = 6500 cycles / 8.667 reference intervals
sliding step                 = 500 cycles / 0.667 reference intervals
```

The sixteen-packet batches are much shorter than the sliding window.  They make
F/X/Y references overlap at Root and represent normal application/NIC packet
batches, but they do not make the plotted output alternate between zero and an
artificial line-rate impulse.  The slower Y-share pattern and the continuously
offered F/X traffic generate the visible low-frequency variation.

The Token Bucket is charged from each packet's actual length, not from the
average packet length:

```text
packet_service_cycles =
    ceil(packet_bytes * 8 * 125 MHz / configured_rate)
```

The output byte length is preserved in packet metadata and checked at final
packet-out.  Window throughput accumulates actual output bytes.  This
testbench therefore instantiates the already-parameterized scheduling datapath
with `MTW=32`: source ID, wrapped sequence ID and packet length occupy metadata,
while the low `PTW=16` bits remain available for the PIFO rank.  No core RTL
behavior is changed.

The two replay modes are:

```text
Token Bucket disabled:
    F/D/E/C/A/B -> FULL Scheduling Push

Token Bucket enabled:
    F/D/E       -> FULL Scheduling Push
    C/A/B       -> LOCAL(Y) -> Timing event -> PARENT_REF(Y)
```

Root ranks remain the experiment's SP ranks (`F=0`, `X=1`, `Y=2`); X and Y
use the supplied monotonic WFQ-style ranks and Z uses A/B SP ranks.  Because a
strict-priority Root would starve Y if F and X references were literally
resident on every cycle, the test measures rather than assumes simultaneous
Root activity.  In the current enabled run at least two Root subtrees have
outstanding references for 5.82% of measurement cycles; the disabled run has
13.09% overlap.  X, Y and Z all receive service, and enabled Y/Z local
occupancy remains backlogged throughout the measurement.

Run and plot the experiment with:

```powershell
./sim_heterogeneous.ps1 `
  -Test three_tier_node_y_hierarchical_ab `
  -TargetBps 2000000000 `
  -SustainedIntervals 2000
python ./plot_hierarchical_sustained_ab.py
```

The 2000-interval Verilator result is:

| Metric | Token Bucket disabled | Token Bucket enabled |
|---|---:|---:|
| Same deterministic trace slots | 14,112 | 14,112 |
| Total packets, exactly once | 14,112 | 14,112 |
| Y packets in measurement | 2,408 | 2,222 |
| Y bytes in measurement | 3,250,850 | 2,999,750 |
| Sliding-window mean | 2.164763 Gbit/s | 1.999455 Gbit/s |
| Sliding-window minimum | 1.207692 Gbit/s | 1.784615 Gbit/s |
| Sliding-window maximum | 3.715385 Gbit/s | 2.276923 Gbit/s |
| Sliding-window standard deviation | 0.454 Gbit/s | 0.103 Gbit/s |
| Mean absolute deviation from R | 0.379 Gbit/s | 0.094 Gbit/s |
| Root multi-active fraction | 13.0869% | 5.8196% |
| Root all-three-active fraction | 2.5225% | 0.5335% |
| Y local-active fraction | 16.8304% | 100.0000% |
| Z local-active fraction | 14.3195% | 100.0000% |
| Y source-queue backlog fraction | 0.1605% | 97.2286% |
| Deferred release cycles | n/a | 37 |
| Maximum release delay | n/a | 23 cycles |

The disabled long-run rate is still close to the 2 Gbit/s reference, but its
same-size sliding windows move continuously between about 1.21 and 3.72
Gbit/s.  Enabled traffic remains close to R with a much smaller 1.78-to-2.28
Gbit/s range.  Its window standard deviation is about 23% of the disabled
case.  Unlike the former fixed-1500-byte, integer-period window, the enabled
line is no longer mathematically forced to be flat: packet costs vary and the
6500-cycle window is not an integer multiple of the 750-cycle reference
interval.

The raw outputs are:

- `hierarchical_sustained_ab_windows.csv`: one row per mode and sliding window,
  including Y rate, F/X/Y served counts, Root active fractions, local subtree
  backlog, and source-queue backlog.
- `hierarchical_sustained_ab_events.csv`: every measurement packet-out with
  mode, cycle, source ID, source sequence, actual packet bytes, corresponding
  service cycles, output node and subtree.
- `hierarchical_sustained_ab_summary.csv`: aggregate rate range, backlog,
  competition, defer and drain statistics.
- `plot_hierarchical_sustained_ab.py`: produces the main comparison PNG/PDF and
  a separate Root-active, local-backlog and served-window diagnostic PNG/PDF.

The main comparison follows the compact line-and-marker style of PIEO Fig. 11.
It selects source time 2--6 ms and rebases that interval to a compact 0--4 ms
x-axis.  It keeps the raw 6500-cycle sliding-window traces as low-alpha
background lines.  The foreground uses the same anti-aliased
low-frequency resampling for both modes: each plotted point is the mean of 40
adjacent raw windows, producing one display point per 160 us and 25 points
across the visible range.  This affects presentation only; no CSV
sample or reported statistic is changed.
`hierarchical_sustained_ab_comparison_raw.png` and PDF retain the unsmoothed
rebased 0--4 ms traces for audit and reproduction.

The self-check also requires identical per-source traces, exactly-once output,
no release before eligibility, service for every Root subtree, a fully empty
Timing/Scheduling drain, enabled mean within 3% of R, non-extreme disabled
windows, and disabled mean absolute deviation at least twice the enabled one.
Packet metadata carries an 11-bit per-source ID and a 16-bit actual packet
length.  Long runs therefore compare
accepted and output multiplicity for every `(source,ID)` instead of assuming
the ID never wraps; the unwrapped source sequence is still used to generate
scheduling ranks.  The test limits measurement length to 4000 service
intervals so those 16-bit ranks do not wrap in the configured workload.
As in the other tests, this demonstrates aggregate eligibility shaping under
the measured contention pattern, not a strict physical-egress sliding-window
pacer after arbitrary prolonged backpressure.

## Verification

Run from PowerShell:

```powershell
./sim_heterogeneous.ps1 -Test recursive_schedule
./sim_heterogeneous.ps1 -Test recursive_performance
./sim_heterogeneous.ps1 -Test three_tier_token_bucket
./sim_heterogeneous.ps1 -Test three_tier_rate_sweep
./sim_heterogeneous.ps1 -Test three_tier_node_y_rate_sweep
./sim_heterogeneous.ps1 -Test three_tier_node_y
./sim_heterogeneous.ps1 -Test three_tier_node_y_multistream
./sim_heterogeneous.ps1 -Test three_tier_node_y_ab -TargetBps 2000000000
./sim_heterogeneous.ps1 -Test three_tier_node_y_hierarchical_ab `
  -TargetBps 2000000000 -SustainedIntervals 2000
./sim_heterogeneous.ps1 -Test three_tier_node_y_multistream_sustained `
  -TargetBps 10000000000 -SustainedIntervals 3000
./sim_heterogeneous.ps1 -Test shaping_stage28
./sim_heterogeneous.ps1 -Test shaping_stage5
```

The directed Token-Bucket test configures an empty bucket and three D packets
with service time 8 cycles.  It checks computed eligibility times, no early
release, exactly-once admission, per-node counts, final drain, and the output
order across Root SP, X/Y WFQ ranks, and Z SP ranks.

The current Verilator result is:

```text
D_ELIGIBILITY,12,20,28
D_ACTUAL_RELEASE,41,52,63
```

The difference is BMW/timing-release processing delay, not an eligibility
violation.  `actual_release_time >= eligibility_time` holds for every event.

The dequeue-only scheduling microbenchmark preloads 48 packets, then excludes
fill/drain from its completion window.  With a 125 MHz clock assumption it
currently reports:

| Path | Request window | Completion window | Completion rate | Packets/s at 125 MHz |
|---|---:|---:|---:|---:|
| Root | 102 cycles | 283 cycles | 0.169611 pkt/cycle | 21,201,413 |
| X -> Root | 113 cycles | 283 cycles | 0.169611 pkt/cycle | 21,201,413 |
| Z -> Y -> Root | 129 cycles | 283 cycles | 0.169611 pkt/cycle | 21,201,413 |

These are RTL-simulation service rates, not a post-route line-rate claim.
Replace 125 MHz with the achieved post-route clock before reporting hardware
packets/s.  Longer paths increase request/E2E latency, while the shared Root
BMW execution path determines the steady completion rate in this workload.

## 1500-byte rate sweep

`ThreeTierTokenBucketRateSweep_tb.sv` drives the complete timing and scheduling
domains at a modeled 125 MHz clock.  Each rate case uses twelve fixed 1500-byte
D packets, an explicitly empty bucket, and `bucket_capacity_time=0`, so the
bucket behaves as a strict eligibility-time pacer with no idle burst credit.

The experiment computes:

```text
packet_service_time = ceil(1500 * 8 * 125 MHz / target_rate)
```

The measured results are:

| Target | Service cycles | Eligibility gap | Admission gap | Measured admission rate | Maximum admission delay |
|---:|---:|---:|---:|---:|---:|
| 0.1 Gbit/s | 15000 | 15000 | 15000 | 0.1 Gbit/s | 11 cycles |
| 0.2 Gbit/s | 7500 | 7500 | 7500 | 0.2 Gbit/s | 11 cycles |
| 0.5 Gbit/s | 3000 | 3000 | 3000 | 0.5 Gbit/s | 11 cycles |
| 1.0 Gbit/s | 1500 | 1500 | 1500 | 1.0 Gbit/s | 11 cycles |
| 2.0 Gbit/s | 750 | 750 | 750 | 2.0 Gbit/s | 11 cycles |
| 5.0 Gbit/s | 300 | 300 | 300 | 5.0 Gbit/s | 11 cycles |
| 10 Gbit/s | 150 | 150 | 150 | 10 Gbit/s | 11 cycles |

Thus, without scheduling contention, both computed eligibility and actual
timing-to-scheduling admission exactly match all seven configured rates.  The
11-cycle BMW/release pipeline delay is constant across the packets and does
not change their spacing.

The same test also characterizes the known catch-up boundary.  Four 10 Gbit/s
D releases are allowed to become due while continuous direct Scheduling Push
work blocks shaping admission.  The ReleaseFIFO retains all four events, but
after the direct workload stops their admission gap is only five cycles rather
than the configured 150 cycles:

```text
CATCHUP_RESULT,target_mbps=10000,service_cycles=150,
queued_releases=4,direct_blockers=153,
actual_gap_min=5,actual_gap_max=5,
catchup_bps=300000000000,deferred_cycles=470
```

This confirms that the current RTL is an exact eligibility-time Token Bucket
under normal admission, but it is not yet a strict physical-egress or
sliding-window rate limiter after downstream backpressure.  Enforcing that
stronger contract requires token revalidation at Scheduling admission or at
packet output.

## Y split packet-output rate sweep

The parameterized rate-sweep testbench can also exercise the split Y path:

```powershell
./sim_heterogeneous.ps1 -Test three_tier_node_y_rate_sweep
```

This mode sets `SPLIT_SHAPING=1`, `SHAPED_TARGET_NODE=Y`, and sends C packets
with `target=Y`.  For every rate case it first waits for all twelve LOCAL
Pushes and verifies the pre-release state `Y=12, Root=0`.  It then consumes
one packet after each due `PARENT_REF(Y)` admission and records three rates:

```text
Token Bucket eligibility
PARENT_REF admission into Root
final Root -> Y recursive packet output
```

With 1500-byte packets, a modeled 125 MHz clock, no scheduling contention,
and an empty zero-capacity bucket, the current result is:

| Target | Service cycles | Eligibility rate | Root admission rate | Y packet-output rate | Maximum admission delay |
|---:|---:|---:|---:|---:|---:|
| 0.1 Gbit/s | 15000 | 0.1 Gbit/s | 0.1 Gbit/s | 0.1 Gbit/s | 11 cycles |
| 0.2 Gbit/s | 7500 | 0.2 Gbit/s | 0.2 Gbit/s | 0.2 Gbit/s | 11 cycles |
| 0.5 Gbit/s | 3000 | 0.5 Gbit/s | 0.5 Gbit/s | 0.5 Gbit/s | 11 cycles |
| 1.0 Gbit/s | 1500 | 1.0 Gbit/s | 1.0 Gbit/s | 1.0 Gbit/s | 11 cycles |
| 2.0 Gbit/s | 750 | 2.0 Gbit/s | 2.0 Gbit/s | 2.0 Gbit/s | 11 cycles |
| 5.0 Gbit/s | 300 | 5.0 Gbit/s | 5.0 Gbit/s | 5.0 Gbit/s | 11 cycles |
| 10 Gbit/s | 150 | 10 Gbit/s | 10 Gbit/s | 10 Gbit/s | 11 cycles |

The minimum and maximum packet-output gaps equal the configured service time
in every case.  This demonstrates exact Y output spacing for the tested
uncontended continuous-consumer workload.  It does not supersede the mixed
backpressure result above: queued due releases can still catch up in a burst
when Root admission was previously blocked.

## Multi-shard timing-head invariant

`ShapingLogicalHeadSummary.sv` now invalidates a logical summary whenever any
owned physical shard has an update in flight.  Previously it could ignore the
updating shard and reserve a later stable sibling head.  In the D test this
manifested as reserving release rank 20 while the directory correctly popped
rank 12.  The registered summary is also masked by the live pending-update
vector, preventing a one-cycle stale-head issue.

## Vivado 2019.2

`elaborate_three_tier_token_bucket_vivado.tcl` elaborates the complete top for
`xcu200-fsgd2104-2-e`.  The current run completes with zero errors, zero
critical warnings, and zero multi-driven nets.  The physical-shard debug-port
revision was re-elaborated successfully in
`vivado_non_work_conserving_multistream.log`.

`implement_three_tier_token_bucket_vivado.tcl` now runs constrained synthesis,
optimization, placement, physical optimization, routing, DRC, post-route STA,
and utilization reporting for the current aggregate-Y top.  It also emits the
routed checkpoint, timing simulation netlist, and SDF.  The implementation
configuration is:

```text
part                 = xcu200-fsgd2104-2-e
top                  = ThreeTierTokenBucketVPIFO
clock                = 8.000 ns / 125 MHz
SPLIT_SHAPING        = 1
SHAPED_TARGET_NODE   = Y (2)
SEQUENCE_WIDTH       = 32
```

The clock-only OOC run `current_125mhz_20260820` is fully routed and gives the
following internal register-to-register result:

| Metric | Post-route result |
|---|---:|
| Setup WNS / TNS | +1.071 ns / 0 ns |
| Setup failing / total endpoints | 0 / 56,186 |
| Hold WNS / THS | +0.030 ns / 0 ns |
| Hold failing / total endpoints | 0 / 56,186 |
| Unconstrained internal endpoints | 0 |
| Registers without clocks | 0 |

The worst setup path is from
`schedule_domain/core/logical_pending/slot_valid_reg[13]` to
`schedule_domain/context_tag_mem_reg[3][12][0]/CE`: 6.825 ns data path,
1.565 ns logic, 5.260 ns route, and 18 logic levels.  Vivado reports that all
specified timing constraints are met.

Post-route resource use is:

| Resource | Used | U200 utilization |
|---|---:|---:|
| CLB LUTs | 28,358 | 2.40% |
| LUT as memory | 3,240 | 0.55% |
| CLB registers | 16,345 | 0.69% |
| BRAM / URAM / DSP | 0 / 0 / 0 | 0% |
| RAMD64E / RAMD32 | 2,904 / 588 | n/a |

The zero BRAM/URAM count is significant: the current BMW SRAM structures are
being implemented primarily as distributed RAM, so this result is not yet a
resource-scalability proof for much larger capacities.  DRC reports one
`RTSTAT-10` warning for OOC outputs/debug nets with no routable load; it does
not report a routing error.

The clock-only OOC run intentionally has no external interface contract:
330 synchronous input ports have no input delay and 322 outputs have no output
delay.  A second fully routed run,
`current_125mhz_io1ns_20260820`, applies a documented OOC assumption of 1 ns
maximum input delay, 0 ns minimum input delay, 1 ns maximum output delay, and
0 ns minimum output delay.  This removes all no-input/no-output-delay findings,
but its timing result is:

```text
setup WNS/TNS       = +0.889 ns / 0 ns
hold WNS/THS        = -0.080 ns / -11.544 ns
hold failing points = 212 / 56,659
```

The worst hold path is the zero-logic-level OOC interface path
`i_d_packet_data[20] -> split_schedule_bundle_reg[20]/D`, not an internal
Timing/Scheduling register-to-register path.  Vivado also warns that OOC ports
lack `HD.PARTPIN_LOCS`, so their partial physical routes are not an accurate
model of the eventual shell connection.  This run must therefore be reported
as an interface-budget hold failure, not as timing closure.  The implementation
script now exits nonzero whenever either setup or hold slack is negative.

The defensible current conclusion is: the synthesized core's internal paths
meet 125 MHz after routing, while U200 shell/CMAC/PCIe integration timing is
still unproven.  Closing that boundary requires the real wrapper registers,
clock uncertainty, partition pins or shell placement, and actual input/output
delay constraints.  Routed Verilog and SDF have been generated, but the result
above is post-route static timing analysis; no SDF-annotated dynamic test has
yet been claimed.

## Verilator lint

The final sustained top was linted with Verilator 5.032 using `--lint-only
--timing` and the same 21 RTL/testbench modules used for the sustained build.
The result is zero errors.  The remaining warnings are pre-existing width and
combinational-structure diagnostics:

```text
WIDTHEXPAND = 14
WIDTHTRUNC  = 2
UNOPTFLAT   = 1
errors      = 0
```

The warnings are in `TaskDistribute.sv`, `PIFO_SRAM.sv`, `ShardDirectory.sv`,
`PopResultFIFO.sv`, `HeterogeneousPIFO.sv`, and
`RecursiveScheduleTreeHeterogeneousPIFO.sv`.  The sustained testbench's
wall-time and longint arithmetic casts are clean.  The complete lint output is
preserved in `verilator_sustained_lint.log`.

## Recursive-Pop window and 150 MHz follow-up

The sustained consumer is now parameterized by `SUSTAINED_POP_WINDOW`.  A
Root Pop is issued only when the outstanding count is below this window, the
visible Root count exceeds the already-reserved outstanding count, the
32-entry scheduling pending buffer is at or below 24 entries, and no due Y
release is waiting.  The last two guards preserve space and an arbitration
opportunity for `PARENT_REF(Y)`, avoiding the earlier speculative-Pop
deadlock.  The historical default remains one outstanding Pop; performance
rate curves explicitly use the measured minimum safe window of two.

At 125 MHz, 1500-byte packets, a 50 Gbit/s Y aggregate limit, and 3000 service
intervals, the controlled window sweep produced:

| Pop window | Eligibility | Root admission | Y output | Max actual outstanding | Max pending |
|---:|---:|---:|---:|---:|---:|
| 1 | 38.250 Gbit/s | 38.250 Gbit/s | 37.033 Gbit/s | 1 | 6 |
| 2 | 50.000 Gbit/s | 50.000 Gbit/s | 50.000 Gbit/s | 2 | 5 |
| 4 | 50.000 Gbit/s | 50.000 Gbit/s | 50.000 Gbit/s | 2 | 5 |
| 8 | 50.000 Gbit/s | 50.000 Gbit/s | 50.000 Gbit/s | 2 | 5 |

Every case drained, had equal accepted/output packet totals, and reported zero
protocol errors.  Thus the earlier approximately 34 Gbit/s high-rate result
was primarily a single-outstanding testbench limit, not the Token Bucket or
BMW-tree's demonstrated intrinsic ceiling.  Two outstanding recursive Pops
are sufficient for this workload; larger configured windows do not increase
actual concurrency.

The testbench clock and bit-rate accounting are also parameterized by
`CLOCK_FREQUENCY_HZ`.  At 150 MHz the 50 Gbit/s service interval is 36 cycles.
With a Pop window of two, transaction acceptance, eligibility, Root admission,
and final Y output all measured exactly 50.000 Gbit/s.  Work and the local Y/Z
subtree were backlogged for 100% of the measurement; the maximum outstanding
and pending counts were two and five.  All 4768 accepted packets were output,
including all 3096 shaped packets, with zero protocol errors.

The complete `ThreeTierTokenBucketVPIFO` was then implemented out of context
on `xcu200-fsgd2104-2-e` at a 6.666667 ns clock period.  Post-route setup WNS
is +0.711 ns, hold WNS is +0.034 ns, and routing completed with no failed nets,
critical warnings, or errors.  The worst setup path is an internal Timing
domain path from the shaping PopResultFIFO dequeue data register to the timing
completion-data register; its data-path delay is 5.938 ns.  Post-route use is
28,402 CLB LUTs, including 3240 LUTs as memory, and 16,345 CLB registers, with
no BRAM, URAM, or DSP inference.  This remains an OOC result with unconstrained
external interfaces and unset `HD.PARTPIN_LOCS`; it demonstrates internal
150 MHz timing closure, not shell-level U200 timing closure.
