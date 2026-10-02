param(
    [string]$Assembly = "s3.asm",
    [string]$Output = "SegaCD/generated/s3-mmd-full.asm",
    [switch]$SegaCDBankedLayout,
    # Sub CPU command used by the game to request one compressed asset.
    # Must NOT collide with the boot commands used by IPX.asm (209 = S3BANK0, 210 = S3GAME, 212 = lookup).
    [int]$AssetCommand = 209,
    # Addresses (in Work RAM) of the Sega CD BIOS jump-table slots for V-Int and H-Int.
    # Take them from the Runtime/Support MMD loader (where it stores the MMD header hint/vint fields).
    # Each slot is assumed to hold a 6-byte "jmp (abs).l". If omitted, the vectors are NOT installed.
    [string]$VIntJumpAddress = "",
    [string]$HIntJumpAddress = "",
    # Cart-address offset fix: Sub CPU asset lookup is keyed by the CARTRIDGE ROM offset, but the banked
    # MMD layout shifts everything after the sound bank. Disable only if the Sub CPU already compensates.
    [switch]$NoAssetRemap,
    # Paint CRAM red and halt when a CD asset load fails (instead of silently returning).
    [switch]$DebugLoadFailure
)

$ErrorActionPreference = "Stop"
$sourcePath = (Resolve-Path -LiteralPath $Assembly).Path
$source = [System.Collections.Generic.List[string]]::new()
$source.AddRange([System.IO.File]::ReadAllLines($sourcePath))

# Cartridge builds reset the assembler's logical address to zero at the end of
# sonic3k.constants.asm. An MMD is phased at $200000, so that reset makes p2bin
# calculate a negative output size (which wraps to almost 4 GiB). Keep the ROM
# phase relative for MMD builds, matching the Sega CD reference pipeline.
$constantsPath = (Resolve-Path -LiteralPath "sonic3k.constants.asm").Path
$constants = [System.Collections.Generic.List[string]]::new()
$constants.AddRange([System.IO.File]::ReadAllLines($constantsPath))
$orgIndex = -1
for ($i = 0; $i -lt $constants.Count; $i++) {
    if ($constants[$i] -match '^\s*!org\s+0\s*(;.*)?$') { $orgIndex = $i }
}
if ($orgIndex -lt 0) { throw "Could not locate the final !org 0 in sonic3k.constants.asm." }
$constants.RemoveAt($orgIndex)
$constants.Insert($orgIndex, "`t`tif MMD_Enabled")
$constants.Insert($orgIndex + 1, "`t`t; keep the assembled MMD address; do not reset it to a negative origin")
$constants.Insert($orgIndex + 2, "`t`relse")
$constants.Insert($orgIndex + 3, "`t`t!org 0")
$constants.Insert($orgIndex + 4, "`t`tendif")
$constantsOutput = Join-Path (Get-Location) "SegaCD/generated/sonic3k.constants-mmd.asm"
[System.IO.File]::WriteAllLines($constantsOutput, $constants)

# Preserve the 68000 ROM location while emitting the small Z80 startup routine
# at Z80 address zero, as the Mega CD reference disassembly does.
$z80Start = -1
$z80End = -1
for ($i = 0; $i -lt $source.Count; $i++) {
    if ($source[$i] -match '^\s*cpu\s+Z80\b') { $z80Start = $i }
    if ($z80Start -ge 0 -and $source[$i] -match '^\s*cpu\s+68000\b') { $z80End = $i; break }
}
if ($z80Start -lt 0 -or $z80End -le $z80Start) { throw "Could not locate the Z80 startup block in $Assembly." }
$source.Insert($z80Start, "`t`tsave")
$z80End++
$source.Insert($z80End + 1, "`t`trestore")

for ($i = 0; $i -lt $source.Count; $i++) {
    if ($source[$i] -match '^\s*include\s+"sonic3k\.constants\.asm"') {
        $source[$i] = "`t`tinclude `"SegaCD/generated/sonic3k.constants-mmd.asm`""
        break
    }
}

if ($SegaCDBankedLayout) {
    $macroIndex = -1
    for ($i = 0; $i -lt $source.Count; $i++) {
        if ($source[$i] -match '^\s*include\s+"sonic3k\.macros\.asm"') { $macroIndex = $i; break }
    }
    if ($macroIndex -lt 0) { throw "Could not locate sonic3k.macros.asm for the Sega CD banked build." }
    $source.Insert($macroIndex + 1, "MMD_Enabled = 1")

    # Keep the first 256 KiB of the main image in Word RAM and map the next
    # 128 KiB-sized ROM window into PRG-RAM. The first assembled object past
    # Word RAM is the continuation HUD art at $240126.
    $oldBankPhase = -1
    for ($i = 0; $i -lt $source.Count; $i++) {
        if ($source[$i] -match '^\s*phase\s+\$20000\b') { $oldBankPhase = $i; break }
    }
    if ($oldBankPhase -ge 0) { $source.RemoveAt($oldBankPhase) }

    $bankStartIndex = -1
    $musicStartIndex = -1
    for ($i = 0; $i -lt $source.Count; $i++) {
        if ($source[$i] -match '^\s*ArtNem_ContinueDigits:') { $bankStartIndex = $i }
        if ($source[$i] -match '^\s*Snd_Bank1_Start:') { $musicStartIndex = $i; break }
    }
    if ($bankStartIndex -lt 0 -or $musicStartIndex -le $bankStartIndex) {
        throw "Could not locate the Word RAM/PRG-RAM and audio boundaries in $Assembly."
    }
    $source.Insert($bankStartIndex, "`t`tphase `$20000 ; PRG-RAM bank 0: ROM window after Word RAM")
    $musicStartIndex++
    $source.Insert($musicStartIndex, "`t`tphase `$260000 ; CD sound data has a separate ROM-relative address range")

    # These calls become cross-window references after the phase change. Keep
    # their targets absolute so the 68000 reaches PRG-RAM bank 0 correctly.
    for ($i = 0; $i -lt $source.Count; $i++) {
        $source[$i] = $source[$i] -replace '\b(jmp|jsr)\s+Swing_Setup1\(pc\)', '$1 (Swing_Setup1).l'
        $source[$i] = $source[$i] -replace '\blea\s+Child1_MakeRoboShip3\(pc\),a2', 'lea (Child1_MakeRoboShip3).l,a2'
        $source[$i] = $source[$i] -replace '\blea\s+ObjDat_AIZMiniboss\(pc\),a1', 'lea (ObjDat_AIZMiniboss).l,a1'
        $source[$i] = $source[$i] -replace '\blea\s+ChildObjDat_46F80\(pc\),a2', 'lea (ChildObjDat_46F80).l,a2'
        $source[$i] = $source[$i] -replace '\blea\s+Pal_AIZMiniboss\(pc\),a1', 'lea (Pal_AIZMiniboss).l,a1'
        $source[$i] = $source[$i] -replace '\bjsr\s+sub_40A4A\(pc\)', 'jsr (sub_40A4A).l'
        $source[$i] = $source[$i] -replace '\bbra\.w\s+loc_46E80\b', 'jmp (loc_46E80).l'
    }
}

$countryIndex = -1
$vectorsIndex = -1
for ($i = 0; $i -lt $source.Count; $i++) {
    if ($source[$i] -match '^Vectors:') { $vectorsIndex = $i }
    if ($source[$i] -match '^Country_Code:') { $countryIndex = $i }
}
if ($vectorsIndex -lt 0 -or $countryIndex -le $vectorsIndex) {
    throw "Could not locate the Genesis vectors/header in $Assembly."
}

# Replace the cartridge vectors and Genesis header with the Sega CD MMD header.
$source.RemoveRange($vectorsIndex, $countryIndex - $vectorsIndex + 1)
$source.Insert($vectorsIndex, "`t`tMMD 0,`$200000,0,EntryPoint,JmpTo_HInt,VInt")
$source.Insert($vectorsIndex + 1, "Country_Code: dc.b `"JUE             `"")
$source.Insert($vectorsIndex + 2, "Checksum: dc.w 0")
$source.Insert($vectorsIndex + 3, "ROMEndLoc: dc.l EndOfROM-1")

# A disc-loaded module has no cartridge country/checksum fields to validate.
for ($i = 0; $i -lt $source.Count; $i++) {
    if ($source[$i] -match '^\s*bra\.s\s+Test_CountryCode\b') {
        $source[$i] = "`t`tbra.w Test_Checksum_Done"
        break
    }
}

# The Genesis country/lockout screen is not part of the CD boot path. Remove
# that unused block to make room in Word RAM for the disc asset resolver.
$lockoutStart = -1
$checksumDone = -1
for ($i = 0; $i -lt $source.Count; $i++) {
    if ($source[$i] -match '^Test_CountryCode:') { $lockoutStart = $i }
    if ($source[$i] -match '^Test_Checksum_Done:') { $checksumDone = $i; break }
}
if ($lockoutStart -lt 0 -or $checksumDone -le $lockoutStart) {
    throw "Could not locate the Genesis lockout block in $Assembly."
}
$source.RemoveRange($lockoutStart, $checksumDone - $lockoutStart)

# The Mega CD BIOS leaves I/O state in Main RAM. Sonic 3 treats any nonzero
# controller/expansion state as a cartridge soft reset and skips the Z80 setup,
# which can hang during sound initialization after the BIOS logo. A CD launch
# must always perform the cold hardware setup.
$entryIndex = -1
$stackLineIndex = -1
$setupLineIndex = -1
for ($i = 0; $i -lt $source.Count; $i++) {
    if ($source[$i] -match '^EntryPoint:') { $entryIndex = $i; break }
}
if ($entryIndex -ge 0) {
    for ($i = $entryIndex + 1; $i -lt $source.Count; $i++) {
        if ($stackLineIndex -lt 0 -and $source[$i] -match '^\s*lea\s+\(System_stack\)\.w,sp') { $stackLineIndex = $i }
        if ($stackLineIndex -ge 0 -and $source[$i] -match '^\s*lea\s+SetupValues\(pc\),a5') { $setupLineIndex = $i; break }
    }
}
if ($stackLineIndex -lt 0 -or $setupLineIndex -le $stackLineIndex) {
    throw "Could not locate the Sonic 3 reset checks before SetupValues."
}
$source.RemoveRange($stackLineIndex + 1, $setupLineIndex - $stackLineIndex - 1)
$source.Insert($stackLineIndex + 1, "; Always initialize VDP, Z80, and RAM after Sega CD BIOS startup.")

# VInt_14 polls the pads while waiting on the SEGA splash, but the retail
# routine unnecessarily halts the Z80 around that I/O. On the Sega CD this
# can leave the frame interrupt waiting forever for the Z80 bus. Pad polling
# uses the I/O ports directly, so keep it out of the Z80 bus-request path.
$vint14Index = -1
$stopZ80Index = -1
for ($i = 0; $i -lt $source.Count; $i++) {
    if ($source[$i] -match '^VInt_14:') { $vint14Index = $i; break }
}
if ($vint14Index -ge 0) {
    for ($i = $vint14Index + 1; $i -lt $source.Count; $i++) {
        if ($source[$i] -match '^VInt_4:') { break }
        if ($source[$i] -match '^\s*stopZ80\s*$') { $stopZ80Index = $i; break }
    }
}
if ($stopZ80Index -lt 0 -or
    $stopZ80Index + 2 -ge $source.Count -or
    $source[$stopZ80Index + 1] -notmatch '^\s*bsr\.w\s+Poll_Controllers\b' -or
    $source[$stopZ80Index + 2] -notmatch '^\s*startZ80\s*$') {
    throw "Could not locate the Z80-wrapped controller poll in VInt_14."
}
$source.RemoveAt($stopZ80Index + 2)
$source.RemoveAt($stopZ80Index)
$source.Insert($stopZ80Index, "; Pad polling in VInt_14 does not need to stop the Z80 on Sega CD.")

# The CD asset path is reached from the 68000 decompression entries. It
# releases the Sub CPU while SPX reads one module, then re-acquires PRG-RAM
# bank 3 for the compressed source. All decoder bodies remain in Word RAM;
# the wrappers restore bank 0 before returning to game code.
$assetRemapLines = @()
if (-not $NoAssetRemap) {
    $assetRemapLines = @(
        "`t`t cmpi.l #(ArtUnc_Sonic-`$200000),d0",
        "`t`t blo.s .NoRemap",
        "`t`t addi.l #(`$100000-(ArtUnc_Sonic-`$200000)),d0 ; back to the cartridge ROM offset used by S3ALOOK.BIN",
        ".NoRemap:"
    )
}
$loadFailedDebugLines = @()
if ($DebugLoadFailure) {
    $loadFailedDebugLines = @(
        "`t`t move.l #`$C0000000,`$C00004",
        "`t`t move.w #`$000E,`$C00000 ; red = CD asset load failed",
        "`t`t bra.s *"
    )
}

$assetRuntime = @(
    "SegaCD_LoadAsset:",
    "`t`t movem.l d0-d7/a1-a6,-(sp)"
) + $assetRemapLines + @(
    "`t`t move.w d0,`$A12014",
    "`t`t swap d0",
    "`t`t move.w d0,`$A12012",
    "`t`t bclr #1,`$A12001",
    ".WaitReady:",
    "`t`t move.w `$A12020,d1",
    "`t`t bne.s .WaitReady",
    "`t`t cmp.w `$A12020,d1",
    "`t`t bne.s .WaitReady",
    "`t`t move.w #$AssetCommand,`$A12010",
    ".WaitAck:",
    "`t`t move.w `$A12020,d1",
    "`t`t cmpi.w #$AssetCommand,d1",
    "`t`t bne.s .WaitAck",
    "`t`t cmp.w `$A12020,d1",
    "`t`t bne.s .WaitAck",
    "`t`t clr.w `$A12010",
    ".WaitDone:",
    "`t`t move.w `$A12020,d1",
    "`t`t bne.s .WaitDone",
    "`t`t cmp.w `$A12020,d1",
    "`t`t bne.s .WaitDone",
    "`t`t move.w `$A12022,d1",
    "`t`t cmpi.w #`$FFFF,d1",
    "`t`t beq.s .LoadFailed",
    "`t`t tst.w `$A12024",
    "`t`t beq.s .LoadFailed",
    "`t`t bset #1,`$A12001",
    ".WaitPRGRAM:",
    "`t`t btst #1,`$A12001",
    "`t`t beq.s .WaitPRGRAM",
    "`t`t moveq #0,d0",
    "`t`t move.b `$A12003,d0",
    "`t`t andi.b #`$3F,d0",
    "`t`t ori.b #`$C0,d0",
    "`t`t move.b d0,`$A12003",
    "`t`t movea.l #`$00020000,a0",
    "`t`t andi.l #`$0000FFFF,d1",
    "`t`t adda.l d1,a0",
    "`t`t movem.l (sp)+,d0-d7/a1-a6",
    "`t`t andi.b #`$FE,ccr",
    "`t`t rts",
    ".LoadFailed:"
) + $loadFailedDebugLines + @(
    "`t`t bset #1,`$A12001",
    ".RestoreBus:",
    "`t`t btst #1,`$A12001",
    "`t`t beq.s .RestoreBus",
    "`t`t moveq #0,d0",
    "`t`t move.b `$A12003,d0",
    "`t`t andi.b #`$3F,d0",
    "`t`t ori.b #`$40,d0 ; BK1:BK0 = 01 -> physical PRG-RAM bank 1 = S3BANK0 (see IPX.asm)",
    "`t`t move.b d0,`$A12003",
    "`t`t movem.l (sp)+,d0-d7/a1-a6",
    "`t`t ori.b #1,ccr",
    "`t`t rts",
    "",
    "SegaCD_RestoreBank0:",
    "`t`t movem.l d0,-(sp)",
    "`t`t moveq #0,d0",
    "`t`t move.b `$A12003,d0",
    "`t`t andi.b #`$3F,d0",
    "`t`t ori.b #`$40,d0 ; BK1:BK0 = 01 -> physical PRG-RAM bank 1 = S3BANK0 (see IPX.asm)",
    "`t`t move.b d0,`$A12003",
    "`t`t movem.l (sp)+,d0",
    "`t`t rts",
    ""
)
$assetRuntimeIndex = -1
for ($i = 0; $i -lt $source.Count; $i++) {
    if ($source[$i] -match '^JumpToSegaScreen:') { $assetRuntimeIndex = $i; break }
}
if ($assetRuntimeIndex -lt 0) { throw "Could not locate JumpToSegaScreen for the Sega CD asset resolver." }
$source.InsertRange($assetRuntimeIndex, [string[]]$assetRuntime)

$decoderWrappers = [ordered]@{
    Nem_Decomp = @(
        'move.l a0,d0', 'cmpi.l #$00240000,d0', 'blo.w Nem_Decomp_Original',
        'move.w sr,-(sp)', 'ori.w #$0700,sr', 'move.l a0,-(sp)',
        'move.l a0,d0', 'subi.l #$00200000,d0', 'bsr.w SegaCD_LoadAsset',
        'bcs.s .AssetFailed', 'bsr.w Nem_Decomp_Original',
        'bsr.w SegaCD_RestoreBank0', 'movea.l (sp)+,a0', 'move.w (sp)+,sr', 'rts',
        '.AssetFailed:', 'movea.l (sp)+,a0', 'move.w (sp)+,sr', 'rts'
    )
    Nem_Decomp_To_RAM = @(
        'move.l a0,d0', 'cmpi.l #$00240000,d0', 'blo.w Nem_Decomp_To_RAM_Original',
        'move.w sr,-(sp)', 'ori.w #$0700,sr', 'move.l a0,-(sp)',
        'move.l a0,d0', 'subi.l #$00200000,d0', 'bsr.w SegaCD_LoadAsset',
        'bcs.s .AssetFailed', 'bsr.w Nem_Decomp_To_RAM_Original',
        'bsr.w SegaCD_RestoreBank0', 'movea.l (sp)+,a0', 'move.w (sp)+,sr', 'rts',
        '.AssetFailed:', 'movea.l (sp)+,a0', 'move.w (sp)+,sr', 'rts'
    )
    Eni_Decomp = @(
        'move.l a0,d0', 'cmpi.l #$00240000,d0', 'blo.w Eni_Decomp_Original',
        'move.w sr,-(sp)', 'ori.w #$0700,sr', 'move.l a0,-(sp)',
        'move.l a0,d0', 'subi.l #$00200000,d0', 'bsr.w SegaCD_LoadAsset',
        'bcs.s .AssetFailed', 'move.l a0,-(sp)', 'bsr.w Eni_Decomp_Original',
        'move.l a0,d0', 'move.l (sp)+,d1', 'sub.l d1,d0', 'movea.l (sp)+,a0',
        'adda.l d0,a0', 'bsr.w SegaCD_RestoreBank0', 'move.w (sp)+,sr', 'rts',
        '.AssetFailed:', 'movea.l (sp)+,a0', 'move.w (sp)+,sr', 'rts'
    )
    Kos_Decomp = @(
        'move.l a0,d0', 'cmpi.l #$00240000,d0', 'blo.w Kos_Decomp_Original',
        'move.w sr,-(sp)', 'ori.w #$0700,sr', 'move.l a0,-(sp)',
        'move.l a0,d0', 'subi.l #$00200000,d0', 'bsr.w SegaCD_LoadAsset',
        'bcs.s .AssetFailed', 'move.l a0,-(sp)', 'bsr.w Kos_Decomp_Original',
        'move.l a0,d0', 'move.l (sp)+,d1', 'sub.l d1,d0', 'movea.l (sp)+,a0',
        'adda.l d0,a0', 'bsr.w SegaCD_RestoreBank0', 'move.w (sp)+,sr', 'rts',
        '.AssetFailed:', 'movea.l (sp)+,a0', 'move.w (sp)+,sr', 'rts'
    )
}
foreach ($name in $decoderWrappers.Keys) {
    $labelIndex = -1
    for ($i = 0; $i -lt $source.Count; $i++) {
        if ($source[$i] -match ('^' + [regex]::Escape($name + ':') + '$')) { $labelIndex = $i; break }
    }
    if ($labelIndex -lt 0) { throw "Could not locate decoder entry ${name}: in $Assembly." }
    $source[$labelIndex] = "${name}_Original:"
    $wrapperLines = [System.Collections.Generic.List[string]]::new()
    $wrapperLines.Add("${name}:")
    foreach ($line in $decoderWrappers[$name]) {
        if ($line.EndsWith(':')) { $wrapperLines.Add($line) }
        else { $wrapperLines.Add("`t$line") }
    }
    $wrapperLines.Add("")
    $source.InsertRange($labelIndex, [string[]]$wrapperLines)
}

# Queue_Kos normally keeps a raw source pointer and decompresses it over later
# frames. That cannot work for compressed assets stored on CD: their addresses
# are outside Word RAM and the PRG-RAM bank used as the CD staging buffer must
# be restored before the game resumes. Load and decompress external queue
# sources synchronously, while leaving in-memory sources on the original path.
$queueKosIndex = -1
for ($i = 0; $i -lt $source.Count; $i++) {
    if ($source[$i] -match '^Queue_Kos:') { $queueKosIndex = $i; break }
}
if ($queueKosIndex -lt 0) { throw "Could not locate Queue_Kos for the Sega CD asset resolver." }
$source[$queueKosIndex] = "Queue_Kos_Original:"
$queueKosWrapper = @(
    "Queue_Kos:",
    "`t`tmove.l a1,d0",
    "`t`tcmpi.l #`$00240000,d0",
    "`t`tblo.w Queue_Kos_Original",
    "`t`tmove.w sr,-(sp)",
    "`t`tori.w #`$0700,sr",
    "`t`t movem.l d0-d7/a0-a6,-(sp)",
    "`t`tmove.l a1,d0",
    "`t`tsubi.l #`$00200000,d0",
    "`t` bsr.w SegaCD_LoadAsset",
    "`t`tbcs.s Queue_Kos_CD_AssetFailed",
    "`t`tmovea.l a2,a1",
    "`t` bsr.w Kos_Decomp_Original",
    "`t` bsr.w SegaCD_RestoreBank0",
    "Queue_Kos_CD_AssetFailed:",
    "`t`t movem.l (sp)+,d0-d7/a0-a6",
    "`t`tmove.w (sp)+,sr",
    "`t`trts",
    ""
)
$source.InsertRange($queueKosIndex, [string[]]$queueKosWrapper)

# The cartridge reset path above wipes Work RAM from $FF0000 up to CrossResetRAM. On Sega CD that
# range includes the BIOS interrupt jump table, and the IPX jumps straight to the game entry point
# (it does not go through the MMD loader that would copy the header's hint/vint fields). Without
# this, the first V-Int jumps into zeroed RAM and the 68000 crashes right at the SEGA/title screen.
# Re-install the table right after the RAM clear, while interrupts are still masked.
$interruptInstall = [System.Collections.Generic.List[string]]::new()
if ($VIntJumpAddress -ne "") {
    $interruptInstall.Add("`t`tmove.w #`$4EF9,($VIntJumpAddress).l")
    $interruptInstall.Add("`t`tmove.l #VInt,($VIntJumpAddress+2).l")
}
if ($HIntJumpAddress -ne "") {
    $interruptInstall.Add("`t`tmove.w #`$4EF9,($HIntJumpAddress).l")
    $interruptInstall.Add("`t`tmove.l #JmpTo_HInt,($HIntJumpAddress+2).l")
}
if ($interruptInstall.Count -eq 0) {
    Write-Warning "VIntJumpAddress/HIntJumpAddress not given: the BIOS interrupt jump table will NOT be reinstalled and the game will likely crash on the first V-Int."
} else {
    $checksumDoneIndex = -1
    for ($i = 0; $i -lt $source.Count; $i++) {
        if ($source[$i] -match '^Test_Checksum_Done:') { $checksumDoneIndex = $i; break }
    }
    $initVdpIndex = -1
    if ($checksumDoneIndex -ge 0) {
        for ($i = $checksumDoneIndex + 1; $i -lt $source.Count; $i++) {
            if ($source[$i] -match '^\s*bsr\.w\s+Init_VDP\b') { $initVdpIndex = $i; break }
        }
    }
    if ($initVdpIndex -lt 0) { throw "Could not locate Init_VDP after Test_Checksum_Done to install the Sega CD interrupt vectors." }
    $interruptInstall.Insert(0, "; Reinstall the Sega CD BIOS V-Int/H-Int jump table wiped by the RAM clear above.")
    $source.InsertRange($initVdpIndex, [string[]]$interruptInstall)
}

# The cartridge build pads to exactly 2 MiB. In an MMD build the assembler is
# phased into Word RAM, so this cart-only final ORG would move backwards.
for ($i = $source.Count - 1; $i -ge 0; $i--) {
    if ($source[$i] -match '^\s*org\s+\$200000\s*$') {
        $source.RemoveAt($i)
        break
    }
}

# Load the header macro after the project's 68000 macro setup.
$macroInclude = "`t`tinclude `"SegaCD/MMDDefs.asm`""
$insertIndex = -1
for ($i = 0; $i -lt $source.Count; $i++) {
    if ($source[$i] -match '^\s*include "s3.constants.asm"') { $insertIndex = $i + 1; break }
}
if ($insertIndex -lt 0) {
    throw "Could not find s3.constants.asm include in $Assembly."
}
$source.Insert($insertIndex, $macroInclude)

$outputPath = Join-Path (Get-Location) $Output
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $outputPath) | Out-Null
New-Item -ItemType Directory -Force -Path "SegaCD/build" | Out-Null
[System.IO.File]::WriteAllLines($outputPath, $source)
Write-Host "Generated $outputPath with Sega CD MMD header."
