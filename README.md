# Configurable Dodge Mod

![Configurable Dodge Mod thumbnail](media/main.png)

Stamina-based dodge for **S.T.A.L.K.E.R. 2: Heart of Chornobyl 2.1**. Hold a
movement key and press the dodge button, or double-tap your dodge keys; Skif
dodges left, right or back, camera-relative. Keys and forces are edited in one
ini and apply live — no MCM, no restart.

The mod is a UE4SS Lua script: `src/ConfigurableDodgeMod` ships as the
`ConfigurableDodgeMod` folder.

## Install

Requires an existing update 2.1 UE4SS installation.

1. Copy `ConfigurableDodgeMod` into `Stalker2\Binaries\Win64\ue4ss\Mods\`.
2. Add `ConfigurableDodgeMod : 1` to `ue4ss\Mods\mods.txt`.
3. Start the game.

Uninstall by deleting the folder and its `mods.txt` line.

## Configure

Edit `ConfigurableDodgeMod.ini` in the mod folder and save. Changes apply within
about two seconds.

| Key | Meaning | Default |
| --- | --- | --- |
| `Modality` | `button` (hold a movement key + press `ButtonKey`) or `doubletap` | `button` |
| `ButtonKey` | dodge button | `Left Alt` |
| `DoubleTapLeft/Right/Back` | double-tap keys | `Z` / `C` / `S` |
| `DoubleTapWindow` | max seconds between taps | `0.155` |
| `SideHorizontal/SideVertical` | side dodge force, cm/s | `650` / `500` |
| `BackHorizontal/BackVertical` | back dodge force, cm/s | `900` / `200` |
| `StaminaCost` | stamina per dodge (`0` = free) | `15` |
| `EnergyDrinkEffect` | free dodges during the drink's no-drain window | `1` |
| `EnergyDrinkFreeSeconds` | length of that window | `4.5` |
| `EnergyDrinkOveruseJump` | advanced detection threshold; leave at `50` | `50` |

## Bindable keys

`ButtonKey` and the `DoubleTap` keys accept:

| Group | Names |
| --- | --- |
| Letters | `A` – `Z` |
| Digits | `0` – `9`, or `Zero` – `Nine` |
| Function | `F1` – `F12` (F13–F24 do not exist in the engine) |
| Arrows | `Left` `Up` `Right` `Down` |
| Edit | `Home` `End` `PageUp` `PageDown` `Insert` `Delete` `BackSpace` |
| Misc | `Tab` `Enter` `Escape` `SpaceBar` `Pause` `CapsLock` `NumLock` `ScrollLock` |
| Modifiers | `LeftShift` `RightShift` `LeftControl` `RightControl` `LeftAlt` `RightAlt` |
| Symbols | `Semicolon` `Equals` `Comma` `Hyphen` `Period` `Slash` `Tilde` `LeftBracket` `Backslash` `RightBracket` `Apostrophe` |
| Numpad | `NumPadZero` – `NumPadNine` `Multiply` `Add` `Subtract` `Decimal` `Divide` |
| Mouse | `LeftMouseButton` `RightMouseButton` `MiddleMouseButton` `ThumbMouseButton` (4) `ThumbMouseButton2` (5) |

Aliases: `Left Alt`, `Right Alt`, `Left Ctrl`, `Right Ctrl`, `Left Shift`,
`Right Shift`, `Space`, `Backspace`. A VK hex code such as `0x58` also works.

## Behaviour

- Hold `A` / `D` / `S` and press `Left Alt` (default). Forward-only movement does
  not dodge.
- 15 stamina per dodge; low stamina and open menus block dodges.
- After an energy drink, dodges are free for the same short window in which the
  game stops stamina drain.

## Build

Needs PowerShell 5.1 only:

```powershell
.\package.ps1
```

Writes `dist\Configurable Dodge Mod_<ver>_mod-only.zip`, the Nexus upload.
`dist\` is generated and ignored by git; archives are never overwritten, so bump
`-Ue4ssVersion` for a new release. `Deploy.ps1` installs the mod straight into a
detected game folder.

## Credits

- Dodge concept: rbwadle (Nexus 1243).
- RE-UE4SS and the STALKER 2 compatibility effort.
- GSC Game World, for a moddable UE5 game.
