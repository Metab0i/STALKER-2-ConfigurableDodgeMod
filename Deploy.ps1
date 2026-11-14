# Deploy the development copy (src\ConfigurableDodgeMod) into the game's
# UE4SS mod folder. Run from the repo root:
#
#   Deploy.bat            -> copy the code (main.lua)
#   Deploy.bat -Ini       -> also apply ConfigurableDodgeMod.ini
#
# The game install is discovered automatically (Steam App 1643320 registry
# entry, then Steam library folders). To override, pass -Target "<path to
# ...\ue4ss\Mods\ConfigurableDodgeMod>" or create deploy.target next to this
# script containing the game folder (the one with Stalker2\Binaries).
#
# The ini is NOT copied by default: the installed ini is your live config,
# and overwriting it with the shipped default would silently reset your keys.
param(
    [switch]$Ini,
    [string]$Target = ""
)

$ErrorActionPreference = "Stop"
$src = Join-Path $PSScriptRoot "src\ConfigurableDodgeMod_UE4SS"
$SteamAppId = "1643320"
$GameFolderName = "S.T.A.L.K.E.R. 2 Heart of Chornobyl"

if (-not (Test-Path (Join-Path $src "Scripts\main.lua"))) { throw "source not found: $src" }

function Find-GameRoot {
    # 1. deploy.target next to this script (game folder)
    $cfg = Join-Path $PSScriptRoot "deploy.target"
    if (Test-Path $cfg) {
        $p = (Get-Content $cfg -Raw).Trim()
        if ($p -and (Test-Path (Join-Path $p "Stalker2\Binaries\Win64"))) { return $p }
    }

    # 2. Steam's uninstall entry for the app (install location)
    foreach ($key in @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App $SteamAppId",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Steam App $SteamAppId",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Steam App $SteamAppId"
    )) {
        try {
            $loc = (Get-ItemProperty -Path $key -ErrorAction Stop).InstallLocation
            if ($loc -and (Test-Path (Join-Path $loc "Stalker2\Binaries\Win64"))) { return $loc }
        } catch { }
    }

    # 3. Steam libraries: every library that has the game folder
    $libraries = @()
    foreach ($key in @("HKCU:\Software\Valve\Steam", "HKLM:\SOFTWARE\WOW6432Node\Valve\Steam", "HKLM:\SOFTWARE\Valve\Steam")) {
        try {
            $props = Get-ItemProperty -Path $key -ErrorAction Stop
            foreach ($candidate in @($props.SteamPath, $props.InstallPath)) {
                if ($candidate -and (Test-Path $candidate)) { $libraries += ($candidate -replace '/', '\'); break }
            }
        } catch { }
        if ($libraries.Count -gt 0) { break }
    }
    foreach ($steam in $libraries) {
        $vdf = Join-Path $steam "steamapps\libraryfolders.vdf"
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $lib = $m.Groups[1].Value -replace '\\\\', '\'
                if ($lib -and (Test-Path $lib)) { $libraries += $lib }
            }
        }
    }
    foreach ($lib in ($libraries | Select-Object -Unique)) {
        foreach ($rel in @("steamapps\common\$GameFolderName", "SteamApps\common\$GameFolderName")) {
            $cand = Join-Path $lib $rel
            if (Test-Path (Join-Path $cand "Stalker2\Binaries\Win64")) { return $cand }
        }
    }
    return $null
}

if (-not $Target) {
    $game = Find-GameRoot
    if (-not $game) {
        throw "Could not find the S.T.A.L.K.E.R. 2 install. Pass -Target '<game>\Stalker2\Binaries\Win64\ue4ss\Mods\ConfigurableDodgeMod' or create deploy.target with the game folder path."
    }
    $Target = Join-Path $game "Stalker2\Binaries\Win64\ue4ss\Mods\ConfigurableDodgeMod"
    Write-Host "found game: $game"
}

$modsDir = Split-Path -Parent $Target
if (-not (Test-Path $modsDir)) {
    throw "UE4SS Mods folder not found: $modsDir - install UE4SS first, or pass -Target."
}
if (-not (Test-Path (Join-Path $Target "Scripts\main.lua"))) {
    New-Item -ItemType Directory -Path (Join-Path $Target "Scripts") -Force | Out-Null
    Write-Host "creating mod folder: $Target"
}

Copy-Item (Join-Path $src "Scripts\main.lua") (Join-Path $Target "Scripts\main.lua") -Force
if ($Ini) {
    Copy-Item (Join-Path $src "ConfigurableDodgeMod.ini") (Join-Path $Target "ConfigurableDodgeMod.ini") -Force
}

Write-Host "deployed code to $Target" -ForegroundColor Green
if ($Ini) { Write-Host "applied ConfigurableDodgeMod.ini" -ForegroundColor Green }
