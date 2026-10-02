param(
    [string]$Manifest = "SegaCD/s3-asset-manifest.csv",
    [string]$OutputDirectory = "SegaCD/build/modules",
    [int]$MaxModuleBytes = 61440,
    [int]$SectorBytes = 2048,
    [int]$LoadModuleCommandId = 206
)

$ErrorActionPreference = "Stop"
$root = (Get-Location).Path
$manifestPath = Join-Path $root $Manifest
$outputPath = Join-Path $root $OutputDirectory
if (!(Test-Path -LiteralPath $manifestPath)) { throw "Asset manifest not found: $manifestPath" }
if ($MaxModuleBytes -le 0 -or $MaxModuleBytes -ge 65536) { throw "MaxModuleBytes must be less than the 64 KiB module-size field." }
if ($SectorBytes -ne 2048) { throw "Sega CD data sectors are 2048 bytes; SectorBytes must be 2048." }
if ($LoadModuleCommandId -lt 1 -or $LoadModuleCommandId -gt 255) { throw "LoadModuleCommandId must fit in the Sub CPU command byte." }
New-Item -ItemType Directory -Force -Path $outputPath | Out-Null

# These modules report their byte size through a 16-bit Gate Array status
# register. Remove stale output from an
# earlier build so the ISO cannot accidentally pick up orphaned module files.
$resolvedOutput = (Resolve-Path -LiteralPath $outputPath).Path
$resolvedRoot = (Resolve-Path -LiteralPath $root).Path
if (!$resolvedOutput.StartsWith($resolvedRoot.TrimEnd('\') + '\', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "OutputDirectory must stay inside the Sonic 3 workspace: $resolvedOutput"
}
Get-ChildItem -LiteralPath $resolvedOutput -Filter "S3M*.BIN" -File | Remove-Item -Force

function Get-AssetGroup([string]$path) {
    $parts = $path.Replace('\','/').Split('/')
    if ($parts.Length -lt 2) { return "MISC" }
    if ($parts[0] -eq "Levels") { return "LVL_" + $parts[1].ToUpperInvariant() }
    if ($parts[0] -eq "General" -and $parts[1] -eq "Sprites") { return "SPR" }
    if ($parts[0] -eq "General") { return "GEN_" + $parts[1].ToUpperInvariant().Replace(' ','_') }
    return $parts[0].ToUpperInvariant()
}

$rows = Import-Csv -LiteralPath $manifestPath
$categorized = @{}
foreach ($row in $rows) {
    $group = Get-AssetGroup $row.Asset
    if (!$categorized.ContainsKey($group)) { $categorized[$group] = [System.Collections.Generic.List[object]]::new() }
    $categorized[$group].Add($row)
}
$groups = [System.Collections.Generic.List[object]]::new()
foreach ($groupName in ($categorized.Keys | Sort-Object)) {
    $current = $null
    $groupAssets = $categorized[$groupName] | Sort-Object { [Convert]::ToInt32($_.ROMStart.Substring(2),16) }
    foreach ($row in $groupAssets) {
        $source = Join-Path $root ($row.Asset -replace '/', '\')
        if (!(Test-Path -LiteralPath $source)) { throw "Asset not found: $($row.Asset)" }
        $bytes = [System.IO.File]::ReadAllBytes($source)
        if ($bytes.Length -ne [int]$row.SpanBytes) { throw "Asset size mismatch for $($row.Label): expected $($row.SpanBytes), found $($bytes.Length)." }

        # Keep each disc file below the loader's 16-bit length limit. Large
        # source assets become sequential entries that the runtime can join.
        $assetOffset = 0
        while ($assetOffset -lt $bytes.Length) {
            $pieceLength = [Math]::Min($MaxModuleBytes, $bytes.Length - $assetOffset)
            $pieceData = [byte[]]::new($pieceLength)
            [Array]::Copy($bytes, $assetOffset, $pieceData, 0, $pieceLength)
            $alignedLength = [int]([Math]::Ceiling($pieceLength / [double]$SectorBytes) * $SectorBytes)

            if ($null -eq $current -or ($current.Bytes + $alignedLength) -gt $MaxModuleBytes) {
                $chunk = if ($null -eq $current) { 1 } else { $current.Chunk + 1 }
                $current = [pscustomobject]@{ Group = $groupName; Chunk = $chunk; Bytes = 0; Assets = [System.Collections.Generic.List[object]]::new() }
                $groups.Add($current)
            }
            $current.Assets.Add([pscustomobject]@{
                Row = $row
                Data = $pieceData
                AssetOffset = $assetOffset
                Length = $pieceLength
                AlignedLength = $alignedLength
            })
            $current.Bytes += $alignedLength
            $assetOffset += $pieceLength
        }
    }
}

$moduleRows = [System.Collections.Generic.List[object]]::new()
$assetRows = [System.Collections.Generic.List[object]]::new()
$moduleId = 0
foreach ($group in $groups) {
    $name = "S3M{0:D2}.BIN" -f $moduleId
    if ($moduleId -gt 99) { throw "More than 100 asset modules are required; the ISO 9660 names need another format." }
    $moduleFile = Join-Path $outputPath $name
    $moduleBuffer = [byte[]]::new($group.Bytes)
    $offset = 0
    $firstAsset = $assetRows.Count
    foreach ($asset in $group.Assets) {
        [Array]::Copy($asset.Data, 0, $moduleBuffer, $offset, $asset.Length)
        $romStart = [Convert]::ToInt32($asset.Row.ROMStart.Substring(2),16) + $asset.AssetOffset
        $assetRows.Add([pscustomobject]@{
            ModuleId = $moduleId
            ModuleFile = $name
            ModuleOffset = $offset
            AssetOffset = $asset.AssetOffset
            ROMStart = $romStart
            Length = $asset.Length
            Label = $asset.Row.Label
            Asset = $asset.Row.Asset
        })
        $offset += $asset.AlignedLength
    }
    [System.IO.File]::WriteAllBytes($moduleFile, $moduleBuffer)
    $moduleRows.Add([pscustomobject]@{
        ModuleId = $moduleId
        ModuleFile = $name
        Group = $group.Group
        Bytes = $group.Bytes
        FirstAsset = $firstAsset
        AssetCount = $group.Assets.Count
    })
    $moduleId++
}

$moduleCsv = Join-Path $outputPath "S3CD_Modules.csv"
$assetCsv = Join-Path $outputPath "S3CD_Assets.csv"
$indexAsm = Join-Path $outputPath "S3CD_ModuleIndex.asm"
$moduleRows | Export-Csv -LiteralPath $moduleCsv -NoTypeInformation -Encoding UTF8
$assetRows | Export-Csv -LiteralPath $assetCsv -NoTypeInformation -Encoding UTF8

$asm = [System.Collections.Generic.List[string]]::new()
$asm.Add("; Generated by SegaCD/Build-AssetModules.ps1")
$asm.Add("S3CD_ModuleCount = $($moduleRows.Count)")
$asm.Add("S3CD_AssetCount = $($assetRows.Count)")
$asm.Add("S3CD_ModuleIndex:")
foreach ($module in $moduleRows) {
    $asm.Add("`tdc.w $($module.ModuleId), $($module.AssetCount)")
    $asm.Add("`tdc.l `$" + $module.Bytes.ToString('X8') + ", `$" + $module.FirstAsset.ToString('X8'))
}
$asm.Add("S3CD_AssetIndex:")
foreach ($asset in $assetRows) {
    $asm.Add("`tdc.l `$" + $asset.ROMStart.ToString('X6') + ", `$" + $asset.ModuleOffset.ToString('X8') + ", `$" + $asset.Length.ToString('X8'))
    $asm.Add("`tdc.w $($asset.ModuleId), 0")
}
[System.IO.File]::WriteAllLines($indexAsm, $asm)

# Generate the Sub CPU filename table used by Sonic CD's SPX loader.
$spxAsm = [System.Collections.Generic.List[string]]::new()
$spxAsm.Add("; Generated by SegaCD/Build-AssetModules.ps1. Asset-only table; do not include in SPX.")
$spxAsm.Add("S3CD_ModuleCount = $($moduleRows.Count)")
$spxAsm.Add("S3CD_ModuleFileTable:")
foreach ($module in $moduleRows) { $spxAsm.Add("`tdc.l S3CD_File_$($module.ModuleId.ToString('D2'))") }
foreach ($module in $moduleRows) {
    $spxAsm.Add("S3CD_File_$($module.ModuleId.ToString('D2')):")
    $spxAsm.Add("`tdc.b `"$($module.ModuleFile);1`", 0")
}
$spxAsm.Add("`teven")
$spxPath = Join-Path $outputPath "S3CD_AssetSPXModules.asm"
[System.IO.File]::WriteAllLines($spxPath, $spxAsm)

$defs = [System.Collections.Generic.List[string]]::new()
$defs.Add("; Generated by SegaCD/Build-AssetModules.ps1. Do not edit.")
$defs.Add("S3CD_ModuleCount = $($moduleRows.Count)")
$defs.Add("; SCMD_DUMMY1 slot copied from the analyzed Sonic CD command table.")
$defs.Add("S3CD_LoadModuleCommand = $LoadModuleCommandId")
$defsPath = Join-Path $root "SegaCD\generated\S3CD_AssetModuleDefs.asm"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $defsPath) | Out-Null
[System.IO.File]::WriteAllLines($defsPath, $defs)

Write-Host "Created $($moduleRows.Count) sector-aligned asset modules ($($assetRows.Count) assets)."
foreach ($module in $moduleRows) { Write-Host ("{0} {1,-16} {2,7} bytes  {3,3} assets" -f $module.ModuleId,$module.Group,$module.Bytes,$module.AssetCount) }
