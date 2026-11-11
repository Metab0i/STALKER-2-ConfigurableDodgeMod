# Configurable Dodge Mod - interactive setup
# Writes ConfigurableDodgeMod.ini next to this script.
# Everything can also be edited by hand in that file - it applies live in game.

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot  # this script lives in the mod folder, next to the ini
$ini = Join-Path $root "ConfigurableDodgeMod.ini"
if (-not (Test-Path $ini)) {
    # fall back to the working directory, then create next to the script
    $cwdIni = Join-Path (Get-Location).Path "ConfigurableDodgeMod.ini"
    if (Test-Path $cwdIni) { $ini = $cwdIni }
}
$inv = [Globalization.CultureInfo]::InvariantCulture

# ================= input capture =================
# Keys and mouse buttons are polled with GetAsyncKeyState - deterministic edge
# detection that sees every physical key, including bare modifiers
# (Alt/Ctrl/Shift) which console key reading cannot report.
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CapIn {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
}
"@
$MouseVK = @{
    0x01 = 'LeftMouseButton'; 0x02 = 'RightMouseButton'; 0x04 = 'MiddleMouseButton'
    0x05 = 'ThumbMouseButton'; 0x06 = 'ThumbMouseButton2'
}

# mouse buttons and keyboard keys are both polled
$CandidateVK = @(0x01, 0x02, 0x04, 0x05, 0x06)  # mouse buttons
$CandidateVK += 0x08, 0x09, 0x0D, 0x13, 0x14, 0x1B, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2D, 0x2E
$CandidateVK += 0x30..0x39      # 0-9
$CandidateVK += 0x41..0x5A      # A-Z
$CandidateVK += 0x5B, 0x5C      # Win keys
$CandidateVK += 0x60..0x6F      # numpad
$CandidateVK += 0x70..0x87      # F1-F24
$CandidateVK += 0x90, 0x91      # num lock / scroll lock
$CandidateVK += 0xA0..0xA5      # Shift / Ctrl / Alt (left + right)
$CandidateVK += 0xBA..0xC0      # OEM punctuation
$CandidateVK += 0xDB..0xDE      # brackets, backslash, quote
$CandidateVK += 0xE2

function Test-KeyDown([int]$vk) {
    return (([CapIn]::GetAsyncKeyState($vk) -band 0x8000) -ne 0)
}

function Get-VKName([int]$vk) {
    if ($MouseVK.ContainsKey($vk)) { return $MouseVK[$vk] }
    if ($vk -ge 0x41 -and $vk -le 0x5A) { return [string][char]$vk }
    if ($vk -ge 0x30 -and $vk -le 0x39) { return [string][char]$vk }
    if ($vk -ge 0x70 -and $vk -le 0x87) { return "F" + ($vk - 0x6F) }
    switch ($vk) {
        0x08 { 'Backspace' } 0x09 { 'Tab' } 0x0D { 'Enter' } 0x13 { 'Pause' } 0x14 { 'CapsLock' }
        0x1B { 'Escape' } 0x20 { 'Space' } 0x21 { 'PageUp' } 0x22 { 'PageDown' } 0x23 { 'End' } 0x24 { 'Home' }
        0x25 { 'Left' } 0x26 { 'Up' } 0x27 { 'Right' } 0x28 { 'Down' } 0x2D { 'Insert' } 0x2E { 'Delete' }
        0x5B { 'Left Win' } 0x5C { 'Right Win' }
        0xA0 { 'Left Shift' } 0xA1 { 'Right Shift' } 0xA2 { 'Left Ctrl' } 0xA3 { 'Right Ctrl' }
        0xA4 { 'Left Alt' } 0xA5 { 'Right Alt' }
        0xBA { ';' } 0xBB { '=' } 0xBC { ',' } 0xBD { '-' } 0xBE { '.' } 0xBF { '/' } 0xC0 { '`' }
        0xDB { '[' } 0xDC { '\' } 0xDD { ']' } 0xDE { "'" } 0xE2 { '\' }
        default { 'VK 0x{0:X2}' -f $vk }
    }
}

function Capture-KeyOrMouse([string]$default, [string]$label) {
    Write-Host ""
    Write-Host "  $label" -ForegroundColor Cyan
    Write-Host "  Press the key or mouse button now. Enter = keep '$(Format-KeyDisplay $default)', Esc = cancel."

    # Snapshot the current key state, then briefly settle. A key pressed
    # during the settle MUST still count (pressing right after the prompt
    # must not be lost); keys already held are ignored until released, so
    # the Enter that answered the previous prompt cannot leak in.
    $prev = @{}
    foreach ($vk in $CandidateVK) { $prev[$vk] = (Test-KeyDown $vk) }
    $settleDeadline = [DateTime]::UtcNow.AddSeconds(2)
    $quiet = $false
    while (-not $quiet -and [DateTime]::UtcNow -lt $settleDeadline) {
        $quiet = $true
        foreach ($vk in $CandidateVK) {
            $down = Test-KeyDown $vk
            if ($down -and -not $prev[$vk]) {
                if ($vk -eq 0x0D -or $vk -eq 0x1B) {
                    Write-Host "  kept $(Format-KeyDisplay $default)"
                    return $default
                }
                if ($MouseVK.ContainsKey($vk)) {
                    Write-Host ("  captured: {0}" -f $MouseVK[$vk]) -ForegroundColor Green
                    return $MouseVK[$vk]
                }
                Write-Host ("  captured: {0} (0x{1:X2})" -f (Get-VKName $vk), $vk) -ForegroundColor Green
                return ('0x{0:X2}' -f $vk)
            }
            if ($down) { $quiet = $false }
            $prev[$vk] = $down
        }
        if (-not $quiet) { Start-Sleep -Milliseconds 15 }
    }

    while ($true) {
        foreach ($vk in $CandidateVK) {
            $down = Test-KeyDown $vk
            if ($down -and -not $prev[$vk]) {
                if ($vk -eq 0x0D -or $vk -eq 0x1B) {
                    Write-Host "  kept $(Format-KeyDisplay $default)"
                    return $default
                }
                if ($MouseVK.ContainsKey($vk)) {
                    Write-Host ("  captured: {0}" -f $MouseVK[$vk]) -ForegroundColor Green
                    return $MouseVK[$vk]
                }
                Write-Host ("  captured: {0} (0x{1:X2})" -f (Get-VKName $vk), $vk) -ForegroundColor Green
                return ('0x{0:X2}' -f $vk)
            }
            $prev[$vk] = $down
        }
        Start-Sleep -Milliseconds 10
    }
}

# Discard keys that are already queued in the console input buffer. Captured
# key presses are real keystrokes, so without this the key used to pick the
# dodge button would be typed into the next prompt (and Enter would answer it
# with an empty line). Harmless when input is redirected.
function Clear-ConsoleInput {
    Start-Sleep -Milliseconds 50   # let the input queue settle
    try {
        while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
    } catch { }
}
# Human-readable form of a stored key value: "Z (0x5A)"; names stay as-is.
function Format-KeyDisplay([string]$value) {
    if ($value -match '^0[xX]([0-9A-Fa-f]{1,2})$') {
        $vk = [Convert]::ToInt32($matches[1], 16)
        return ('{0} (0x{1:X2})' -f (Get-VKName $vk), $vk)
    }
    return $value
}
# Key values are stored as VK hex for exactness, with the plain-English name
# as an inline ";" comment so the ini stays readable:
#   ButtonKey=0x58   ; X
function Format-KeyEntry([string]$value) {
    if ($value -match '^0[xX]([0-9A-Fa-f]{1,2})$') {
        $vk = [Convert]::ToInt32($matches[1], 16)
        return ('{0}   ; {1}' -f $value, (Get-VKName $vk))
    }
    return $value
}
# ================= numeric input with validation =================
function ConvertTo-Number([string]$text) {
    $value = 0.0
    if ([double]::TryParse($text, [Globalization.NumberStyles]::Float, $inv, [ref]$value)) { return $value }
    return $null
}

function Read-ValidNumber([string]$label, [string]$current, [double]$min, [double]$max) {
    while ($true) {
        Clear-ConsoleInput
        $entered = Read-Host "  $label [$current]"
        if ([string]::IsNullOrWhiteSpace($entered)) {
            $value = ConvertTo-Number $current
            if ($value -ne $null -and $value -ge $min -and $value -le $max) { return $value }
            Write-Host "  the current value '$current' is not valid - please type a number ($min-$max)." -ForegroundColor Red
            continue
        }
        $value = ConvertTo-Number ($entered.Trim())
        if ($value -eq $null) {
            Write-Host "  '$entered' is not a number - try again (example: 650)." -ForegroundColor Red
            continue
        }
        if ($value -lt $min -or $value -gt $max) {
            Write-Host "  $value is out of range - enter a number between $min and $max." -ForegroundColor Red
            continue
        }
        return $value
    }
}

function Format-Number([double]$value) {
    return $value.ToString("0.###", $inv)
}

# ================= banner =================
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host " Configurable Dodge Mod - Setup" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "Keys are captured live - just press them. Any key works:" -ForegroundColor DarkGray
Write-Host "  - modifiers: Left Alt / Right Alt / Ctrl / Shift" -ForegroundColor DarkGray
Write-Host "  - letters, digits, F1-F12, arrows, Home/End/PgUp/PgDn, Insert/Delete" -ForegroundColor DarkGray
Write-Host "  - mouse: LeftMouseButton, RightMouseButton, MiddleMouseButton," -ForegroundColor DarkGray
Write-Host "           ThumbMouseButton (Mouse 4), ThumbMouseButton2 (Mouse 5)" -ForegroundColor DarkGray
Write-Host ""

# --- read existing values (defaults if missing) ---
$cur = @{ Modality = "button"; ButtonKey = "Left Alt"; DoubleTapLeft = "Z"; DoubleTapRight = "C"; DoubleTapBack = "S"; SideHorizontal = "650"; SideVertical = "500"; BackHorizontal = "900"; BackVertical = "200"; StaminaCost = "20"; DoubleTapWindow = "0.16" }
if (Test-Path $ini) {
    foreach ($line in Get-Content $ini) {
        if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$' -and $line -notmatch '^\s*;') {
            $cur[$matches[1]] = ($matches[2] -replace '\s*;.*$', '').Trim()
        }
    }
}
if ($cur["Modality"] -ne "doubletap") { $cur["Modality"] = "button" }

# --- modality ---
$resetRequested = $false
while ($true) {
    Write-Host "Choose your dodge modality " -ForegroundColor Cyan -NoNewline
    Write-Host "[current: $($cur['Modality'])]" -ForegroundColor Yellow
    Write-Host "  1) Dodge button - hold a movement key, press a dodge button"
    Write-Host "  2) Double-tap   - double-tap dodge keys (Z / C / S)"
    Write-Host "  3) Reset to defaults - button mode, Left Alt, Z/C/S double-tap keys, default forces"
    Clear-ConsoleInput
    $mode = Read-Host "1, 2 or 3 [Enter = keep $($cur['Modality'])]"
    if ([string]::IsNullOrWhiteSpace($mode)) { break }
    if ($mode.Trim() -eq "1") { $cur["Modality"] = "button"; break }
    if ($mode.Trim() -eq "2") { $cur["Modality"] = "doubletap"; break }
    if ($mode.Trim() -eq "3") {
        $cur["Modality"] = "button"
        $cur["ButtonKey"] = "Left Alt"
        $cur["DoubleTapLeft"] = "Z"
        $cur["DoubleTapRight"] = "C"
        $cur["DoubleTapBack"] = "S"
        $cur["DoubleTapWindow"] = "0.16"
        $cur["SideHorizontal"] = "650"
        $cur["SideVertical"] = "500"
        $cur["BackHorizontal"] = "900"
        $cur["BackVertical"] = "200"
        $cur["StaminaCost"] = "20"
        $resetRequested = $true
        break
    }
    Write-Host "  please type 1, 2 or 3 (or press Enter to keep the current mode)." -ForegroundColor Red
}

if (-not $resetRequested) {
    # --- keys (captured, not typed) ---
    if ($cur["Modality"] -eq "button") {
        $cur["ButtonKey"] = Capture-KeyOrMouse $cur["ButtonKey"] "DODGE BUTTON - hold a movement key + press this to dodge:"
        Clear-ConsoleInput
    } else {
        $cur["DoubleTapLeft"]  = Capture-KeyOrMouse $cur["DoubleTapLeft"]  "DOUBLE-TAP LEFT key:"
        Clear-ConsoleInput
        $cur["DoubleTapRight"] = Capture-KeyOrMouse $cur["DoubleTapRight"] "DOUBLE-TAP RIGHT key:"
        Clear-ConsoleInput
        $cur["DoubleTapBack"]  = Capture-KeyOrMouse $cur["DoubleTapBack"]  "DOUBLE-TAP BACK key:"
        Clear-ConsoleInput
    }

    # --- forces + stamina (validated) ---
    Write-Host ""
    Write-Host "Directional/vertical forces (cm/s) and stamina - type a number, or Enter to keep:" -ForegroundColor Cyan
    $cur["SideHorizontal"] = Format-Number (Read-ValidNumber "Side dodge directional force" $cur["SideHorizontal"] 1 10000)
    $cur["SideVertical"]   = Format-Number (Read-ValidNumber "Side dodge vertical force"   $cur["SideVertical"]   0 10000)
    $cur["BackHorizontal"] = Format-Number (Read-ValidNumber "Back dodge directional force" $cur["BackHorizontal"] 1 10000)
    $cur["BackVertical"]   = Format-Number (Read-ValidNumber "Back dodge vertical force"   $cur["BackVertical"]   0 10000)
    $cur["StaminaCost"]    = Format-Number (Read-ValidNumber "Stamina cost"                $cur["StaminaCost"]    0 1000)
} else {
    Write-Host ""
    Write-Host "Reset to defaults: button mode, Left Alt dodge button, Z/C/S double-tap keys, default forces." -ForegroundColor Green
}

$window = ConvertTo-Number $cur["DoubleTapWindow"]
if ($window -eq $null -or $window -le 0 -or $window -gt 5) { $cur["DoubleTapWindow"] = "0.16" }

# --- write ---
$content = @(
    "; Configurable Dodge Mod - configuration (generated by Setup.ps1)",
    "; Edit by hand anytime - changes apply within ~2 seconds in game.",
    "",
    "[Config]",
    "; `"button`" = hold a movement key, press the dodge button",
    "; `"doubletap`" = double-tap the dodge keys",
    "Modality=$($cur['Modality'])",
    "",
    "; --- Button modality ---",
    "; Any key name, VK hex (0xA4) or mouse button - modifiers work too",
    "ButtonKey=$(Format-KeyEntry $cur['ButtonKey'])",
    "",
    "; --- Double-tap modality ---",
    "DoubleTapLeft=$(Format-KeyEntry $cur['DoubleTapLeft'])",
    "DoubleTapRight=$(Format-KeyEntry $cur['DoubleTapRight'])",
    "DoubleTapBack=$(Format-KeyEntry $cur['DoubleTapBack'])",
    "DoubleTapWindow=$($cur['DoubleTapWindow'])",
    "",
    "; --- Directional and vertical forces (cm/s) and stamina cost (vanilla jump = 20) ---",
    "SideHorizontal=$($cur['SideHorizontal'])",
    "SideVertical=$($cur['SideVertical'])",
    "BackHorizontal=$($cur['BackHorizontal'])",
    "BackVertical=$($cur['BackVertical'])",
    "StaminaCost=$($cur['StaminaCost'])",
    ""
)
[System.IO.File]::WriteAllLines($ini, $content)
Write-Host ""
Write-Host "Saved: $ini" -ForegroundColor Green
Write-Host "In game the change applies within ~2 seconds (live reload) - no restart."
