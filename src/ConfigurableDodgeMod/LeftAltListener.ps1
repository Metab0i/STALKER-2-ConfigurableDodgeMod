# Configurable Dodge Mod - Left Alt listener
# Watches the Left Alt key at the OS level (GetAsyncKeyState - sees modifier
# keys, unlike UE4SS) and writes each press to alt_press.txt for the mod.
# Start once (Listener.bat); runs hidden until the game closes or you kill it.

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class AltPoll {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
}
"@

$flag = Join-Path $PSScriptRoot "alt_press.txt"
$counter = 0
if (Test-Path $flag) {
    $parsed = 0
    if ([int]::TryParse((Get-Content $flag -First 1), [ref]$parsed)) { $counter = $parsed }
}

Write-Host "Left Alt listener running - presses are forwarded to the dodge mod."
Write-Host "This window can be minimized. Close it to stop the listener."

$wasDown = $false
while ($true) {
    $state = [AltPoll]::GetAsyncKeyState(0xA4) -bor [AltPoll]::GetAsyncKeyState(0xA5) -bor [AltPoll]::GetAsyncKeyState(0x12)  # Left/Right Alt
    $down = (($state -band 0x8000) -ne 0)
    if ($down -and -not $wasDown) {
        $counter++
        [System.IO.File]::WriteAllText($flag, "$counter")
    }
    $wasDown = $down

    # stop automatically when the game closes
    if (-not (Get-Process Stalker2-Win64-Shipping -ErrorAction SilentlyContinue)) {
        if (Get-Process Stalker2 -ErrorAction SilentlyContinue) { continue }
        break
    }
    Start-Sleep -Milliseconds 30
}
