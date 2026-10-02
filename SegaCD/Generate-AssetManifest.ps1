param(
    [string]$Assembly = "s3.asm",
    [string]$Listing = "s3.lst",
    [string]$Output = "SegaCD/s3-asset-manifest.csv"
)

$ErrorActionPreference = "Stop"

if (!(Test-Path -LiteralPath $Assembly) -or !(Test-Path -LiteralPath $Listing)) {
    throw "Run buildS3.bat first so that $Assembly and $Listing exist."
}

$sourceLines = [System.IO.File]::ReadAllLines((Resolve-Path -LiteralPath $Assembly))
$labels = [System.Collections.Generic.Dictionary[int,string]]::new()
$lastLabel = ""
for ($i = 0; $i -lt $sourceLines.Length; $i++) {
    if ($sourceLines[$i] -match '^([A-Za-z_][A-Za-z0-9_]*):') {
        $lastLabel = $Matches[1]
    }
    $labels[$i + 1] = $lastLabel
}

$assets = [System.Collections.Generic.List[object]]::new()
$pending = $null
$listingReader = [System.IO.File]::OpenText((Resolve-Path -LiteralPath $Listing))
try {
    while ($null -ne ($line = $listingReader.ReadLine())) {
        $position = [regex]::Match($line, '^\s*(\d+)/\s*([0-9A-Fa-f]+)\s*:')
        if (!$position.Success) {
            continue
        }

        $sourceLine = [int]$position.Groups[1].Value
        $address = [Convert]::ToInt32($position.Groups[2].Value, 16)
        if ($null -ne $pending -and $sourceLine -gt $pending.SourceLine) {
            $assets.Add([pscustomobject]@{
                SourceLine = $pending.SourceLine
                ROMStart   = $pending.Start
                ROMEnd     = $address
                Asset      = $pending.Asset
            })
            $pending = $null
        }

        $include = [regex]::Match($line, '^\s*(\d+)/\s*([0-9A-Fa-f]+)\s*:.*binclude\s+"([^"]+)"')
        if ($include.Success) {
            $pending = @{
                SourceLine = [int]$include.Groups[1].Value
                Start      = [Convert]::ToInt32($include.Groups[2].Value, 16)
                Asset      = $include.Groups[3].Value
            }
        }
    }
}
finally {
    $listingReader.Dispose()
}

$projectRoot = (Get-Location).Path
$manifest = foreach ($asset in $assets) {
    $path = Join-Path $projectRoot ($asset.Asset -replace '/', '\')
    if (!(Test-Path -LiteralPath $path)) {
        throw "Referenced binary asset not found: $($asset.Asset)"
    }

    [pscustomobject]@{
        ROMStart   = "0x{0:X6}" -f $asset.ROMStart
        ROMEnd     = "0x{0:X6}" -f $asset.ROMEnd
        SpanBytes  = $asset.ROMEnd - $asset.ROMStart
        AssetBytes = (Get-Item -LiteralPath $path).Length
        SourceLine = $asset.SourceLine
        Label      = $labels[$asset.SourceLine]
        Asset      = $asset.Asset
    }
}

$outputPath = Join-Path $projectRoot $Output
$outputDirectory = Split-Path -Parent $outputPath
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
$manifest | Export-Csv -LiteralPath $outputPath -NoTypeInformation -Encoding UTF8
Write-Host "Wrote $($manifest.Count) binary include records to $outputPath"
