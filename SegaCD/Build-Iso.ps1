param(
    [string]$RomImage = "s3built.bin",
    [string]$ModulesDirectory = "SegaCD/build/modules",
    [string]$GameModulesDirectory = "SegaCD/build",
    [string]$RuntimeDirectory = "SegaCD/build/runtime",
    [string]$SupportDirectory = "SegaCD/Runtime/Support",
    [string]$MkisoFs = "SegaCD/tools/mkisofs.exe",
    [string]$OutputIso = "SegaCD/build/S3CD.iso"
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path -LiteralPath ".").Path
$buildRoot = (Resolve-Path -LiteralPath "SegaCD/build").Path
$resolvedBuild = $buildRoot.TrimEnd('\') + '\'
$romPath = (Resolve-Path -LiteralPath $RomImage).Path
$modulesPath = (Resolve-Path -LiteralPath $ModulesDirectory).Path
$gameModulesPath = (Resolve-Path -LiteralPath $GameModulesDirectory).Path
$runtimePath = (Resolve-Path -LiteralPath $RuntimeDirectory).Path
$supportPath = (Resolve-Path -LiteralPath $SupportDirectory).Path
$mkisofsPath = (Resolve-Path -LiteralPath $MkisoFs).Path
$isoPath = Join-Path $root $OutputIso
$filesystemIso = Join-Path $buildRoot "S3CD-filesystem.iso"
$nextIso = Join-Path $buildRoot "S3CD.next.iso"
$stagingRoot = Join-Path $buildRoot "iso-staging"
$filesPath = Join-Path $stagingRoot "FILES"
$systemHeaderPath = Join-Path $supportPath "SystemHeader.bin"
$ipPath = Join-Path $supportPath "IP.BIN"
$spPath = Join-Path $supportPath "SP.BIN"
$spxPath = Join-Path $runtimePath "SPX___.BIN"
$ipxPath = Join-Path $runtimePath "IPX___.MMD"
$gameCorePath = Join-Path $gameModulesPath "S3GAME.MMD"
$gameBankPath = Join-Path $gameModulesPath "S3BANK0.BIN"
$assetLookupPath = Join-Path $modulesPath "S3ALOOK.BIN"

foreach ($requiredFile in @($romPath, $mkisofsPath, $systemHeaderPath, $ipPath, $spPath, $spxPath, $ipxPath, $gameCorePath, $gameBankPath, $assetLookupPath)) {
    if (!(Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw "Required Sega CD build file is missing: $requiredFile" }
}
if ((Get-Item -LiteralPath $romPath).Length -ne 0x200000) { throw "Sonic 3 ROM must be exactly 2 MiB." }
if ((Get-Item -LiteralPath $gameCorePath).Length -ne 0x40000) { throw "Sonic 3 Word RAM core must be exactly 256 KiB." }
if ((Get-Item -LiteralPath $gameBankPath).Length -ne 0x20000) { throw "Sonic 3 PRG-RAM bank 0 must be exactly 128 KiB." }
if ((Get-Item -LiteralPath $spxPath).Length -gt 0x4800) { throw "SPX runtime overlaps the Sub CPU stack allocation at address 0x10000." }
if ((Get-Item -LiteralPath $assetLookupPath).Length -eq 0 -or ((Get-Item -LiteralPath $assetLookupPath).Length % 16) -ne 0) { throw "Sonic 3 asset lookup table has an invalid record size." }
if ((Get-Item -LiteralPath $assetLookupPath).Length -ge 65536) { throw "Sonic 3 asset lookup table exceeds the Sub CPU file-size field." }
if ((Get-Item -LiteralPath $systemHeaderPath).Length -ne 0x200) { throw "SystemHeader.bin must be exactly 512 bytes." }
if ((Get-Item -LiteralPath $ipPath).Length -gt 0xE00) { throw "IP.BIN will overlap the SP area in the Sega CD system image." }
if ((Get-Item -LiteralPath $spPath).Length -gt 0x7000) { throw "SP.BIN is larger than its 0x7000-byte boot allocation." }

foreach ($outputTarget in @($isoPath, $filesystemIso, $nextIso, $stagingRoot)) {
    $fullTarget = [System.IO.Path]::GetFullPath($outputTarget)
    if (!$fullTarget.StartsWith($resolvedBuild, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Build outputs must stay under SegaCD/build: $fullTarget"
    }
}

$romModules = @(Get-ChildItem -LiteralPath $modulesPath -Filter "S3R*.BIN" -File | Sort-Object Name)
$assetModules = @(Get-ChildItem -LiteralPath $modulesPath -Filter "S3M*.BIN" -File | Sort-Object Name)
if ($romModules.Count -ne 35) { throw "Expected 35 Sonic 3 ROM segments, found $($romModules.Count)." }
if ($assetModules.Count -eq 0) { throw "No Sonic 3 asset modules were generated." }

New-Item -ItemType Directory -Force -Path $filesPath | Out-Null

# Refresh only the known files this builder owns, leaving the staging directory
# itself in place so an open directory handle cannot break subsequent builds.
Get-ChildItem -LiteralPath $filesPath -File | Where-Object {
    $_.Name -match '^S3(R|M)\d{2}\.BIN$' -or
    $_.Name -in @("S3ROM.BIN", "IPX___.MMD", "SPX___.BIN", "S3GAME.MMD", "S3BANK0.BIN", "S3ALOOK.BIN", "S3ROM.CSV", "S3MOD.CSV", "S3ASSET.CSV", "S3RMAP.ASM", "S3AMAP.ASM")
} | Remove-Item -Force

Copy-Item -LiteralPath $romPath -Destination (Join-Path $filesPath "S3ROM.BIN")
Copy-Item -LiteralPath $ipxPath -Destination (Join-Path $filesPath "IPX___.MMD")
Copy-Item -LiteralPath $spxPath -Destination (Join-Path $filesPath "SPX___.BIN")
Copy-Item -LiteralPath $gameCorePath -Destination (Join-Path $filesPath "S3GAME.MMD")
Copy-Item -LiteralPath $gameBankPath -Destination (Join-Path $filesPath "S3BANK0.BIN")
Copy-Item -LiteralPath $assetLookupPath -Destination (Join-Path $filesPath "S3ALOOK.BIN")
foreach ($module in $romModules + $assetModules) {
    Copy-Item -LiteralPath $module.FullName -Destination (Join-Path $filesPath $module.Name)
}

$metadata = @(
    @{ Source = (Join-Path $modulesPath "S3CD_RomModules.csv"); Name = "S3ROM.CSV" },
    @{ Source = (Join-Path $modulesPath "S3CD_Modules.csv"); Name = "S3MOD.CSV" },
    @{ Source = (Join-Path $modulesPath "S3CD_Assets.csv"); Name = "S3ASSET.CSV" },
    @{ Source = (Join-Path $root "SegaCD/generated/S3CD_RomSegmentIndex.asm"); Name = "S3RMAP.ASM" },
    @{ Source = (Join-Path $modulesPath "S3CD_ModuleIndex.asm"); Name = "S3AMAP.ASM" }
)
foreach ($item in $metadata) {
    if (!(Test-Path -LiteralPath $item.Source -PathType Leaf)) { throw "Module index missing: $($item.Source)" }
    Copy-Item -LiteralPath $item.Source -Destination (Join-Path $filesPath $item.Name)
}

$arguments = @(
    "-quiet",
    "-A", "SONIC 3 SEGA CD",
    "-V", "SONIC3CD",
    "-publisher", "SONIC 3 DISASSEMBLY",
    "-sysid", "MEGA_CD",
    "-iso-level", "1",
    "-o", $filesystemIso,
    $filesPath
)
& $mkisofsPath @arguments
if ($LASTEXITCODE -ne 0) { throw "mkisofs failed with exit code $LASTEXITCODE." }
if (!(Test-Path -LiteralPath $filesystemIso -PathType Leaf)) { throw "mkisofs did not create $filesystemIso" }

function Read-IsoRootNames([string]$path) {
    $stream = [System.IO.File]::OpenRead($path)
    try {
        if ($stream.Length -lt (17 * 2048)) { throw "ISO filesystem is too small to contain a PVD." }
        $stream.Position = 16 * 2048
        $pvd = [byte[]]::new(2048)
        if ($stream.Read($pvd, 0, $pvd.Length) -ne $pvd.Length) { throw "Could not read the ISO filesystem PVD." }
        if ($pvd[0] -ne 1 -or [System.Text.Encoding]::ASCII.GetString($pvd, 1, 5) -ne "CD001" -or $pvd[6] -ne 1) {
            throw "mkisofs output does not contain a valid ISO 9660 primary volume descriptor."
        }
        $rootLength = [BitConverter]::ToUInt32($pvd, 166)
        $rootLba = [BitConverter]::ToUInt32($pvd, 158)
        if ($rootLength -le 0 -or $rootLength -gt 1MB) { throw "ISO root directory size is invalid: $rootLength bytes." }
        $rootDirectory = [byte[]]::new($rootLength)
        $stream.Position = [long]$rootLba * 2048
        if ($stream.Read($rootDirectory, 0, $rootDirectory.Length) -ne $rootDirectory.Length) { throw "Could not read ISO root directory." }

        $rootNames = [System.Collections.Generic.List[string]]::new()
        $offset = 0
        while ($offset -lt $rootDirectory.Length) {
            $recordLength = [int]$rootDirectory[$offset]
            if ($recordLength -eq 0) {
                $offset = ([int]([Math]::Floor($offset / 2048) + 1)) * 2048
                continue
            }
            if ($offset + $recordLength -gt $rootDirectory.Length -or $recordLength -lt 34) { throw "ISO root directory contains a malformed entry." }
            $nameLength = [int]$rootDirectory[$offset + 32]
            if (33 + $nameLength -gt $recordLength) { throw "ISO root directory has an invalid filename entry." }
            $rootNames.Add([System.Text.Encoding]::ASCII.GetString($rootDirectory, $offset + 33, $nameLength))
            $offset += $recordLength
        }
        return ,@($rootNames)
    }
    finally { $stream.Dispose() }
}

$rootNames = Read-IsoRootNames $filesystemIso
$romCount = @($rootNames | Where-Object { $_ -match '^S3R\d{2}\.BIN;1$' }).Count
$assetCount = @($rootNames | Where-Object { $_ -match '^S3M\d{2}\.BIN;1$' }).Count
foreach ($requiredName in @("IPX___.MMD;1", "SPX___.BIN;1", "S3ROM.BIN;1", "S3R00.BIN;1", "S3M00.BIN;1", "S3GAME.MMD;1", "S3BANK0.BIN;1", "S3ALOOK.BIN;1")) {
    if ($rootNames -notcontains $requiredName) { throw "ISO filesystem is missing required boot/game file $requiredName" }
}
if ($romCount -ne $romModules.Count -or $assetCount -ne $assetModules.Count) {
    throw "ISO filesystem is missing Sonic 3 payload files (ROM $romCount/$($romModules.Count), assets $assetCount/$($assetModules.Count))."
}

# Build the Sega CD system area: System ID/header, copied IP/SP startup binaries,
# then the ISO9660 user area with its reserved first 16 sectors removed.
$bootAreaBytes = 0x8000
$filesystemBytes = [System.IO.File]::ReadAllBytes($filesystemIso)
if ($filesystemBytes.Length -le $bootAreaBytes) { throw "ISO9660 payload has no user area after its reserved sectors." }
$systemArea = [byte[]]::new($bootAreaBytes)
$systemHeader = [System.IO.File]::ReadAllBytes($systemHeaderPath)
[Array]::Copy($systemHeader, 0, $systemArea, 0, $systemHeader.Length)

function Set-HeaderField([byte[]]$buffer, [int]$offset, [int]$length, [string]$value, [bool]$nullTerminated = $false) {
    $encoded = [System.Text.Encoding]::ASCII.GetBytes($value)
    $available = if ($nullTerminated) { $length - 1 } else { $length }
    if ($encoded.Length -gt $available) { throw "Header field text is too long for offset 0x$($offset.ToString('X'))." }
    for ($i = 0; $i -lt $length; $i++) { $buffer[$offset + $i] = 0x20 }
    [Array]::Copy($encoded, 0, $buffer, $offset, $encoded.Length)
    if ($nullTerminated) { $buffer[$offset + $length - 1] = 0 }
}

Set-HeaderField $systemArea 0x10 12 "SONIC3CD   " $true
Set-HeaderField $systemArea 0x20 12 "SONIC3CD   " $true
Set-HeaderField $systemArea 0x50 8 "10012026"
Set-HeaderField $systemArea 0x120 48 "SONIC 3 THE HEDGEHOG CD"
Set-HeaderField $systemArea 0x150 48 "SONIC 3 THE HEDGEHOG CD"
Set-HeaderField $systemArea 0x180 16 "GM S3CD-0001 -00"
Set-HeaderField $systemArea 0x1F0 16 "JUE"

$ipBytes = [System.IO.File]::ReadAllBytes($ipPath)
$spBytes = [System.IO.File]::ReadAllBytes($spPath)
[Array]::Copy($ipBytes, 0, $systemArea, 0x200, $ipBytes.Length)
[Array]::Copy($spBytes, 0, $systemArea, 0x1000, $spBytes.Length)
$systemArea[0xFFE] = 0x01
$systemArea[0xFFF] = 0x09

$nextStream = [System.IO.File]::Create($nextIso)
try {
    $nextStream.Write($systemArea, 0, $systemArea.Length)
    $nextStream.Write($filesystemBytes, $bootAreaBytes, $filesystemBytes.Length - $bootAreaBytes)
}
finally { $nextStream.Dispose() }

$checkStream = [System.IO.File]::OpenRead($nextIso)
try {
    $bootCheck = [byte[]]::new(0x200)
    if ($checkStream.Read($bootCheck, 0, $bootCheck.Length) -ne $bootCheck.Length) { throw "Could not read the generated Sega CD system header." }
    if ([System.Text.Encoding]::ASCII.GetString($bootCheck, 0, 14) -ne "SEGADISCSYSTEM") { throw "Boot sector lacks the Sega CD system-disc identifier." }
    if ([System.Text.Encoding]::ASCII.GetString($bootCheck, 0x20, 8) -ne "SONIC3CD") { throw "Boot header does not identify the Sonic 3 CD runtime." }
    $checkStream.Position = 16 * 2048
    $pvdCheck = [byte[]]::new(7)
    if ($checkStream.Read($pvdCheck, 0, $pvdCheck.Length) -ne $pvdCheck.Length -or
        $pvdCheck[0] -ne 1 -or [System.Text.Encoding]::ASCII.GetString($pvdCheck, 1, 5) -ne "CD001" -or $pvdCheck[6] -ne 1) {
        throw "Generated Sega CD image does not place the ISO9660 PVD at logical sector 16."
    }
}
finally { $checkStream.Dispose() }

$resolvedIso = [System.IO.Path]::GetFullPath($isoPath)
if (!$resolvedIso.StartsWith($resolvedBuild, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Output ISO must stay under SegaCD/build." }
$publishedIso = $isoPath
try {
    Move-Item -LiteralPath $nextIso -Destination $isoPath -Force
}
catch {
    if (!(Test-Path -LiteralPath $nextIso -PathType Leaf) -or !(Test-Path -LiteralPath $isoPath -PathType Leaf)) { throw }
    $fallbackName = "S3CD-Sonic3-{0}.iso" -f (Get-Date -Format "yyyyMMdd-HHmmss")
    $publishedIso = Join-Path $buildRoot $fallbackName
    Move-Item -LiteralPath $nextIso -Destination $publishedIso -Force
    Write-Warning "Could not replace the configured ISO (it may be open in an emulator); published the new image separately."
}
Write-Host "Created Sega CD system image: $publishedIso"
Write-Host "Boot files include S3GAME.MMD and S3BANK0.BIN; disc contains $romCount ROM segments and $assetCount asset modules; ISO bytes: $((Get-Item -LiteralPath $publishedIso).Length)."
