param(
    [string]$Source = "s3.asm",
    [string]$OutputDirectory = "SegaCD/build",
    [string]$P2Bin = "../sonic-cd-disassembly-main/_Bin/p2bin.exe",
    # Work RAM addresses of the Sega CD BIOS V-Int / H-Int jump-table slots (e.g. '$FFFFFD0C').
    # Read them from the Runtime/Support MMD loader. Without them the game crashes on the first V-Int.
    [string]$VIntJumpAddress = "",
    [string]$HIntJumpAddress = "",
    [int]$AssetCommand = 209,
    [switch]$NoAssetRemap,
    [switch]$DebugLoadFailure
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path -LiteralPath ".").Path
$buildRoot = (Resolve-Path -LiteralPath "SegaCD/build").Path
$resolvedBuild = $buildRoot.TrimEnd('\') + '\'
$outputPath = [System.IO.Path]::GetFullPath((Join-Path $root $OutputDirectory))
if ($outputPath -ne $buildRoot -and !$outputPath.StartsWith($resolvedBuild, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Game modules must be written under SegaCD/build: $outputPath"
}

$sourcePath = (Resolve-Path -LiteralPath $Source).Path
$generator = (Resolve-Path -LiteralPath "SegaCD/Generate-MMDSource.ps1").Path
$assembler = (Resolve-Path -LiteralPath "build_tools/Windows-x86/asw.exe").Path
$p2binPath = (Resolve-Path -LiteralPath $P2Bin).Path
$generatedAssembly = Join-Path $root "SegaCD/generated/s3-mmd-playable-layout.asm"
$objectPath = Join-Path $root "SegaCD/generated/s3-mmd-playable-layout.p"
$corePath = Join-Path $outputPath "S3GAME.MMD"
$bankPath = Join-Path $outputPath "S3BANK0.BIN"

$generatorArgs = @{
    Assembly = $sourcePath
    Output = "SegaCD/generated/s3-mmd-playable-layout.asm"
    SegaCDBankedLayout = $true
    AssetCommand = $AssetCommand
    VIntJumpAddress = $VIntJumpAddress
    HIntJumpAddress = $HIntJumpAddress
}
if ($NoAssetRemap) { $generatorArgs.NoAssetRemap = $true }
if ($DebugLoadFailure) { $generatorArgs.DebugLoadFailure = $true }
& $generator @generatorArgs
if (!(Test-Path -LiteralPath $generatedAssembly -PathType Leaf)) { throw "MMD source generation failed." }

& $assembler -xx -n -q -A -L -U -E -i . $generatedAssembly
if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $objectPath -PathType Leaf)) {
    throw "Sonic 3 MMD assembly failed. See SegaCD/generated/s3-mmd-playable-layout.log."
}

& $p2binPath $objectPath $corePath "-r" '$0-$3FFFF'
if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $corePath -PathType Leaf)) {
    throw "Could not extract the 256 KiB Word RAM module from the Sonic 3 assembly."
}
& $p2binPath $objectPath $bankPath "-r" '$20000-$3FFFF'
if ($LASTEXITCODE -ne 0 -or !(Test-Path -LiteralPath $bankPath -PathType Leaf)) {
    throw "Could not extract the 128 KiB PRG-RAM overflow bank from the Sonic 3 assembly."
}

$core = [System.IO.File]::ReadAllBytes($corePath)
$bank = [System.IO.File]::ReadAllBytes($bankPath)
if ($core.Length -ne 0x40000) { throw "S3GAME.MMD must be 256 KiB; found $($core.Length) bytes." }
if ($bank.Length -ne 0x20000) { throw "S3BANK0.BIN must be 128 KiB; found $($bank.Length) bytes." }
$header = [BitConverter]::ToString($core[0..15]).Replace("-", "")
$entry = ([uint32]$core[8] -shl 24) -bor ([uint32]$core[9] -shl 16) -bor ([uint32]$core[10] -shl 8) -bor [uint32]$core[11]
if ($header.Substring(0, 16) -ne "0000000000000000" -or $entry -ne 0x0020011C) {
    throw "S3GAME.MMD has an unexpected MMD header or entry point: $header / 0x$($entry.ToString('X8'))."
}
$nonzeroBank = @($bank | Where-Object { $_ -ne 0 }).Count
if ($nonzeroBank -eq 0) { throw "S3BANK0.BIN is empty after extraction." }
Write-Host "Built Sonic 3 game modules: $corePath ($($core.Length) bytes), $bankPath ($($bank.Length) bytes); entry 0x$($entry.ToString('X8'))."
