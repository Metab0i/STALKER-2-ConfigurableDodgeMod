# Configurable Dodge Mod for S.T.A.L.K.E.R. 2

![Configurable Dodge Mod thumbnail](media/main.png)

Double-tap **Z** (left), **C** (right) or **S** (back) and Skif hops out of the
way. Values (dodge strengths, stamina cost, keys) are configurable in the
Mod Configuration Menu.




## Demo

[![Dodging demo video](https://img.youtube.com/vi/KpYUs2ZFAlU/0.jpg)](https://www.youtube.com/watch?v=KpYUs2ZFAlU)

## Requirements

| Dependency | Version / ID |
| --- | --- |
| S.T.A.L.K.E.R. 2: Heart of Chornobyl | update 2.0+ (Steam) |
| UE4SS | experimental build `v3.0.1-1028-gd7e7826d` (GitHub `UE4SS-RE/RE-UE4SS`, `experimental` tag) |
| RE-UE4SS Compatibility Fix for Update 2.0 (UE5.5) | Nexus Mods ID 2341, v1.2 (ship game-specific `GUObjectArray`/`FName::ToString` signatures + patched `UE4SS.dll`; the `_full` package already includes it) |
| Mod Configuration Menu | Nexus Mods ID 2225, v2.0 (optional — mod works without it at default values) |

## Install

1. Copy the `ConfigurableDodgeMod` folder to `Stalker2\Binaries\Win64\ue4ss\Mods\`
2. Add `ConfigurableDodgeMod : 1` to `ue4ss\Mods\mods.txt` (no spaces in the mod id)
3. Launch. Default: hold a movement key and press **Mouse 5** to dodge.

No MCM needed — the mod is configured entirely through a plain ini file.

## Configure

Run **`Setup.bat`** (in the mod folder) for an interactive setup — it asks for
your dodge modality (button or double-tap, one at a time), captures keys, and
writes the config. Or edit **`ConfigurableDodgeMod.ini`** directly:

- `Modality` = `button` (hold movement key + press the dodge button) or
  `doubletap` (double-tap the dodge keys) — only one is active
- `ButtonKey` — the dodge button (default `Left Alt`; any keyboard key,
  modifier (Alt/Ctrl/Shift) or mouse button works)
- `DoubleTapLeft/Right/Back` — the double-tap keys (default `Z` / `C` / `S`)
- Dodge forces and stamina cost

**Key name reference:** https://ue4ss.org/data-complex/coding-standard#a-name-usage

Changes to the ini apply **live within ~2 seconds** — no restart.

## Notes

- Each dodge costs 20 SP (vanilla jump); dodging is blocked at low stamina
- Dodging is disabled while the game is in a menu/dialog (stash, conversations)
- Modifier keys (Alt/Ctrl/Shift) are supported: UE4SS's input hook cannot see
  them (Windows delivers them as system-key messages), so the mod starts a
  small PowerShell listener automatically at boot. It watches the configured
  keys at the OS level and streams presses to the mod through a named pipe
  (kernel memory - no files are written). It is mutex-guarded, starts once,
  and exits automatically when the game closes. If the message "Dodge keys are
  inactive" appears, restart the game once; you can also start it manually by
  running `DodgeSignal.ps1` in the mod folder.
- Keyboard and mouse buttons both work; the listener handles every key
  uniformly, so delivery is independent of UE4SS's input hook

## Credits

- Dodge concept: **rbwadle** (Nexus 1243) — the original pak mod predates
  update 2.0's engine and cannot load on it; this is a script-side rebuild
- **UE4SS** (RE-UE4SS, MIT) and the community compatibility fix (Nexus 2341)



