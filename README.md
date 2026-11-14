# Configurable Dodge Mod

![Configurable Dodge Mod thumbnail](media/main.png)

Stamina-based dodge for **S.T.A.L.K.E.R. 2: Heart of Chornobyl 2.1** (build
`a6b31ee`). Hold a movement key and press the dodge button, or double-tap your
dodge keys; Skif dodges left, right or back, camera-relative. Keys and forces
are edited in one ini and apply live — no MCM, no restart.

## Variants

| Variant | Source | Ships as |
| --- | --- | --- |
| **UE4SS (Lua)** | `src/ConfigurableDodgeMod_UE4SS` | `ConfigurableDodgeMod` folder |
| **DLL (C++)** | `src/ConfigurableDodgeMod_DLL` | `ConfigurableDodgeNative` folder |

Both load through **UE4SS for update 2.1** and behave the same. The DLL variant
compiles the dodge logic and reads the game's own functions; it uses UE4SS only
as a loader and calls no UE4SS API.

## Install

Requires an existing update 2.1 UE4SS installation. Download the archive for the
variant you want (or build both with `package.ps1`).

**UE4SS**

1. Copy `ConfigurableDodgeMod` into `Stalker2\Binaries\Win64\ue4ss\Mods\`.
2. Add `ConfigurableDodgeMod : 1` to `ue4ss\Mods\mods.txt`.
3. Start the game.

**DLL**

1. Copy `ConfigurableDodgeNative` into `Stalker2\Binaries\Win64\ue4ss\Mods\`.
2. Add `ConfigurableDodgeNative : 1` to `ue4ss\Mods\mods.txt`.
3. Start the game.

Uninstall either variant by deleting its folder and its `mods.txt` line.

## Configure

| Variant | File, in the mod folder |
| --- | --- |
| UE4SS | `ConfigurableDodgeMod.ini` |
| DLL | `ConfigurableDodge.ini` |

Shared keys: `Modality`, `ButtonKey`, `DoubleTapLeft/Right/Back`,
`DoubleTapWindow`, `SideHorizontal/SideVertical`, `BackHorizontal/BackVertical`,
`StaminaCost`, `EnergyDrinkEffect`, `EnergyDrinkFreeSeconds`,
`EnergyDrinkOveruseJump`. The DLL adds `Cooldown`, `RequireStamina`,
`RequireCursorFree` and `Log`. Every key is documented in the ini comments.

Save the file in game; changes apply within about two seconds. The DLL variant
only ticks while the game window has focus, so edit while playing, not while
alt-tabbed.

## Build

Needs PowerShell 5.1 and MinGW-w64 (`g++` on `PATH`, or pass `-Gcc`):

```powershell
.\package.ps1
```

It compiles the DLL and writes both upload archives:

```
dist\ConfigurableDodgeNativeDist_UE4SS\Configurable Dodge Mod_<ver>_UE4SS.zip
dist\ConfigurableDodgeNativeDist_DLL\Configurable Dodge Mod_<ver>_DLL.zip
```

`dist\` is generated and ignored by git; archives are never overwritten, so bump
`-Ue4ssVersion` / `-DllVersion` for a new release. `Deploy.ps1` installs the
UE4SS variant straight into a detected game folder.

Everything the DLL assumes about the game was read out of build `a6b31ee`:
`FUObjectArray` RVA `0xA0D4980`, the `PeekMessageW` IAT slot `0x9C37B30`, the
stamina/overuse function RVAs, the struct offsets in
`ue4ss\UE4SS_ObjectDump.txt`, and the `LaunchCharacter` vtable slot `0x948`. A
game update invalidates them: the mod logs its scan stages and refuses any
launch whose target is outside the game image instead of crashing.

## Bindable keys

`ButtonKey` and the `DoubleTap` keys accept:

| Group | Names |
| --- | --- |
| Letters | `A` – `Z` |
| Digits | `0` – `9`, or `Zero` – `Nine` |
| Function | `F1` – `F24` |
| Arrows | `Left` `Up` `Right` `Down` |
| Edit | `Home` `End` `PageUp` `PageDown` `Insert` `Delete` `BackSpace` |
| Misc | `Tab` `Enter` `Escape` `SpaceBar` `Pause` `CapsLock` `NumLock` `ScrollLock` |
| Modifiers | `LeftShift` `RightShift` `LeftControl` `RightControl` `LeftAlt` `RightAlt` |
| Symbols | `Semicolon` `Equals` `Comma` `Hyphen` `Period` `Slash` `Tilde` `LeftBracket` `Backslash` `RightBracket` `Apostrophe` |
| Numpad | `NumPadZero` – `NumPadNine` `Multiply` `Add` `Subtract` `Decimal` `Divide` |
| Mouse | `LeftMouseButton` `RightMouseButton` `MiddleMouseButton` `ThumbMouseButton` (4) `ThumbMouseButton2` (5) |

Aliases: `Left Alt`, `Right Alt`, `Left Ctrl`, `Right Ctrl`, `Left Shift`,
`Right Shift`, `Space`, `Backspace`. A VK hex code such as `0x58` also works.
Names are matched case-insensitively.

## Behaviour

- Hold `A` / `D` / `S` and press `Left Alt` (default). Forward-only movement does
  not dodge.
- 15 stamina per dodge; low stamina and open menus block dodges.
- After an energy drink, dodges are free for the same short window in which the
  game stops stamina drain.

## Credits

- Dodge concept: rbwadle (Nexus 1243).
- RE-UE4SS and the STALKER 2 compatibility effort.
- GSC Game World, for a moddable UE5 game.
