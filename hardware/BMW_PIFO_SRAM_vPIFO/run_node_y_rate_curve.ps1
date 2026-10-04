param(
    [ValidateRange(8, 10000)]
    [int]$SustainedIntervals = 3000,
    [ValidateRange(1000000, 1000000000)]
    [UInt64]$ClockHz = 125000000,
    [ValidateRange(1, 16)]
    [int]$PopWindow = 2
)

$ErrorActionPreference = "Stop"
$rates = @(
    [UInt64]100000000,
    [UInt64]200000000,
    [UInt64]500000000,
    [UInt64]1000000000,
    [UInt64]2000000000,
    [UInt64]5000000000,
    [UInt64]10000000000,
    [UInt64]20000000000,
    [UInt64]50000000000
)

$resultDirectory = Join-Path $PSScriptRoot `
    "node_y_rate_curve_logs_${ClockHz}hz_w${PopWindow}"
New-Item -ItemType Directory -Force -Path $resultDirectory | Out-Null
$simulationScript = Join-Path $PSScriptRoot "sim_heterogeneous.ps1"
$records = @()

foreach ($rate in $rates) {
    Write-Host "Running Node-Y aggregate rate limit $rate bit/s"
    $logPath = Join-Path $resultDirectory "node_y_$rate.log"
    # Windows PowerShell 5.1 wraps native stderr (including harmless Verilator
    # warnings) as ErrorRecord objects.  Keep collecting stderr in the log and
    # decide success from the simulator exit code instead of aborting on a
    # warning before $LASTEXITCODE can be inspected.
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $simulationScript `
        -Test three_tier_node_y_multistream_sustained `
        -TargetBps $rate `
        -ClockHz $ClockHz `
        -PopWindow $PopWindow `
        -SustainedIntervals $SustainedIntervals `
        -RateCurveMode 2>&1
    $simulationExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedErrorActionPreference
    $output | Set-Content -LiteralPath $logPath -Encoding UTF8

    if ($simulationExitCode -ne 0) {
        $output | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
        throw "Node-Y rate experiment failed for $rate bit/s; see $logPath"
    }

    $metrics = @{}
    foreach ($line in $output) {
        $lineText = [string]$line
        if ($lineText -match '^([A-Za-z][A-Za-z0-9_]*)=(.*)$') {
            $metrics[$matches[1]] = $matches[2]
        }
    }
    if (!$metrics.ContainsKey("packet_output_window_bps") -or
        !$metrics.ContainsKey("protocol_error")) {
        throw "Missing rate metrics for $rate bit/s; see $logPath"
    }

    $records += [pscustomobject][ordered]@{
        clock_frequency_hz = $metrics.clock_frequency_hz
        pop_window = $metrics.pop_window
        rate_limit_bps = $rate
        effective_configured_rate_bps = $metrics.effective_configured_rate_bps
        service_cycles = $metrics.service_cycles
        warmup_cycles = $metrics.warmup_cycles
        measurement_cycles = $metrics.measurement_cycles
        measurement_transaction_packets = $metrics.measurement_transaction_packets
        measurement_eligibility_timestamps = $metrics.measurement_eligibility_timestamps
        measurement_root_admissions = $metrics.measurement_root_admissions
        measurement_shaped_packets = $metrics.measurement_shaped_packets
        measurement_shaped_bytes = $metrics.measurement_shaped_bytes
        transaction_acceptance_window_bps = $metrics.transaction_acceptance_window_bps
        eligibility_timestamp_window_bps = $metrics.eligibility_timestamp_window_bps
        eligibility_timestamp_interval_bps = $metrics.eligibility_timestamp_interval_bps
        root_admission_window_bps = $metrics.root_admission_window_bps
        root_admission_interval_bps = $metrics.root_admission_interval_bps
        packet_output_window_bps = $metrics.packet_output_window_bps
        packet_output_interval_bps = $metrics.packet_output_interval_bps
        packet_output_envelope_bps = $metrics.packet_output_envelope_bps
        relative_error_percent = $metrics.relative_error_percent
        source_valid_fraction = $metrics.source_valid_fraction
        source_stalled_fraction = $metrics.source_stalled_fraction
        work_backlogged_fraction = $metrics.work_backlogged_fraction
        local_subtree_backlogged_fraction = $metrics.local_subtree_backlogged_fraction
        timing_backlogged_fraction = $metrics.timing_backlogged_fraction
        event_table_backlogged_fraction = $metrics.event_table_backlogged_fraction
        eligible_release_backlogged_fraction = $metrics.eligible_release_backlogged_fraction
        deferred_cycles = $metrics.deferred_cycles
        max_release_delay = $metrics.max_release_delay
        total_accepted_packets = $metrics.total_accepted_packets
        total_output_packets = $metrics.total_output_packets
        shaped_accepted_packets = $metrics.shaped_accepted_packets
        shaped_output_packets = $metrics.shaped_output_packets
        root_shard_pushes = $metrics.Root_shard_pushes
        x_pushes = $metrics.X_pushes
        y_pushes = $metrics.Y_pushes
        z_pushes = $metrics.Z_pushes
        protocol_error = $metrics.protocol_error
        raw_log = "$([IO.Path]::GetFileName($resultDirectory))/node_y_$rate.log"
    }

    Write-Host ("  achieved={0:N6} Gbit/s, protocol_error={1}" -f `
        ([double]$metrics.packet_output_window_bps / 1.0e9), `
        $metrics.protocol_error)
}

$csvPath = Join-Path $PSScriptRoot "node_y_rate_limit_curve.csv"
$records | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "Raw rate-curve statistics written to $csvPath"
