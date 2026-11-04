# Configurable Dodge Mod for S.T.A.L.K.E.R. 2

![Configurable Dodge Mod thumbnail](media/main.png)

Hold a movement key and press your dodge button (default **Left Alt**), or
double-tap your dodge keys, and Skif dodges left / right / back relative to the
camera. Each dodge costs stamina. Every key and force value is configurable.

## Demo

[![Dodging demo video](https://img.youtube.com/vi/aLGJFVEcolc/0.jpg)](https://www.youtube.com/watch?v=aLGJFVEcolc)

## How button capture works

UE4SS keybindings never see Windows system keys (Alt/Ctrl/Shift) and are
unreliable after loading a world, so the mod uses its own input path:

1. At game start the mod launches `DodgeSignal.ps1`, a small PowerShell
   listener (mutex-guarded, exits with the game).
2. The listener reads the configured keys at the OS level
   (`GetAsyncKeyState`) and times the double-taps.
3. It streams press counters to the mod through a named pipe - kernel memory,
   nothing is written to disk.
4. The Lua side reads the pipe and performs the dodge. If the listener stops,
   the mod restarts it automatically.

Because capture happens at the OS level, keyboard keys, modifiers
(Left Alt / Ctrl / Shift) and mouse buttons all behave identically.

## Install

1. Copy the `ConfigurableDodgeMod` folder into
   `Stalker2\Binaries\Win64\ue4ss\Mods\`
2. Add `ConfigurableDodgeMod : 1` to `ue4ss\Mods\mods.txt`
3. Launch the game. Default: hold **A/D/S** + press **Left Alt**.

The `_full` package includes the UE4SS runtime and the update 2.x
compatibility fix.

## Use

- Hold a movement key and press the dodge button. A/D/S dodge left / right /
  back; forward-only movement does nothing.
- In double-tap mode, double-tap the configured keys (Z / C / S by default).
- 20 stamina per dodge (vanilla jump). Low stamina and open menus/dialogs block
  dodges.

## Configure

Run **`Setup.bat`** in the mod folder:

- choose button or double-tap mode
- press a key to bind it - any key works, including Left Alt/Ctrl/Shift and
  mouse buttons; it is stored as name plus hex (e.g. `0x58   ; X`)
- set forces and stamina cost, or press **3** to reset everything to defaults

<p>
<img src="media/setup-1-modality.png" width="32%">
<img src="media/setup-2-key-capture.png" width="32%">
<img src="media/setup-3-forces.png" width="32%">
</p>

Or edit **`ConfigurableDodgeMod.ini`** directly:

| Key | Meaning | Default |
| --- | --- | --- |
| `Modality` | `button` or `doubletap` | `button` |
| `ButtonKey` | dodge button (name, VK hex or mouse button) | `Left Alt` |
| `DoubleTapLeft/Right/Back` | double-tap keys | `Z` / `C` / `S` |
| `DoubleTapWindow` | max seconds between taps | `0.25` |
| `SideHorizontal/SideVertical` | side dodge force (cm/s) | `650` / `500` |
| `BackHorizontal/BackVertical` | back dodge force (cm/s) | `900` / `200` |
| `StaminaCost` | stamina per dodge | `20` |

Changes apply live within ~2 seconds - no restart.

## Requirements

| Dependency | Version |
| --- | --- |
| S.T.A.L.K.E.R. 2: Heart of Chornobyl | update 2.0+ |
| UE4SS | experimental `v3.0.1-1028-gd7e7826d` |
| RE-UE4SS Compatibility Fix (Nexus 2341) | v1.2 - included in the `_full` package |

## Credits

- Dodge concept: **rbwadle** (Nexus 1243) - the original pak mod cannot load on
  update 2.0
- **UE4SS** (RE-UE4SS, MIT) and the community compatibility fix (Nexus 2341)
