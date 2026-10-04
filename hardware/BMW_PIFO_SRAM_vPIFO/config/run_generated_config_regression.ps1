param(
    [switch]$SkipFlat,
    [switch]$SkipHierarchical
)

$ErrorActionPreference = "Stop"
$rtlDirectory = Split-Path -Parent $PSScriptRoot
$generator = Join-Path $PSScriptRoot "generate_vpifo_config.py"
$baselineConfig = Join-Path $PSScriptRoot "vpifo_config.json"
$generatedDirectory = Join-Path $rtlDirectory "generated"
$configurations = @(
    $baselineConfig,
    (Join-Path $PSScriptRoot "examples\homogeneous.json"),
    (Join-Path $PSScriptRoot "examples\heterogeneous_2_3_1_2.json"),
    (Join-Path $PSScriptRoot "examples\five_logical.json")
)

$drive = $rtlDirectory.Substring(0, 1).ToLowerInvariant()
$relative = $rtlDirectory.Substring(2).Replace('\', '/')
$linuxDirectory = "/mnt/$drive$relative"
$wsl = "$env:SystemRoot\System32\wsl.exe"

$flatSources = "generated/vpifo_config_pkg.sv INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv GeneratedHeterogeneousPIFO_tb.sv"
$hierarchicalSources = "generated/vpifo_config_pkg.sv INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HierarchicalHeterogeneousPIFO.sv GeneratedHierarchicalHeterogeneousPIFO_tb.sv"

function Invoke-Generator([string]$configuration) {
    & python $generator --config $configuration --output-dir $generatedDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "configuration generation failed: $configuration"
    }
}

function Invoke-WslRegression(
    [string]$top,
    [string]$sources,
    [string]$outputDirectory
) {
    $command = "cd '$linuxDirectory' && verilator --binary --timing -Wno-fatal --top-module $top $sources -Mdir $outputDirectory && ./$outputDirectory/V$top"
    & $wsl sh -lc $command
    if ($LASTEXITCODE -ne 0) {
        throw "Verilator regression failed: $top ($outputDirectory)"
    }
}

try {
    foreach ($configuration in $configurations) {
        Invoke-Generator $configuration
        $configName = [System.IO.Path]::GetFileNameWithoutExtension($configuration)
        if (-not $SkipFlat) {
            Write-Host "=== generated flat regression: $configName ==="
            Invoke-WslRegression "GeneratedHeterogeneousPIFO_tb" $flatSources "obj_dir_generated_${configName}_flat"
        }
        if (-not $SkipHierarchical) {
            Write-Host "=== generated hierarchical regression: $configName ==="
            Invoke-WslRegression "GeneratedHierarchicalHeterogeneousPIFO_tb" $hierarchicalSources "obj_dir_generated_${configName}_hierarchical"
        }
    }
} finally {
    # Leave checked-in/generated artifacts synchronized with the user's main
    # configuration even when an intermediate compile or simulation fails.
    Invoke-Generator $baselineConfig
}

Write-Host "PASS: generated configuration regression matrix"
