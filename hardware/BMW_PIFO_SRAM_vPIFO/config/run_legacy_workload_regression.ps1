param()

$ErrorActionPreference = "Stop"
$rtlDirectory = Split-Path -Parent $PSScriptRoot
$configGenerator = Join-Path $PSScriptRoot "generate_vpifo_config.py"
$fixtureGenerator = Join-Path $PSScriptRoot "generate_legacy_trace_fixture.py"
$baselineConfig = Join-Path $PSScriptRoot "vpifo_config.json"
$workloadConfig = Join-Path $PSScriptRoot "examples\original_workloads.json"
$treeIdMap = Join-Path $PSScriptRoot "legacy_tree_id_map.json"
$generatedDirectory = Join-Path $rtlDirectory "generated"
$softwareTests = Join-Path (Split-Path -Parent (Split-Path -Parent $rtlDirectory)) "software\SDL_compiler\compiler_test"

$workloads = @(
    @{ Name = "original_sp"; Stem = "test2_1" },
    @{ Name = "original_wfq"; Stem = "test2_2" },
    @{ Name = "original_wfq_pfabric"; Stem = "test2_3" }
)

$drive = $rtlDirectory.Substring(0, 1).ToLowerInvariant()
$relative = $rtlDirectory.Substring(2).Replace('\', '/')
$linuxDirectory = "/mnt/$drive$relative"
$wsl = "$env:SystemRoot\System32\wsl.exe"
$sources = "generated/vpifo_config_pkg.sv generated/legacy_trace_pkg.sv INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HierarchicalHeterogeneousPIFO.sv LegacyHierarchicalHeterogeneousPIFO_tb.sv"

function Invoke-ConfigGenerator([string]$configuration) {
    & python $configGenerator --config $configuration --output-dir $generatedDirectory
    if ($LASTEXITCODE -ne 0) {
        throw "configuration generation failed: $configuration"
    }
}

try {
    Invoke-ConfigGenerator $workloadConfig
    foreach ($workload in $workloads) {
        $trace = Join-Path $softwareTests ($workload.Stem + ".trace")
        $reference = Join-Path $softwareTests ($workload.Stem + ".ref")
        & python $fixtureGenerator `
            --name $workload.Name `
            --replay-mode batch_reference `
            --trace $trace `
            --reference $reference `
            --tree-id-map $treeIdMap `
            --config-manifest (Join-Path $generatedDirectory "vpifo_config_manifest.json") `
            --output-dir $generatedDirectory
        if ($LASTEXITCODE -ne 0) {
            throw "legacy fixture generation failed: $($workload.Name)"
        }

        $outputDirectory = "obj_dir_legacy_$($workload.Name)"
        $command = "cd '$linuxDirectory' && verilator --binary --timing -Wno-fatal --top-module LegacyHierarchicalHeterogeneousPIFO_tb $sources -Mdir $outputDirectory && ./$outputDirectory/VLegacyHierarchicalHeterogeneousPIFO_tb"
        & $wsl sh -lc $command
        if ($LASTEXITCODE -ne 0) {
            throw "legacy workload regression failed: $($workload.Name)"
        }
    }
} finally {
    # Production generated artifacts always return to the user's main config.
    Invoke-ConfigGenerator $baselineConfig
}

Write-Host "PASS: original SP/WFQ/WFQ+pFabric workload regressions"
