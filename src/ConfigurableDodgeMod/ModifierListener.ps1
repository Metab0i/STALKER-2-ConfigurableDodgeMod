# Configurable Dodge Mod - modifier key listener (v3, generic)
# Watches ALL modifier keys at the OS level (GetAsyncKeyState - UE4SS's input
# hook cannot see them) and translates each press into a synthetic F13-F18
# keypress, which UE4SS delivers reliably. The mod binds those F-keys.
# Started automatically by the mod at game boot. Exits when the game closes.
# Refuses to run twice (mutex).

Add-Type @"
using System;
using System.Runtime.InteropServices;
public static class ModListen {
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] p, int size);
    [DllImport("kernel32.dll")] public static extern bool CreateMutex(IntPtr attr, bool initial, string name);
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public MOUSEINPUT mi; public ulong pad; }
    public static void TapMouse4() {
        INPUT[] d = new INPUT[1]; d[0].type = 0; d[0].mi.dwFlags = 0x0080; d[0].mi.mouseData = 1; // XDOWN, XBUTTON1
        SendInput(1, d, Marshal.SizeOf(typeof(INPUT)));
        System.Threading.Thread.Sleep(30);
        INPUT[] u = new INPUT[1]; u[0].type = 0; u[0].mi.dwFlags = 0x0100; u[0].mi.mouseData = 1; // XUP
        SendInput(1, u, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@

$created = $false
try { $mutex = [System.Threading.Mutex]::new($true, "DodgeModModifierListener", [ref]$created) } catch { $created = $true }
if (-not $created) { exit }

# every modifier press (L/R Alt, Ctrl, Shift) becomes a Mouse 4 tap -
# the single dodge-input channel verified to deliver in gameplay
$wasDown = @{}
$modVKs = @(0xA0, 0xA1, 0xA2, 0xA3, 0xA4, 0xA5, 0x10, 0x11, 0x12)

Write-Host "Modifier key listener running (Alt/Ctrl/Shift -> dodge inputs)."
Write-Host "Auto-exits when the game closes."

while ($true) {
    foreach ($mvk in $modVKs) {
        $down = (([ModListen]::GetAsyncKeyState($mvk) -band 0x8000) -ne 0)
        if ($down -and -not $wasDown[$mvk]) {
            [ModListen]::TapMouse4()
        }
        $wasDown[$mvk] = $down
    }

    # auto-exit when the game closes
    $alive = $false
    foreach ($n in @('Stalker2-Win64-Shipping', 'Stalker2')) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { $alive = $true; break }
    }
    if (-not $alive) { break }
    Start-Sleep -Milliseconds 25
}
