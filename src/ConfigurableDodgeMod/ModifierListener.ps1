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
    [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort vk; public ushort scan; public uint flags; public uint time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public KEYBDINPUT ki; public ulong pad; }
    public static void Tap(ushort vk) {
        INPUT[] d = new INPUT[1]; d[0].type = 1; d[0].ki.vk = vk;
        SendInput(1, d, Marshal.SizeOf(typeof(INPUT)));
        System.Threading.Thread.Sleep(30);
        INPUT[] u = new INPUT[1]; u[0].type = 1; u[0].ki = new KEYBDINPUT { vk = vk, flags = 2 };
        SendInput(1, u, Marshal.SizeOf(typeof(INPUT)));
    }
}
"@

$created = $false
try { $mutex = [System.Threading.Mutex]::new($true, "DodgeModModifierListener", [ref]$created) } catch { $created = $true }
if (-not $created) { exit }

# modifier VK -> synthetic F-key VK (private channel, no keyboard has F13+)
$map = @{
    0xA0 = 0x80  # Left Shift  -> F17
    0xA1 = 0x81  # Right Shift -> F18
    0xA2 = 0x7E  # Left Ctrl   -> F15
    0xA3 = 0x7F  # Right Ctrl  -> F16
    0xA4 = 0x7C  # Left Alt    -> F13
    0xA5 = 0x7D  # Right Alt   -> F14
    0x10 = 0x7C  # generic Shift
    0x11 = 0x7E  # generic Ctrl
    0x12 = 0x7C  # generic Alt
}
$wasDown = @{}
$modVKs = @($map.Keys)

Write-Host "Modifier key listener running (Alt/Ctrl/Shift -> dodge inputs)."
Write-Host "Auto-exits when the game closes."

while ($true) {
    foreach ($mvk in $modVKs) {
        $down = (([ModListen]::GetAsyncKeyState($mvk) -band 0x8000) -ne 0)
        if ($down -and -not $wasDown[$mvk]) {
            [ModListen]::Tap([byte]$map[$mvk])
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
