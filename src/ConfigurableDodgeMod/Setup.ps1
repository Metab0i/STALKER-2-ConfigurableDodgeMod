# Configurable Dodge Mod - interactive setup
# Writes ConfigurableDodgeMod.ini next to this script's folder.
# Everything can also be edited by hand in that file - it applies live.

$ErrorActionPreference = "Stop"
$root = $PSScriptRoot  # this script lives in the mod folder, next to the ini
$ini = Join-Path $root "ConfigurableDodgeMod.ini"
Add-Type -AssemblyName System.Windows.Forms

# ================= input capture (keyboard + mouse) =================
Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class CapInput {
    [DllImport("user32.dll")] public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc cb, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")] public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelKeyboardProc cb, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] public static extern IntPtr GetModuleHandle(string name);
    public delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);
    public delegate IntPtr LowLevelKeyboardProc(int nCode, IntPtr wParam, IntPtr lParam);
    public struct MSLL { public uint vk; public uint mouseData; public uint flags; public uint time; public IntPtr extra; }
    public struct KBDLL { public uint vkCode; public uint scanCode; public uint flags; public uint time; public IntPtr extra; }
    public static string Captured = null;
    public static int CapturedVK = -1;
    public static IntPtr HookMouse(int id, LowLevelMouseProc cb) { return SetWindowsHookEx(id, cb, GetModuleHandle(null), 0); }
    public static IntPtr HookKeyboard(int id, LowLevelKeyboardProc cb) { return SetWindowsHookEx(id, cb, GetModuleHandle(null), 0); }
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
    public static IntPtr KeyboardProc(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0 && CapturedVK < 0) {
            int msg = (int)wParam;
            if (msg == 0x0100 || msg == 0x0104) {   // WM_KEYDOWN, WM_SYSKEYDOWN
                KBDLL k = (KBDLL)Marshal.PtrToStructure(lParam, typeof(KBDLL));
                CapturedVK = (int)k.vkCode;
            }
        }
        return CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);
    }
}
"@

function Get-VKName([int]$vk) {
    if ($vk -ge 0x41 -and $vk -le 0x5A) { return [string][char]$vk }
    if ($vk -ge 0x30 -and $vk -le 0x39) { return [string][char]$vk }
    if ($vk -ge 0x70 -and $vk -le 0x7B) { return "F" + ($vk - 0x6F) }
    switch ($vk) {
        0x20 { 'Space' } 0x0D { 'Enter' } 0x1B { 'Escape' } 0x09 { 'Tab' } 0x14 { 'CapsLock' } 0x08 { 'Backspace' }
        0x26 { 'Up' } 0x28 { 'Down' } 0x25 { 'Left' } 0x27 { 'Right' }
        0xA0 { 'Left Shift' } 0xA1 { 'Right Shift' } 0xA2 { 'Left Ctrl' } 0xA3 { 'Right Ctrl' }
        0xA4 { 'Left Alt' } 0xA5 { 'Right Alt' } 0x5B { 'Left Win' } 0x5C { 'Right Win' }
        default { 'VK 0x{0:X2}' -f $vk }
    }
}

$MouseHex = @{
    LeftMouseButton = '0x01'; RightMouseButton = '0x02'; MiddleMouseButton = '0x04'
    ThumbMouseButton = '0x05'; ThumbMouseButton2 = '0x06'
}

function Capture-KeyOrMouse([string]$default, [string]$label) {
    while ($true) {
        Write-Host ""
        Write-Host "  $label" -ForegroundColor Cyan
        Write-Host "  Press any key (Alt/Ctrl/Shift included) or mouse button now."
        Write-Host "  Enter = keep '$default', Esc = cancel."
        [CapInput]::Captured = $null
        [CapInput]::CapturedVK = -1
        $hkMouse = [CapInput]::HookMouse(14, [CapInput+LowLevelMouseProc]::MouseProc)    # WH_MOUSE_LL
        $hkKey = [CapInput]::HookKeyboard(13, [CapInput+LowLevelKeyboardProc]::KeyboardProc) # WH_KEYBOARD_LL
        try {
            while ($true) {
                if ([CapInput]::Captured -ne $null) {
                    $name = [CapInput]::Captured
                    Write-Host "  captured: $name" -ForegroundColor Green
                    return $MouseHex[$name]
                }
                if ([CapInput]::CapturedVK -ge 0) {
                    $vk = [CapInput]::CapturedVK
                    if ($vk -eq 0x0D -or $vk -eq 0x1B) { Write-Host "  kept $default"; return $default }
                    Write-Host ("  captured: {0} (0x{1:X2})" -f (Get-VKName $vk), $vk) -ForegroundColor Green
                    return ('0x{0:X2}' -f $vk)
                }
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 10
            }
        }
        finally {
            [CapInput]::UnhookWindowsHookEx($hkMouse) | Out-Null
            [CapInput]::UnhookWindowsHookEx($hkKey) | Out-Null
        }
    }
}

# ================= banner =================
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host " Configurable Dodge Mod - Setup" -ForegroundColor Yellow
Write-Host "=============================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "Any key works: A-Z, 0-9, F1-F12, Space, CapsLock, Tab, arrows," -ForegroundColor DarkGray
Write-Host "punctuation, and modifiers (Left Alt, Ctrl, Shift) - plus mouse buttons:" -ForegroundColor DarkGray
Write-Host "  LeftMouseButton / RightMouseButton / MiddleMouseButton /" -ForegroundColor DarkGray
Write-Host "  ThumbMouseButton (Mouse 4) / ThumbMouseButton2 (Mouse 5)" -ForegroundColor DarkGray
Write-Host ""
Write-Host "Keys are captured live; no typing needed. Modifier keys and mouse" -ForegroundColor Yellow
Write-Host "buttons are handled by a small listener the mod starts automatically." -ForegroundColor Yellow
Write-Host ""

# --- read existing values (defaults if missing) ---
$cur = @{ Modality = "button"; ButtonKey = "Left Alt"; DoubleTapLeft = "Z"; DoubleTapRight = "C"; DoubleTapBack = "S"; SideHorizontal = "650"; SideVertical = "500"; BackHorizontal = "900"; BackVertical = "200"; StaminaCost = "20"; DoubleTapWindow = "0.25" }
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
    "; Any key name, VK hex (0xA4) or mouse button - modifiers work too",
    "ButtonKey=$($cur['ButtonKey'])",
    "",
    "; --- Double-tap modality ---",
    "DoubleTapLeft=$($cur['DoubleTapLeft'])",
    "DoubleTapRight=$($cur['DoubleTapRight'])",
    "DoubleTapBack=$($cur['DoubleTapBack'])",
    "DoubleTapWindow=$($cur['DoubleTapWindow'])",
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
Write-Host "In game the change applies within ~2 seconds (live reload) - no restart."
