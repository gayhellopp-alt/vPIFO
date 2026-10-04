param(
    [string]$WorkbookPath = "",
    [string]$RunRoot = "",
    [string]$BackupPath = "",
    [switch]$ResumeAfterFailedImport
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($WorkbookPath)) {
    $WorkbookPath = Join-Path $PSScriptRoot "..\..\FPGA_data.xlsx"
}
if ([string]::IsNullOrWhiteSpace($RunRoot)) {
    $RunRoot = Join-Path $PSScriptRoot "heterogeneous_capacity_runs"
}

$WorkbookPath = [System.IO.Path]::GetFullPath($WorkbookPath)
$RunRoot = [System.IO.Path]::GetFullPath($RunRoot)
$CsvPath = Join-Path $RunRoot "heterogeneous_capacity_results.csv"
$ManifestPath = Join-Path $RunRoot "matrix_manifest.json"

if (!(Test-Path -LiteralPath $WorkbookPath)) {
    throw "workbook does not exist: $WorkbookPath"
}
if (!(Test-Path -LiteralPath $CsvPath)) {
    throw "result CSV does not exist: $CsvPath"
}
if (!(Test-Path -LiteralPath $ManifestPath)) {
    throw "matrix manifest does not exist: $ManifestPath"
}

if ([string]::IsNullOrWhiteSpace($BackupPath)) {
    $workbookDirectory = Split-Path -Parent $WorkbookPath
    $BackupPath = Join-Path $workbookDirectory `
        "FPGA_data_before_heterogeneous_import.xlsx"
}
$BackupPath = [System.IO.Path]::GetFullPath($BackupPath)

function Get-OleColor([int]$Red, [int]$Green, [int]$Blue) {
    return $Red + (256 * $Green) + (65536 * $Blue)
}

function Get-OrCreateWorksheet($Workbook, [string]$Name) {
    foreach ($candidate in $Workbook.Worksheets) {
        if ($candidate.Name -eq $Name) {
            return $candidate
        }
    }
    $created = $Workbook.Worksheets.Add()
    $created.Name = $Name
    return $created
}

function Reset-GeneratedWorksheet($Worksheet) {
    while ($Worksheet.ListObjects.Count -gt 0) {
        $Worksheet.ListObjects.Item(1).Unlist()
    }
    $Worksheet.Cells.UnMerge() | Out-Null
    $Worksheet.Cells.Clear() | Out-Null
}

function Set-Title($Worksheet, [string]$Text, [int]$LastColumn) {
    $range = $Worksheet.Range(
        $Worksheet.Cells.Item(1, 1),
        $Worksheet.Cells.Item(1, $LastColumn)
    )
    $range.Merge()
    $range.Value2 = $Text
    $range.Font.Bold = $true
    $range.Font.Size = 16
    $range.Font.Color = Get-OleColor 255 255 255
    $range.Interior.Color = Get-OleColor 31 78 121
    $range.HorizontalAlignment = -4108
    $range.RowHeight = 28
}

function Style-Header($Range) {
    $Range.Font.Bold = $true
    $Range.Font.Color = Get-OleColor 255 255 255
    $Range.Interior.Color = Get-OleColor 68 114 196
    $Range.HorizontalAlignment = -4108
    $Range.VerticalAlignment = -4108
    $Range.WrapText = $true
}

function Set-ExcelCellValue($Worksheet, [int]$Row, [int]$Column, $Value) {
    $cell = $Worksheet.Cells.Item($Row, $Column)
    if ($null -eq $Value) {
        $cell.ClearContents() | Out-Null
    } elseif ($Value -is [ValueType]) {
        $cell.Value2 = [double]$Value
    } else {
        $cell.Value2 = [string]$Value
    }
}

$results = Import-Csv -LiteralPath $CsvPath -Encoding UTF8
$manifest = Get-Content -LiteralPath $ManifestPath -Raw -Encoding UTF8 |
    ConvertFrom-Json

$excel = $null
$workbook = $null
$openedByScript = $false

try {
    try {
        $excel = [Runtime.InteropServices.Marshal]::GetActiveObject(
            "Excel.Application"
        )
    } catch {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $openedByScript = $true
    }

    foreach ($candidate in $excel.Workbooks) {
        if ($candidate.FullName -ieq $WorkbookPath) {
            $workbook = $candidate
            break
        }
    }
    if ($null -eq $workbook) {
        $workbook = $excel.Workbooks.Open($WorkbookPath)
        $openedByScript = $true
    }
    if ($workbook.ReadOnly) {
        throw "workbook is read-only: $WorkbookPath"
    }
    if (!$workbook.Saved -and !$ResumeAfterFailedImport) {
        throw "workbook contains unsaved user changes; save it before importing"
    }

    if (!(Test-Path -LiteralPath $BackupPath)) {
        $workbook.SaveCopyAs($BackupPath)
    }

    $configSheet = Get-OrCreateWorksheet $workbook "Hetero12_Config"
    $resultSheet = Get-OrCreateWorksheet $workbook "Hetero12_Results"
    $optimizationSheet = Get-OrCreateWorksheet $workbook `
        "Hetero12_Optimization"
    Reset-GeneratedWorksheet $configSheet
    Reset-GeneratedWorksheet $resultSheet
    Reset-GeneratedWorksheet $optimizationSheet

    Set-Title $configSheet "Full Heterogeneous vPIFO: 12-point Configuration Matrix" 13

    $metadata = @(
        @("Scope", "Full HeterogeneousPIFO: LRB + Directory + PopResultFIFO + BMW Engine"),
        @("Configuration model", "Generation/compile-time; not run-time migration or resizing"),
        @("Git baseline", "5475d3df7164e4b97e7f271ed8c1d66288040f44"),
        @("Device / tool", "xcu200-fsgd2104-2-e / Vivado 2019.2"),
        @("Clock constraint", "3.333 ns (300 MHz)"),
        @("Synthesis / implementation", "OOC PerformanceOptimized; Explore opt/place/phys_opt/route"),
        @("Fixed parameters", "M=2; logical=4; request ports=4; LRB depth=12; PopResultFIFO depth=10; TaskFIFO depth=8"),
        @("Data widths", "PTW=16; MTW=16; CTW=10"),
        @("Stage15 performance baseline", "144 / 163 / 116 / 136 / 211 cycles; PASS"),
        @("Functional verification", "12/12 full-capacity regressions PASS; fill every physical shard and drain by rank"),
        @("Implementation status", "12/12 fully routed; routing errors=0; hold PASS; all setup WNS < 0 at 300 MHz"),
        @("OOC limitation", "No parent HD.PARTPIN_LOCS for top ports; internal timing/resources are comparable, external packaged I/O timing is not")
    )
    for ($index = 0; $index -lt $metadata.Count; $index++) {
        $row = $index + 3
        $configSheet.Cells.Item($row, 1).Value2 = $metadata[$index][0]
        $configSheet.Cells.Item($row, 2).Value2 = $metadata[$index][1]
        $configSheet.Cells.Item($row, 1).Font.Bold = $true
        $configSheet.Range(
            $configSheet.Cells.Item($row, 2),
            $configSheet.Cells.Item($row, 13)
        ).Merge()
    }

    $configHeaderRow = 17
    $configHeaders = @(
        "Point", "LEVEL", "M", "Shard capacity", "Logical count",
        "Physical count", "Shard counts", "Shard offsets",
        "Logical required capacity", "Total structural capacity",
        "Functional result", "Push+pop operations", "Config fingerprint"
    )
    for ($column = 0; $column -lt $configHeaders.Count; $column++) {
        $configSheet.Cells.Item($configHeaderRow, $column + 1).Value2 =
            $configHeaders[$column]
    }
    Style-Header $configSheet.Range(
        $configSheet.Cells.Item($configHeaderRow, 1),
        $configSheet.Cells.Item($configHeaderRow, $configHeaders.Count)
    )

    $configRow = $configHeaderRow + 1
    foreach ($point in $manifest.points) {
        $offsets = @()
        $nextOffset = 0
        foreach ($count in $point.shard_counts) {
            $offsets += $nextOffset
            $nextOffset += [int]$count
        }
        $configValues = @(
            $point.name
            [double]$point.level
            [double]$manifest.fixed_parameters.order
            [double]$point.shard_capacity
            [double]$manifest.fixed_parameters.logical_tree_num
            [double]$point.physical_tree_num
            "[" + ($point.shard_counts -join ",") + "]"
            "[" + ($offsets -join ",") + "]"
            "[" + ($point.required_capacity -join ",") + "]"
            [double]$point.physical_tree_num * [double]$point.shard_capacity
            "PASS"
            2.0 * [double]$point.physical_tree_num * [double]$point.shard_capacity
            $point.fingerprint
        )
        for ($column = 0; $column -lt $configValues.Count; $column++) {
            Set-ExcelCellValue $configSheet $configRow ($column + 1) `
                $configValues[$column]
        }
        $configRow++
    }

    $configTableRange = $configSheet.Range(
        $configSheet.Cells.Item($configHeaderRow, 1),
        $configSheet.Cells.Item($configRow - 1, $configHeaders.Count)
    )
    $configTable = $configSheet.ListObjects.Add(1, $configTableRange, $null, 1)
    $configTable.Name = "HeterogeneousConfigMatrix"
    $configTable.TableStyle = "TableStyleMedium2"

    Set-Title $resultSheet "Full Heterogeneous vPIFO: Synthesis and Post-route Results" 26
    $resultSheet.Cells.Item(2, 1).Value2 =
        "Estimated Fmax = 1000 / (3.333 - WNS), for point-to-point comparison only. See Hetero12_Config for the complete setup."
    $resultSheet.Range(
        $resultSheet.Cells.Item(2, 1),
        $resultSheet.Cells.Item(2, 26)
    ).Merge()
    $resultSheet.Cells.Item(2, 1).Font.Italic = $true

    $resultHeaderRow = 4
    $resultFields = @(
        @("point", "Point"),
        @("stage", "Stage"),
        @("level", "LEVEL"),
        @("physical_tree_num", "Physical count"),
        @("shard_capacity", "Shard capacity"),
        @("total_capacity", "Total capacity"),
        @("shard_counts", "Shard counts"),
        @("lut", "CLB LUT"),
        @("logic_lut", "Logic LUT"),
        @("lutram", "LUTRAM"),
        @("ff", "FF"),
        @("carry8", "CARRY8"),
        @("f7", "F7 MUX"),
        @("f8", "F8 MUX"),
        @("directory_lut", "Directory LUT"),
        @("engine_lut", "Engine LUT"),
        @("lrb_lut", "LRB LUT"),
        @("pop_fifo_lut", "Pop FIFO LUT"),
        @("wns_ns", "WNS (ns)"),
        @("tns_ns", "TNS (ns)"),
        @("estimated_fmax_mhz", "Est. Fmax (MHz)"),
        @("violating_endpoints", "Violating endpoints"),
        @("datapath_delay_ns", "Datapath delay (ns)"),
        @("logic_levels", "Logic levels"),
        @("startpoint", "Worst-path startpoint"),
        @("endpoint", "Worst-path endpoint")
    )
    for ($column = 0; $column -lt $resultFields.Count; $column++) {
        $resultSheet.Cells.Item($resultHeaderRow, $column + 1).Value2 =
            $resultFields[$column][1]
    }
    Style-Header $resultSheet.Range(
        $resultSheet.Cells.Item($resultHeaderRow, 1),
        $resultSheet.Cells.Item($resultHeaderRow, $resultFields.Count)
    )

    $resultRow = $resultHeaderRow + 1
    foreach ($result in $results) {
        for ($column = 0; $column -lt $resultFields.Count; $column++) {
            $field = $resultFields[$column][0]
            $value = $result.$field
            if ($field -eq "stage") {
                $value = if ($value -eq "route") { "Post-route" } else { "Synthesis" }
            } elseif ($field -in @(
                    "level", "physical_tree_num", "shard_capacity",
                    "total_capacity", "lut", "logic_lut", "lutram", "ff",
                    "carry8", "f7", "f8", "directory_lut", "engine_lut",
                    "lrb_lut", "pop_fifo_lut", "violating_endpoints",
                    "logic_levels"
                )) {
                if (![string]::IsNullOrWhiteSpace($value)) {
                    $value = [double]$value
                }
            } elseif ($field -in @(
                    "wns_ns", "tns_ns", "estimated_fmax_mhz",
                    "datapath_delay_ns"
                )) {
                if (![string]::IsNullOrWhiteSpace($value)) {
                    $value = [double]::Parse(
                        $value,
                        [Globalization.CultureInfo]::InvariantCulture
                    )
                }
            }
            Set-ExcelCellValue $resultSheet $resultRow ($column + 1) $value
        }
        $resultRow++
    }

    $resultTableRange = $resultSheet.Range(
        $resultSheet.Cells.Item($resultHeaderRow, 1),
        $resultSheet.Cells.Item($resultRow - 1, $resultFields.Count)
    )
    $resultTable = $resultSheet.ListObjects.Add(1, $resultTableRange, $null, 1)
    $resultTable.Name = "HeterogeneousCapacityResults"
    $resultTable.TableStyle = "TableStyleMedium2"

    $resultSheet.Range("S5:S$($resultRow - 1)").NumberFormat = "0.000"
    $resultSheet.Range("T5:T$($resultRow - 1)").NumberFormat = "0.000"
    $resultSheet.Range("U5:U$($resultRow - 1)").NumberFormat = "0.0"
    $resultSheet.Range("W5:W$($resultRow - 1)").NumberFormat = "0.000"
    $negativeWns = $resultSheet.Range("S5:S$($resultRow - 1)").FormatConditions.Add(
        1, 6, 0
    )
    $negativeWns.Interior.Color = Get-OleColor 255 199 206
    $negativeWns.Font.Color = Get-OleColor 156 0 6

    Set-Title $optimizationSheet `
        "Full Heterogeneous vPIFO: Optimization Evidence and Priorities" 8
    $optimizationSheet.Cells.Item(2, 1).Value2 =
        "Priorities are based on the 12 post-route points. No proposal below changes visible latency unless explicitly re-authorized."
    $optimizationSheet.Range(
        $optimizationSheet.Cells.Item(2, 1),
        $optimizationSheet.Cells.Item(2, 8)
    ).Merge()
    $optimizationSheet.Cells.Item(2, 1).Font.Italic = $true

    $evidence = @(
        @("Timing diagnosis", "Worst paths are 61%-73% routing delay; every sampled worst path stays within one SLR"),
        @("Small-point limiter", "LRB associative age/P-P relation logic is the worst path at L4/N4, L4/N8, L5/N5, and L6/N6"),
        @("Large-point limiter", "Directory head/RR state drives LRB retire or Engine TaskFIFO controls at most medium/large points"),
        @("Directory scaling", "Directory LUT: 609 at L4/N4, 7,857 at L4/N32, and 20,210 at L4/N64"),
        @("Engine fanout", "At L4/N64, shared SRAM address A[6]/A[7] fanout is approximately 841/757"),
        @("Reset fanout", "Asynchronous reset fanout grows from about 2,496 at L4/N4 to 5,194 at L4/N64"),
        @("Tool-only precedent", "Earlier aggressive post-route phys_opt improved the production baseline by only about 45 ps")
    )
    for ($index = 0; $index -lt $evidence.Count; $index++) {
        $row = $index + 4
        $optimizationSheet.Cells.Item($row, 1).Value2 = $evidence[$index][0]
        $optimizationSheet.Cells.Item($row, 1).Font.Bold = $true
        $optimizationSheet.Cells.Item($row, 2).Value2 = $evidence[$index][1]
        $optimizationSheet.Range(
            $optimizationSheet.Cells.Item($row, 2),
            $optimizationSheet.Cells.Item($row, 8)
        ).Merge()
    }

    $optimizationHeaderRow = 13
    $optimizationHeaders = @(
        "Priority", "Proposal", "Primary target", "Measured evidence",
        "Expected benefit", "Risk / invariant", "Validation gate",
        "Recommended pilot"
    )
    for ($column = 0; $column -lt $optimizationHeaders.Count; $column++) {
        $optimizationSheet.Cells.Item(
            $optimizationHeaderRow, $column + 1
        ).Value2 = $optimizationHeaders[$column]
    }
    Style-Header $optimizationSheet.Range(
        $optimizationSheet.Cells.Item($optimizationHeaderRow, 1),
        $optimizationSheet.Cells.Item(
            $optimizationHeaderRow, $optimizationHeaders.Count
        )
    )

    $optimizationItems = @(
        @(
            "P0 experiment", "Equal-capacity LEVEL comparison",
            "Configuration", "Existing families are not equal-capacity",
            "Select a better LEVEL/shard-count point before RTL changes",
            "No RTL or latency change; compare equal useful capacity",
            "Full-capacity regression plus route resource/timing table",
            "L4/N32 cap960 vs L5/N16 cap992 vs L6/N8 cap1008"
        ),
        @(
            "P0 low risk", "Drive static shard map outputs from constants",
            "Directory FF/reset", "These outputs are reset-loaded and never updated; about 792 FF at L4/N64",
            "Remove static FF and reduce reset/control fanout",
            "Must preserve identical shard-list/count values from cycle 0",
            "All functional tests, elaboration, synth hierarchy diff",
            "L4/N64 for area; L4/N8 for timing/performance"
        ),
        @(
            "P0 experiment", "Sweep LRB depth 4/6/8/12",
            "LRB LUT/timing", "LRB is 6.0K-7.7K LUT; Stage15 phase 5 already has 25 capture stalls and 11 reservation stalls",
            "May reduce LUT and associative routing without redesign",
            "May reduce throughput; Stage15 cycles are strict gates",
            "All regressions and exact 144/163/116/136/211 cycle baseline",
            "Production L4/N7 first, then L4/N16"
        ),
        @(
            "P1 highest", "Replace pairwise head minimum with balanced tournament",
            "Directory LUT/timing", "L4/N64 pair comparators: 672 pairwise versus 60 tournament",
            "Large reduction in comparison logic and long-range routing",
            "Preserve valid/rank/lower-physical-ID tuple ordering; no new stage",
            "Exhaustive Directory unit tests, 12 functional points, Stage15 cycles",
            "L4/N16 then L4/N32; expand only after clean equivalence"
        ),
        @(
            "P1 high", "Generate a fixed per-logical Directory selection path",
            "Directory decode/scan", "Top maps one Directory request port to each constant logical ID",
            "Remove dynamic logical-ID mux/prefix scans and localize request logic",
            "Preserve RR, pending, busy, fallback, and P/P selection order",
            "ShardDirectory directed tests plus full P/P/fallback regressions",
            "L4/N16 with [8,4,2,2]"
        ),
        @(
            "P1 high", "Predecode BMW rotating address offsets and replicate local decoders",
            "Engine fanout/timing", "Shared address nets reach fanout 841/757 and frequently end at TaskFIFO/SRAM controls",
            "Reduce runtime divide/modulo/mux logic and routing concentration",
            "Exact rotating placement/address range must remain bit-identical",
            "Address sweep assertions, full-capacity tests, SRAM utilization diff",
            "L6/N12 for geometry, then L4/N32 for fanout"
        ),
        @(
            "P1 medium", "Predecode root updates per physical shard/lane",
            "Directory update", "Current update logic scales approximately with LEVEL times physical count",
            "Reduce broadcast compare and update routing for L5/L6",
            "Preserve same-cycle completion visibility; duplicate update remains unreachable assumption",
            "Directory update unit tests and all full-capacity tests",
            "L6/N12 then L6/N24"
        ),
        @(
            "P1 experiment", "Controlled placement and phys_opt pilots",
            "Routing", "Worst paths are routing-dominated but within one SLR",
            "Potential local improvement after structural fanout reduction",
            "Hard Pblocks may worsen global fanout; tool-only gain was about 45 ps",
            "Same seed/direction, route status, WNS/TNS and path-class comparison",
            "L4/N16 and L4/N32; AggressiveExplore plus soft hierarchy placement"
        ),
        @(
            "P2 redesign", "Replace LRB age/provenance matrices with tags/descriptors",
            "LRB LUT/timing", "slot_older and merge provenance create depth-squared associative logic",
            "Largest likely small-point LUT and timing reduction",
            "Requires proof of request order and reciprocal P/P atomicity",
            "Formal/directed ordering proof, all functional tests, exact Stage15 cycles",
            "Prototype only after depth sweep and Directory work"
        ),
        @(
            "P2 medium", "Reduce reset tree and localize TaskFIFO control",
            "Reset/Engine routing", "Reset fanout reaches about 5.2K; TaskFIFO controls are recurring endpoints",
            "Moderate placement/routing improvement",
            "Do not claim warm reset; preserve accepted TaskFIFO write-enable behavior",
            "Cold-reset regressions, Stage15 cycles, post-route fanout comparison",
            "L4/N32 after structural Directory changes"
        )
    )

    $optimizationRow = $optimizationHeaderRow + 1
    foreach ($item in $optimizationItems) {
        for ($column = 0; $column -lt $item.Count; $column++) {
            Set-ExcelCellValue $optimizationSheet $optimizationRow `
                ($column + 1) $item[$column]
        }
        $optimizationRow++
    }
    $optimizationTableRange = $optimizationSheet.Range(
        $optimizationSheet.Cells.Item($optimizationHeaderRow, 1),
        $optimizationSheet.Cells.Item(
            $optimizationRow - 1, $optimizationHeaders.Count
        )
    )
    $optimizationTable = $optimizationSheet.ListObjects.Add(
        1, $optimizationTableRange, $null, 1
    )
    $optimizationTable.Name = "HeterogeneousOptimizationPriorities"
    $optimizationTable.TableStyle = "TableStyleMedium4"

    $configSheet.Columns.AutoFit() | Out-Null
    $resultSheet.Columns.AutoFit() | Out-Null
    $optimizationSheet.Columns.AutoFit() | Out-Null
    $configSheet.Columns.Item(2).ColumnWidth = 72
    $configSheet.Columns.Item(13).ColumnWidth = 28
    $resultSheet.Columns.Item(7).ColumnWidth = 18
    $resultSheet.Columns.Item(25).ColumnWidth = 55
    $resultSheet.Columns.Item(26).ColumnWidth = 55
    for ($column = 2; $column -le 8; $column++) {
        $optimizationSheet.Columns.Item($column).ColumnWidth = 32
    }
    $configSheet.UsedRange.VerticalAlignment = -4108
    $resultSheet.UsedRange.VerticalAlignment = -4108
    $optimizationSheet.UsedRange.VerticalAlignment = -4108
    $configSheet.UsedRange.WrapText = $true
    $resultSheet.Range("Y:Z").WrapText = $true
    $optimizationSheet.UsedRange.WrapText = $true

    $workbook.Save()
    Write-Output "IMPORTED_WORKBOOK=$WorkbookPath"
    Write-Output "BACKUP_WORKBOOK=$BackupPath"
    Write-Output "CONFIG_POINTS=$($manifest.points.Count)"
    Write-Output "RESULT_ROWS=$($results.Count)"
    Write-Output "OPTIMIZATION_ITEMS=$($optimizationItems.Count)"
} finally {
    if ($openedByScript -and $null -ne $workbook) {
        $workbook.Close($true)
    }
    if ($openedByScript -and $null -ne $excel) {
        $excel.Quit()
    }
}
