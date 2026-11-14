# Configurable Dodge Mod (native) v4.0.0

Native dodge mod for **S.T.A.L.K.E.R. 2: Heart of Chornobyl 2.1.0** (build
`a6b31ee`), packaged as a standard **UE4SS C++ mod**. No proxy DLL, no helper
process, no changes outside the mod folder.

## Performance notes

- The controller scan walks `GUObjectArray` chunk-first: one chunk-pointer read
  per 65 536 objects instead of one per object.
- `Readable()` caches the last committed region, so consecutive objects skip the
  `VirtualQuery`; the cache is dropped at the start of every tick, because the
  game frees and recomits memory between frames.
- Control rotation is validated before stamina is spent, so an aborted dodge
  costs nothing.

## Install

1. UE4SS for 2.1 must already be installed in `Stalker2\Binaries\Win64`.
2. Copy `dist\ConfigurableDodgeNative\` into `Stalker2\Binaries\Win64\ue4ss\Mods\`.
3. Add `ConfigurableDodgeNative : 1` to `ue4ss\Mods\mods.txt`.
4. The mod folder contains an empty `enabled.txt`; this UE4SS 3.0.1 build keys
   per-mod enablement off that file (`mods.json` is not required).
5. Start the game.

Config edits are picked up about a second after the file changes, while the game
window has focus (the mod only ticks while the game is foreground).

Installing by hand is the whole procedure; nothing else is written outside the
mod folder.

```
ConfigurableDodgeNative\
  dlls\main.dll              <- compiler output
  ConfigurableDodge.ini      <- edit this, applies within ~1 s in game
  README.txt
  ConfigurableDodge.log      <- written at runtime when Log=1
```

Uninstall = delete the folder and the `mods.txt` line. UE4SS calls
`uninstall_mod`, which restores the game's `PeekMessageW` import before the DLL
is freed.

## Why this loader

The previous prototype injected itself by spoofing `version.dll`, which is a
system DLL that other modules also import. A C++ mod folder loaded by UE4SS is
the documented extension point: UE4SS loads `dlls\main.dll`, calls `start_mod`,
and calls `uninstall_mod` on shutdown. The mod uses no UE4SS headers, so it is
insensitive to UE4SS API churn: `start_mod` returns `nullptr` deliberately, so
UE4SS never calls a `CppUserModBase` virtual on a fabricated object.

## What it does

`start_mod` starts one helper thread that:

1. waits for the main module and `user32.dll`,
2. resolves the game's `PeekMessageW` import slot and rewrites it to our detour,
3. exits. The detour then ticks the mod on the game thread at 10 ms.

A dodge scans `GUObjectArray` for the local `APlayerController` (identified by
the `ULocalPlayer::PlayerController` back-pointer), reads control rotation,
spends stamina through the game's own getters/setters, and calls
`ACharacter::LaunchCharacter` through the vtable.

## Verified constants

| Constant | Value | How |
| --- | --- | --- |
| `FUObjectArray` RVA | `0xA0D4980` | UE4SS's own `GUObjectArray` signature on this build resolves to it |
| `PeekMessageW` IAT slot | `0x9C37B30` | Import-directory walk; the slot is `USER32.dll!PeekMessageW` |
| `GetSP` / `ForceSetSP` / `GetOveruse` | `0x1FB413C` / `0x68984C2` / `0x6896BB6` | Disassembly: `(pawn)`-taking float getter, int32 setter, float getter |
| `Controller::Pawn` | `+0x2F0` | `ue4ss\UE4SS_ObjectDump.txt` |
| `Controller::ControlRotation` | `+0x328` | same dump |
| `PlayerController::Player` | `+0x350` | same dump |
| `PlayerController::PlayerCameraManager` | `+0x368` | same dump |
| `Player::PlayerController` | `+0x30` | same dump |
| `Pawn::LastControlInputVector` | `+0x310` | same dump (FVector, 3 doubles) |
| `PlayerController::bShowMouseCursor` | `+0x56C`, bit 0 | same dump (`fm: 1 bm: 1`; only bit 0 may be tested) |
| `ACharacter::LaunchCharacter` vtable slot | `0x948` | Runtime vtable from a loaded save; slot resolves to `0x35ADC38`, which reads `CharacterMovement` at `+0x338` (matches `Character:CharacterMovement`), takes the 24-byte `FVector` by pointer plus two bools, and adds it to the velocity |

## Not statically verified (fails safe at runtime)

- Nothing structural is left unverified. The controller scan still logs its
  stage counts (`scan: N objects, M with player pointer, K with
  player->controller match`) so a build change that moves an offset fails
  visibly instead of silently.

## Fixes over the previous prototype

1. **UE5 large-world-coordinates.** `FVector`/`FRotator` are three doubles
   (24 bytes). The old code passed a 12-byte struct into `LaunchCharacter`,
   which reads 24 bytes.
2. **Init thread actually started.** `DllMain` had `// proxy-only test` where the
   thread belonged, so the hook, config and tick never ran.
3. **Direction from `Pawn::LastControlInputVector`** (`+0x310`, verified in the
   object dump) dotted against control-rotation yaw, matching the Lua version's
   camera-relative behaviour.
4. **Game-thread latch fixed.** `DllMain` used to pin `g_gameThread` to the
   thread that loaded the DLL — under UE4SS that is the loader thread, so every
   game-thread tick was rejected. The thread is now pinned on the first
   `PeekMessage` call.
5. **Guarded launch**: readable vtable slot, in-image target, finite velocity.
6. **Live config reload**, so forces and stamina cost are edited in game.
7. **Static link**: no `libwinpthread` dependency.

## Note on the missing-saves symptom

It is unrelated to this mod. `Saved\NULL\` vs `Saved\STEAM\` is the game's
online-subsystem profile folder. The 30 saves live in
`%LOCALAPPDATA%\Stalker2\Saved\STEAM\SaveGames\Data`. See the session report.
