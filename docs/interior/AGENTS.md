# AGENTS.md — Interior Camera (Enhanced Camera Suite)

Project-specific instructions for working on the **interior** camera inside the
*Enhanced Camera Suite*. Read [`README.md`](./README.md) for the feature overview;
this file is the *how* and the *gotchas*.

## 1. What this is

The Enhanced Interior Camera is a physics-driven driver/cockpit camera for BeamNG.drive.
It is a **Lua + Vue** camera: camera-mode Lua classes (composition + effects) plus a Vue
settings panel. There is no build step for Lua; the Vue UI ships as source (see §6).

This is one of two cameras in the suite; the *chase* camera is documented in
[`../chase/AGENTS.md`](../chase/AGENTS.md).

Unlike the chase camera (a new, separately named camera mode), the interior camera
**replaces BeamNG's stock `occupant` and `driver` camera modules** — the mod ships its
own `occupant.lua` and `driver.lua` with the same filenames and camera names, so the
enhanced camera is active automatically wherever the stock interior camera would be.

## 2. Repository layout (within the Enhanced Camera Suite)

```
enhanced-camera-suite/
├── lua/ge/extensions/core/cameraModes/
│   ├── occupant.lua                    # enhanced interior camera (replaces stock occupant) — MUST keep this filename
│   ├── driver.lua                      # enhanced driver camera (replaces stock driver) — MUST keep this filename
│   ├── speedshake.lua                  # perlin shake (speed + drift) module (LUT-based)
│   └── enhancedoccupantDefaults.json   # preset defaults (Default / Lookahead / Intense / Smooth / VR (Comfort) / VR (Thrill))
├── lua/ge/extensions/core/enhancedoccupant/   # helper modules (SIBLING dir, NOT under cameraModes/)
│   ├── cameraFeatures.lua              # the feature set, installed onto both camera classes
│   ├── perlin.lua                      # perlin noise
│   ├── profiler.lua                    # lightweight frame/section profiler (profiler.start/stop/frame)
│   ├── steeringLookAhead.lua           # steering-input look-ahead angle offset
│   └── tumbleDetection.lua             # sustained roll/pitch angular-velocity tumble detector (g-force factor)
├── lua/ge/extensions/enhanceddriver/cameraHooks.lua  # drops cached camera modules on mod disable
├── scripts/enhanceddriver/modScript.lua              # drops cached modules on (re)enable — keep in sync!
├── ui/ui-vue/mods/enhanceddriver/
│   ├── index.js                        # registers the "EIC Settings" pause-menu button
│   ├── EICSettings.vue                 # interior settings panel + presets
│   └── SettingSlider.vue / SettingSwitch.vue
├── locales/translations/en-US/enhanceddriver.translation.json
└── package.ps1                         # zips locales/ + lua/ + ui/ + scripts/ into dist/
```

> **CRITICAL — keep the stock module filenames.** The interior camera works by
> module shadowing: BeamNG `require`s `core/cameraModes/occupant` and
> `core/cameraModes/driver`, and the mod's files win because they are mounted later.
> The camera names (`occupant`, `driver`) must stay exactly those of the stock
> cameras — renaming them breaks the "active on the normal interior camera"
> behaviour and every JBeam `cameraConfig` reference.
>
> **CRITICAL — keep helpers out of `cameraModes/`.** `getConstructors()` iterates the
> top-level `*.lua` there and `require`s each as a camera, so a helper placed there is
> loaded as its own camera. Keep helpers in the **sibling** dir
> `lua/ge/extensions/core/enhancedoccupant/` and require them as
> `core/enhancedoccupant/...`.
>
> **CRITICAL — module cache invalidation lists.** Because the mod replaces stock
> modules, a stale `package.loaded` entry silently reverts the camera to stock when
> the mod is toggled off/on in the mod manager. Both
> `scripts/enhanceddriver/modScript.lua` (fires when the mod is activated) and
> `lua/ge/extensions/enhanceddriver/cameraHooks.lua` (stays loaded and reacts when the
> mod is disabled) hold an explicit list of the mod's camera modules to drop from the
> cache. **When you add or rename any camera module or helper module, add it to BOTH
> lists** (see the root `AGENTS.md`).

## 3. Critical gotchas

- **Feature composition.** `core/enhancedoccupant/cameraFeatures.lua` exports an
  `install(cameraClass)` that patches the feature methods onto a camera class;
  `occupant.lua` calls `enhancedOccupant.install(C)`. Add shared interior features in
  `cameraFeatures.lua` so **both** the occupant and driver cameras get them — do not
  fork logic between the two files. `driver.lua` differs only in its driver-specific
  base behaviour (stock copies are kept in `reference/` for diffing).
- **Per-instance smoothers.** All `newTemporalSmoothingNonLinear` smoothers are created
  **per camera instance** in `init` (`gForceFwdSmoother`, `gForceSideSmoother`,
  `gForceSideLeanSmoother`, `gForceUpSmoother`, `velSmootherX/Y/Z`, `fovSmoother`).
  A shared global smoother caused a real bug
  (https://github.com/Austint30/beamng-enhanced-interior-camera/issues/23) — do not
  "refactor" them back to module level.
- **Effect suppression / reset.** Transient effects are gated by
  `self:updateCameraEffectFactor(data.dt)` (a suppression timer + recovery smoother).
  Call `self:suppressCameraEffects()` on `data.teleported`, `reset()`, and
  `onVehicleCameraConfigChanged()`. Effects multiply by the factor so the camera settles
  cleanly on respawn/teleport/vehicle change.
- **Two different look-aheads.**
  - BeamNG's *velocity* look-ahead: the "rock on a string" smoothing (`rockPos`) +
    `lookAheadAngle` (stock `cameraDriverLookAheadAngle`) + `lookAheadSmoothness`.
  - The mod's *steering* look-ahead: `self.steeringLookAhead:getAngleOffset(...)`,
    driven by `steeringLookAheadAngle` / `steeringLookAheadSmoothness`. Keep them separate.
  - The in-game **driver Look-Ahead Angle must be 0%** or the two fight.
- **Vehicle speed vs `data.speed`.** Vehicle speed = `data.vel:length()`. `data.speed` is
  the *UI camera-speed modifier* — never use it for speed-based effects.
- **Acceleration has no direct API.** Compute `a = (data.vel - data.prevVel) / data.dtSim`,
  transform into the vehicle frame with the vehicle rotation quat (`carRotInverse`).
- **Tumble handling.** `self.tumbleDetection:getGForceFactor(carUp, dt)` yields a 0..1
  factor; as the factor rises the camera blends toward the vehicle frame
  (`attachedCamRot`) while horizon lock is relaxed. Keep the forward/up-axis blending
  (not quaternion lerp) — linear blending of near-opposite vectors is guarded with a
  `squaredLength < 1e-8` fallback.
- **VR behaviour.** When `data.openxrSessionRunning`, remove manual head tilt/seat tilt and
  disable look-ahead/smoothers (several `if data.openxrSessionRunning` branches). Preserve
  them. The defaults ship VR presets (**VR (Comfort)** and **VR (Thrill)**) plus a
  `syncVrPreset` option.
- **`physicsFactor` blend.** `combinedPos` lerps the static initial camera local position
  with the live node position by `physicsFactor * cameraEffectFactor`. Seat offsets
  (`seatPosition`, `seatRotation`) are applied on top and persisted separately.
- **Looks like the stock camera to the UI — by construction.** The mod ships
  `occupant.lua`/`driver.lua` under the stock camera names, so the cockpit UI,
  apps, and JBeam `cameraConfig` blocks already see the names they expect. No
  `guihooks` wrapping is needed or present — do not add camera-name indirection.
- **`require` paths are relative to `lua/`.** e.g. `require('core/enhancedoccupant/perlin')`,
  `require('core/cameraModes/speedshake')`.
- **No magic numbers.** Every domain-meaningful literal must be a named local constant with
  a short comment (purpose + units). Only identities (`0`, `1`, `2`, `math.pi`) and loop/
  temp indices may appear bare.
- **Preallocate temps** at module level to keep per-frame allocations out of `update()`.

## 4. BeamNG camera API reference

- **Registration / constructors:** `ge/extensions/core/camera.lua` — `getConstructors()` and
  `processVehicleCameraConfigChanged`.
- **`data` structure:** `newCamData` / per-frame population in `cameraUpdate.lua`.
  Available: `data.veh`, `data.vid`, `data.player`, `data.dt`/`data.dtSim`/`data.dtReal`,
  `data.pos`/`data.prevPos`, `data.vel`/`data.prevVel`, `data.teleported`,
  `data.openxrSessionRunning`, `data.lookBack`, `data.fastSpeedModifier`.
  Output: `data.res.pos`, `data.res.targetPos`, `data.res.rot` (quat), `data.res.fov`.
- **Camera-mode lifecycle hooks** (all optional): `init()`, `update(data)`, `reset()`,
  `onVehicleCameraConfigChanged()`, `onSettingsChanged()`, `onCameraChanged(focused)`,
  `setRefNodes(centerNodeID, leftNodeID, backNodeID)`, `mouseLocked(locked)`.
- **Driver-camera stock settings** the interior camera reads: `cameraDriverPhysics`,
  `cameraDriverAutocenter`, `cameraDriverAllowSeatAdjustments`, `cameraDriverFov`,
  `cameraDriverLookAheadAngle`, `cameraDriverLookAheadSmoothness`,
  `cameraDriverStableHorizon`, `cameraDriverStablePitch`, `cameraDriverVehicleConfigs`,
  `openXRsnapTurnDriver`, `openXRhorizonLockDriver`.
- **Menu label:** none of its own — the camera reuses the stock `occupant`/`driver`
  names, so the stock menu entries and locale keys apply unchanged.
- **Smoothing:** `common/filters.lua` — `newTemporalSmoothingNonLinear(inRate, outRate,
  startingValue)`; `:get(sample, dt)`, `:getWithRate(sample, dt, rate)`, `:set(v)`, `:reset()`.
  Higher rate = faster.
- **manualzoom (FOV):** `core/cameraModes/manualzoom` — `:init(fov, …)`, `:update(data)`.
- **Stock reference copies** for diffing: `reference/occupant.lua.0.40` and
  `reference/driver.lua.0.39`.

## 5. Lua conventions

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
- `profiler.start(name)` / `profiler.stop(name)` bracket the heavy sections in the
  feature update (`LoadPreset`, `FOVSpeedMod`, `PhysicsTransform`, `GForce`,
  `SpeedShake`, `DriftShake`); keep the sections so timing stays debuggable.
- 2-space indent, no semicolons, `local` for module-level temps.

## 6. Vue UI conventions

- The interior panel is `ui/ui-vue/mods/enhanceddriver/EICSettings.vue`; its button is
  registered by the folder-root `index.js` — id `enhanceddriver.eic-settings`, label
  **"EIC Settings"**. (The chase panel registers its own button via `arcadeChaseDemo.js`;
  a planned single tabbed shell for the whole suite is **not yet implemented**.) On load,
  `index.js` also syncs the chase camera's demo gate
  (`syncArcadeChaseFromSettings()`).
- Build the panel from `@/common/components/base` (`BngSlider`, `BngButton`, `BngDropdown`,
  `BngInput`, `BngSwitch`, `BngTabs`, `BngIcon`, `icons`), the `lua` bridge from `@/bridge`,
  `runRaw` from `@/bridge/libs/Lua.js`, and `useSettings` from `@/services/settings`.
- **Layout is side-nav (shared with the chase panel).** Sections are a vertical `BngButton`
  nav (left) + a scrollable panel (right), driven by the `SECTIONS` array in
  `EICSettings.vue` (G-Effects / Shake / Dynamic FOV / Other). Each slider row is a 2-col
  grid (label+description | `BngSlider`) — `SettingSlider.vue` / `SettingSwitch.vue`.
  Speed sliders convert min/max/step/value to the user's unit
  (`displayValue`/`displayMin`/`displayMax`/`displayStep`).
- **SFC styles compile as plain CSS** (no SCSS preprocessor at mod SFC runtime) — no `@use`,
  `@mixin`, or SCSS math.
- **Settings persistence (interior):** stored in the game's settings key **`edcSettings`**
  (one object: `{ chosenPreset, presets = { <custom> = { … } } }`).
  - JS write: `gameSettings.apply({ edcSettings: snapshot })`; JS read:
    `gameSettings.getValue('edcSettings')`.
  - Lua read: `settings.getValue('edcSettings')` inside `loadSettingsPreset()`.
- **Presets:** shipped defaults are
  `/lua/ge/extensions/core/cameraModes/enhancedoccupantDefaults.json` — **Default**,
  **Lookahead**, **Intense**, **Smooth**, **VR (Comfort)**, **VR (Thrill)** — loaded with
  `runRaw("jsonReadFile('<path>')")`. Merge the active preset over the **Default** preset
  so new defaults back-fill old saved values. Custom presets can be created, saved, and
  deleted; `syncVrPreset` / `vrChosenPreset` control the VR preset sync option.
- **Cross-field constraints:** the panel enforces `min ≤ max` for the speed pairs
  (e.g. `fovMaxSpeed = Math.max(fovMinSpeed, fovMaxSpeed)`) in `updateSetting()`.
- **Units:** store speeds in **m/s**; display in the user's unit (km/h or mph) via
  `useSettings().values.uiUnitLength` (`displayValue`/`toStoredValue`).
- **Pause behaviour:** the panel un-pauses the sim on mount and re-pauses on unmount
  unless the route is one of the `UNPAUSED_PAUSE_ROUTES` (vehicle-config / tuning /
  paint / weather etc., where the sim is already running unpaused).

## 7. Testing / reload

- There is **no** automated test runner. Verify in-game.
- After Lua changes, reload the game engine Lua with **Ctrl + L**.
- Switch to the interior camera (it replaces the normal one — no separate menu entry),
  drive at speed, drift, hit crests/valleys, brake hard, and flip the car to exercise the
  g-force, shake, FOV, steering, and tumble paths; check the **EIC Settings** panel
  updates live.
- Remember **Options > Camera > Camera - Driver > Look-Ahead Angle = 0%**, otherwise the
  built-in look-ahead conflicts with the mod's.
- Toggle the mod off/on in the mod manager to verify the camera reverts to stock and
  back (this exercises the module-cache lists in §2).
- Watch the BeamNG log for Lua errors after reload (a `require` path typo or a bad `data`
  field access will surface there).

## 8. Packaging

- `./package.ps1` (PowerShell 7+) from the repo root zips `locales/`, `lua/`, `ui/`, and
  `scripts/` into `dist/austint30.enhanced-interior-camera.zip` — one package for the
  whole suite.
- `./package.ps1 -Install` also drops the zip into the BeamNG mods folder.
- Use PowerShell 7+; older versions produce zips BeamNG can't read.

## 9. Definition of done (per feature)

- Effect logic added in the appropriate place (composition in
  `core/enhancedoccupant/cameraFeatures.lua` so both cameras get it, or the right helper
  module) and driven by a settings key.
- All of its parameters exposed in the Vue settings panel and stored in `edcSettings`.
- Respects the active preset.
- Resets cleanly on teleport / vehicle switch (respect `suppressCameraEffects`).
- No new per-frame allocations in the hot path; per-instance smoothers preserved.
- New/renamed modules added to both module-cache lists (§2).
