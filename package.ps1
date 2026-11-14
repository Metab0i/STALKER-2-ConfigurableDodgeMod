# package.ps1 - build the mod-only ZIP for Nexus upload into dist\
#   Configurable Dodge Mod_<ver>_mod-only.zip : the script mod (requires an existing UE4SS)
# Existing archives are never overwritten.
param(
    [string]$Version = "3.4"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSCommandPath
$Dist = Join-Path $ProjectRoot "dist"
New-Item -ItemType Directory -Path $Dist -Force | Out-Null

$ModSrc = Join-Path $ProjectRoot "src\ConfigurableDodgeMod_UE4SS"
if (-not (Test-Path (Join-Path $ModSrc "Scripts\main.lua"))) {
    throw "src\ConfigurableDodgeMod_UE4SS\Scripts\main.lua not found"
}

$StagingRoot = Join-Path $env:TEMP "opencode\Configurable Dodge Mod_pkg"
if (Test-Path $StagingRoot) { Remove-Item $StagingRoot -Recurse -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem

$name = "Configurable Dodge Mod_$($Version)_mod-only"
$stage = Join-Path $StagingRoot $name
$modDst = Join-Path $stage "ConfigurableDodgeMod"
New-Item -ItemType Directory -Path (Join-Path $modDst "Scripts") -Force | Out-Null
Copy-Item (Join-Path $ModSrc "Scripts\main.lua") (Join-Path $modDst "Scripts\main.lua")
Copy-Item (Join-Path $ModSrc "ConfigurableDodgeMod.ini") $modDst

# Keep the GitHub thumbnail, but do not leave a broken local link in the ZIP.
Copy-Item (Join-Path $ProjectRoot "README.md") $stage
$readmePath = Join-Path $stage "README.md"
$readme = (Get-Content -LiteralPath $readmePath -Raw) -replace '(?m)^!\[Configurable Dodge Mod thumbnail\]\(media/main\.png\)\r?\n\r?\n', ''
Set-Content -LiteralPath $readmePath -Value $readme -Encoding UTF8 -NoNewline

$zipPath = Join-Path $Dist "$name.zip"
if (Test-Path $zipPath) { throw "Refusing to overwrite existing package: $zipPath" }
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath)
Write-Output "built $zipPath"
Write-Output "done."
