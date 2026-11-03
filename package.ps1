# package.ps1 - build distributable zips for Nexus upload into dist\
#   Configurable Dodge Mod_<ver>_mod-only.zip : just the script mod (requires the user to already have UE4SS)
#   Configurable Dodge Mod_<ver>_full.zip     : the script mod + a complete UE4SS runtime (dwmapi.dll etc.)
param(
    [string]$Version = "1.5"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSCommandPath
$Dist = Join-Path $ProjectRoot "dist"
New-Item -ItemType Directory -Path $Dist -Force | Out-Null

if (-not (Test-Path (Join-Path $ProjectRoot "src\Configurable Dodge Mod\Scripts\main.lua"))) {
    throw "src\Configurable Dodge Mod\Scripts\main.lua not found"
}

$GameDir = "D:\Steam\steamapps\common\S.T.A.L.K.E.R. 2 Heart of Chornobyl"
$Win64 = Join-Path $GameDir "Stalker2\Binaries\Win64"
$StagingRoot = Join-Path $env:TEMP "opencode\Configurable Dodge Mod_pkg"
if (Test-Path $StagingRoot) { Remove-Item $StagingRoot -Recurse -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-Package($name, $installerText, $includeRuntime) {
    $stage = Join-Path $StagingRoot $name
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    # mod folder (renamed to the UE4SS mod id expected by mods.txt)
    Copy-Item -Recurse (Join-Path $ProjectRoot "src\Configurable Dodge Mod") (Join-Path $stage "Configurable Dodge Mod")

    # installation readme
    Set-Content -LiteralPath (Join-Path $stage "INSTALL.txt") -Value $installerText -Encoding UTF8

    # project readme (distributed as-is)
    Copy-Item (Join-Path $ProjectRoot "README.md") $stage

    # optional UE4SS runtime (proxy dll + ue4ss folder; our mod is already inside the staged copy)
    if ($includeRuntime) {
        Copy-Item (Join-Path $Win64 "dwmapi.dll") $stage
        Copy-Item -Recurse (Join-Path $Win64 "ue4ss") $stage
        # strip files that are personal to this machine (logs, crash dumps, object dumps)
        Get-ChildItem "$stage\ue4ss" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "^UE4SS\.(log|txt)$|UE4SS_ObjectDump|\.dmp$|\.cache$" } |
            Remove-Item -Force
        Get-ChildItem "$stage\ue4ss" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "\.log$|\.dmp$|_ObjectDump" } |
            Remove-Item -Force
    }

    $zipPath = Join-Path $Dist "$name.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath)
    Write-Output "built $zipPath"
}

$modOnlyText = @"
SIMPLE DODGE (UE4SS script mod) v$Version
=========================================

REQUIRES: UE4SS already installed in Stalker2\Binaries\Win64\
(cabinet with the STALKER 2 Update 2.x compatibility fix - a working setup
 shows up as dwmapi.dll + ue4ss\UE4SS.dll next to the game exe).

INSTALL
1. Copy the Configurable Dodge Mod folder into  Stalker2\Binaries\Win64\ue4ss\Mods\
2. Add "Configurable Dodge Mod : 1" to  Stalker2\Binaries\Win64\ue4ss\Mods\mods.txt
   (or edit the existing Configurable Dodge Mod line to end with : 1)
3. Launch the game. Double-tap Z = dodge left, C = dodge right, S = dodge back.

If you use the Mod Configuration Menu, configure Configurable Dodge Mod in MCM
(press the MCM key, open Configurable Dodge Mod).

Full readme: see README.md in this archive.
"@

$fullText = @"
SIMPLE DODGE - FULL INSTALL (UE4SS included) v$Version
======================================================

This package includes a community-compatible UE4SS runtime for
S.T.A.L.K.E.R. 2 Update 2.0+ plus the Configurable Dodge Mod mod, pre-configured.

1. Copy everything from this archive into
   S.T.A.L.K.E.R. 2 Heart of Chornobyl\Stalker2\Binaries\Win64\
   (the folder with Stalker2-Win64-Shipping.exe)
2. Launch the game.
3. Double-tap Z = dodge left, C = dodge right, S = dodge back.

If you use the Mod Configuration Menu, configure Configurable Dodge Mod in MCM
(press the MCM key, open Configurable Dodge Mod).

Full readme: see README.md in this archive.
"@

New-Package "Configurable Dodge Mod_$($Version)_mod-only" $modOnlyText $false
New-Package "Configurable Dodge Mod_$($Version)_full" $fullText $true

Write-Output "done."





