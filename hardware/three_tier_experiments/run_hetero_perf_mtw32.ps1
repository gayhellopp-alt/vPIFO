param(
    [ValidateRange(1, 1024)]
    [int]$PendingDepth = 12,
    [string]$BuildTag = "stage27_single_shard_rr"
)

$rtlDirectory = Join-Path $PSScriptRoot "..\BMW_PIFO_SRAM_vPIFO"
$drive = $rtlDirectory.Substring(0, 1).ToLowerInvariant()
$relative = $rtlDirectory.Substring(2).Replace('\', '/')
$linuxRtlDirectory = "/mnt/$drive$relative"
$outputDirectory = "obj_dir_hetero_perf_mtw32_${BuildTag}"

$sources = @(
    "generated/vpifo_config_pkg.sv",
    "INFER_SDPRAM.v",
    "TaskFIFO.sv",
    "TaskDistribute.sv",
    "PIFO_SRAM.sv",
    "PIFO_SRAM_TOP.sv",
    "ShardDirectory.sv",
    "PopResultFIFO.sv",
    "LogicalRequestBuffer.sv",
    "HeterogeneousPIFO.sv",
    "HeterogeneousPIFO_perf_tb.sv"
) -join " "

$command = "cd '$linuxRtlDirectory' && " +
    "verilator --binary --timing -Wno-fatal " +
    "--top-module HeterogeneousPIFO_perf_tb " +
    "-GPTW=16 -GMTW=32 -GLOGICAL_PENDING_DEPTH=$PendingDepth " +
    "$sources -Mdir $outputDirectory && " +
    "./$outputDirectory/VHeterogeneousPIFO_perf_tb"

& "$env:SystemRoot\System32\wsl.exe" sh -lc $command
exit $LASTEXITCODE
