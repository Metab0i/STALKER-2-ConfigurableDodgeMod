# Configurable Dodge Mod for S.T.A.L.K.E.R. 2

![Configurable Dodge Mod thumbnail](media/main.png)

Hold a movement key and press your dodge button (default **Left Alt**), or
double-tap your dodge keys, and Skif dodges left / right / back relative to the
camera. Each dodge costs stamina. Every key and force value is configurable by
editing a single ini file, live.

## Demo

[![Dodging demo video](https://img.youtube.com/vi/aLGJFVEcolc/0.jpg)](https://www.youtube.com/watch?v=aLGJFVEcolc)

## How key detection works

Dodges are driven entirely by UE4SS keybind events: the configured key is
registered as a keybind, so a press calls the dodge directly. Left/Right Alt,
Ctrl, and Shift use their Windows virtual-key codes plus UE4SS's corresponding
modifier state. There is no Lua input-polling loop, engine key-state polling,
helper process, or console window.

All keys listed below are supported. F13-F24 and the Windows keys are not
advertised as supported bindings.

## Energy drink interaction

Vanilla energy drinks briefly stop stamina drain after drinking. The mod
samples the game's energetic-overuse value once a second (and again on every
dodge); a sharp rise means a drink was just consumed. Dodges during the same
short window are free, matching the game's behaviour. Default window: 4.5 s.
Set `EnergyDrinkEffect=0` to ignore it.

## Install

Requires an existing update 2.1 UE4SS installation.

1. Copy the `ConfigurableDodgeMod` folder into
   `Stalker2\Binaries\Win64\ue4ss\Mods\`.
2. Add `ConfigurableDodgeMod : 1` to `ue4ss\Mods\mods.txt`.
3. Launch the game.

Default controls: hold **A/D/S** and press **Left Alt** to dodge.

## Use

- Hold a movement key and press the dodge button. A/D/S dodge left / right /
  back; forward-only movement does nothing.
- In double-tap mode, double-tap the configured keys (Z / C / S by default).
- 15 stamina per dodge. Low stamina and open menus/dialogs block dodges.
- Right after an energy drink, dodges are free for the same short window in
  which the game itself stops stamina drain.

## Configure

Edit **`ConfigurableDodgeMod.ini`** in the mod folder and save - changes apply
in game within ~2 seconds. No setup tool, no restart.

| Key | Meaning | Default |
| --- | --- | --- |
| `Modality` | `button` (hold a movement key + press `ButtonKey`) or `doubletap` | `button` |
| `ButtonKey` | dodge button (key name, VK hex or mouse button) | `Left Alt` |
| `DoubleTapLeft/Right/Back` | double-tap keys | `Z` / `C` / `S` |
| `DoubleTapWindow` | max seconds between taps (try 0.12-0.20) | `0.155` |
| `SideHorizontal/SideVertical` | side dodge force (cm/s) | `650` / `500` |
| `BackHorizontal/BackVertical` | back dodge force (cm/s) | `900` / `200` |
| `StaminaCost` | stamina per dodge (`0` = free) | `15` |
| `EnergyDrinkEffect` | free dodges during the drink's no-drain window (`1` / `0`) | `1` |
| `EnergyDrinkFreeSeconds` | length of that window (seconds) | `4.5` |
| `EnergyDrinkOveruseJump` | advanced; leave at `50` | `50` |

## Bindable keys

`ButtonKey` and `DoubleTapLeft/Right/Back` accept an engine key name, a VK hex
code (`0x58`) or a mouse button. Names are case-sensitive.

| Group | Names |
| --- | --- |
| Letters | `A` - `Z` |
| Digits | `0` - `9` (or `Zero` - `Nine`) |
| Function | `F1` - `F12` (F13-F24 do not exist in the engine) |
| Arrows | `Left` `Up` `Right` `Down` |
| Edit | `Home` `End` `PageUp` `PageDown` `Insert` `Delete` `BackSpace` |
| Misc | `Tab` `Enter` `Escape` `SpaceBar` `Pause` `CapsLock` `NumLock` `ScrollLock` |
| Modifiers | `LeftShift` `RightShift` `LeftControl` `RightControl` `LeftAlt` `RightAlt` |
| Symbols | `Semicolon` `Equals` `Comma` `Hyphen` `Period` `Slash` `Tilde` `LeftBracket` `Backslash` `RightBracket` `Apostrophe` |
| Numpad | `NumPadZero` - `NumPadNine` `Multiply` `Add` `Subtract` `Decimal` `Divide` |
| Mouse | `LeftMouseButton` `RightMouseButton` `MiddleMouseButton` `ThumbMouseButton` (Mouse 4) `ThumbMouseButton2` (Mouse 5) |

Aliases: `Left Alt`, `Right Alt`, `Left Ctrl`, `Right Ctrl`, `Left Shift`,
`Right Shift`, `Left Control`, `Right Control`, `Space`, `Backspace`, and the
literal symbol keys `;` `=` `,` `-` `.` `/` `[` `]` `\` `'`.

Examples:

```ini
ButtonKey=Left Alt
ButtonKey=ThumbMouseButton2
ButtonKey=0x58
DoubleTapLeft=Q
```

## Requirements

| Dependency | Version |
| --- | --- |
| S.T.A.L.K.E.R. 2: Heart of Chornobyl | update 2.1 |
| UE4SS | the update 2.1 build |

## Credits

- Dodge concept: **rbwadle** (Nexus 1243) - the original pak mod cannot load on
  update 2.0
- **UE4SS** (RE-UE4SS, MIT) and the community compatibility fix (Nexus 2341)
