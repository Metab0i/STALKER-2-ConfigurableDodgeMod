# Engineering principles (apply to all code)

- **YAGNI** — implement only what the current requirement needs. No speculative features, abstractions, or "just in case" code.
- **KISS** — choose the simplest design that works. Fewer moving parts, fewer dependencies, less code.
- **SOLID** — small, single-purpose units with clear boundaries. Introduce an abstraction only when it removes real duplication or isolates a real change.
- **Code is a liability.** The less code that actualizes the system, and the simpler it is, the healthier the system. Prefer deleting and configuring over adding. If a requirement can be met without code, do that.

---

# Project: Configurable Dodge Mod (UE4SS Lua)

A stamina-based dodge for S.T.A.L.K.E.R. 2, delivered as a single UE4SS Lua mod.

## Requirements

1. The player can dodge by applying force to Skif, using the game's own
   `LaunchCharacter`.
2. Dodge properties are configurable in one hand-edited ini:
   - forces
   - dodge modality: button or double-tap
   - energy drink effects
3. The solution stays as simple as possible.
4. One delivery form: the `ConfigurableDodgeMod` folder dropped into
   `ue4ss\Mods\` with a `mods.txt` line.

## Non-goals

No alternative build or loader, no MCM, no dev-only tooling, no extra effects, no
speculative abstractions. Add only when a concrete requirement demands it.

## Layout

- `src/ConfigurableDodgeMod` — the shipped mod (`Scripts\main.lua`, `ConfigurableDodgeMod.ini`)
- `dist` — generated upload archive, ignored by git
- `package.ps1` / `Deploy.ps1` — packaging and local install
