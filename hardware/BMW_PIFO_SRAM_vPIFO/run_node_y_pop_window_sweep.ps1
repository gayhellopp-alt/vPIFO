param(
    [ValidateRange(1, 1000000000000)]
    [UInt64]$TargetBps = 50000000000,
    [ValidateRange(1000000, 1000000000)]
    [UInt64]$ClockHz = 125000000,
    [ValidateRange(8, 10000)]
    [int]$SustainedIntervals = 3000
)

$ErrorActionPreference = "Stop"
$windows = @(1, 2, 4, 8)
$resultDirectory = Join-Path $PSScriptRoot `
    "node_y_pop_window_logs_${ClockHz}hz_${TargetBps}bps"
New-Item -ItemType Directory -Force -Path $resultDirectory | Out-Null
$simulationScript = Join-Path $PSScriptRoot "sim_heterogeneous.ps1"
$records = @()

foreach ($window in $windows) {
    Write-Host "Running Node-Y Pop window $window at $ClockHz Hz, target $TargetBps bit/s"
    $logPath = Join-Path $resultDirectory "pop_window_$window.log"
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    $output = & $simulationScript `
        -Test three_tier_node_y_multistream_sustained `
        -TargetBps $TargetBps `
        -ClockHz $ClockHz `
        -PopWindow $window `
        -SustainedIntervals $SustainedIntervals `
        -RateCurveMode 2>&1
    $simulationExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedErrorActionPreference
    $output | Set-Content -LiteralPath $logPath -Encoding UTF8

    if ($simulationExitCode -ne 0) {
        $output | Select-Object -Last 50 | ForEach-Object { Write-Host $_ }
        throw "Node-Y Pop-window experiment failed for window $window; see $logPath"
    }

    $metrics = @{}
    foreach ($line in $output) {
        $lineText = [string]$line
        if ($lineText -match '^([A-Za-z][A-Za-z0-9_]*)=(.*)$') {
            $metrics[$matches[1]] = $matches[2]
        }
    }
    foreach ($requiredMetric in @(
        "clock_frequency_hz", "pop_window", "eligibility_timestamp_window_bps",
        "root_admission_window_bps", "packet_output_window_bps",
        "protocol_error")) {
        if (!$metrics.ContainsKey($requiredMetric)) {
            throw "Missing $requiredMetric for window $window; see $logPath"
        }
    }

    $records += [pscustomobject][ordered]@{
        clock_frequency_hz = $metrics.clock_frequency_hz
        target_bps = $TargetBps
        effective_configured_rate_bps = $metrics.effective_configured_rate_bps
        service_cycles = $metrics.service_cycles
        pop_window = $metrics.pop_window
        measurement_cycles = $metrics.measurement_cycles
        measurement_transaction_packets = $metrics.measurement_transaction_packets
        measurement_eligibility_timestamps = $metrics.measurement_eligibility_timestamps
        measurement_root_admissions = $metrics.measurement_root_admissions
        measurement_pop_accepts = $metrics.measurement_pop_accepts
        measurement_shaped_packets = $metrics.measurement_shaped_packets
        transaction_acceptance_window_bps = $metrics.transaction_acceptance_window_bps
        eligibility_timestamp_window_bps = $metrics.eligibility_timestamp_window_bps
        root_admission_window_bps = $metrics.root_admission_window_bps
        packet_output_window_bps = $metrics.packet_output_window_bps
        transaction_acceptance_cycles_per_packet = $metrics.transaction_acceptance_cycles_per_packet
        eligibility_cycles_per_packet = $metrics.eligibility_cycles_per_packet
        root_admission_cycles_per_packet = $metrics.root_admission_cycles_per_packet
        packet_output_cycles_per_packet = $metrics.packet_output_cycles_per_packet
        max_schedule_outstanding = $metrics.max_schedule_outstanding
        max_schedule_pending = $metrics.max_schedule_pending
        work_backlogged_fraction = $metrics.work_backlogged_fraction
        local_subtree_backlogged_fraction = $metrics.local_subtree_backlogged_fraction
        timing_backlogged_fraction = $metrics.timing_backlogged_fraction
        eligible_release_backlogged_fraction = $metrics.eligible_release_backlogged_fraction
        deferred_cycles = $metrics.deferred_cycles
        max_release_delay = $metrics.max_release_delay
        total_accepted_packets = $metrics.total_accepted_packets
        total_output_packets = $metrics.total_output_packets
        shaped_accepted_packets = $metrics.shaped_accepted_packets
        shaped_output_packets = $metrics.shaped_output_packets
        protocol_error = $metrics.protocol_error
        raw_log = "$([IO.Path]::GetFileName($resultDirectory))/pop_window_$window.log"
    }

    Write-Host ("  eligibility={0:N3}, Root={1:N3}, output={2:N3} Gbit/s; max outstanding={3}, pending={4}" -f `
        ([double]$metrics.eligibility_timestamp_window_bps / 1.0e9), `
        ([double]$metrics.root_admission_window_bps / 1.0e9), `
        ([double]$metrics.packet_output_window_bps / 1.0e9), `
        $metrics.max_schedule_outstanding, $metrics.max_schedule_pending)
}

$csvPath = Join-Path $PSScriptRoot `
    "node_y_pop_window_sweep_${ClockHz}hz_${TargetBps}bps.csv"
$records | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
Write-Host "Pop-window statistics written to $csvPath"
