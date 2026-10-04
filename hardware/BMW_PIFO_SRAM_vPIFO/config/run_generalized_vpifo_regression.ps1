$ErrorActionPreference = "Stop"

$rtlDirectory = Split-Path -Parent $PSScriptRoot
$repository = Resolve-Path (Join-Path $rtlDirectory "..\..")
$generator = Join-Path $PSScriptRoot "generate_generalized_vpifo_config.py"
$configuration = Join-Path $PSScriptRoot "generalized_vpifo_config.json"
$generatedDirectory = Join-Path $rtlDirectory "generated"
$forestConfiguration = Join-Path $PSScriptRoot "examples\generalized_schedule_forest_per_tree.json"
$forestGeneratedDirectory = Join-Path $rtlDirectory "generated_forest"
$annotationTest = Join-Path $repository "software\SDL_compiler\generalization\test_compile_vpifo_annotations.py"

& python (Join-Path $PSScriptRoot "test_generate_vpifo_config.py")
if ($LASTEXITCODE -ne 0) { throw "legacy generator tests failed" }
& python (Join-Path $PSScriptRoot "test_generate_generalized_vpifo_config.py")
if ($LASTEXITCODE -ne 0) { throw "generalized generator tests failed" }
& python $annotationTest
if ($LASTEXITCODE -ne 0) { throw "annotation compiler tests failed" }
& python $generator --config $configuration --output-dir $generatedDirectory
if ($LASTEXITCODE -ne 0) { throw "generalized RTL generation failed" }
& python $generator --config $forestConfiguration --output-dir $forestGeneratedDirectory
if ($LASTEXITCODE -ne 0) { throw "schedule-forest RTL generation failed" }

$drive = $rtlDirectory.Substring(0, 1).ToLowerInvariant()
$relative = $rtlDirectory.Substring(2).Replace('\', '/')
$linuxDirectory = "/mnt/$drive$relative"
$commonSources = "generated/vpifo_config_pkg.sv INFER_SDPRAM.v TaskFIFO.sv TaskDistribute.sv PIFO_SRAM.sv PIFO_SRAM_TOP.sv ShardDirectory.sv PopResultFIFO.sv LogicalRequestBuffer.sv HeterogeneousPIFO.sv HierarchicalHeterogeneousPIFO.sv ScheduleForestHeterogeneousPIFO.sv ShapingEventTable.sv ShapingReleaseFIFO.sv ShapingLogicalHeadSummary.sv ShapingDueArbiter.sv MultiLogicalShapingPIFO.sv ShapingReleaseToParent.sv NonWorkConservingPIFOStage45.sv ShapingTransactionEngine.sv NonWorkConservingPIFOStage5.sv VPIFOConnectionTable.sv GeneralizedVPIFO.sv"
$sources = "generated/generalized_vpifo_config_pkg.sv $commonSources GeneralizedVPIFO_tb.sv"
$command = "cd '$linuxDirectory' && verilator --binary --timing -Wno-fatal --top-module GeneralizedVPIFO_tb $sources -Mdir obj_dir_generalized && ./obj_dir_generalized/VGeneralizedVPIFO_tb"
& "$env:SystemRoot\System32\wsl.exe" sh -lc $command
if ($LASTEXITCODE -ne 0) { throw "generalized VPIFO simulation failed" }

$forestSources = "generated_forest/generalized_vpifo_config_pkg.sv $commonSources GeneralizedVPIFOForest_tb.sv"
$forestCommand = "cd '$linuxDirectory' && verilator --binary --timing -Wno-fatal --top-module GeneralizedVPIFOForest_tb $forestSources -Mdir obj_dir_generalized_forest && ./obj_dir_generalized_forest/VGeneralizedVPIFOForest_tb"
& "$env:SystemRoot\System32\wsl.exe" sh -lc $forestCommand
if ($LASTEXITCODE -ne 0) { throw "generalized schedule-forest simulation failed" }

Write-Host "PASS: generalized VPIFO Stage 1-5 plus schedule-forest regression"
