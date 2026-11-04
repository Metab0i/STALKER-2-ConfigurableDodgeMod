# Configurable Dodge Mod - input listener (v5)
# Owns ALL key-binding logic: watches the keys configured in
# ConfigurableDodgeMod.ini at the OS level (GetAsyncKeyState - sees every
# key, including modifiers that UE4SS cannot), performs the double-tap
# detection, and streams the resulting press counters to the mod through a
# named pipe (pure memory - nothing touches the disk).
# Started automatically by the mod at game boot. Exits when the game closes.

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SigListen {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern bool CreateMutex(IntPtr attr, bool initial, string name);
}
"@

$created = $false
try { $mutex = [System.Threading.Mutex]::new($true, "DodgeModSignalListener", [ref]$created) } catch { $created = $true }
if (-not $created) { exit }

# ================= configuration =================
$root = Split-Path -Parent $PSScriptRoot
$ini = Join-Path $root "ConfigurableDodgeMod.ini"
$cur = @{
    Modality = "button"; ButtonKey = "Left Alt"
    DoubleTapLeft = "Z"; DoubleTapRight = "C"; DoubleTapBack = "S"
    DoubleTapWindow = "0.25"
}
function Read-Ini {
    if (-not (Test-Path $ini)) { return }
    foreach ($line in Get-Content $ini -ErrorAction SilentlyContinue) {
        if ($line -match '^\s*([A-Za-z_]+)\s*=\s*(.*?)\s*$' -and $line -notmatch '^\s*;') {
            $cur[$matches[1]] = $matches[2]
        }
    }
}
Read-Ini

# ================= name -> Virtual-Key =================
$VK = @{
    Space = 0x20; Enter = 0x0D; Escape = 0x1B; Tab = 0x09; CapsLock = 0x14; Back = 0x08
    Up = 0x26; Down = 0x28; Left = 0x25; Right = 0x27
    OemMinus = 0xBD; Oemplus = 0xBB; Oemcomma = 0xBC; OemPeriod = 0xBE; Oemtilde = 0xC0
    Oem1 = 0xBA; Oem2 = 0xBF; Oem4 = 0xDB; Oem5 = 0xDC; Oem6 = 0xDD; Oem7 = 0xDE; Oem102 = 0xE2
    LeftMouseButton = 0x01; RightMouseButton = 0x02; MiddleMouseButton = 0x04
    ThumbMouseButton = 0x05; ThumbMouseButton2 = 0x06
    LShiftKey = 0xA0; RShiftKey = 0xA1; LControlKey = 0xA2; RControlKey = 0xA3
    LMenu = 0xA4; RMenu = 0xA5; LAlt = 0xA4; RAlt = 0xA5
    'Left Alt' = 0xA4; 'Right Alt' = 0xA5
}
65..90 | ForEach-Object { $VK[[char]$_] = $_ }   # A-Z
48..57 | ForEach-Object { $VK[[char]$_] = $_ }   # 0-9
1..12   | ForEach-Object { $VK["F$_"] = 0x6F + $_ }

function Resolve-VK([string]$name) {
    $n = $name.Trim()
    if ($VK.ContainsKey($n)) { return [int]$VK[$n] }
    if ($n -match '^0[xX]([0-9A-Fa-f]{1,2})$') { return [Convert]::ToInt32($matches[1], 16) }
    if ($n.Length -eq 1) { $b = [Text.Encoding]::ASCII.GetBytes($n)[0]; if ($b -ge 1) { return [int]$b } }
    return $null
}

# ================= state =================
$counters = @{ btn = 0; dtl = 0; dtr = 0; dtb = 0 }
$held = @{}
$lastTap = @{}
$gamePid = 0

function Update-Keys {
    # resolve current VKs from config
    $btnVK = $null
    $dtVKs = @{}
    if ($cur["Modality"] -eq "button") {
        $btnVK = Resolve-VK $cur["ButtonKey"]
    } else {
        foreach ($d in @(@("dtl", "DoubleTapLeft"), @("dtr", "DoubleTapRight"), @("dtb", "DoubleTapBack"))) {
            $dtVKs[$d[0]] = Resolve-VK $cur[$d[1]]
        }
    }

    # only count while the game window is in the foreground
    $fg = [SigListen]::GetForegroundWindow()
    $fgPid = 0
    [SigListen]::GetWindowThreadProcessId($fg, [ref]$fgPid) | Out-Null
    if ($gamePid -ne 0 -and $fgPid -ne $gamePid) {
        foreach ($k in @($held.Keys)) { $held[$k] = $false }
        return
    }

    $t = [Diagnostics.Stopwatch]::StartNew()
    if ($cur["Modality"] -eq "button") {
        if ($btnVK -ne $null) {
            $down = (([SigListen]::GetAsyncKeyState($btnVK) -band 0x8000) -ne 0)
            $key = "btn$btnVK"
            if ($down -and -not $held[$key]) { $counters["btn"]++ }
            $held[$key] = $down
        }
    } else {
        $windowSec = 0.25
        $parsed = 0.0
        if ([double]::TryParse($cur["DoubleTapWindow"], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$parsed)) { $windowSec = $parsed }
        foreach ($d in @(@("dtl", "left", "DoubleTapLeft"), @("dtr", "right", "DoubleTapRight"), @("dtb", "back", "DoubleTapBack"))) {
            $vk = $dtVKs[$d[0]]
            if ($vk -eq $null) { continue }
            $key = "dt$vk"
            $down = (([SigListen]::GetAsyncKeyState($vk) -band 0x8000) -ne 0)
            if ($down -and -not $held[$key]) {
                $nowMs = [Diagnostics.Stopwatch]::StartNew()
                $last = 0.0
                if ($lastTap[$d[0]] -ne $null) { $last = $lastTap[$d[0]] }
                $elapsed = ($nowMs.Elapsed.TotalSeconds) - $last
                if ($elapsed -le $windowSec) {
                    $counters[$d[0]]++
                    $lastTap[$d[0]] = 0.0
                } else {
                    $lastTap[$d[0]] = $nowMs.Elapsed.TotalSeconds
                }
            }
            $held[$key] = $down
        }
    }
}

# find the game process id once it exists
function Find-GamePid {
    $p = Get-Process Stalker2-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { $p = Get-Process Stalker2 -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($p) { return [int]$p.Id }
    return 0
}

$gamePid = Find-GamePid
Write-Host "Dodge input listener running (modality: $($cur['Modality']))."
Write-Host "Auto-exits when the game closes."

# ================= pipe server =================
while ($true) {
    if ($gamePid -eq 0) { $gamePid = Find-GamePid }
    $server = New-Object System.IO.Pipes.NamedPipeServerStream("DodgeModSignal", [System.IO.Pipes.PipeDirection]::Out)
    try {
        $server.WaitForConnection()
        $writer = New-Object System.IO.StreamWriter($server)
        $writer.AutoFlush = $true
        while ($true) {
            Read-Ini
            Update-Keys
            $state = "btn=$($counters['btn']) dtl=$($counters['dtl']) dtr=$($counters['dtr']) dtb=$($counters['dtb'])"
            $writer.WriteLine($state)
            if (-not $server.IsConnected) { break }
            Start-Sleep -Milliseconds 50
        }
    } catch {}
    finally {
        if ($writer) { $writer.Dispose() }
        $server.Dispose()
    }
    if ($gamePid -ne 0 -and -not (Get-Process -Id $gamePid -ErrorAction SilentlyContinue)) { $gamePid = Find-GamePid }
    if ($gamePid -eq 0 -and -not (Get-Process Stalker2* -ErrorAction SilentlyContinue)) { break }
    Start-Sleep -Milliseconds 30
}
