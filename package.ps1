# package.ps1 - build distributable zips for Nexus upload into dist\
#   Configurable Dodge Mod_<ver>_mod-only.zip : just the script mod (requires the user to already have UE4SS)
#   Configurable Dodge Mod_<ver>_full.zip     : the script mod + a complete UE4SS runtime (dwmapi.dll etc.)
param(
    [string]$Version = "2.3"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSCommandPath
$Dist = Join-Path $ProjectRoot "dist"
New-Item -ItemType Directory -Path $Dist -Force | Out-Null

if (-not (Test-Path (Join-Path $ProjectRoot "src\ConfigurableDodgeMod\Scripts\main.lua"))) {
    throw "src\ConfigurableDodgeMod\Scripts\main.lua not found"
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
    Copy-Item -Recurse (Join-Path $ProjectRoot "src\ConfigurableDodgeMod") (Join-Path $stage "ConfigurableDodgeMod")

    # installation readme
    Set-Content -LiteralPath (Join-Path $stage "INSTALL.txt") -Value $installerText -Encoding UTF8

    # project readme (distributed as-is) + the images it references
    Copy-Item (Join-Path $ProjectRoot "README.md") $stage
    $mediaSrc = Join-Path $ProjectRoot "media"
    if (Test-Path $mediaSrc) {
        $mediaDst = Join-Path $stage "media"
        New-Item -ItemType Directory -Path $mediaDst -Force | Out-Null
        Get-ChildItem $mediaSrc -File -Filter *.png | Copy-Item -Destination $mediaDst -Force
    }

    # optional UE4SS runtime (proxy dll + ue4ss folder; our mod is already inside the staged copy)
    if ($includeRuntime) {
        Copy-Item (Join-Path $Win64 "dwmapi.dll") $stage
        Copy-Item -Recurse (Join-Path $Win64 "ue4ss") $stage
        # strip files that are personal to this machine (logs, crash dumps, object dumps)
        Get-ChildItem "$stage\ue4ss" -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "^UE4SS\.(log|txt)$|UE4SS_ObjectDump|\.dmp$|\.cache$" } |
            Remove-Item -Force
        Get-ChildItem "$stage\ue4ss" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match "\.log$|\.dmp$|_ObjectDump|^\.hotreload$" } |
            Remove-Item -Force

        # redistribute the UE4SS compatibility fix's attribution files alongside
        # its patched binaries (required by its attribution terms)
        $fixZip = Join-Path $GameDir "mod packs\STALKER2 UE4SS Update2.0.5 Compatibility Fix V1.2 2341 1.2 2026-09-13T07-37Z OxGWqGd2R.zip"
        if (Test-Path $fixZip) {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $attrDir = Join-Path $stage "CompatibilityFix-Attribution"
            New-Item -ItemType Directory -Path $attrDir -Force | Out-Null
            $fx = [System.IO.Compression.ZipFile]::OpenRead($fixZip)
            foreach ($e in $fx.Entries) {
                if ($e.FullName -match '(^|/)(LICENSES_AND_ATTRIBUTION\.txt|SOURCE_AND_BUILD_INFO\.txt|CHANGELOG\.txt)$|^(patches|licenses)/[^/]+$') {
                    $dest = Join-Path $attrDir ($e.FullName -replace '/', '\')
                    $destParent = Split-Path -Parent $dest
                    if (-not (Test-Path $destParent)) { New-Item -ItemType Directory -Path $destParent -Force | Out-Null }
                    [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
                }
            }
            $fx.Dispose()
        } else {
            Write-Warning "Compatibility-fix zip not found at $fixZip - attribution files NOT bundled. Build the next release where it's reachable."
        }
    }

    $zipPath = Join-Path $Dist "$name.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath)
    Write-Output "built $zipPath"
}

$modOnlyText = @"
CONFIGURABLE DODGE MOD (UE4SS script mod) v$Version
=========================================

REQUIRES: UE4SS already installed in Stalker2\Binaries\Win64\
(cabinet with the STALKER 2 Update 2.x compatibility fix - a working setup
 shows up as dwmapi.dll + ue4ss\UE4SS.dll next to the game exe).

INSTALL
1. Copy the Configurable Dodge Mod folder into  Stalker2\Binaries\Win64\ue4ss\Mods\
2. Add "ConfigurableDodgeMod : 1" to  Stalker2\Binaries\Win64\ue4ss\Mods\mods.txt
   (the mod id must have no spaces)
3. Launch the game. Default: hold A / D / S + press Left Alt = dodge.
   Run Setup.bat (in the mod folder) for an interactive setup, or edit
   ConfigurableDodgeMod.ini - changes apply live in about 2 seconds.
   Modifier keys (Alt/Ctrl/Shift) and mouse buttons all work - a small
   listener starts automatically with the game.


Full readme: see README.md in this archive.
"@

$fullText = @"
CONFIGURABLE DODGE MOD - FULL INSTALL (UE4SS included) v$Version
======================================================

This package includes a community-compatible UE4SS runtime for
S.T.A.L.K.E.R. 2 Update 2.0+ plus the Configurable Dodge Mod, pre-configured.

1. Copy everything from this archive into
   S.T.A.L.K.E.R. 2 Heart of Chornobyl\Stalker2\Binaries\Win64\
   (the folder with Stalker2-Win64-Shipping.exe)
2. Launch the game.
3. Default: hold A / D / S + press Left Alt = dodge left / right / back.
   Run Setup.bat in the mod folder to switch to double-tap mode or rebind.
   Modifier keys and mouse buttons all work - the listener starts with the game.


Full readme: see README.md in this archive.
"@

New-Package "Configurable Dodge Mod_$($Version)_mod-only" $modOnlyText $false
New-Package "Configurable Dodge Mod_$($Version)_full" $fullText $true

Write-Output "done."







