# package.ps1 - build the Nexus upload into dist\
#   Configurable Dodge Mod_<ver>_mod-only.zip : the script mod (requires an existing UE4SS)
# dist\ is ignored by git; the archive is the upload artifact.
param(
    [string]$Ue4ssVersion = "3.4"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSCommandPath
$ModSrc = Join-Path $ProjectRoot "src\ConfigurableDodgeMod"
$Readme = Join-Path $ProjectRoot "README.md"
$Dist = Join-Path $ProjectRoot "dist"
New-Item -ItemType Directory -Path $Dist -Force | Out-Null

if (-not (Test-Path (Join-Path $ModSrc "Scripts\main.lua"))) {
    throw "src\ConfigurableDodgeMod\Scripts\main.lua not found"
}

$stagingRoot = Join-Path $env:TEMP "opencode\Configurable Dodge Mod_pkg"
$stage = Join-Path $stagingRoot "ue4ss"
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$mod = Join-Path $stage "ConfigurableDodgeMod"
New-Item -ItemType Directory -Path (Join-Path $mod "Scripts") -Force | Out-Null

Copy-Item (Join-Path $ModSrc "Scripts\main.lua") (Join-Path $mod "Scripts\main.lua")
Copy-Item (Join-Path $ModSrc "ConfigurableDodgeMod.ini") $mod

# Ship the README, minus the GitHub-only thumbnail.
$readme = (Get-Content -LiteralPath $Readme -Raw) -replace '(?m)^!\[[^\]]*\]\(media/[^)]*\)\r?\n\r?\n', ''
Set-Content -LiteralPath (Join-Path $stage "README.md") -Value $readme -Encoding UTF8 -NoNewline

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = Join-Path $Dist "Configurable Dodge Mod_$($Ue4ssVersion)_mod-only.zip"
if (Test-Path $zip) { throw "Refusing to overwrite existing package: $zip" }
[System.IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
Write-Output "built $zip"
Write-Output "done."
