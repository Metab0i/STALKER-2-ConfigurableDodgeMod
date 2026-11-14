# Engineering principles (apply to all code)

- **YAGNI** — implement only what the current requirement needs. No speculative features, abstractions, or "just in case" code.
- **KISS** — choose the simplest design that works. Fewer moving parts, fewer dependencies, less code.
- **SOLID** — small, single-purpose units with clear boundaries. Introduce an abstraction only when it removes real duplication or isolates a real change.
- **Code is a liability.** The less code that actualizes the system, and the simpler it is, the healthier the system. Prefer deleting and configuring over adding. If a requirement can be met without code, do that.

---

# dev_noue4ss — native dodge rewrite

Goal: replace the Lua dodge mod with a compiled implementation that owns its
own logic, with the mod's configuration in one hand-editable ini.

## Requirements

1. The player can dodge by applying force to Skif, using the same force-application mechanism as the current mod.
2. Dodge properties are configurable:
   - forces
   - dodge modality: button or double-tap
   - energy drink effects
3. The solution must be as simple as possible.
4. Shipping form is a folder dropped into `ue4ss\Mods\` as a **UE4SS C++ mod**.

## Loader decision

Requirement 4 originally read "no UE4SS dependency". That was dropped after the
proxy route was rejected: loading native code into the game requires a proxy
DLL, and spoofing `version.dll` (or `winmm`/`dwmapi`) was judged worse than
using UE4SS as the loader. The mod uses UE4SS only as a loader: it exports
`start_mod`/`uninstall_mod`, returns `nullptr` (never a fabricated
`CppUserModBase`), and calls no UE4SS API, so UE4SS version churn cannot break
it.

## Non-goals

Do not add anything not required above. No full parity, no MCM, no dev-only
tooling, no extra effects, no speculative abstractions. Add only when a concrete
requirement demands it.
