# AGENTS.md — Chase Camera (Enhanced Camera Suite)

Project-specific instructions for working on the **chase** camera (`arcadeOrbit`)
inside the *Enhanced Camera Suite*. Read [`REQUIREMENTS.md`](./REQUIREMENTS.md) for
the full feature spec.

> **Shared suite conventions** — registration rules, the BeamNG camera API, the Lua
> class pattern, Vue panel basics, testing, and packaging — live in the
> [root `AGENTS.md`](../../AGENTS.md). This file holds only the chase-specific parts.

## 1. What this is

A DriveClub-style arcade chase camera for BeamNG.drive, built on the stock orbit
camera. It is one of two cameras in the suite; the *interior* camera is documented
in [`../interior/AGENTS.md`](../interior/AGENTS.md).

In this repo the chase camera ships as a **hidden demo** — it stays out of the
camera menu until "Enable Arcade Chase Camera" is turned on in the interior
settings panel (see §3).

## 2. Repository layout (chase camera)

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

## 3. Chase-specific gotchas

- **The demo gate.** `arcadeOrbit.lua` reads `settings.getValue('edcSettings')` and sets
  `self.hidden` / `self.disabledByDefault` from `edcSettings.arcadeChaseEnabled`
  (`isDemoEnabled()` at the top of the file). The camera only appears in the camera
  menu (and the camera cycle) when the interior panel's "Enable Arcade Chase Camera"
  switch is on. The Vue side mirrors the same flag through `arcadeChaseDemo.js`
  (`arcadeChaseDemoIsEnabled()` / `arcadeChaseDemoApply(on)`, which registers/
  unregisters the "ACC Settings" button). If you touch the gate, keep **both** sides
  in sync.
- **Camera axes / sign conventions.** The camera looks along its forward with `quatFromDir`.
  For the collision-jerk left/right and roll directions, verify signs against the live
  camera frame before trusting them; the interior camera's g-force block
  (`core/enhancedoccupant/cameraFeatures.lua`) is a working reference for the
  force→angle math.
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
- **Reset wiring.** On `data.teleported` and on vehicle switch (`onVehicleSwitched`),
  the camera resets all effect state and smoothers — see the `data.teleported` block in
  `arcadeOrbit.lua`; each effect module also exposes `reset()` for this.

## 4. Chase-specific API notes

- **Menu label:** `ui.camera.mode.arcadeOrbit` → "Arcade Chase Camera" (present in
  `locales/translations/en-US/enhanceddriver.translation.json`).
- **Camera rotation input** (gamepad/mouse, `core/cameraInput.lua`):
  - Absolute (gamepad R-stick / kbd, 0–1): `MoveManager.yawLeft/yawRight`,
    `MoveManager.pitchUp/pitchDown` — use `(yawRight - yawLeft)`, `(pitchUp - pitchDown)`.
  - Relative (mouse RMB drag, per-frame deltas): `MoveManager.yawRelative/pitchRelative`.
  - Helpers: `core_camera.getLastFilter()`, `core_camera.timeSinceLastRotation()`,
    `core_camera.getLastCameraMovementType()`.
- **Collision (reuse, don't rewrite):** `ge/extensions/core/cameraModes/collision.lua`
  — required directly by `arcadeOrbit.lua`.
- **Reference orbit camera:** the stock `orbit` camera (the chase camera is built on it;
  game root: `I:\SteamLibrary\steamapps\common\BeamNG.drive\lua`).

## 5. Lua conventions (chase)

- **Effect modules** live in `core/arcadeOrbit/effects/`, each returning a constructor
  (root class pattern) exposing `init()`, `update(data, ctx)`, `reset()`, and setters
  (e.g. `setAmpMultiplier`, `setMinSpeed`). The main camera instantiates them in `init()`,
  pushes settings in `applyConfig()`, calls `update` in a fixed order, and calls `reset()`
  on teleport/vehicle switch.
- **Perlin:** `core/arcadeOrbit/perlin.lua` — `perlin:noise(x,y,z)` ∈ [-1,1];
  `perlin:OctavePerlin(x,y,z,octaves,amplitude,frequency)`. For per-frame shake, prefer
  the LUT-sampling approach in `core/cameraModes/speedshake.lua` over calling `noise()`
  per octave.

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

## 7. Chase Vue specifics

- The chase panel is `ui/ui-vue/mods/enhanceddriver/ArcadeChaseSettings.vue`. The pause-menu
  button is registered by `arcadeChaseDemo.js` — id `arcadeOrbit.settings`, label
  **"ACC Settings"** — and is created/removed dynamically with the demo gate (§3). The
  interior panel's button is registered separately by the folder-root `index.js`; a planned
  single tabbed shell for both panels is **not yet implemented**.
- Sections are driven by the `SECTIONS` array in `ArcadeChaseSettings.vue`; slider rows use
  `ArcadeChaseSettingSlider.vue` (the shared 2-col grid row pattern).
- **Widening the mod card:** the non-scoped `<style>` block in `ArcadeChaseSettings.vue`
  targets the host card with
  `.pause-layout .menu-content-card-1:has(> .card-cnt > .pause-main-card > .aoc-settings)`.
- **Settings persistence (chase):** stored to `/arcadeOrbitSettings.json`
  (`{ chosenPreset, presets = { … } }`) with shipped defaults in
  `lua/ge/extensions/core/arcadeOrbit/arcadeOrbitDefaults.json`; the JS side saves with
  `jsonWriteFile('/arcadeOrbitSettings.json', …)` and then calls
  `arcadeOrbitReloadSettings()` to reload the Lua cameras.

## 8. Testing specifics

- Enable "Enable Arcade Chase Camera" in the interior settings panel, switch to the camera
  (camera menu → "Arcade Chase Camera"), drive at speed, drift, hit crests/valleys, and
  brake hard to exercise each effect; check the **ACC Settings** button updates live.

## 9. Definition of done (per chase feature)

- Effect implemented in its own `core/arcadeOrbit/effects/<name>.lua` file and composed by
  `arcadeOrbit.lua`.
- All of its parameters exposed in the chase settings panel and stored in the settings JSON.
- Respects the active preset (e.g. shake off in **Smooth**).
- Resets cleanly on teleport / vehicle switch (see §3; ignore the teleport-frame phantom
  spike).
- No new per-frame allocations in the hot path.
- New/renamed modules added to both module-cache lists (root `AGENTS.md` §1).
- The demo gate (§3) still works: camera + ACC button hidden until the interior panel's
  switch is turned on.

## 10. Known issues

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
