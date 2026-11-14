# Configurable Dodge Mod

Stamina-based dodge for **S.T.A.L.K.E.R. 2: Heart of Chornobyl 2.1** (build
`a6b31ee`). Hold a movement key and press the dodge button, or double-tap your
dodge keys; Skif dodges left, right or back, camera-relative. Keys and forces
are edited in one ini and apply live — no MCM, no restart.

Two implementations share the same behaviour and config keys:

| Variant | Source | Ship this |
| --- | --- | --- |
| **UE4SS (Lua)** | `src/ConfigurableDodgeMod_UE4SS` | `ConfigurableDodgeMod` folder |
| **DLL (C++)** | `src/ConfigurableDodgeMod_DLL` | `dist/ConfigurableDodgeNative` folder |

Both load through **UE4SS for update 2.1**. The DLL variant compiles the dodge
logic and reads the game's own functions; it uses UE4SS only as a loader and
calls no UE4SS API.

## Install

Requires an existing update 2.1 UE4SS installation.

**UE4SS variant**

1. Copy `src/ConfigurableDodgeMod_UE4SS` into `Stalker2\Binaries\Win64\ue4ss\Mods\`
   and rename it to `ConfigurableDodgeMod`.
2. Add `ConfigurableDodgeMod : 1` to `ue4ss\Mods\mods.txt`.
3. Start the game.

**DLL variant**

1. Copy `dist/ConfigurableDodgeNative` into `Stalker2\Binaries\Win64\ue4ss\Mods\`.
2. Add `ConfigurableDodgeNative : 1` to `ue4ss\Mods\mods.txt` (keep the bundled
   `enabled.txt` in the folder).
3. Start the game.

Uninstall either variant by deleting its folder and its `mods.txt` line.

## Configure

| Variant | File, next to the mod folder contents |
| --- | --- |
| UE4SS | `ConfigurableDodgeMod.ini` |
| DLL | `ConfigurableDodge.ini` |

Both use the same keys: `Modality`, `ButtonKey`, `DoubleTapLeft/Right/Back`,
`DoubleTapWindow`, `SideHorizontal/SideVertical`, `BackHorizontal/BackVertical`,
`StaminaCost`, `EnergyDrinkEffect`, `EnergyDrinkFreeSeconds`,
`EnergyDrinkOveruseJump`. The DLL also has `Cooldown`, `RequireStamina`,
`RequireCursorFree` and `Log`. Every key is documented in the ini comments,
including the bindable key names, VK hex codes (`0x58`) and mouse buttons.

Save the file in game; changes apply within about two seconds. The DLL variant
only ticks while the game window has focus, so edit while playing, not while
alt-tabbed.

## Build the DLL variant

Needs MinGW-w64 (GCC 13+) and nothing else:

```powershell
g++ -std=c++17 -O2 -shared -static -o dist\ConfigurableDodgeNative\dlls\main.dll src\ConfigurableDodgeMod_DLL\dodge.cpp
```

Close the game before replacing `dlls\main.dll`; Windows holds the loaded image
open. Offsets are verified against build `a6b31ee`; a game update needs
`src/ConfigurableDodgeMod_DLL/README.txt`'s verification steps repeated.

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
