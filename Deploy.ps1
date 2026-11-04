# Deploy the development copy (src\ConfigurableDodgeMod) into the game's
# UE4SS mod folder. Run from the repo root:
#
#   Deploy.bat            -> copy the code (main.lua, listener, Setup)
#   Deploy.bat -Ini       -> also apply ConfigurableDodgeMod.ini
#
# The ini is NOT copied by default: the installed ini is your live config,
# and overwriting it with the shipped default would silently reset your keys.
param(
    [switch]$Ini,
    [string]$Target = "D:\Steam\steamapps\common\S.T.A.L.K.E.R. 2 Heart of Chornobyl\Stalker2\Binaries\Win64\ue4ss\Mods\ConfigurableDodgeMod"
)

$ErrorActionPreference = "Stop"
$src = Join-Path $PSScriptRoot "src\ConfigurableDodgeMod"

if (-not (Test-Path (Join-Path $src "Scripts\main.lua"))) { throw "source not found: $src" }
if (-not (Test-Path (Join-Path $Target "Scripts\main.lua"))) { throw "target is not the installed mod folder: $Target" }

Copy-Item (Join-Path $src "Scripts\main.lua") (Join-Path $Target "Scripts\main.lua") -Force
foreach ($f in @("DodgeSignal.ps1", "Setup.ps1", "Setup.bat")) {
    Copy-Item (Join-Path $src $f) (Join-Path $Target $f) -Force
}
if ($Ini) {
    Copy-Item (Join-Path $src "ConfigurableDodgeMod.ini") (Join-Path $Target "ConfigurableDodgeMod.ini") -Force
}

Write-Host "deployed code to $Target" -ForegroundColor Green
if ($Ini) { Write-Host "applied ConfigurableDodgeMod.ini" -ForegroundColor Green }
