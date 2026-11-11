# package.ps1 - build distributable zips for Nexus upload into dist\
#   Configurable Dodge Mod_<ver>_mod-only.zip : just the script mod (requires an existing UE4SS)
#   Configurable Dodge Mod_<ver>_full.zip     : the script mod + a complete UE4SS runtime
param(
    [string]$Version = "3.1"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSCommandPath
$Dist = Join-Path $ProjectRoot "dist"
New-Item -ItemType Directory -Path $Dist -Force | Out-Null

$ModSrc = Join-Path $ProjectRoot "src\ConfigurableDodgeMod"
if (-not (Test-Path (Join-Path $ModSrc "Scripts\main.lua"))) {
    throw "src\ConfigurableDodgeMod\Scripts\main.lua not found"
}

$GameDir = "D:\Steam\steamapps\common\S.T.A.L.K.E.R. 2 Heart of Chornobyl"
$Win64 = Join-Path $GameDir "Stalker2\Binaries\Win64"
$StagingRoot = Join-Path $env:TEMP "opencode\Configurable Dodge Mod_pkg"
if (Test-Path $StagingRoot) { Remove-Item $StagingRoot -Recurse -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem

function New-Package($name, $includeRuntime) {
    $stage = Join-Path $StagingRoot $name
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    if ($includeRuntime) {
        Copy-Item (Join-Path $Win64 "dwmapi.dll") $stage
        Copy-Item -Recurse (Join-Path $Win64 "ue4ss") $stage

        # strip machine-specific files (logs, dumps, dev gate)
        Get-ChildItem "$stage\ue4ss" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(UE4SS\.(log|txt)|.*_ObjectDump.*|.*\.dmp|.*\.cache|.*\.log|\.hotreload)$' } |
            Remove-Item -Force

        # the mod belongs in the UE4SS mods folder (not next to the game exe)
        $modDst = Join-Path $stage "ue4ss\Mods\ConfigurableDodgeMod"
        if (Test-Path $modDst) { Remove-Item $modDst -Recurse -Force }
        Copy-Item -Recurse $ModSrc $modDst

        # ensure the mod is enabled
        $modsTxt = Join-Path $stage "ue4ss\Mods\mods.txt"
        if (Test-Path $modsTxt) {
            $lines = Get-Content $modsTxt | Where-Object { $_ -notmatch '^\s*ConfigurableDodgeMod\s*:' }
            $lines += "ConfigurableDodgeMod : 1"
            Set-Content -LiteralPath $modsTxt -Value $lines -Encoding UTF8
        }

        # attribution files for the UE4SS compatibility fix (required by its terms)
        $fixZip = Join-Path $GameDir "mod packs\STALKER2 UE4SS Update2.0.5 Compatibility Fix V1.2 2341 1.2 2026-09-13T07-37Z OxGWqGd2R.zip"
        if (Test-Path $fixZip) {
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
            Write-Warning "Compatibility-fix zip not found at $fixZip - attribution files NOT bundled."
        }
    } else {
        Copy-Item -Recurse $ModSrc (Join-Path $stage "ConfigurableDodgeMod")
    }

    $zipPath = Join-Path $Dist "$name.zip"
    if (Test-Path $zipPath) { Remove-Item $zipPath }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath)
    Write-Output "built $zipPath"
}

New-Package "Configurable Dodge Mod_$($Version)_mod-only" $false
New-Package "Configurable Dodge Mod_$($Version)_full" $true

Write-Output "done."
