param(
    [ValidateRange(1, 126)]
    [int]$PacketsPerLeaf = 126,
    [string]$BuildTag = "stage27_single_shard_rr"
)

$drive = $PSScriptRoot.Substring(0, 1).ToLowerInvariant()
$relative = $PSScriptRoot.Substring(2).Replace('\', '/')
$linuxExperimentDirectory = "/mnt/$drive$relative"
$linuxRtlDirectory = "$linuxExperimentDirectory/../BMW_PIFO_SRAM_vPIFO"
$outputDirectory = "obj_dir_three_tier_hetero_mtw32_${BuildTag}"

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
    "../three_tier_experiments/ThreeTierHeterogeneousVPIFO.sv",
    "../three_tier_experiments/ThreeTierScheduler_tb.sv"
) -join " "

$command = "cd '$linuxRtlDirectory' && " +
    "verilator --binary --timing -Wno-fatal -DHETERO_DUT " +
    "--top-module ThreeTierScheduler_tb -GMTW=32 " +
    "-GPACKETS_PER_LEAF=$PacketsPerLeaf $sources " +
    "-Mdir $outputDirectory && " +
    "./$outputDirectory/VThreeTierScheduler_tb"

& "$env:SystemRoot\System32\wsl.exe" sh -lc $command
exit $LASTEXITCODE
