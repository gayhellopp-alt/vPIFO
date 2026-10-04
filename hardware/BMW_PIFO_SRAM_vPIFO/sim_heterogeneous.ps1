param(
    [ValidateSet("directory", "duplicate_update", "fifo", "pending", "heterogeneous", "performance", "multi_pop", "warm_reset", "hierarchical", "hierarchical_alt", "schedule_forest", "recursive_schedule", "recursive_performance", "shaping_arbiter", "shaping_event_table", "shaping_stage28", "shaping_sequence_wrap", "shaping_stage45", "shaping_transaction", "shaping_stage5", "three_tier_token_bucket", "three_tier_rate_sweep", "three_tier_node_y_rate_sweep", "three_tier_node_y", "three_tier_node_y_multistream", "three_tier_node_y_multistream_sustained", "three_tier_node_y_ab", "three_tier_node_y_hierarchical_ab", "generalized", "generalized_forest", "generated_flat", "generated_hierarchical")]
    [string]$Test = "heterogeneous",
    [ValidateRange(1, 1024)]
    [int]$PendingDepth = 12,
    [ValidateRange(1, 1000000000000)]
    [UInt64]$TargetBps = 10000000000,
    [ValidateRange(1000000, 1000000000)]
    [UInt64]$ClockHz = 125000000,
    [ValidateRange(8, 1000000)]
    [int]$SustainedIntervals = 3000,
    [ValidateRange(-16, 75)]
    [int]$YShareOffsetPercent = 0,
    [ValidateRange(0, 1000000)]
    [int]$DisabledExpectedMbps = 0,
    [ValidateRange(1, 16)]
    [int]$PopWindow = 1,
    [ValidateRange(4, 1024)]
    [int]$SchedulePendingDepth = 32,
    [ValidateRange(2, 1024)]
    [int]$SchedulePopTrackDepth = 32,
    [ValidateRange(1, 64)]
    [int]$TimingSequenceWidth = 32,
    [switch]$RateCurveMode,
    [ValidatePattern('^[A-Za-z0-9_-]*$')]
    [string]$BuildTag = ""
)

$drive = $PSScriptRoot.Substring(0, 1).ToLowerInvariant()
$relative = $PSScriptRoot.Substring(2).Replace('\', '/')
$linuxDirectory = "/mnt/$drive$relative"
$configPackage = "generated/vpifo_config_pkg.sv"

if ($Test -eq "directory") {
    $top = "ShardDirectory_tb"
    $sources = "$configPackage ShardDirectory.sv ShardDirectory_tb.sv"
    $outputDirectory = "obj_dir_shard"
} elseif ($Test -eq "duplicate_update") {
    $top = "ShardDirectory_duplicate_update_tb"
    $sources = "$configPackage ShardDirectory.sv ShardDirectory_duplicate_update_tb.sv"
    $outputDirectory = "obj_dir_shard_duplicate_update"
} elseif ($Test -eq "fifo") {
    $top = "PopResultFIFO_tb"
    $sources = "PopResultFIFO.sv PopResultFIFO_tb.sv"
    $outputDirectory = "obj_dir_pop_fifo"
} elseif ($Test -eq "pending") {
    $top = "LogicalRequestBuffer_tb"
    $sources = "LogicalRequestBuffer.sv LogicalRequestBuffer_tb.sv"
    $outputDirectory = "obj_dir_logical_pending"
} elseif ($Test -eq "heterogeneous") {
    $top = "HeterogeneousPIFO_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HeterogeneousPIFO_tb.sv"
    $outputDirectory = "obj_dir_hetero"
} elseif ($Test -eq "performance") {
    $top = "HeterogeneousPIFO_perf_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HeterogeneousPIFO_perf_tb.sv"
    $outputDirectory = "obj_dir_hetero_perf"
} elseif ($Test -eq "multi_pop") {
    $top = "HeterogeneousPIFO_multi_pop_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HeterogeneousPIFO_multi_pop_tb.sv"
    $outputDirectory = "obj_dir_hetero_multi_pop"
} elseif ($Test -eq "warm_reset") {
    $top = "HeterogeneousPIFO_warm_reset_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HeterogeneousPIFO_warm_reset_tb.sv"
    $outputDirectory = "obj_dir_hetero_warm_reset"
} elseif ($Test -eq "hierarchical") {
    $top = "HierarchicalHeterogeneousPIFO_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HierarchicalHeterogeneousPIFO.sv HierarchicalHeterogeneousPIFO_tb.sv"
    $outputDirectory = "obj_dir_hierarchical"
} elseif ($Test -eq "hierarchical_alt") {
    $top = "HierarchicalHeterogeneousPIFO_alt_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HierarchicalHeterogeneousPIFO.sv HierarchicalHeterogeneousPIFO_alt_tb.sv"
    $outputDirectory = "obj_dir_hierarchical_alt"
} elseif ($Test -eq "schedule_forest") {
    $top = "ScheduleForestHeterogeneousPIFO_tb"
    $sources = "$configPackage generated_forest/generalized_vpifo_config_pkg.sv INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv ScheduleForestHeterogeneousPIFO.sv ScheduleForestHeterogeneousPIFO_tb.sv"
    $outputDirectory = "obj_dir_schedule_forest"
} elseif ($Test -eq "recursive_schedule") {
    $top = "RecursiveScheduleTreeHeterogeneousPIFO_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv RecursiveScheduleTreeHeterogeneousPIFO.sv RecursiveScheduleTreeHeterogeneousPIFO_tb.sv"
    $outputDirectory = "obj_dir_recursive_schedule"
} elseif ($Test -eq "recursive_performance") {
    $top = "RecursiveScheduleTreePerformance_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv RecursiveScheduleTreeHeterogeneousPIFO.sv RecursiveScheduleTreePerformance_tb.sv"
    $outputDirectory = "obj_dir_recursive_schedule_perf"
} elseif ($Test -eq "shaping_arbiter") {
    $top = "ShapingDueArbiter_tb"
    $sources = "ShapingDueArbiter.sv ShapingDueArbiter_tb.sv"
    $outputDirectory = "obj_dir_shaping_arbiter"
} elseif ($Test -eq "shaping_event_table") {
    $top = "ShapingEventTable_tb"
    $sources = "ShapingEventTable.sv ShapingEventTable_tb.sv"
    $outputDirectory = "obj_dir_shaping_event_table_o2a"
} elseif ($Test -eq "shaping_stage28") {
    $top = "MultiLogicalShapingPIFO_stage28_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv MultiLogicalShapingPIFO_stage28_tb.sv"
    $outputDirectory = "obj_dir_shaping_stage28"
} elseif ($Test -eq "shaping_sequence_wrap") {
    $top = "MultiLogicalShapingPIFO_sequence_wrap_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv MultiLogicalShapingPIFO_sequence_wrap_tb.sv"
    $outputDirectory = "obj_dir_shaping_sequence_wrap"
} elseif ($Test -eq "shaping_stage45") {
    $top = "NonWorkConservingPIFOStage45_tb"
    $sources = "$configPackage generated/generalized_vpifo_config_pkg.sv INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HierarchicalHeterogeneousPIFO.sv ScheduleForestHeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv ShapingReleaseToParent.sv NonWorkConservingPIFOStage45.sv NonWorkConservingPIFOStage45_tb.sv"
    $outputDirectory = "obj_dir_shaping_stage45"
} elseif ($Test -eq "shaping_transaction") {
    $top = "ShapingTransactionEngine_tb"
    $sources = "ShapingTransactionEngine.sv ShapingTransactionEngine_tb.sv"
    $outputDirectory = "obj_dir_shaping_transaction"
} elseif ($Test -eq "shaping_stage5") {
    $top = "NonWorkConservingPIFOStage5_tb"
    $sources = "$configPackage generated/generalized_vpifo_config_pkg.sv INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HierarchicalHeterogeneousPIFO.sv ScheduleForestHeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv ShapingReleaseToParent.sv NonWorkConservingPIFOStage45.sv ShapingTransactionEngine.sv NonWorkConservingPIFOStage5.sv NonWorkConservingPIFOStage5_tb.sv"
    $outputDirectory = "obj_dir_shaping_stage5"
} elseif ($Test -eq "three_tier_token_bucket") {
    $top = "ThreeTierTokenBucketVPIFO_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv ShapingReleaseToParent.sv ShapingTransactionEngine.sv RecursiveScheduleTreeHeterogeneousPIFO.sv ThreeTierTokenBucketVPIFO.sv ThreeTierTokenBucketVPIFO_tb.sv"
    $outputDirectory = "obj_dir_three_tier_token_bucket"
} elseif ($Test -eq "three_tier_rate_sweep") {
    $top = "ThreeTierTokenBucketRateSweep_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv ShapingReleaseToParent.sv ShapingTransactionEngine.sv RecursiveScheduleTreeHeterogeneousPIFO.sv ThreeTierTokenBucketVPIFO.sv ThreeTierTokenBucketRateSweep_tb.sv"
    $outputDirectory = "obj_dir_three_tier_rate_sweep"
} elseif ($Test -eq "three_tier_node_y_rate_sweep") {
    $top = "ThreeTierTokenBucketRateSweep_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv ShapingReleaseToParent.sv ShapingTransactionEngine.sv RecursiveScheduleTreeHeterogeneousPIFO.sv ThreeTierTokenBucketVPIFO.sv ThreeTierTokenBucketRateSweep_tb.sv"
    $outputDirectory = "obj_dir_three_tier_node_y_rate_sweep"
} elseif ($Test -eq "three_tier_node_y") {
    $top = "ThreeTierNodeYTokenBucket_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv ShapingReleaseToParent.sv ShapingTransactionEngine.sv RecursiveScheduleTreeHeterogeneousPIFO.sv ThreeTierTokenBucketVPIFO.sv ThreeTierNodeYTokenBucket_tb.sv"
    $outputDirectory = "obj_dir_three_tier_node_y"
} elseif ($Test -eq "three_tier_node_y_multistream") {
    $top = "ThreeTierNodeYMultiStream_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv ShapingReleaseToParent.sv ShapingTransactionEngine.sv RecursiveScheduleTreeHeterogeneousPIFO.sv ThreeTierTokenBucketVPIFO.sv ThreeTierNodeYMultiStream_tb.sv"
    $outputDirectory = "obj_dir_three_tier_node_y_multistream"
} elseif ($Test -eq "three_tier_node_y_multistream_sustained") {
    $top = "ThreeTierNodeYMultiStream_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv ShapingReleaseToParent.sv ShapingTransactionEngine.sv RecursiveScheduleTreeHeterogeneousPIFO.sv ThreeTierTokenBucketVPIFO.sv ThreeTierNodeYMultiStream_tb.sv"
    $outputDirectory = "obj_dir_three_tier_node_y_multistream_sustained"
} elseif ($Test -eq "three_tier_node_y_ab") {
    $top = "ThreeTierNodeYShapingAB_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv ShapingReleaseToParent.sv ShapingTransactionEngine.sv RecursiveScheduleTreeHeterogeneousPIFO.sv ThreeTierTokenBucketVPIFO.sv ThreeTierNodeYShapingAB_tb.sv"
    $outputDirectory = "obj_dir_three_tier_node_y_ab"
} elseif ($Test -eq "three_tier_node_y_hierarchical_ab") {
    $top = "ThreeTierNodeYHierarchicalSustainedAB_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv ShapingReleaseToParent.sv ShapingTransactionEngine.sv RecursiveScheduleTreeHeterogeneousPIFO.sv ThreeTierTokenBucketVPIFO.sv ThreeTierNodeYHierarchicalSustainedAB_tb.sv"
    $outputDirectory = "obj_dir_three_tier_node_y_hierarchical_ab"
} elseif ($Test -eq "generalized") {
    $top = "GeneralizedVPIFO_tb"
    $sources = "$configPackage generated/generalized_vpifo_config_pkg.sv INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HierarchicalHeterogeneousPIFO.sv ScheduleForestHeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv ShapingReleaseToParent.sv NonWorkConservingPIFOStage45.sv ShapingTransactionEngine.sv NonWorkConservingPIFOStage5.sv VPIFOConnectionTable.sv GeneralizedVPIFO.sv GeneralizedVPIFO_tb.sv"
    $outputDirectory = "obj_dir_generalized"
} elseif ($Test -eq "generalized_forest") {
    $top = "GeneralizedVPIFOForest_tb"
    $sources = "$configPackage generated_forest/generalized_vpifo_config_pkg.sv INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HierarchicalHeterogeneousPIFO.sv ScheduleForestHeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv ShapingReleaseToParent.sv NonWorkConservingPIFOStage45.sv ShapingTransactionEngine.sv NonWorkConservingPIFOStage5.sv VPIFOConnectionTable.sv GeneralizedVPIFO.sv GeneralizedVPIFOForest_tb.sv"
    $outputDirectory = "obj_dir_generalized_forest"
} elseif ($Test -eq "generated_flat") {
    $top = "GeneratedHeterogeneousPIFO_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv GeneratedHeterogeneousPIFO_tb.sv"
    $outputDirectory = "obj_dir_generated_flat"
} else {
    $top = "GeneratedHierarchicalHeterogeneousPIFO_tb"
    $sources = "$configPackage INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HierarchicalHeterogeneousPIFO.sv GeneratedHierarchicalHeterogeneousPIFO_tb.sv"
    $outputDirectory = "obj_dir_generated_hierarchical"
}

$parameterArgument = ""
if ($Test -in @("heterogeneous", "performance")) {
    $parameterArgument = "-GLOGICAL_PENDING_DEPTH=$PendingDepth"
    if ($PendingDepth -ne 12) {
        $outputDirectory = "${outputDirectory}_d${PendingDepth}"
    }
}
$nonConservingTests = @(
    "three_tier_token_bucket",
    "three_tier_rate_sweep",
    "three_tier_node_y_rate_sweep",
    "three_tier_node_y",
    "three_tier_node_y_multistream",
    "three_tier_node_y_multistream_sustained",
    "three_tier_node_y_ab",
    "three_tier_node_y_hierarchical_ab"
)
if ($Test -in $nonConservingTests) {
    $parameterArgument =
        "-GSCHEDULE_PENDING_DEPTH=$SchedulePendingDepth " +
        "-GSCHEDULE_POP_TRACK_DEPTH=$SchedulePopTrackDepth"
    $outputDirectory =
        "${outputDirectory}_sched${SchedulePendingDepth}_track${SchedulePopTrackDepth}"
}
if ($Test -eq "three_tier_node_y_rate_sweep") {
    $parameterArgument += " -GSPLIT_SHAPING=1 -GSHAPED_TARGET_NODE=2 " +
        "-GINGRESS_TARGET_NODE=2 -GSTREAM_OUTPUT=1 -GRUN_CATCHUP=0"
}
if ($Test -eq "three_tier_node_y_multistream") {
    $packetBits = [UInt64]1500 * [UInt64]8
    $clockHz = [UInt64]125000000
    $serviceNumerator = $packetBits * $clockHz
    $serviceTime = [UInt64][math]::Floor(
        ([double]$serviceNumerator) / ([double]$TargetBps))
    if (($serviceNumerator % [UInt64]$TargetBps) -ne 0) {
        $serviceTime++
    }
    $parameterArgument += " -GTARGET_SERVICE_TIME=$serviceTime"
    $parameterArgument +=
        " -GTIMING_SEQUENCE_WIDTH=$TimingSequenceWidth"
    if ($TargetBps -ne 10000000000) {
        $outputDirectory = "${outputDirectory}_$TargetBps"
    }
}
if ($Test -eq "three_tier_node_y_multistream_sustained") {
    $packetBits = [UInt64]1500 * [UInt64]8
    $serviceNumerator = $packetBits * $ClockHz
    $serviceTime = [UInt64][math]::Floor(
        ([double]$serviceNumerator) / ([double]$TargetBps))
    if (($serviceNumerator % [UInt64]$TargetBps) -ne 0) {
        $serviceTime++
    }
    $parameterArgument += " -GSUSTAINED_MODE=1 " +
        "-GTARGET_SERVICE_TIME=$serviceTime " +
        "-GCLOCK_FREQUENCY_HZ=$ClockHz " +
        "-GSUSTAINED_POP_WINDOW=$PopWindow " +
        "-GTIMING_SEQUENCE_WIDTH=$TimingSequenceWidth " +
        "-GSUSTAINED_MEASUREMENT_SERVICE_INTERVALS=$SustainedIntervals"
    if ($RateCurveMode) {
        $parameterArgument += " -GSUSTAINED_RATE_CURVE_MODE=1"
    }
    $outputDirectory = "${outputDirectory}_${TargetBps}_${ClockHz}_w${PopWindow}"
}
if (($Test -in @(
        "three_tier_node_y_multistream",
        "three_tier_node_y_multistream_sustained")) -and
    ($TimingSequenceWidth -ne 32)) {
    $outputDirectory = "${outputDirectory}_seq${TimingSequenceWidth}"
}
if ($Test -eq "three_tier_node_y_ab") {
    $packetBits = [UInt64]1500 * [UInt64]8
    $clockHz = [UInt64]125000000
    $serviceNumerator = $packetBits * $clockHz
    $serviceTime = [UInt64][math]::Floor(
        ([double]$serviceNumerator) / ([double]$TargetBps))
    if (($serviceNumerator % [UInt64]$TargetBps) -ne 0) {
        $serviceTime++
    }
    $parameterArgument += " -GTARGET_SERVICE_TIME=$serviceTime"
    $outputDirectory = "${outputDirectory}_$TargetBps"
}
if ($Test -eq "three_tier_node_y_hierarchical_ab") {
    $packetBits = [UInt64]1500 * [UInt64]8
    $clockHz = [UInt64]125000000
    $serviceNumerator = $packetBits * $clockHz
    $serviceTime = [UInt64][math]::Floor(
        ([double]$serviceNumerator) / ([double]$TargetBps))
    if (($serviceNumerator % [UInt64]$TargetBps) -ne 0) {
        $serviceTime++
    }
    $parameterArgument += " -GTARGET_SERVICE_TIME=$serviceTime " +
        "-GMEASUREMENT_SERVICE_INTERVALS=$SustainedIntervals " +
        "-GY_SHARE_OFFSET_PERCENT=$YShareOffsetPercent " +
        "-GDISABLED_EXPECTED_MBPS=$DisabledExpectedMbps"
    $outputDirectory = "${outputDirectory}_${TargetBps}_${SustainedIntervals}"
    if ($YShareOffsetPercent -ne 0) {
        $outputDirectory =
            "${outputDirectory}_yshare${YShareOffsetPercent}"
    }
}
if ($BuildTag -ne "") {
    $outputDirectory = "${outputDirectory}_$BuildTag"
}

$runCommand = "./$outputDirectory/V$top"
if ($Test -in @(
        "three_tier_node_y_ab",
        "three_tier_node_y_hierarchical_ab")) {
    # These testbenches emit CSV files with fixed names.  Run from their
    # parameter-specific build directory so O0/O1 artifacts cannot overwrite
    # one another or the historical CSVs in the RTL source directory.
    $runCommand = "cd '$outputDirectory' && ./V$top"
}

$command = "cd '$linuxDirectory' && verilator --binary --timing " +
    "-Wno-fatal $parameterArgument --top-module $top $sources " +
    "-Mdir $outputDirectory && $runCommand"
& "$env:SystemRoot\System32\wsl.exe" sh -lc $command
exit $LASTEXITCODE
