# AGENTS.md — Chase Camera (Enhanced Camera Suite)

Project-specific instructions for working on the **chase** camera (`arcadeOrbit`)
inside the *Enhanced Camera Suite*. Read [`REQUIREMENTS.md`](./REQUIREMENTS.md) for
the full feature spec; this file is the *how* and the *gotchas*.

## 1. What this is

A DriveClub-style arcade chase camera for BeamNG.drive, built on the stock orbit
camera. It is a **Lua + Vue** camera: a camera-mode Lua class plus a Vue settings
panel. There is no build step for Lua; the Vue UI ships as source (see §7).

This is one of two cameras in the suite; the *interior* camera is documented in
[`../interior/AGENTS.md`](../interior/AGENTS.md).

In this repo the chase camera ships as a **hidden demo** — it stays out of the
camera menu until "Enable Arcade Chase Camera" is turned on in the interior
settings panel (see §3).

## 2. Repository layout (within the Enhanced Camera Suite)

```
enhanced-camera-suite/
├── lua/ge/extensions/core/cameraModes/
│   └── arcadeOrbit.lua                 # main camera mode (composes the effects) — MUST stay in cameraModes/
├── lua/ge/extensions/core/arcadeOrbit/ # helper modules (SIBLING dir, NOT under cameraModes/)
│   ├── arcadeOrbitDefaults.json        # preset defaults (Default / Smooth / Intense)
│   ├── perlin.lua                      # perlin noise (noise / OctavePerlin)
│   ├── refNodes.lua                    # one-shot ref-node sync/registration
│   ├── vehicleMeasure.lua              # roof height / vehicle height / rear distance
│   └── effects/                        # one file per effect, composed by arcadeOrbit.lua
│       ├── velocityAim.lua             # drift look (aim offset toward velocity)
│       ├── speedShake.lua              # speed-based perlin shake
│       ├── driftShake.lua              # drift/burnout shake (slip-angle driven)
│       ├── accelDistance.lua           # acceleration boom delta
│       ├── accelResponse.lua           # crest/valley height + pitch overlay
│       ├── brakePitch.lua              # sustained braking aim offset
│       ├── decelJolt.lua               # sudden-deceleration aim jolt
│       ├── accelJolt.lua               # sudden-acceleration aim jolt
│       ├── leanInRoll.lua              # sustained cornering lean-in roll
│       ├── followSmoothing.lua         # boom pitch follow smoothing
│       └── speedDistance.lua           # speed-based boom length + brake cancellation
├── ui/ui-vue/mods/enhanceddriver/
│   ├── index.js                        # interior ("EIC Settings") button + demo sync
│   ├── arcadeChaseDemo.js              # registers/unregisters the "ACC Settings" button (demo gate)
│   ├── ArcadeChaseSettings.vue         # chase settings panel + presets
│   └── ArcadeChaseSettingSlider.vue    # reusable slider row
├── locales/translations/en-US/enhanceddriver.translation.json
│   └── "ui.camera.mode.arcadeOrbit": "Arcade Chase Camera"
└── package.ps1                         # zips locales/ + lua/ + ui/ + scripts/ into dist/
```

> **CRITICAL — camera registration path.** BeamNG auto-discovers camera modes **only**
> from `lua/ge/extensions/core/cameraModes/*.lua` (game: `ge/extensions/core/camera.lua`,
> `FS:findFiles(camDirectory, "*.lua", 1, false, false)`). The camera name is the
> **filename without extension**. The working camera **must** be at
> `lua/ge/extensions/core/cameraModes/arcadeOrbit.lua`.
>
> **CRITICAL — do NOT put helper `.lua` files in `cameraModes/`.** `getConstructors()`
> iterates the top-level `*.lua` and does `require('core/cameraModes/' .. <filename>)`,
> so a helper there is loaded as its own camera. Keep all helpers in the **sibling** dir
> `lua/ge/extensions/core/arcadeOrbit/` and require them as `core/arcadeOrbit/...`.
> Only actual camera modes belong in `cameraModes/`.

## 3. Critical gotchas

- **The demo gate.** `arcadeOrbit.lua` reads `settings.getValue('edcSettings')` and sets
  `self.hidden` / `self.disabledByDefault` from `edcSettings.arcadeChaseEnabled`
  (`isDemoEnabled()` at the top of the file). The camera only appears in the camera
  menu (and the camera cycle) when the interior panel's "Enable Arcade Chase Camera"
  switch is on. The Vue side mirrors the same flag through `arcadeChaseDemo.js`
  (`arcadeChaseDemoIsEnabled()` / `arcadeChaseDemoApply(on)`, which registers/
  unregisters the "ACC Settings" button). If you touch the gate, keep **both** sides
  in sync.
- **Vehicle speed vs `data.speed`.** Vehicle speed = `data.vel:length()`. `data.speed` is
  the *UI camera-speed modifier* (2–100) and is **not** vehicle speed — never use it for
  speed-based effects (shake/FOV). (game: `ge/extensions/core/camera.lua`)
- **Acceleration has no direct API.** Compute it: `a = (data.vel - data.prevVel) / data.dtSim`
  (world space), then transform into the vehicle frame with the vehicle rotation quat.
  The teleport frame itself has a phantom velocity spike (`data.vel` zeroed while
  `data.prevVel` still holds the old speed — reads as a hundreds-of-g impact); the
  jolt/brake modules explicitly ignore it, so rewinds and recovers never trigger a jolt.
- **Camera axes / sign conventions.** The camera looks along its forward with `quatFromDir`.
  For the collision-jerk left/right and roll directions, verify signs against the live camera
  frame before trusting them; the interior camera's g-force block
  (`core/enhancedoccupant/cameraFeatures.lua`) is a working reference for the force→angle
  math.
- **`ny` (back node − ref) points toward the REAR of the vehicle.** Evidence:
  `core/arcadeOrbit/effects/velocityAim.lua` — the aim only applies while
  `velLocal.y < 0` (velocity projected on the back node = "moving forward").
  Direction of travel is **`−ny`**. Sign-sensitive effects (e.g. `brakePitch`'s
  longitudinal decel) must project against `−ny`; fold/symmetric effects (drift slip
  angle, folded at 90°) are insensitive to the sign. Getting this wrong makes a decel
  effect fire on acceleration instead of braking.
- **mathlib `setRotate` is inverted vs the standard right-hand rule.**
  `LuaVec3:setRotate(q)` applies the *conjugate* of `q` — a positive `setFromAxisAngle`
  angle rotates the opposite way. Verified convention in `arcadeOrbit.lua`: axis =
  `lookDir × worldUp` + **positive** angle ⇒ aim tilts **down** (that is how `basePitch`
  "+ = down" works). So camera pitch-down = positive angle about that axis; pitch-up = negative.
- **Reset/teleport spikes.** On `data.teleported` and on vehicle switch (`onVehicleSwitched`),
  reset all effect state and smoothers (see the `data.teleported` block in `arcadeOrbit.lua`).
- **Per-instance state.** Smoothers/timers are created per camera instance (in `init`), not as
  shared globals.
- **`require` paths are relative to `lua/`.** e.g. `require('core/arcadeOrbit/perlin')`,
  `require('core/arcadeOrbit/effects/speedShake')`.
- **Module cache invalidation lists.** New/renamed chase modules must be added to **both**
  `scripts/enhanceddriver/modScript.lua` and
  `lua/ge/extensions/enhanceddriver/cameraHooks.lua` (see the root `AGENTS.md`).

## 4. BeamNG camera API reference

- **Registration / constructors:** `ge/extensions/core/camera.lua` — `getConstructors()` and
  `processVehicleCameraConfigChanged` (camera config ordering, `disabledByDefault`, `order`,
  `hidden`, `isFilter`, `isGlobal`).
- **`data` structure:** `newCamData` / per-frame population in `cameraUpdate.lua`.
  Available: `data.veh`, `data.vid`, `data.player`, `data.dt`/`data.dtSim`/`data.dtReal`,
  `data.pos`/`data.prevPos`, `data.vehPos`, `data.vel`/`data.prevVel`, `data.teleported`,
  `data.openxrSessionRunning`, `data.lookBack`, `data.fastSpeedModifier`.
  Output: `data.res.pos`, `data.res.targetPos`, `data.res.rot` (quat), `data.res.fov`,
  `data.res.nearClip`, `data.res.collisionCompatible`.
- **Camera-mode lifecycle hooks** (all optional): `init()`, `update(data)`, `reset()`,
  `onVehicleCameraConfigChanged()`, `onSettingsChanged()`, `onVehicleSwitched()`,
  `onCameraChanged(focused)`, `setRefNodes(ref, left, back, dynamicFovRearNodeID)`.
- **JBeam config merge:** vehicle JBeam camera values (`distance`, `fov`, `rotation`, …) are
  merged onto the camera object before `onVehicleCameraConfigChanged`.
- **Menu label:** locale key `ui.camera.mode.<cameraName>`. So `arcadeOrbit.lua` →
  `ui.camera.mode.arcadeOrbit` (present in `locales/translations/en-US/enhanceddriver.translation.json`).
- **Camera rotation input** (gamepad/mouse, `core/cameraInput.lua`):
  - Absolute (gamepad R-stick / kbd, 0–1): `MoveManager.yawLeft/yawRight`,
    `MoveManager.pitchUp/pitchDown` — use `(yawRight - yawLeft)`, `(pitchUp - pitchDown)`.
  - Relative (mouse RMB drag, per-frame deltas): `MoveManager.yawRelative/pitchRelative`.
  - Helpers: `core_camera.getLastFilter()`, `core_camera.timeSinceLastRotation()`,
    `core_camera.getLastCameraMovementType()`.
- **Smoothing:** `common/filters.lua` — `newTemporalSmoothingNonLinear(inRate, outRate,
  startingValue)`; methods `:get(sample, dt)`, `:getWithRate(sample, dt, rate)`, `:set(v)`,
  `:reset()`. Higher rate = faster.
- **Collision (reuse, don't rewrite):** `ge/extensions/core/cameraModes/collision.lua`.
- **Reference orbit camera:** the stock `orbit` camera (the chase camera is built on it;
  game root: `I:\SteamLibrary\steamapps\common\BeamNG.drive\lua`).

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
- **Effect modules** live in `core/arcadeOrbit/effects/`, each returning a constructor
  (same pattern) exposing `init()`, `update(data, ctx)`, `reset()`, and setters (e.g.
  `setAmpMultiplier`, `setMinSpeed`). The main camera instantiates them in `init()`, pushes
  settings in `applyConfig()`, calls `update` in a fixed order, and calls `reset()` on
  teleport/vehicle switch.
- **Style:** 2-space indent, no semicolons, `local` for module-level temps, preallocate temps
  at module level (avoid per-frame allocations in the hot loop).
- **No magic numbers.** Every numeric literal that encodes a domain meaning must be a named
  local constant with a short inline comment explaining its purpose and units. Only
  mathematical identities (`0`, `1`, `2`, `math.pi`) and loop/temp indices may appear bare.
- **Perlin:** `core/arcadeOrbit/perlin.lua` — `perlin:noise(x,y,z)` ∈ [-1,1];
  `perlin:OctavePerlin(x,y,z,octaves,amplitude,frequency)`. For per-frame shake, prefer the
  LUT-sampling approach in `core/cameraModes/speedshake.lua` over calling `noise()` per octave.

## 6. Reference (the "good example")

The *interior* camera in the same suite is a working reference for the force→angle math,
suppression/reset, and settings load/merge:

- `lua/ge/extensions/core/cameraModes/occupant.lua` + `driver.lua` — interior cameras;
  feature composition via `enhancedOccupant.install(C)`, settings load/merge.
- `lua/ge/extensions/core/enhancedoccupant/cameraFeatures.lua` — g-force/collision
  effects, dynamic FOV, suppression/reset, tumble detection usage.
- `lua/ge/extensions/core/cameraModes/speedshake.lua` — perlin shake (LUT-based), drift shake.
- `lua/ge/extensions/core/enhancedoccupant/{perlin,tumbleDetection}.lua` — perlin + tumble
  detector (the chase spec's tumble mode, REQUIREMENTS.md §5.7, should reuse the detector
  rather than grow a second copy).
- `lua/ge/extensions/core/cameraModes/enhancedoccupantDefaults.json` — preset defaults shape
  (the chase `arcadeOrbitDefaults.json` mirrors it).
- `ui/ui-vue/mods/enhanceddriver/EICSettings.vue` + `SettingSlider.vue` — UI.

## 7. Vue UI conventions

- The chase panel is `ui/ui-vue/mods/enhanceddriver/ArcadeChaseSettings.vue`. The pause-menu
  button is registered by `arcadeChaseDemo.js` — id `arcadeOrbit.settings`, label
  **"ACC Settings"** — and is created/removed dynamically with the demo gate (§3). The
  interior panel's button is registered separately by the folder-root `index.js`; a planned
  single tabbed shell for both panels is **not yet implemented**.
- Build the panel from `@/common/components/base` (`BngSlider`, `BngButton`, `BngDropdown`,
  `BngSwitch`), the `lua` bridge from `@/bridge`, `runRaw` from `@/bridge/libs/Lua.js`, and
  `useSettings` from `@/services/settings`.
- **Layout is side-nav, not tabs.** The pause-menu mod card is hard-limited to ~28em wide, so
  horizontal tab heads clip. Sections are a vertical `BngButton` nav (left) + a scrollable
  panel (right), data-driven by the `SECTIONS` array in `ArcadeChaseSettings.vue`. Each slider
  row is a 2-col grid (label+description | `BngSlider`) to save vertical space
  (`ArcadeChaseSettingSlider.vue`). This is the suite's shared panel design — the interior
  panel uses the same layout.
- **Widening the mod card** is done by a **non-scoped** `<style>` block in
  `ArcadeChaseSettings.vue` targeting the host card with
  `.pause-layout .menu-content-card-1:has(> .card-cnt > .pause-main-card > .aoc-settings)`.
  It needs `!important` because the game's scoped layout rule out-specifies it in this CEF
  build.
- **SFC styles compile as plain CSS** (the mod SFC runtime runs `compileStyleAsync` without an
  SCSS preprocessor), so only safe nesting / `:has()` / native CSS is usable — no `@use`,
  `@mixin`, or SCSS math.
- **Settings persistence (chase):** the chase camera stores to a file at
  `/arcadeOrbitSettings.json` (one object: `{ chosenPreset, presets = { … } }`) with shipped
  defaults in `lua/ge/extensions/core/arcadeOrbit/arcadeOrbitDefaults.json`, and the JS side
  reloads the Lua via `arcadeOrbitReloadSettings()` after save
  (`jsonWriteFile('/arcadeOrbitSettings.json', …)`). Load defaults with
  `runRaw("jsonReadFile('<path>')")`.
- **Units:** store speeds in **m/s**; display in the user's unit (km/h or mph) via
  `useSettings().values.uiUnitLength`.

## 8. Testing / reload

- There is **no** automated test runner. Verify in-game.
- After Lua changes, reload the game engine Lua with **Ctrl + L**.
- Enable "Enable Arcade Chase Camera" in the interior settings panel, switch to the camera
  (camera menu → "Arcade Chase Camera"), drive at speed, drift, hit crests/valleys, and
  brake hard to exercise each effect; check the **ACC Settings** button updates live.
- Watch the BeamNG log for Lua errors after reload (a `require` path typo or a bad `data`
  field access will surface there).

## 9. Packaging

- `./package.ps1` (PowerShell 7+) from the repo root zips `locales/`, `lua/`, `ui/`, and
  `scripts/` into `dist/austint30.enhanced-interior-camera.zip` — one package for the
  whole suite.
- `./package.ps1 -Install` also drops the zip into the BeamNG mods folder.
- Use PowerShell 7+; older versions produce zips BeamNG can't read.

## 10. Definition of done (per feature)

- Effect implemented in its own `core/arcadeOrbit/effects/<name>.lua` file and composed by
  `arcadeOrbit.lua`.
- All of its parameters exposed in the Vue settings panel and stored in the settings JSON.
- Respects the active preset (e.g. shake off in **Smooth**).
- Resets cleanly on teleport / vehicle switch (no spikes, no NaNs; ignore the
  teleport-frame phantom spike).
- No new per-frame allocations in the hot path.
- New/renamed modules added to both module-cache lists (§3).

## 11. Known issues

- **Trailers.** When a trailer is attached the camera origin moves to the combined
  vehicle/trailer correctly, but the camera does not pull back afterwards, so the trailer
  is not kept visible on screen.
- **Vehicle switch.** When switching to a different vehicle the camera origin is left
  offset by several metres from the car.

> **Fix guidance — study the stock orbit camera first.** The chase camera is built on the
> stock `orbit` camera, which already handles both trailers and vehicle switches
> correctly. Before inventing new logic for either issue, read how the stock `orbit`
> mode (and the ref-node selection it relies on) folds the trailer into the camera
> ref/distance and re-derives the camera pose when the vehicle changes, then port that
> approach into `arcadeOrbit.lua` instead of rolling separate handling.
