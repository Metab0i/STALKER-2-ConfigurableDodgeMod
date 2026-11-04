# Configurable Dodge Mod - interactive setup
# Writes ConfigurableDodgeMod.ini next to this mod's folder.
# Everything can also be edited by hand in that file - it applies live.

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$ini = Join-Path $root "ConfigurableDodgeMod.ini"
Add-Type -AssemblyName System.Windows.Forms

# ================= input capture (keyboard + mouse) =================
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CapInput {
    [DllImport("user32.dll")] public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc cb, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandle(string name);
    public delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);
    public struct MSLL { public uint vk; public uint mouseData; public uint flags; public uint time; public IntPtr extra; }
    public static string Captured = null;
    public static IntPtr Hook(int id, LowLevelMouseProc cb) { return SetWindowsHookEx(id, cb, GetModuleHandle(null), 0); }
    public static IntPtr MouseProc(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0 && Captured == null) {
            MSLL info = (MSLL)Marshal.PtrToStructure(lParam, typeof(MSLL));
            if (wParam == (IntPtr)0x0201) Captured = "LeftMouseButton";       // WM_LBUTTONDOWN
            else if (wParam == (IntPtr)0x0204) Captured = "RightMouseButton"; // WM_RBUTTONDOWN
            else if (wParam == (IntPtr)0x0207) Captured = "MiddleMouseButton";// WM_MBUTTONDOWN
            else if (wParam == (IntPtr)0x020B) {                              // WM_XBUTTONDOWN
                if ((info.mouseData >> 16) == 1) Captured = "ThumbMouseButton";
                else Captured = "ThumbMouseButton2";
            }
        }
        return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }
}
"@

$VK_ENTER = 13
$VK_ESCAPE = 27

function Test-ModifierName([string]$name) {
    $u = $name.ToUpper() -replace '[^A-Z0-9]', ''
    return ($u -match 'ALT$' -or $u -match 'CTRL$' -or $u -match 'SHIFT$' -or $u -match 'MENU$' -or $u -eq 'ALT' -or $u -eq 'CTRL' -or $u -eq 'SHIFT')
}

# ConsoleKey / mouse -> Virtual-Key code (hex string), for the ini
$VK_HEX = @{
    Space = '0x20'; Enter = '0x0D'; Escape = '0x1B'; Tab = '0x09'; CapsLock = '0x14'; Back = '0x08'
    Up = '0x26'; Down = '0x28'; Left = '0x25'; Right = '0x27'
    OemMinus = '0xBD'; Oemplus = '0xBB'; Oemcomma = '0xBC'; OemPeriod = '0xBE'; Oemtilde = '0xC0'
    Oem1 = '0xBA'; Oem2 = '0xBF'; Oem4 = '0xDB'; Oem5 = '0xDC'; Oem6 = '0xDD'; Oem7 = '0xDE'; Oem102 = '0xE2'
    LShiftKey = '0xA0'; RShiftKey = '0xA1'; LControlKey = '0xA2'; RControlKey = '0xA3'
    LMenu = '0xA4'; RMenu = '0xA5'
}
1..12 | ForEach-Object { $VK_HEX["F$_"] = '0x{0:X2}' -f (0x6F + $_) }
function Convert-ToVKHex([string]$name) {
    $n = $name.Trim()
    if ($VK_HEX.ContainsKey($n)) { return $VK_HEX[$n] }
    if ($n.Length -eq 1 -and $n -cmatch '[A-Z]') { return '0x{0:X2}' -f [int][char]$n }
    if ($n.Length -eq 2 -and $n -match '^D[0-9]$') { return '0x{0:X2}' -f (0x30 + [int]$n.Substring(1)) }
    if ($n -match '^NumPad([0-9])$') { return '0x{0:X2}' -f (0x60 + [int]$matches[1]) }
    return $null
}
function Capture-KeyOrMouse([string]$default, [string]$label) {
    :outer while ($true) {
        Write-Host ""
        Write-Host "  $label" -ForegroundColor Cyan
        Write-Host "  Press any keyboard key or mouse button now (Enter = keep '$default', Esc = cancel)..."
        [System.Windows.Forms.Application]::DoEvents()
        $script:CapInput_Captured = $null
        $hhk = [CapInput]::Hook(14, [CapInput+LowLevelMouseProc]::MouseProc)  # WH_MOUSE_LL
        try {
            while ($true) {
                if ([CapInput]::Captured -ne $null) {
                    $name = [CapInput]::Captured
                    Write-Host "  captured: $name" -ForegroundColor Green
                    $mouseHex = @{ LeftMouseButton = "0x01"; RightMouseButton = "0x02"; MiddleMouseButton = "0x04" }
                    if ($mouseHex.ContainsKey($name)) { return $mouseHex[$name] }
                    if (Test-ModifierName $name) {
                        Write-Host "  WARNING: modifier/UI-mouse keys cannot be dodge buttons. Pick another." -ForegroundColor Red
                        continue outer
                    }
                    return (Convert-ToVKHex $name)
                }
                if ([Console]::KeyAvailable) {
                    $k = [Console]::ReadKey($true)
                    if ($k.Key -eq 'Enter') { Write-Host "  kept $default"; return $default }
                    if ($k.Key -eq 'Escape') { Write-Host "  kept $default"; return $default }
                    $name = $k.Key.ToString()
                    if ($name -eq 'Spacebar') { $name = 'Space' }
                    elseif ($name -eq 'OemMinus') { $name = 'Minus' }
                    elseif ($name -eq 'Oemplus') { $name = 'Plus' }
                    elseif ($name -eq 'Oemcomma') { $name = 'Comma' }
                    elseif ($name -eq 'OemPeriod') { $name = 'Period' }
                    elseif ($name -eq 'Oemtilde') { $name = 'Tilde' }
                    Write-Host "  captured: $name" -ForegroundColor Green
                    if ((Test-ModifierName $name) -or (($k.Modifiers -band [ConsoleModifiers]::Alt) -ne 0) -or (($k.Modifiers -band [ConsoleModifiers]::Control) -ne 0) -or (($k.Modifiers -band [ConsoleModifiers]::Shift) -ne 0)) {
                        Write-Host "  WARNING: modifier keys (Alt/Ctrl/Shift) are invisible to UE4SS input hooks and can never be dodge buttons. Pick another." -ForegroundColor Red
                        continue outer
                    }
                    return (Convert-ToVKHex $name)
                }
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 10
            }
        }
        finally {
            [CapInput]::UnhookWindowsHookEx($hhk) | Out-Null
        }
    }
}

# ================= banner =================
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host " Configurable Dodge Mod - Setup" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "Possible keys: A-Z, 0-9, F1-F12, Space, CapsLock, Tab, arrows," -ForegroundColor DarkGray
Write-Host "Minus, Plus, Comma, Period, Tilde - and mouse buttons:" -ForegroundColor DarkGray
Write-Host "  LeftMouseButton / RightMouseButton / MiddleMouseButton /" -ForegroundColor DarkGray
Write-Host "  ThumbMouseButton (Mouse 4) / ThumbMouseButton2 (Mouse 5)" -ForegroundColor DarkGray
Write-Host "Full reference: https://ue4ss.org/data-complex/coding-standard#a-name-usage" -ForegroundColor DarkGray
Write-Host "NOTE: modifier keys (Alt / Ctrl / Shift) can NEVER be dodge buttons -" -ForegroundColor Red
Write-Host "UE4SS does not see them in gameplay. You will be warned if you pick one." -ForegroundColor Red
Write-Host ""

# --- read existing values (defaults if missing) ---
$cur = @{ Modality = "button"; ButtonKey = "ThumbMouseButton2"; DoubleTapLeft = "Z"; DoubleTapRight = "C"; DoubleTapBack = "S"; SideHorizontal = "650"; SideVertical = "500"; BackHorizontal = "900"; BackVertical = "200"; StaminaCost = "20" }
if (Test-Path $ini) {
    foreach ($line in Get-Content $ini) {
        if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$' -and $line -notmatch '^\s*;') {
            $cur[$matches[1]] = $matches[2]
        }
    }
}

# --- modality ---
Write-Host "Choose your dodge modality (only one can be active):" -ForegroundColor Cyan
Write-Host "  1) Dodge button - hold a movement key, press a dodge button  [current: $($cur['Modality'])]"
Write-Host "  2) Double-tap   - double-tap dodge keys (Z / C / S)          [current: $($cur['Modality'])]"
$mode = Read-Host "1 or 2 [Enter = keep $($cur['Modality'])]"
if ($mode -eq "1") { $cur["Modality"] = "button" }
elseif ($mode -eq "2") { $cur["Modality"] = "doubletap" }

# --- keys (captured, not typed) ---
if ($cur["Modality"] -eq "button") {
    $cur["ButtonKey"] = Capture-KeyOrMouse $cur["ButtonKey"] "DODGE BUTTON - hold a movement key + press this to dodge:"
} else {
    $cur["DoubleTapLeft"]  = Capture-KeyOrMouse $cur["DoubleTapLeft"]  "DOUBLE-TAP LEFT key:"
    $cur["DoubleTapRight"] = Capture-KeyOrMouse $cur["DoubleTapRight"] "DOUBLE-TAP RIGHT key:"
    $cur["DoubleTapBack"]  = Capture-KeyOrMouse $cur["DoubleTapBack"]  "DOUBLE-TAP BACK key:"
}

# --- forces + stamina ---
Write-Host ""
Write-Host "Forces (cm/s) and stamina - type a number, or Enter to keep:" -ForegroundColor Cyan
$cur["SideHorizontal"] = Read-Host "  Side dodge horizontal [$($cur['SideHorizontal'])]"
if ([string]::IsNullOrWhiteSpace($cur["SideHorizontal"])) { $cur["SideHorizontal"] = "650" }
$cur["SideVertical"]   = Read-Host "  Side dodge vertical   [$($cur['SideVertical'])]"
if ([string]::IsNullOrWhiteSpace($cur["SideVertical"])) { $cur["SideVertical"] = "500" }
$cur["BackHorizontal"] = Read-Host "  Back dodge horizontal [$($cur['BackHorizontal'])]"
if ([string]::IsNullOrWhiteSpace($cur["BackHorizontal"])) { $cur["BackHorizontal"] = "900" }
$cur["BackVertical"]   = Read-Host "  Back dodge vertical   [$($cur['BackVertical'])]"
if ([string]::IsNullOrWhiteSpace($cur["BackVertical"])) { $cur["BackVertical"] = "200" }
$cur["StaminaCost"]    = Read-Host "  Stamina cost          [$($cur['StaminaCost'])]"
if ([string]::IsNullOrWhiteSpace($cur["StaminaCost"])) { $cur["StaminaCost"] = "20" }

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
    "; Key name reference: https://ue4ss.org/data-complex/coding-standard#a-name-usage",
    "ButtonKey=$($cur['ButtonKey'])",
    "",
    "; --- Double-tap modality ---",
    "DoubleTapLeft=$($cur['DoubleTapLeft'])",
    "DoubleTapRight=$($cur['DoubleTapRight'])",
    "DoubleTapBack=$($cur['DoubleTapBack'])",
    "",
    "; --- Forces (cm/s) and stamina cost (vanilla jump = 20) ---",
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
Write-Host "In game the change applies within ~2 seconds (hot reload)."
Write-Host "If the game is not running, it applies on next launch."
