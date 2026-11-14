# package.ps1 - build the Nexus uploads into dist\
#   ConfigurableDodgeNativeDist_UE4SS\Configurable Dodge Mod_<ver>_UE4SS.zip
#   ConfigurableDodgeNativeDist_DLL\Configurable Dodge Mod_<ver>_DLL.zip
# dist\ is ignored by git; these archives are the upload artifacts.
# The DLL archive is built from source, so the repo never carries a binary.
param(
    [string]$Ue4ssVersion = "3.4",
    [string]$DllVersion = "4.0",
    [string]$Gcc = "g++"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = Split-Path -Parent $PSCommandPath
$Ue4ssSrc = Join-Path $ProjectRoot "src\ConfigurableDodgeMod_UE4SS"
$DllSrc = Join-Path $ProjectRoot "src\ConfigurableDodgeMod_DLL"
$Readme = Join-Path $ProjectRoot "README.md"

$Ue4ssDist = Join-Path $ProjectRoot "dist\ConfigurableDodgeNativeDist_UE4SS"
$DllDist = Join-Path $ProjectRoot "dist\ConfigurableDodgeNativeDist_DLL"
New-Item -ItemType Directory -Path $Ue4ssDist, $DllDist -Force | Out-Null

function New-Stage([string]$Name) {
    $stagingRoot = Join-Path $env:TEMP "opencode\Configurable Dodge Mod_pkg"
    $stage = Join-Path $stagingRoot $Name
    if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    # Ship the README, minus the GitHub-only thumbnail.
    $readme = (Get-Content -LiteralPath $Readme -Raw) -replace '(?m)^!\[[^\]]*\]\(media/[^)]*\)\r?\n\r?\n', ''
    Set-Content -LiteralPath (Join-Path $stage "README.md") -Value $readme -Encoding UTF8 -NoNewline
    return $stage
}

function New-Zip([string]$Stage, [string]$ZipPath) {
    if (Test-Path $ZipPath) { throw "Refusing to overwrite existing package: $ZipPath" }
    [System.IO.Compression.ZipFile]::CreateFromDirectory($Stage, $ZipPath)
    Write-Output "built $ZipPath"
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

# UE4SS variant: the Lua script mod.
$stage = New-Stage "ue4ss"
$mod = Join-Path $stage "ConfigurableDodgeMod"
New-Item -ItemType Directory -Path (Join-Path $mod "Scripts") -Force | Out-Null
Copy-Item (Join-Path $Ue4ssSrc "Scripts\main.lua") (Join-Path $mod "Scripts\main.lua")
Copy-Item (Join-Path $Ue4ssSrc "ConfigurableDodgeMod.ini") $mod
New-Zip $stage (Join-Path $Ue4ssDist "Configurable Dodge Mod_$($Ue4ssVersion)_UE4SS.zip")

# DLL variant: compile, then ship the drop-in folder.
$build = Join-Path $ProjectRoot "build"
New-Item -ItemType Directory -Path $build -Force | Out-Null
$dll = Join-Path $build "main.dll"
& $Gcc -std=c++17 -O2 -shared -static -o $dll (Join-Path $DllSrc "dodge.cpp")
if ($LASTEXITCODE -ne 0) { throw "compile failed with exit code $LASTEXITCODE" }

$stage = New-Stage "dll"
$mod = Join-Path $stage "ConfigurableDodgeNative"
New-Item -ItemType Directory -Path (Join-Path $mod "dlls") -Force | Out-Null
Copy-Item $dll (Join-Path $mod "dlls\main.dll")
Copy-Item (Join-Path $DllSrc "ConfigurableDodge.ini") $mod
New-Zip $stage (Join-Path $DllDist "Configurable Dodge Mod_$($DllVersion)_DLL.zip")

Write-Output "done."
