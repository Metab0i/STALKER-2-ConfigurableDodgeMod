# Configurable Dodge Mod - input listener (v7)
# Owns ALL key-binding logic: watches the keys configured in
# ConfigurableDodgeMod.ini at the OS level (GetAsyncKeyState - sees every
# key, including modifiers that UE4SS cannot), performs the double-tap
# detection, and streams press counters to the mod through a named pipe
# (kernel memory - nothing touches the disk).
#
# Lifetime is tied to the game by a process handle: the listener opens the
# game process with SYNCHRONIZE rights and waits on it - when the game
# terminates, the wait signals and the listener exits.
#
# Pipe lifecycle (fixes the busy/deadlock issue): ONE persistent server
# instance; waits for the Lua client (250 ms timeout so the game-exit check
# always runs), writes the state line every 50 ms while connected, then
# disconnects and waits for the next client.
#
# Started automatically by the mod at game boot. Exits when the game closes.

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class SigListen {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("kernel32.dll")] public static extern bool CreateMutex(IntPtr attr, bool initial, string name);
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
}
"@

$created = $false
try { $mutex = [System.Threading.Mutex]::new($true, "DodgeModSignalListener", [ref]$created) } catch { $created = $true }
if (-not $created) { exit }

# ================= configuration =================
$root = $PSScriptRoot  # this script lives in the mod folder, next to the ini
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
            $cur[$matches[1]] = ($matches[2] -replace '\s*;.*$', '').Trim()
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
$iniReadAt = [Diagnostics.Stopwatch]::StartNew()
$pressClock = [Diagnostics.Stopwatch]::StartNew()   # one clock for double-tap timing
$gamePid = 0
$hGame = [IntPtr]::Zero

function Find-GamePid {
    $p = Get-Process Stalker2-Win64-Shipping -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $p) { $p = Get-Process Stalker2 -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($p) { return [int]$p.Id }
    return 0
}

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
                # a FRESH stopwatch per press made elapsed ~0, so every single
                # press counted as a double-tap; use one shared clock
                $nowSec = $pressClock.Elapsed.TotalSeconds
                $last = 0.0
                if ($lastTap[$d[0]] -ne $null) { $last = $lastTap[$d[0]] }
                if ($last -gt 0.0 -and ($nowSec - $last) -le $windowSec) {
                    $counters[$d[0]]++
                    $lastTap[$d[0]] = 0.0
                } else {
                    $lastTap[$d[0]] = $nowSec
                }
            }
            $held[$key] = $down
        }
    }
}

# ================= lifetime: tied to the game process =================
while ($hGame -eq [IntPtr]::Zero) {
    $gamePid = Find-GamePid
    if ($gamePid -ne 0) {
        $hGame = [SigListen]::OpenProcess(0x00100000, $false, $gamePid)  # PROCESS_SYNCHRONIZE
        if ($hGame -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 500; $gamePid = 0 }
    } else {
        Start-Sleep -Milliseconds 500
    }
}

# ================= pipe server =================
# One-shot protocol: the Lua client opens the pipe, we write exactly one
# state line and disconnect (EOF). The client reads it with read("*a")
# which needs EOF to return - a persistent connection would block the
# client thread forever and hold the single pipe instance "busy".
#
# NOTE: WaitForConnectionAsync may only have ONE pending wait at a time -
# the same task is reused across 250 ms slices so the game-exit check keeps
# running while we wait for the next client.
$server = $null
$waitTask = $null
$gameDead = $false

while (-not $gameDead) {
    # game terminated? (kernel wait, zero cost - signals immediately on exit)
    if ([SigListen]::WaitForSingleObject($hGame, 0) -eq 0) { $gameDead = $true; break }

    # live config: re-read the ini every ~2 s
    if ($iniReadAt.ElapsedMilliseconds -gt 2000) {
        $iniReadAt.Restart()
        Read-Ini
    }

    if ($server -eq $null) {
        try {
            $server = New-Object System.IO.Pipes.NamedPipeServerStream("DodgeModSignal", [System.IO.Pipes.PipeDirection]::Out)
            $waitTask = $null
        } catch {
            # stale instance still winding down - brief backoff
            Start-Sleep -Milliseconds 100
            continue
        }
    }

    if ($waitTask -eq $null) { $waitTask = $server.WaitForConnectionAsync() }
    # .Wait() re-throws if the connect task faulted (client connect/close race)
    # - without this guard that exception terminated the whole listener and
    # dodging went silent until the next game restart
    $connected = $false
    try { $connected = $waitTask.Wait(250) } catch {
        try { $server.Dispose() } catch {}
        $server = $null; $waitTask = $null
        Start-Sleep -Milliseconds 100
        continue
    }
    if (-not $connected) { continue }
    $waitTask = $null   # completed - a fresh wait is created next iteration

    try {
        Update-Keys
        $state = "btn=$($counters['btn']) dtl=$($counters['dtl']) dtr=$($counters['dtr']) dtb=$($counters['dtb'])`n"
        $bytes = [Text.Encoding]::ASCII.GetBytes($state)
        $server.Write($bytes, 0, $bytes.Length)
        $server.Flush()
    } catch {}

    try { $server.Disconnect() } catch {}
}

if ($server) { $server.Dispose() }
[SigListen]::CloseHandle($hGame) | Out-Null