# package.ps1 - build distributable zips for Nexus upload into dist\
#   Configurable Dodge Mod_<ver>_mod-only.zip : just the script mod (requires an existing UE4SS)
#   Configurable Dodge Mod_<ver>_full.zip     : the script mod + a pinned UE4SS runtime ZIP
#
# Usage:
#   .\package.ps1 -Version "3.4" -RuntimeZip "C:\Pinned\UE4SS-update-2.1.zip"
# The full package never reads the live game installation or overwrites an old ZIP.
param(
    [string]$Version = "3.4",
    [string]$RuntimeZip = ""
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSCommandPath
$Dist = Join-Path $ProjectRoot "dist"
New-Item -ItemType Directory -Path $Dist -Force | Out-Null

$ModSrc = Join-Path $ProjectRoot "src\ConfigurableDodgeMod"
if (-not (Test-Path (Join-Path $ModSrc "Scripts\main.lua"))) {
    throw "src\ConfigurableDodgeMod\Scripts\main.lua not found"
}

$StagingRoot = Join-Path $env:TEMP "opencode\Configurable Dodge Mod_pkg"
if (Test-Path $StagingRoot) { Remove-Item $StagingRoot -Recurse -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Copy-ModFiles($destination) {
    New-Item -ItemType Directory -Path (Join-Path $destination "Scripts") -Force | Out-Null
    Copy-Item (Join-Path $ModSrc "Scripts\main.lua") (Join-Path $destination "Scripts\main.lua")
    Copy-Item (Join-Path $ModSrc "ConfigurableDodgeMod.ini") $destination
}

function New-Package($name, $includeRuntime) {
    $stage = Join-Path $StagingRoot $name
    New-Item -ItemType Directory -Path $stage -Force | Out-Null

    if ($includeRuntime) {
        if (-not $RuntimeZip -or -not (Test-Path -LiteralPath $RuntimeZip -PathType Leaf)) {
            throw "The full package requires -RuntimeZip with a pinned, complete UE4SS update-2.1 ZIP."
        }
        Expand-Archive -LiteralPath $RuntimeZip -DestinationPath $stage -Force

        # Strip runtime state and crash/debug artifacts from the pinned runtime.
        Get-ChildItem "$stage\ue4ss" -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(UE4SS\.(log|txt)|imgui\.ini|.*_ObjectDump.*|.*\.dmp|.*\.cache|.*\.log|\.hotreload)$' } |
            Remove-Item -Force

        # Replace any mod in the runtime with the validated source file allowlist.
        $modDst = Join-Path $stage "ue4ss\Mods\ConfigurableDodgeMod"
        if (Test-Path $modDst) { Remove-Item $modDst -Recurse -Force }
        Copy-ModFiles $modDst

        # Keep both runtime mod lists consistent and enable no unrelated mods.
        $modsDir = Join-Path $stage "ue4ss\Mods"
        Set-Content -LiteralPath (Join-Path $modsDir "mods.txt") -Value "ConfigurableDodgeMod : 1" -Encoding UTF8
        $modList = @([ordered]@{ mod_name = "ConfigurableDodgeMod"; mod_enabled = $true })
        ConvertTo-Json -InputObject $modList -Depth 3 |
            Set-Content -LiteralPath (Join-Path $modsDir "mods.json") -Encoding UTF8
    } else {
        Copy-ModFiles (Join-Path $stage "ConfigurableDodgeMod")
    }

    # Keep the GitHub thumbnail, but do not leave a broken local link in the ZIP.
    Copy-Item (Join-Path $ProjectRoot "README.md") $stage
    $readmePath = Join-Path $stage "README.md"
    $readme = (Get-Content -LiteralPath $readmePath -Raw) -replace '(?m)^!\[Configurable Dodge Mod thumbnail\]\(media/main\.png\)\r?\n\r?\n', ''
    Set-Content -LiteralPath $readmePath -Value $readme -Encoding UTF8 -NoNewline

    $zipPath = Join-Path $Dist "$name.zip"
    if (Test-Path $zipPath) { throw "Refusing to overwrite existing package: $zipPath" }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath)
    Write-Output "built $zipPath"
}

New-Package "Configurable Dodge Mod_$($Version)_mod-only" $false
New-Package "Configurable Dodge Mod_$($Version)_full" $true

Write-Output "done."
