param(
    [ValidateSet("Generate", "Functional", "Synthesis", "Implementation", "All")]
    [string]$Stage = "All",
    [switch]$Pilot,
    [string[]]$Point = @(),
    [switch]$Force,
    [string]$VivadoPath = "D:\Xilinx_U200\Vivado\2019.2\bin\vivado.bat"
)

$ErrorActionPreference = "Stop"
$rtlDirectory = $PSScriptRoot
$matrixGenerator = Join-Path $rtlDirectory "config\generate_heterogeneous_capacity_matrix.py"
$runRoot = Join-Path $rtlDirectory "heterogeneous_capacity_runs"
$synthesisTcl = Join-Path $rtlDirectory "synth_heterogeneous_capacity.tcl"
$implementationTcl = Join-Path $rtlDirectory "implement_heterogeneous_capacity.tcl"
$testbench = "GeneratedHeterogeneousCapacity_tb"
$wsl = "$env:SystemRoot\System32\wsl.exe"

function Convert-ToWslPath([string]$WindowsPath) {
    $resolved = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($resolved.Length -lt 3 -or $resolved[1] -ne ':') {
        throw "expected a drive-qualified Windows path: $resolved"
    }
    $drive = $resolved.Substring(0, 1).ToLowerInvariant()
    $tail = $resolved.Substring(2).Replace('\', '/')
    return "/mnt/$drive$tail"
}

function Invoke-MatrixGenerator {
    $arguments = @($matrixGenerator, "--output-root", $runRoot)
    if ($Pilot) {
        $arguments += "--pilot"
    }
    foreach ($name in $Point) {
        $arguments += @("--point", $name)
    }
    & python @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "heterogeneous capacity configuration generation failed"
    }
}

function Invoke-Functional([pscustomobject]$ExperimentPoint) {
    $name = $ExperimentPoint.name
    $pointDirectory = Join-Path $runRoot $name
    $generatedDirectory = Join-Path $pointDirectory "generated"
    $objectDirectory = Join-Path $pointDirectory "obj_dir_full"
    $binary = Join-Path $objectDirectory "V$testbench"
    $functionalLog = Join-Path $pointDirectory "functional.log"
    $linuxRtl = Convert-ToWslPath $rtlDirectory
    $linuxGenerated = Convert-ToWslPath $generatedDirectory
    $linuxObject = Convert-ToWslPath $objectDirectory
    $linuxBinary = Convert-ToWslPath $binary

    if (!$Force -and (Test-Path $binary)) {
        $command = "'$linuxBinary'"
    } else {
        $sources = @(
            "'$linuxGenerated/vpifo_config_pkg.sv'",
            "INFER_SDPRAM.v", "TaskFIFO.sv", "TaskDistribute.sv",
            "PIFO_SRAM.sv", "PIFO_SRAM_TOP.sv", "ShardDirectory.sv",
            "PopResultFIFO.sv", "LogicalRequestBuffer.sv",
            "HeterogeneousPIFO.sv", "GeneratedHeterogeneousCapacity_tb.sv"
        ) -join " "
        $command = "cd '$linuxRtl' && verilator --binary --timing " +
            "-Wno-fatal --top-module $testbench $sources " +
            "-Mdir '$linuxObject' && '$linuxBinary'"
    }
    Write-Host "=== full heterogeneous functional: $name ==="
    & $wsl sh -lc $command 2>&1 | Tee-Object -FilePath $functionalLog
    if ($LASTEXITCODE -ne 0) {
        throw "functional regression failed: $name"
    }
}

function Invoke-Synthesis([pscustomobject]$ExperimentPoint) {
    $name = $ExperimentPoint.name
    $pointDirectory = Join-Path $runRoot $name
    $generatedDirectory = Join-Path $pointDirectory "generated"
    $summary = Join-Path $pointDirectory `
        "vivado_synth\reports\${name}_synth_machine_summary.txt"
    if (!$Force -and (Test-Path $summary)) {
        Write-Host "=== synthesis already complete: $name ==="
        return
    }
    Write-Host "=== full heterogeneous synthesis: $name ==="
    $vivadoArguments = @(
        "-mode", "batch", "-source", $synthesisTcl,
        "-journal", (Join-Path $pointDirectory "vivado_synth.jou"),
        "-log", (Join-Path $pointDirectory "vivado_synth.log"),
        "-tclargs", $generatedDirectory, $name
    )
    & $VivadoPath @vivadoArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Vivado synthesis failed: $name"
    }
}

function Invoke-Implementation([pscustomobject]$ExperimentPoint) {
    $name = $ExperimentPoint.name
    $pointDirectory = Join-Path $runRoot $name
    $generatedDirectory = Join-Path $pointDirectory "generated"
    $synthDcp = Join-Path $pointDirectory `
        "vivado_synth\heterogeneous_${name}_ooc_synth.dcp"
    $summary = Join-Path $pointDirectory `
        "vivado_impl\reports\${name}_post_route_machine_summary.txt"
    if (!$Force -and (Test-Path $summary)) {
        Write-Host "=== implementation already complete: $name ==="
        return
    }
    if (!(Test-Path $synthDcp)) {
        throw "synthesis DCP is missing for ${name}: $synthDcp"
    }
    Write-Host "=== full heterogeneous implementation: $name ==="
    $vivadoArguments = @(
        "-mode", "batch", "-source", $implementationTcl,
        "-journal", (Join-Path $pointDirectory "vivado_impl.jou"),
        "-log", (Join-Path $pointDirectory "vivado_impl.log"),
        "-tclargs", $generatedDirectory, $synthDcp, $name
    )
    & $VivadoPath @vivadoArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Vivado implementation failed: $name"
    }
}

Invoke-MatrixGenerator
if ($Stage -eq "Generate") {
    exit 0
}

$manifestPath = Join-Path $runRoot "matrix_manifest.json"
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
foreach ($experimentPoint in $manifest.points) {
    if ($Stage -in @("Functional", "All")) {
        Invoke-Functional $experimentPoint
    }
    if ($Stage -in @("Synthesis", "All")) {
        Invoke-Synthesis $experimentPoint
    }
    if ($Stage -in @("Implementation", "All")) {
        Invoke-Implementation $experimentPoint
    }
}

Write-Host "PASS: heterogeneous capacity matrix stage $Stage"
