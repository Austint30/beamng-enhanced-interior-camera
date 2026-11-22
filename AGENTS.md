# AGENTS.md — Enhanced Camera Suite (BeamNG.drive mod)

This mod is the **Enhanced Camera Suite** (formerly **Enhanced Interior Camera**):
a suite of cameras in one package. It currently ships two camera families, with an
enhanced **hood camera** planned but **not yet implemented**.

| Camera | Camera code | Settings UI |
|--------|-------------|-------------|
| Interior Camera | `lua/ge/extensions/core/cameraModes/occupant.lua` + `driver.lua` (replaces the stock occupant/driver cameras) | `ui/ui-vue/mods/enhanceddriver/EICSettings.vue` |
| Chase Camera (`arcadeOrbit`) | `lua/ge/extensions/core/cameraModes/arcadeOrbit.lua` | `ui/ui-vue/mods/enhanceddriver/ArcadeChaseSettings.vue` |

The **interior** camera replaces BeamNG's stock `occupant` and `driver` camera
modules (same filenames, same camera names), so it is active automatically on the
normal interior camera — no separate menu entry. The **chase** camera is
auto-discovered by BeamNG from `lua/ge/extensions/core/cameraModes/` but ships as
a **hidden demo**: it stays out of the camera menu until "Enable Arcade Chase
Camera" is turned on in the interior settings panel.

Both settings panels live under `ui/ui-vue/mods/enhanceddriver/` and currently
register **separate pause-menu buttons** ("EIC Settings" via `index.js`, "ACC
Settings" via `arcadeChaseDemo.js`). Unifying them into one tabbed shell is
planned but **not yet implemented** — until then, keep the two panels' shared
design conventions in sync (§5).

## Documentation (start here per camera)

- **Interior camera** → [`docs/interior/AGENTS.md`](./docs/interior/AGENTS.md)
  (overview: [`docs/interior/README.md`](./docs/interior/README.md))
- **Chase camera** → [`docs/chase/AGENTS.md`](./docs/chase/AGENTS.md)
  (overview: [`docs/chase/README.md`](./docs/chase/README.md),
  full spec: [`docs/chase/REQUIREMENTS.md`](./docs/chase/REQUIREMENTS.md))

This file holds the rules **both** cameras follow — registration, the BeamNG
camera API, Lua and Vue conventions, testing, and packaging. Each camera's
`AGENTS.md` holds only that camera's specifics (layout, gotchas, settings, known
issues). Read the camera's `AGENTS.md` before changing that camera.

## 1. Camera registration rules

> **CRITICAL — camera registration path.** BeamNG auto-discovers camera modes **only**
> from `lua/ge/extensions/core/cameraModes/*.lua` (game: `ge/extensions/core/camera.lua`,
> `FS:findFiles(camDirectory, "*.lua", 1, false, false)`). The camera name is the
> **filename without extension**. A working camera mode **must** live in that
> directory.
>
> **CRITICAL — do NOT put helper `.lua` files in `cameraModes/`.** `getConstructors()`
> iterates the top-level `*.lua` there and does `require('core/cameraModes/' .. <filename>)`,
> so a helper there is loaded as its own (broken) camera. Keep all helpers in **sibling**
> dirs — `lua/ge/extensions/core/enhancedoccupant/` (interior) and
> `lua/ge/extensions/core/arcadeOrbit/` (chase) — and require them as
> `core/enhancedoccupant/...` / `core/arcadeOrbit/...`. Only actual camera modes belong
> in `cameraModes/`.
>
> **CRITICAL — module cache invalidation lists.** Enabling a mod does **not** reload Lua
> modules that were already `require`d while it was disabled (they stay in
> `package.loaded`), so `core_camera` keeps building stock cameras. Both
> `scripts/enhanceddriver/modScript.lua` (fires when the mod is activated) and
> `lua/ge/extensions/enhanceddriver/cameraHooks.lua` (stays loaded and reacts when the
> mod is disabled) hold an explicit list of the mod's camera modules to drop from the
> cache. **When you add or rename any camera mode or helper module, add it to BOTH
> lists.**

- `require` paths are relative to `lua/`.
- **Menu labels** come from `locales/translations/`. The key
  `ui.camera.mode.arcadeOrbit` ("Arcade Chase Camera") must stay present; the interior
  camera reuses the stock `occupant`/`driver` camera names, so it needs no extra key.
- **Two perlin copies, deliberately.** `core/enhancedoccupant/perlin.lua` and
  `core/arcadeOrbit/perlin.lua` are the same API (`perlin:noise(x,y,z)` ∈ [-1,1],
  `perlin:OctavePerlin(...)`). Keep them API-compatible if you edit one.

## 2. Shared critical gotchas

- **Vehicle speed vs `data.speed`.** Vehicle speed = `data.vel:length()`. `data.speed` is
  the *UI camera-speed modifier* (2–100) and is **not** vehicle speed — never use it for
  speed-based effects (shake/FOV).
- **Acceleration has no direct API.** Compute it: `a = (data.vel - data.prevVel) / data.dtSim`
  (world space), then transform into the vehicle frame with the vehicle rotation quat.
- **Reset/teleport spikes.** On `data.teleported` and on vehicle switch, reset all effect
  state and smoothers — no spikes, no NaNs. The teleport frame itself has a phantom
  velocity spike (`data.vel` zeroed while `data.prevVel` still holds the old speed —
  reads as a hundreds-of-g impact); ignore that frame so rewinds and recovers never
  trigger effects.
- **Per-instance smoothers.** Create `newTemporalSmoothingNonLinear` per camera instance
  (in `init`), never as a module-level global — a shared smoother caused a real bug once
  (see the interior camera's history, issue #23).
- **No magic numbers.** Every numeric literal that encodes a domain meaning (thresholds,
  clamps, scale factors, fallbacks) must be a named local constant with a short inline
  comment explaining its purpose and units. Only mathematical identities (`0`, `1`, `2`,
  `math.pi`) and loop/temp indices may appear bare.
- **Preallocate temps** at module level (see the `local …` blocks at the top of each
  camera module) to keep per-frame allocations out of `update()`.

## 3. BeamNG camera API reference (game root: `I:\SteamLibrary\steamapps\common\BeamNG.drive\lua`)

- **Registration / constructors:** `ge/extensions/core/camera.lua` — `getConstructors()`
  and `processVehicleCameraConfigChanged` (camera config ordering, `disabledByDefault`,
  `order`, `hidden`, `isFilter`, `isGlobal`).
- **`data` structure:** `newCamData` / per-frame population in `cameraUpdate.lua`.
  Available: `data.veh`, `data.vid`, `data.player`, `data.dt`/`data.dtSim`/`data.dtReal`,
  `data.pos`/`data.prevPos`, `data.vehPos`, `data.vel`/`data.prevVel`, `data.teleported`,
  `data.openxrSessionRunning`, `data.lookBack`, `data.fastSpeedModifier`.
  Output: `data.res.pos`, `data.res.targetPos`, `data.res.rot` (quat), `data.res.fov`,
  `data.res.nearClip`, `data.res.collisionCompatible`.
- **Camera-mode lifecycle hooks** (all optional): `init()`, `update(data)`, `reset()`,
  `onVehicleCameraConfigChanged()`, `onSettingsChanged()`, `onVehicleSwitched()`,
  `onCameraChanged(focused)`, `setRefNodes(centerNodeID, leftNodeID, backNodeID,
  dynamicFovRearNodeID)`, `mouseLocked(locked)`.
- **JBeam config merge:** vehicle JBeam camera values (`distance`, `fov`, `rotation`, …)
  are merged onto the camera object before `onVehicleCameraConfigChanged`. Read them
  with `settings.getValue(...)` defaults as fallback.
- **Smoothing:** `common/filters.lua` — `newTemporalSmoothingNonLinear(inRate, outRate,
  startingValue)`; methods `:get(sample, dt)`, `:getWithRate(sample, dt, rate)`, `:set(v)`,
  `:value()`, `:reset()`. Higher rate = faster; `inRate` applies when the value returns
  toward 0, `outRate` when it moves away.

## 4. Shared Lua conventions

- **Class pattern** (match the existing files):
  ```lua
  local C = {}
  C.__index = C
  function C:init() ... end
  function C:update(data) ... end
  -- DO NOT CHANGE CLASS IMPLEMENTATION BELOW
  return function(...)
    local o = ... or {}
    setmetatable(o, C)
    o:init()
    return o
  end
  ```
- **Style:** 2-space indent, no semicolons, `local` for module-level temps, preallocate
  temps at module level (no per-frame allocations in the hot loop).

## 5. Shared Vue UI conventions

- Both panels live under `ui/ui-vue/mods/enhanceddriver/` and register pause-menu buttons
  via `lua.extensions.ui_pause_actions.registerModButton`
  (`{ id, tabId='mods', label, icon, componentName }`).
- Build panels from `@/common/components/base` (`BngSlider`, `BngButton`, `BngDropdown`,
  `BngInput`, `BngSwitch`, `BngTabs`, `BngIcon`, `icons`), the `lua` bridge from
  `@/bridge`, `runRaw` from `@/bridge/libs/Lua.js`, and `useSettings` from
  `@/services/settings`.
- **Layout is side-nav, not tabs.** The pause-menu mod card is hard-limited to ~28em
  wide, so horizontal tab heads clip. Sections are a vertical `BngButton` nav (left) +
  a scrollable panel (right), data-driven by the `SECTIONS` array in each settings SFC.
  Each slider row is a 2-col grid (label+description | `BngSlider`) to save vertical
  space. This is the suite's shared panel design — keep both panels on it.
- **Widening the mod card** is done by a **non-scoped** `<style>` block in the settings
  SFC targeting the host card (`:has(> …)` on a panel-specific class). It needs
  `!important` because the game's scoped layout rule out-specifies it in this CEF build.
- **SFC styles compile as plain CSS** (the mod SFC runtime runs `compileStyleAsync`
  without an SCSS preprocessor), so only native CSS nesting / `:has()` is safe — no
  `@use`, `@mixin`, interpolation, or SCSS math.
- **Settings persistence — two systems, do not mix them:**
  - **Interior:** one JSON object under the BeamNG settings key `edcSettings`. JS:
    `gameSettings.apply({ edcSettings: snapshot })` / `gameSettings.getValue('edcSettings')`;
    Lua: `settings.getValue('edcSettings')`.
  - **Chase:** one JSON **file** at `/arcadeOrbitSettings.json` with shipped defaults in
    `lua/ge/extensions/core/arcadeOrbit/arcadeOrbitDefaults.json`; the JS side saves
    with `jsonWriteFile('/arcadeOrbitSettings.json', …)` and reloads the Lua via
    `arcadeOrbitReloadSettings()`; the Lua side loads in `loadSettings()` with
    `jsonReadFile` (user presets merge over the defaults on top of the chosen preset).
  - Load defaults from a JSON file with `runRaw("jsonReadFile('<path>')")`.
- **Units:** store speeds in **m/s**; display in the user's unit (km/h or mph) via
  `useSettings().values.uiUnitLength` (`displayValue`/`toStoredValue`).

## 6. Testing / reload

- There is **no** automated test runner in this repo. Verify in-game.
- After Lua changes, reload the game engine Lua with **Ctrl + L**.
- Toggle the mod off/on in the mod manager to verify the cameras revert to stock and
  back (this exercises the module-cache lists in §1).
- Watch the BeamNG log for Lua errors after reload (a `require` path typo or a bad
  `data` field access will surface there).

## 7. Packaging

- `./package.ps1` (PowerShell 7+) from the repo root zips `locales/`, `lua/`, `ui/`, and
  `scripts/` into `dist/austint30.enhanced-interior-camera.zip` — one package for the
  whole suite.
- `./package.ps1 -Install` also drops the zip into the BeamNG mods folder.
- Use PowerShell 7+; older versions produce zips BeamNG can't read.

## 8. Planned: enhanced hood camera

No code, spec, or settings exist yet — only the name is reserved. When it lands,
follow the conventions in this file (camera mode in `cameraModes/`, helpers in a
sibling dir, both cache lists updated per §1, locale key added, settings panel
under `ui/ui-vue/mods/enhanceddriver/`). Note the stock hood camera is not a
`cameraModes` file — hood/roof/part cams are JBeam-defined onboard cameras — so the
interior camera's replace-the-stock-module approach does not map 1:1; pick the
integration point deliberately when speccing it.
