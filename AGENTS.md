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
Camera" is turned on in the interior settings panel (see
[`docs/chase/AGENTS.md`](./docs/chase/AGENTS.md)).

Both settings panels live under `ui/ui-vue/mods/enhanceddriver/` and currently
register **separate pause-menu buttons** ("EIC Settings" via `index.js`, "ACC
Settings" via `arcadeChaseDemo.js`). Unifying them into one tabbed shell is
planned but **not yet implemented** — until then, keep the two panels' shared
design conventions in sync (side-nav layout, shared slider-row pattern, plain-CSS
SFC styles; see each camera's `AGENTS.md` §Vue).

## Documentation (start here per camera)

- **Interior camera** → [`docs/interior/AGENTS.md`](./docs/interior/AGENTS.md)
  (overview: [`docs/interior/README.md`](./docs/interior/README.md))
- **Chase camera** → [`docs/chase/AGENTS.md`](./docs/chase/AGENTS.md)
  (overview: [`docs/chase/README.md`](./docs/chase/README.md),
  full spec: [`docs/chase/REQUIREMENTS.md`](./docs/chase/REQUIREMENTS.md))

When changing a camera, follow that camera's `AGENTS.md` (gotchas, BeamNG API, Lua
and Vue conventions). Both cameras share the root `package.ps1`, the `locales/`
translation file, and the module-cache invalidation lists below — update the
translation and both lists whenever a camera module or helper is added or
renamed.

## Shared conventions (both cameras)

- Camera mode files live in `lua/ge/extensions/core/cameraModes/*.lua` (name == filename,
  no extension). Helper modules live in **sibling** dirs (`core/enhancedoccupant/`,
  `core/arcadeOrbit/`) — never in `cameraModes/`.
- **Module cache invalidation lists.** Enabling a mod does **not** reload Lua modules that
  were already `require`d while it was disabled (they stay in `package.loaded`), so
  `core_camera` keeps building stock cameras. Both `scripts/enhanceddriver/modScript.lua`
  (fires when the mod is activated) and
  `lua/ge/extensions/enhanceddriver/cameraHooks.lua` (stays loaded and reacts when the mod
  is disabled) hold an explicit list of the mod's camera modules to drop from the cache.
  **When you add or rename any camera mode or helper module, add it to BOTH lists.**
- `require` paths are relative to `lua/`.
- Vehicle speed is `data.vel:length()` (not `data.speed`); acceleration is
  `(data.vel - data.prevVel) / data.dtSim` transformed into the vehicle frame.
- Reset effect state + smoothers on `data.teleported` and vehicle switch (no spikes/NaNs).
- Per-instance smoothers (not globals). No per-frame allocations in the hot path.
- Camera-menu labels come from `locales/translations/`. The key
  `ui.camera.mode.arcadeOrbit` ("Arcade Chase Camera") must stay present; the interior
  camera reuses the stock `occupant`/`driver` camera names, so it needs no extra key.
- Settings persistence: interior → BeamNG settings key `edcSettings`;
  chase → `/arcadeOrbitSettings.json` (reloaded via `arcadeOrbitReloadSettings()`).
- Speeds are stored in **m/s** and displayed in the user's unit; no magic numbers.
- Package from the repo root with `./package.ps1` (PowerShell 7+); it zips `locales/`,
  `lua/`, `ui/`, and `scripts/` into `dist/austint30.enhanced-interior-camera.zip`.
- The planned **enhanced hood camera** has no code, spec, or settings yet — when it lands,
  follow the conventions in this file (camera mode in `cameraModes/`, helpers in a sibling
  dir, both cache lists updated, locale key added, settings panel under
  `ui/ui-vue/mods/enhanceddriver/`). Note the stock hood camera is not a `cameraModes`
  file — hood/roof/part cams are JBeam-defined onboard cameras — so the interior camera's
  replace-the-stock-module approach does not map 1:1; pick the integration point
  deliberately when speccing it.
