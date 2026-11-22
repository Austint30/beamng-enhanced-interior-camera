# Arcade Chase Camera — Requirements

> Feature spec for the chase camera (`arcadeOrbit`, gated behind "Enable Arcade
> Chase Camera" in the EIC settings panel). The companion docs live alongside this
> file — [`README.md`](README.md) (overview) and [`AGENTS.md`](AGENTS.md)
> (notes/gotchas) — plus the repo-root `AGENTS.md` for suite-wide conventions.
> The file-structure listings below are the spec's working layout; this repo's
> actual layout is documented in the root `AGENTS.md`.

A DriveClub-style arcade chase camera for BeamNG.drive, built on top of the stock
orbit camera. The camera sits behind the vehicle and "looks where the car is going"
by blending the velocity direction with the vehicle's forward vector, then layers on
speed/drift shake, acceleration (crest/valley) response, collision jerk, a sustained
cornering lean-in, a speed-based dynamic FOV, and a stable **tumble-mode** camera pose.
Camera control is selectable among **turntable modes** (Static / Static+ / Dynamic /
Crank). All parameters are user-configurable through a Vue settings UI with presets.

## 1. Goals

- Feel like a game arcade chase cam (DriveClub reference), not a neutral tool cam.
- Every effect is independently tunable and can be toggled off.
- Two shipping presets: **Default** (all effects on, including shake) and **Smooth**
  (shake disabled, gentler motion).
- Clean, modular code: each camera effect lives in its own file under
  `core/arcadeOrbit/features/` and is composed by the main `arcadeOrbit.lua`.

## 2. Non-goals / Out of scope (for now)

- VR-specific behaviour beyond what the base camera already handles.
- Presets beyond the two named above (the preset *system* should still support adding
  more later, mirroring the reference mod).
- Reimplementing orbit-camera collision, zoom, or manual-rotation handling — reuse it.

## 3. Camera base

- Base the camera on the stock **orbit camera** (`orbitOriginal.lua`), keeping its
  positioning (behind-car offset), distance/zoom, collision, and manual mouse rotation.
- **Remove** the orbit camera's "dynamically adjusts camera pitch with speed" feature.
  Concretely, drop the machinery that varies pitch based on `upperSpeedThreshold` /
  `lowerSpeedThreshold`:
  - `calculateDynamicPitchLimit()` and its call sites
  - `smoothedPitchOffset`, `dynamicPitchQuat`, `aboveCamPitchThreshold`,
    `belowThresholdTimer`, `maxDynamicPitch`
  - the pitch-threshold block in `update()` (the `timeSinceManualRotation > 1` branch
    that computes `dynamicPitch` and multiplies `resultRot` by `dynamicPitchQuat`)
  - the `cameraOrbitMaxDrivingPitch` setting read
- The separate "dynamic offset" (height) behaviour driven by `maxDynamicOffset` is a
  distinct feature; keep it only if it does not conflict with the new acceleration
  height response (Section 5). Prefer the new acceleration-driven height for that role.

## 4. Core chase behaviour — velocity-follow aim

- The camera's horizontal aim (yaw) follows a direction that is a weighted blend of the
  vehicle **velocity vector** and the vehicle **forward vector**:
  - ~**80% velocity** + ~**20% forward** by default.
  - `aimDir = normalize( w * velocityDir + (1 - w) * forwardDir )`, `w` default `0.8`.
- This makes the camera swing to look where the car is going during corners/drifts,
  rather than being locked to the car's heading.
- The vertical aim (pitch) and camera height remain driven by the base orbit camera
  plus the acceleration response in Section 5.
- Expose the velocity weight as a setting (`followVelocityWeight`, 0–1, default 0.8).
- Interaction with manual mouse rotation: velocity-follow is the *base* aim; manual
  rotation should still be able to override/offset it (resolve exact precedence during
  implementation, but manual input must never be permanently overridden).

### 4.1 Base framing — camera height and base pitch

- **Camera height** (`cameraHeight`): the camera's vertical position above the vehicle,
  in meters, added **on top of the vehicle's bounding box**. This is a first-class,
  predictable parameter.
  - Note: the stock orbit camera does sit above the car, but its height is implicitly
    `distance × sin(pitch)` relative to the vehicle **center/ref node** — it does **not**
    explicitly use the bounding-box top (the bbox is only used by
    `calculateDynamicPitchLimit`, which we are removing). Making `cameraHeight` explicit
    is therefore a small restructure of the base positioning; keep the orbit camera's
    distance/zoom/collision/manual-rotation, but drive the vertical position from
    `cameraHeight` rather than from pitch.
- **Base pitch** (`basePitch`): a **constant** pitch (look-down) angle applied to the
  camera, in degrees. **Default 3° down** (positive = looking down). This is the resting
  look angle before velocity-follow and acceleration/collision effects are applied.
- Together these define the base chase-cam framing:
  - camera vertical position = top of vehicle bounding box + `cameraHeight`
  - camera look pitch = `basePitch` (down) + velocity/accel/collision offsets
  - camera distance back = orbit distance (retained)

### 4.2 Turntable (camera control) modes

The user's camera-rotation input (gamepad right-stick or mouse) is interpreted by one of
four selectable **turntable modes** (setting `turntableMode`). A shared **input
normalization** step first produces a normalized 2D stick vector `(x, y)` in `[-1, 1]²`:

- **Gamepad right-stick:** `x = yawRight - yawLeft`, `y = pitchUp - pitchDown`
  (raw 0–1 values → normalized to -1..1).
- **Mouse (right-click + drag):** the per-frame relative deltas
  (`MoveManager.yawRelative` / `pitchRelative`) are integrated into a virtual stick
  position (clamped to `[-1, 1]²`) while the button is held, and decay back to center on
  release / idle.
- If the raw inputs are not already normalized, normalize them in this function.
- Source detection: `core_camera.getLastFilter()` (KBD/PAD/MOUSE);
  `core_camera.timeSinceLastRotation()` for idle timing.

Modes:
1. **Static** — behaves like the stock orbit camera: rotate with stick/mouse, and the
   camera **stays where you leave it** (no auto-center). Reuse the orbit camera's
   manual-rotation accumulation.
2. **Static+** — same as Static, but if no rotation input for an adjustable delay
   (default **4 s**), the camera **smoothly resets to the forward** (default) rotation.
3. **Dynamic** — stick *position* maps directly to the camera pose (returns to straight
   when centered):
   - `x = 0` → camera straight (forward).
   - `x → +1` → yaw **+180°** (looking backwards); `x → -1` → yaw **-180°**.
   - `y → -1` (stick down) → camera pitches **up** and drops to near **ground level**
     (as low as possible while keeping the car in frame).
   - `y → +1` (stick up) → camera pitches **down** (default **70%**) and rises **above**
     the car.
   - Mouse right-click + drag acts as the stick.
4. Dial — the camera **points where the stick
   points**; **no pitch** in this mode:
   - `x = 0, y = 0` → straight.
   - stick right → **+90°**; left → **-90°**; up-right 45° → **45°**; stick back (down) →
     **backwards (180°)**.
   - i.e. yaw ≈ `atan2(x, y)` (up = forward, right = +90°, down = 180°, left = -90°).
   - **Vertical input is dead from +1 to -0.75** (stick inside the fixed
     horizontal deadzone): the camera does not move at all — partial
     vertical pulls never produce partial dial angles. Past **-0.75** the
     target changes to the direction of the joystick regardless of
     magnitude (full deflection — a back pull lands at the full back pose;
     the jump from the held target snaps instantly via the target-flip
     rule, as a side effect). Horizontal/diagonal input is analog: the
     direction is always the true stick direction, so slow sweeps through
     any quadrant are monotonic (no reversal, no hitch at back); partial
     input interpolates between straight and the intended direction.
   - **Deadzone** — a fixed 5 % constant (deliberately not user-facing) — no
     rotation until the stick moves past it.
   - **Target-flip snap** — if the commanded target flips ~180° (±5°) from
     the camera's current direction in one frame (flicking the stick from
     forward to back, or releasing the stick from the back position), it is
     taken instantly (the input smoothing is skipped). The snap is purely
     target-based — it does not depend on where the stick is aimed.
   - The **Look Back** action (right-stick click) emulates holding the stick
     at straight-back (the same full back pose through the same math), and
     snaps when that is a ~180° flip from the current direction.
   - Compatible with right-click + mouse drag.

## 5. Camera effects

Each effect is a separate module in `core/arcadeOrbit/features/` exposing at minimum
`init()`, `update(data, ctx)`, `reset()`, and any setters. The main camera composes
them in a defined order and multiplies each effect's contribution by a global
"camera effect factor" (so they can be globally suppressed on teleport/reset, as the
reference `enhanceddriver` does).

### 5.1 Speed shake (perlin)

- Apply **perlin noise** (see `core/arcadeOrbit/perlin.lua`) to the camera **rotation** on
  the **pitch** and **yaw** axes.
- Strength ramps from 0 at a minimum speed up to a **maximum strength** at the maximum
  speed (linear or smooth ramp; configurable).
- Reference implementation to model after: this repo's
  `lua/ge/extensions/core/cameraModes/speedshake.lua`
  (LUT-based perlin sampling, `data.res.rot = data.res.rot * q`).
- Configurable: amplitude, frequency, detail (octaves), min speed, max speed, max
  strength.

### 5.2 Drift / burnout shake (perlin)

- **Drift (implemented)** — slip angle between the vehicle velocity and the vehicle
  forward (velocity-vs-forward): the velocity is rotated into the car's local frame
  (local Y = vehicle forward), its vertical component dropped, and the angle between
  vehicle forward and the flattened velocity is the slip angle (slip-angle technique,
  cf. `enhanceddriver.lua:833-848`).
- The effect is **silent below `driftShake_minAngle`** (the minimum drift angle the
  driver must achieve, default **0°**), then ramps from 0 to **100% as the slip angle
  reaches `driftShake_maxAngle`** (default **30°**), and stays at full strength above
  both — and a forward or a reverse drift of the same angle gives the **same** strength
  (angles past 90° mirror back toward 0 at 180°).
 - The shake also fades in with speed from 0 up to `driftShake_maxSpeed` (default
   **35.4 m/s, ≈ 127 km/h / 79 mph**), so parked / sliding-in-place motion stays quiet.
- Apply perlin noise (LUT sampling, as §5.1) to the camera rotation (**yaw, pitch,
  optionally roll**) scaled by the drift metric. Configurable: per-axis amplitude
  (degrees), frequency, detail (octaves), min angle, max angle, max speed.
- **Falling gate:** while the car's z acceleration is ≤ **−9.8 m/s²** (≥ 1 g downward,
  i.e. airborne / falling) the shake multiplier is **0**.
- Resets cleanly on teleport / vehicle switch (no spikes, no NaNs).
- **Burnout (deferred)** — rear-wheel slip (rear tires spinning) as a second independent
  signal contributing to shake. BeamNG exposes no wheel/slip API at the camera layer, and
  velocity/angular-velocity proxies were explicitly rejected, so the burnout signal (with
  its burnout weight + slip threshold) is deferred until a wheel-slip data source is
  viable. The drift metric and settings keys are already in place.

### 5.3 Acceleration response (crest / valley)

- Compute vehicle acceleration from frame-to-frame velocity change when no direct API
  is available: `a = (data.vel - data.prevVel) / data.dtSim` (world space), then
  transform into the vehicle frame using the vehicle rotation.
- The camera should follow the vehicle's **pitch at a slower rate than its yaw**.
- Normal-force (vertical g) response, using the upward acceleration relative to 1 g:
  - **> 1 g upward** (downforce into a valley): camera **lowers in height** (bounded by
    a configurable max) and **pitches up slightly**.
  - **< 1 g upward** (over a crest): camera **rises in height** (bounded by the same
    max) and **pitches down slightly**.
- Smooth the response factor with `newTemporalSmoothingNonLinear`.
- Configurable: strength, max height offset, g-threshold (deviation from 1 g before the
  effect engages), and smoothness.

### 5.4 Collision jerk

- Driven by sudden acceleration above a configurable threshold. Each sub-effect uses
  `newTemporalSmoothingNonLinear` to smooth its effect factor. All magnitudes scale by
  a configurable strength.
- Sub-effects (verify axis sign conventions against the live camera frame during
  implementation; the reference `enhanceddriver.lua` g-force block is a good starting
  point):
  1. **Jerk forward** — sudden **deceleration** (opposite the camera's forward):
     **pitch the camera down**.
  2. **Jerk upward** — sudden **acceleration** (in the camera's forward direction):
     **pitch the camera up**.
  3. **Roll + yaw left** — sudden acceleration in the camera **+x** direction:
     **yaw left** and **roll right**.
  4. **Roll + yaw right** — sudden acceleration in the camera **-x** direction:
     **yaw right** and **roll left**.
- Configurable: threshold (g), strength, and smoothness.

### 5.5 Lean-in (sustained cornering roll)

- A **sustained** camera **roll** that leans the camera into a corner while the vehicle
  is under a sustained **lateral (side) acceleration** — the "driver leaning into the
  turn" feel. This is the *sustained* counterpart to the sudden side jerk in §5.4.
- **Mixed convention** (as the rest of the g-force family): the **force** is the
  vehicle's lateral acceleration projected onto the **camera's right axis** (the
  view's left/right — camera frame, so it reads correctly at any orbit/turntable
  angle), smoothed with `newTemporalSmoothingNonLinear` so the camera **gradually
  enters and exits** the lean (not a snap). The **direction** is a roll of the
  camera around its own **aim axis** (the aim line itself is untouched — only the
  horizon tilts), rolling toward the inside of the turn (direction of the lateral
  force), mirroring the body roll.
- The smoothed signed g maps 0 → `leanInRoll_maxRoll` between `leanInRoll_minG`
  and `leanInRoll_maxG` (symmetric: a leftward acceleration rolls the other way)
  via a **smoothstep curve**, so the roll **levels out** (zero slope) as it
  engages near `minG` and as it saturates near `maxG` — a gentle S-curve rather
  than a hard linear ramp.
- Applied even while `lockCamera` is held; reset on teleport / vehicle switch
  (and the teleport-frame phantom spike is ignored).
- Configurable: `leanInRoll_minG` (g, dead zone), `leanInRoll_maxG` (g, full
  strength), `leanInRoll_maxRoll` (degrees), `leanInRoll_smoothness` (s),
  `leanInRoll_enabled`.
  Defaults: **0.2 g** min, **1.5 g** max, **5°**, **0.3 s**, on.

### 5.6 Dynamic FOV

- Increase FOV as speed rises above a threshold, up to a maximum at a max-speed
  threshold.
- Smooth the change with `newTemporalSmoothingNonLinear`.
- Configurable: additional FOV (degrees), start speed threshold, max speed threshold,
  and smoothness.
- **Disabled while tumble mode (§5.7) is active** (and during its in/out transitions).
- Reference: `enhanceddriver.lua` `updateFovSpeedMod()`.

### 5.7 Tumble mode

- **Detection** (carried over from the reference `tumbleDetection.lua`): a tumble is
  active while the vehicle's **up vector** sustains roll/pitch angular velocity above a
  threshold for a short delay. Yaw is excluded so flat spins / drifting do **not**
  trigger it. Reuse the reference algorithm; expose the threshold and delay as settings.
- **On tumble start**, capture the vehicle's **last pre-tumble trajectory** (velocity
  direction / heading) as the frozen reference for the pose below.
- **Tumble pose** (all offsets adjustable), applied relative to that frozen trajectory:
  - pitch the camera **down 45°** — a fixed/global downward look, **not** tied to the
    car's live (flipping) orientation;
  - move the camera **back 1 m**;
  - yaw the camera **23° to the left**.
- **Hold** that pose frozen while the tumble continues: do not follow the car's live
  orientation, and **suppress the per-frame effects** (speed/drift shake, acceleration,
  collision jerk, lean-in, and dynamic FOV) for the duration.
- **Transitions** (both times adjustable):
  - blend **into** the tumble pose from the normal pose over an **enter time**;
  - blend **back** to the normal pose over an **exit time** once the tumble ends.
- Reference: `enhanceddriver.lua` `tumbleDetection` usage + `enhanceddriver/tumbleDetection.lua`.

### 5.8 Acceleration camera distance

- Adjusts the camera boom length dynamically based on the vehicle's acceleration projected
  onto the **camera's forward axis** (direction from camera position toward the aim point;
  the previous frame's positions are used to avoid a circular dependency).
- **Accelerating** (positive forward component): camera pulls back — boom length increases
  by up to `accelDistMax` meters.
- **Decelerating** (negative forward component): camera pushes closer — boom length
  decreases by up to `accelDistMax` meters.
- Acceleration is normalised by 1 g (9.81 m/s²): `accelDistMax` is reached at ≥ 1 g of
  forward acceleration/deceleration.
- The offset is **additive** on top of the base orbit distance (does not touch `camDist`;
  applied as a per-frame delta to the computed boom length before the camera position is
  placed).
- Smooth the offset with `newTemporalSmoothingNonLinear`.
- Configurable: `accelDistMax` (m), `accelDistSmoothness`.

### 5.9 Follow smoothing (pitch only)

- Smooths the boom's **pitch** (vertical elevation) so the camera follows the car's
  vertical motion (bumps) gradually rather than instantly. It deliberately does
  **not** smooth the crest/valley response (§5.3): that is applied as a crisp
  overlay **after** the smoother, so this time constant does not dampen it.
- Extracts the boom pitch (`asin(z)` of the boom direction), smooths it with
  `newTemporalSigmoidSmoothing`, and reconstructs the direction **preserving the
  boom's azimuth (world yaw) exactly** — only the elevation changes.
- Applied to the boom direction **before velocity aim and speed shake**, so those
  consume the smoothed boom. The **crest/valley height + pitch offsets (§5.3) are
  applied AFTER the smoother** (height = a parallel shift of the target, pitch = an
  aim tilt), so they stay crisp. The stock input smoothing on user rotation is
  untouched and runs on the user-offset as before.
- The boom **azimuth is deliberately left stock-instant**: the stock anchor/parity
  flip must stay atomic and invisible (boom mirror + orbit parity cancel in the
  same frame). Easing the boom yaw desynchronised it from that invariant and
  produced visible flip glitches while reversing (verified empirically).
- Smoothness is a **time constant in seconds**: higher = more smoothing = slower
  response. `0.1` = snappy, `0.5` = moderate, `2.0` = very smooth.
- Configurable: `followSmoothing_pitchSmooth` (s). In the settings UI it sits next
  to **Follow vehicle direction** — BeamNG's official name (`ui.options.camera.cameraOrbitRelaxation`)
  for the orbit camera's `relaxation` setting ("Lower values = tighter camera
  behavior").
- **Flip interaction:** the stock anchor/parity flip must stay atomic (the boom
  mirror and the orbit parity cancel in the same frame, keeping the flip
  invisible). Two guards enforce that:
  - When a flip fires, the pitch smoother is **adopted** — snapped to the new
    boom pitch for that frame — instead of chasing the flip over its time
    constant (chasing is what turned flips into a visible pitch/height wobble).
  - **Stopped flip guard:** below `STOP_FLIP_SPEED` (~1 km/h) the stock flip
    test is skipped. Stopped, its displacement is ~0 and its sign is sim/
    suspension jitter that toggles anchor/parity every frame — a tilted orbit
    then wobbles pitch/height ("looks up, moves down, …"). While driving the
    test is byte-identical to the stock orbit camera.

### 5.10 Speed-based camera distance

- Increases the camera boom distance as the vehicle's **speed** rises, so the camera
  gradually pulls back on speed builds and eases back in on the brakes.
- Speed = `data.vel:length()` (m/s) — **not** `data.speed` (the UI camera-speed
  modifier; see §9).
- Target offset = `speedDistance_maxDist` × (speed ÷ `speedDistance_maxSpeed`),
  clamped at `speedDistance_maxDist` once speed reaches `speedDistance_maxSpeed`;
  zero at standstill.
- The offset is **additive** on top of the base orbit distance (does not touch
  `camDist`; applied as a per-frame delta to the computed boom length), and is applied
  **before** the acceleration/deceleration distance modifier (§5.8) — the accel/decel
  offset stacks on top of the speed-based offset.
- Smooth the offset with a temporal smoother (time constant in seconds; higher = more
  smoothing); it eases in as speed rises and eases back toward the base distance as
  speed falls.
- **Brake cancellation:** while the car is decelerating, the offset is scaled down so
  the camera eases back toward the car during braking:
  `offset × (1 − strength × min(deceleration ÷ maxDecel, 1))`. No cancellation from
  0 g up; the scaling reaches `strength` at `maxDecel` and stays clamped above it.
  `strength` is stored 0–1 (settings/UI use 0–100 %); `maxDecel` is in g. Deceleration
  = loss of speed (|v| slope), smoothed with a 0.1 s time constant to filter sim
  jitter.
- **Velocity mode** (`speedDistance_velocityMode`, switch, default **off**): apply
  the offset to the camera TARGET (the orbit anchor) along the vehicle's live
  velocity direction instead of extending the boom distance — the anchor is
  displaced **opposite the direction of travel**, and the camera follows it
  through the standard positioning math (nothing moves the camera directly):
  the rig pulls back along the travel line, the car slides ahead in frame as
  speed builds, and during drifts the pull follows the actual travel line
  rather than the boom axis. Magnitude, smoothing, and brake cancellation
  are unchanged; at near-zero speed no offset is applied.
- Reset the smoother and offset on `data.teleported` / vehicle switch (no spikes).
- Configurable: `speedDistance_maxDist` (m), `speedDistance_maxSpeed` (m/s internally,
  displayed in the user's unit), `speedDistance_smoothness` (s, time constant),
  `speedDistance_brakeDecel` (g), `speedDistance_brakeStrength` (0–100 %),
  `speedDistance_velocityMode` (bool).
  Defaults: **0.2 m** max distance, **134.74 m/s (≈ 301 mph / 485 km/h)** max speed,
  0.5 s smoothing, 1.0 g brake max deceleration, 100 % brake cancellation.

### 5.11 Brake pitch (sustained braking decel)

- Phase-4 g-force family, braking direction: a sustained **downward pitch of the
  camera** while the vehicle decelerates (braking), complementing the vertical
  (normal-force) crest/valley response of §5.3.
- **Mixed convention:**
  - The **force (magnitude)** is measured in the **camera's frame** —
    longitudinal deceleration, the frame-to-frame velocity change projected
    onto the camera's look direction. The chase cam flips to face the
    direction of travel when reversing, so "forward" for the viewer is the
    view direction, and a hard brake (or a reverse-into-wall) engages it
    identically in forward or reverse.
  - The **direction** moves the **aim target** up/down **in camera space** (a
    few metres): the camera position stays put and simply re-aims at the
    shifted point (the reference enhanceddriver g-force feel). The resulting
    pitch is `atan(offset / camera-to-aim distance)`, so the same offset reads
    larger at close range — and a large target travel survives the pipeline's
    low-pass filtering far better than a small angular nudge.
 - The pitch is **silent below `brakePitch_minG`** (dead zone, default
   **0.5 g**), ramps 0 → `brakePitch_maxOffset` between `brakePitch_minG` and
    `brakePitch_maxG`, and is clamped at full strength above that.
 - Smoothness is a **time constant in seconds** (same rate for attack — braking —
  and release — coasting): higher = smoother / lazier.
- No spikes on release and no reaction while the car accelerates or coasts;
  complements §5.3 (vertical g) — both can be active at once.
- **Applied even while the user holds a manual camera lock** (`lockCamera`):
  both the measured g (projected on the camera's look direction) and the aim
  tilt (around the camera's right axis) follow the live camera pose, so the
  effect reads relative to wherever the user has moved the camera.
- Reset on `data.teleported` / vehicle switch.
- Configurable: `brakePitch_minG` (g, dead zone), `brakePitch_maxG` (g),
  `brakePitch_maxOffset` (m of aim-target travel down), `brakePitch_smoothness`
  (s), `brakePitch_enabled`.
  Defaults: **0.5 g** min, **2.0 g** max, **1 m**, **0.7 s**, on.

### 5.12 Jolts (sudden decel / accel impacts)

- Two **event-triggered animations**, driven by the *change* in acceleration
  (jerk) rather than its level — unlike brake pitch (§5.11), which follows the
  sustained g level:
  - **`decelJolt`** — a sudden **deceleration** (e.g. hitting something)
    animates the aim **down**.
  - **`accelJolt`** — a sudden **acceleration** (e.g. being hit from behind)
    animates the aim **up** (mirror image).
- Pipeline (per effect, **camera frame** — the vehicle's acceleration
  projected onto the camera's look direction; the chase cam faces the
  direction of travel, so a reverse-into-wall is a camera-frame
  DECELERATION, not an acceleration):
  1. The camera-frame longitudinal g is smoothed (time constant
     `*_accelSmooth`, s).
  2. **Jerk** = the frame-to-frame change of that estimate (g/s).
  3. A jerk above `*_minJerk` **triggers** the animation; its blend-in
     strength = the jerk ramped 0→1 between `*_minJerk` and `*_fullJerk` —
     the impact's strength scales how strongly the animation blends in. A
     stronger impact while the animation is playing **deepens** it (strength
     takes the max; the timer is NOT reset — a hard restart would visibly cut
     the dip off mid-taper); a new animation starts only when idle.
   4. The animation: a **fast dart** to `*_maxRotation` over the first
      `*_attack` share of `*_duration`, then a **damped-cosine settle** back
      to basis over the rest — the aim returns, swings past baseline by
      ~`*_wobble` (the rebound) and stills (the decay envelope reaches 1 % at
      the end of the duration; wobble 0 = a plain exponential return). The
      damped rebound is what reads as physical instead of a canned S-curve.
- Applied as a direct aim rotation (radians, exact at any zoom) with the
  camera position fixed — summed with the brake-pitch target offset's
  rotation (§5.11).
- Share the teleport / vehicle-switch reset of §5.11 — and the modules also
  ignore the phantom velocity spike on the teleport frame itself (`data.vel`
  is zeroed while `data.prevVel` still holds the old speed, which would read
  as a hundreds-of-g impact), so rewinds and recovers never trigger a jolt or
  a brake-pitch push. Like brake pitch, the jolts are applied while the user
  holds a manual camera lock (`lockCamera`), relative to the moved camera's
  direction.
- Configurable per effect: `decelJolt_minJerk` / `accelJolt_minJerk` (g/s),
  `decelJolt_fullJerk` / `accelJolt_fullJerk` (g/s),
  `decelJolt_maxRotation` / `accelJolt_maxRotation` (°),
  `decelJolt_duration` / `accelJolt_duration` (s),
  `decelJolt_attack` / `accelJolt_attack` (0–100 %, stored as %; the dart's
  share of the duration),
  `decelJolt_wobble` / `accelJolt_wobble` (0–100 %, stored as %; the rebound's
  share of the max angle; 0 = plain exponential return),
  `decelJolt_accelSmooth` / `accelJolt_accelSmooth` (s),
  `decelJolt_smooth` / `accelJolt_smooth` (s, temporal smoothing over the
  final value; **0 = bypassed, the raw animation value is used unchanged**),
  `*_enabled`.
  Defaults (decelJolt / accelJolt): **100 g/s** min jerk, **196 / 191 g/s** full
  jerk, **45°**, **1 s** duration, **5 %** attack, **10 / 20 %** wobble,
  **0.15 s** accel smoothing, **0.1 s** result smoothing, on.

## 6. Settings UI

- Use the **new BeamNG Vue UI** (reference: this repo's
  `ui/ui-vue/mods/enhanceddriver/`).
- Register a **pause-menu button** via `lua.extensions.ui_pause_actions.registerModButton`
  (see reference `index.js`).
- A settings panel (`ArcadeOrbitSettings.vue`) with a **preset picker** and
  `SettingSlider.vue` rows for each parameter, grouped into sections (e.g. Chase,
  Shake, Acceleration, Collision, FOV).
- **Presets**: ship **Default** (all effects on, including shake) and **Smooth**
  (shake disabled, gentler motion). The preset system should allow user-created
  presets like the reference (save/load to settings).
- Persist settings as a single JSON object in BeamNG settings (e.g. key
  `arcadeOrbitSettings`), read on the Lua side with `settings.getValue('arcadeOrbitSettings')`
  and applied on the JS side with `useSettings().apply({ arcadeOrbitSettings = ... })`.
- Display speeds in the user's configured unit (km/h or mph), store internally in m/s
  (reference `displayValue`/`toStoredValue` pattern).

## 7. Configuration parameters (defaults are starting points, all tunable)

| Key | Type | Range | Default | Notes |
|-----|------|-------|---------|-------|
| `cameraHeight` | float | 0–5 | 1.5 | Camera height above vehicle bbox (m) |
| `basePitch` | float | -45–45 | 3 | Constant look-down angle (°), + = down |
| `turntableMode` | enum | Static / Static+ / Dynamic / Crank | Static | Camera control scheme |
| `staticPlusResetDelay` | float | 0–30 | 4 | Static+ idle reset delay (s) |
| `dynamicMaxYaw` | float | 0–180 | 180 | Dynamic max yaw (°) |
| `dynamicMaxPitch` | float | 0–100 | 70 | Dynamic max pitch (%), stick up = look down |
| `crankMaxYaw` | float | 0–180 | 90 | Crank max yaw (°) |
| `mouseDragSensitivity` | float | 0–10 | 1 | Mouse-drag → stick scale |
| `followVelocityWeight` | float | 0–1 | 0.8 | Velocity vs forward aim blend |
| `speedShakeAmp` | float | 0–10 | 5.5 | Speed shake amplitude |
| `speedShakeFreq` | float | 0–10 | 0.2 | Speed shake frequency |
| `speedShakeDetail` | int | 1–10 | 3 | Perlin octaves |
| `speedShakeMinSpeed` | speed | 0–400 | 15 | m/s internally |
| `speedShakeMaxSpeed` | speed | 0–400 | 70 | m/s internally |
| `speedShakeMaxStrength` | float | 0–50 | 13 | Max shake strength |
| `driftShakeAmp` | float | 0–10 | 5.5 | Drift/burnout shake amplitude |
| `driftShakeFreq` | float | 0–10 | 1.8 | Drift/burnout shake frequency |
| `driftShakeDetail` | int | 1–10 | 3 | Perlin octaves |
| `driftShakeDriftWeight` | float | 0–1 | 1.0 | Drift contribution |
| `driftShakeBurnoutWeight` | float | 0–1 | 1.0 | Burnout contribution |
| `burnoutSlipThreshold` | float | 0–1 | 0.3 | Rear slip to count as burnout |
| `accelPitchStrength` | float | 0–5 | 1.0 | Crest/valley pitch strength |
| `accelPitchHeightMax` | float | 0–2 | 0.5 | Max height offset (m) |
| `accelPitchGThreshold` | float | 0–40 | 0.2 | g deviation before engaging |
| `accelPitchSmoothness` | float | 0–100 | 50 | Smoothing |
| `collisionJerkThreshold` | float | 0–100 | 0.5 | g threshold |
| `collisionJerkStrength` | float | 0–5 | 1.0 | Jerk strength |
| `collisionJerkSmoothness` | float | 0–100 | 50 | Smoothing |
| `leanInRoll_minG` | float | 0–5 | 0.2 | Dead zone — no roll below this lateral g (camera frame) (§5.5) |
| `leanInRoll_maxG` | float | 0.1–10 | 1.5 | Lateral g at which the full roll is reached (g) (§5.5) |
| `leanInRoll_maxRoll` | float | 0–30 | 5 | Max camera roll at full lateral g (°) (§5.5) |
| `leanInRoll_smoothness` | float | 0.05–2 | 0.3 | Roll time constant in/out (s) (§5.5) |
| `dynamicFovAddDegrees` | float | 0–50 | 5 | Max FOV increase |
| `dynamicFovMinSpeed` | speed | 0–400 | 45 | m/s internally |
| `dynamicFovMaxSpeed` | speed | 0–400 | 87 | m/s internally |
| `dynamicFovSmoothness` | float | 0–100 | 90 | Smoothing |
| `tumbleEnabled` | bool | | true | Enable tumble mode |
| `tumblePitchDown` | float | 0–90 | 45 | Downward pitch offset (°) |
| `tumbleYawLeft` | float | -90–90 | 23 | Left yaw offset (°) |
| `tumbleBackDistance` | float | 0–5 | 1 | Backward offset (m) |
| `tumbleEnterTime` | float | 0–5 | 0.5 | Transition-in time (s) |
| `tumbleExitTime` | float | 0–5 | 0.8 | Transition-out time (s) |
| `tumbleDetectThreshold` | float | 0–360 | 45 | deg/s roll/pitch to count as a tumble |
| `tumbleDetectDelay` | float | 0–2 | 0.3 | Sustained time before confirming |
| `accelDistMax` | float | 0–5 | 1.5 | Max boom length change from acceleration (m) |
| `accelDistSmoothness` | float | 0–100 | 50 | Smoothing rate |
| `relaxation` ("Follow vehicle direction" in the UI) | float | 1–10 | 3 | Orbit anchor radius — how tightly the camera follows the vehicle's direction; lower = tighter behavior |
| `followSmoothing_pitchSmooth` | float | 0.1–10 | 3.5 | Boom pitch follow time constant (s) — yaw smoothing intentionally absent (§5.9) |
| `speedDistance_maxDist` | float | 0–5 | 0.2 | Max additional boom distance at max speed (m) (§5.10) |
| `speedDistance_maxSpeed` | speed | 0–400 | 134.74 | Speed at which the full offset is reached (m/s internally; 134.74 ≈ 301 mph / 485 km/h) (§5.10) |
| `speedDistance_smoothness` | float | 0.05–10 | 0.5 | Speed-distance offset time constant (s); higher = smoother (§5.10) |
| `speedDistance_brakeDecel` | float | 0.1–5 | 1.0 | Max deceleration before full brake cancellation (g) (§5.10) |
| `speedDistance_brakeStrength` | float | 0–100 | 100 | Brake cancellation strength at max deceleration (0–100 %) (§5.10) |
| `speedDistance_velocityMode` | bool | | false | Apply the offset to the camera target (orbit anchor displaced opposite travel; the camera follows) instead of extending the boom distance (§5.10) |
| `brakePitch_minG` | float | 0–4.5 | 0.5 | Dead zone — no pitch below this deceleration (g) (§5.11) |
| `brakePitch_maxG` | float | 0.1–5 | 2.0 | Braking g-force at which the full pitch is reached (g) (§5.11) |
| `brakePitch_maxOffset` | float | 0–10 | 1 | Aim-target travel down at full deceleration (m, camera space; camera stays put) (§5.11) |
| `brakePitch_smoothness` | float | 0.05–2 | 0.7 | Pitch time constant (s); higher = smoother (§5.11) |
| `decelJolt_minJerk` | float | 0–100 | 100 | Jerk (g/s) that triggers the jolt (§5.12) |
| `decelJolt_fullJerk` | float | 1–200 | 196 | Jerk (g/s) at 100 % blend-in; ramps from Min Jerk (§5.12) |
| `decelJolt_maxRotation` | float | 0–90 | 45 | Aim rotation down at a full-strength jolt (°) (§5.12) |
| `decelJolt_duration` | float | 0.2–3 | 1 | Down-and-back animation length (s) (§5.12) |
| `decelJolt_attack` | float | 5–95 | 5 | The dart's share of the duration (0–100 %) (§5.12) |
| `decelJolt_wobble` | float | 0–100 | 10 | First-rebound swing past baseline, as % of the max angle (0 = plain decay) (§5.12) |
| `decelJolt_accelSmooth` | float | 0.05–0.5 | 0.15 | Acceleration-estimate time constant for jerk detection (s) (§5.12) |
| `decelJolt_smooth` | float | 0–1 | 0.1 | Temporal smoothing over the final jolt value (s; 0 = off, raw value) (§5.12) |
| `accelJolt_minJerk` | float | 0–100 | 100 | Jerk (g/s) that triggers the jolt (§5.12) |
| `accelJolt_fullJerk` | float | 1–200 | 191 | Jerk (g/s) at 100 % blend-in; ramps from Min Jerk (§5.12) |
| `accelJolt_maxRotation` | float | 0–90 | 45 | Aim rotation up at a full-strength jolt (°) (§5.12) |
| `accelJolt_duration` | float | 0.2–3 | 1 | Up-and-back animation length (s) (§5.12) |
| `accelJolt_attack` | float | 5–95 | 5 | The dart's share of the duration (0–100 %) (§5.12) |
| `accelJolt_wobble` | float | 0–100 | 20 | First-rebound swing past baseline, as % of the max angle (0 = plain decay) (§5.12) |
| `accelJolt_accelSmooth` | float | 0.05–0.5 | 0.15 | Acceleration-estimate time constant for jerk detection (s) (§5.12) |
| `accelJolt_smooth` | float | 0–1 | 0.1 | Temporal smoothing over the final jolt value (s; 0 = off, raw value) (§5.12) |

Preset definitions:
- **Default** — user-tuned baseline (all effects on).
- **Smooth** and **Intense** — currently ship as identical copies of the same
  baseline (user-tuned); treat them as starting points to differentiate once
  distinct feels are wanted (e.g. Smooth = shake off / softer, Intense = stronger).

## 8. File structure

```
enhanced-camera-suite/
├── lua/ge/extensions/core/cameraModes/
│   └── arcadeOrbit.lua                 # main camera mode (composes effects) — MUST be here
├── lua/ge/extensions/core/arcadeOrbit/ # helper modules (SIBLING dir, NOT under cameraModes/)
│   ├── perlin.lua                      # perlin noise (already present; relocated here)
│   ├── tumbleDetection.lua             # §5.7 tumble detector (carried over)
│   └── features/
│       ├── turntable.lua               # §4.2 camera control modes + input normalization
│       ├── velocityFollow.lua          # §4 velocity/forward aim blend
│       ├── speedShake.lua              # §5.1 perlin speed shake
│       ├── driftShake.lua              # §5.2 drift shake (burnout signal deferred)
│       ├── accelerationPitch.lua       # §5.3 crest/valley height + pitch
│       ├── collisionJerk.lua           # §5.4 sudden accel/decel jerk
│       ├── leanInRoll.lua              # §5.5 sustained cornering roll (camera frame)
│       ├── dynamicFov.lua              # §5.6 speed-based FOV
│       ├── tumbleMode.lua              # §5.7 tumble pose + transitions
│       ├── accelDistance.lua           # §5.8 acceleration-driven camera distance
│       ├── followSmoothing.lua         # §5.9 boom follow smoothing (pitch only)
│       ├── speedDistance.lua           # §5.10 speed-based camera distance
│       ├── brakePitch.lua              # §5.11 braking pitch-down (Phase 4)
│       ├── decelJolt.lua               # §5.12 sudden-decel impact jolt (down)
│       └── accelJolt.lua               # §5.12 sudden-accel impact jolt (up)
├── ui/ui-vue/mods/arcadeOrbit/
│   ├── index.js                        # register pause-menu button
│   ├── ArcadeOrbitSettings.vue         # settings panel + presets
│   └── SettingSlider.vue               # reusable slider row
├── locales/translations/en-US/arcadeOrbit.translation.json
│   └── "ui.camera.mode.arcadeOrbit": "Arcade Chase Camera"
├── package.ps1                         # zip locales/ + lua/ + ui/ into dist/
├── REQUIREMENTS.md
└── AGENTS.md
```

> **Location is mandatory:** BeamNG only auto-registers camera modes found in
> `lua/ge/extensions/core/cameraModes/`, and it loads every `*.lua` there **recursively**
> as a camera (`require('core/cameraModes/' .. <filename>)`). So the camera **must** be in
> that dir, but helper `.lua` files must **not** be in a subdirectory of it (they get loaded
> as cameras and fail). Helpers live in the sibling dir `lua/ge/extensions/core/arcadeOrbit/`.
> The current scratch files under `lua/ge/cameraModes/` are **not** discovered and were relocated.

## 9. Technical constraints / API notes

- **Camera registration:** filename = camera name. `arcadeOrbit.lua` → camera
  `arcadeOrbit`, menu label from locale `ui.camera.mode.arcadeOrbit`.
- **`update(data)` contract:** write results to `data.res.pos`, `data.res.rot`
  (quat), `data.res.fov`; set `data.res.collisionCompatible = true`.
- **Frame data available:** `data.veh`, `data.vel`, `data.prevVel`, `data.pos`,
  `data.prevPos`, `data.vehPos`, `data.dt`/`data.dtSim`, `data.teleported`,
  `data.openxrSessionRunning`, `data.lookBack`.
- **Vehicle speed** = `data.vel:length()`. Note `data.speed` is the *UI camera speed
  modifier* (2–100), **not** vehicle speed — do not use it for speed-based effects.
- **Acceleration:** no direct API; compute `(data.vel - data.prevVel) / data.dtSim`.
- **Smoothing:** `newTemporalSmoothingNonLinear(inRate, outRate, start)`;
  `:get(sample, dt)`, `:getWithRate(sample, dt, rate)`, `:set(v)`, `:value()`,
  `:reset()`. Higher rate = faster; `inRate` applies when returning toward 0,
  `outRate` when moving away.
- **Perlin:** `perlin:noise(x,y,z)` ∈ [-1, 1]; `perlin:OctavePerlin(...)`.
- **Reset/teleport:** on `data.teleported` and vehicle switch, reset all effect
  state and smoothers to avoid spikes (reference `suppressCameraEffects()` pattern).

## 10. Open questions / assumptions

- Exact precedence of velocity-follow aim vs manual mouse rotation (assumption:
  velocity-follow is the base aim; manual input offsets/overrides it).
- Whether burnout detection can rely on rear-wheel slip data across all vehicles
  (assumption: use slip where available, velocity/forward proxy otherwise).
- Sign conventions for the collision-jerk left/right and roll directions must be
  verified against the live camera frame (assumption: follow the user's stated
  mapping, flip signs if observed inverted).
- Default numeric values are reasonable starting points and are expected to be
  re-tuned in-game.

## 11. Phased delivery plan

Each phase is **independently testable in-game** and builds on the previous one.
Phases 3–6 are largely independent of one another and can be reordered if priorities
shift. The first phase is the "walking skeleton": a registered, drivable camera.

### Phase 1 — Foundation & base camera (walking skeleton)
- **Goal:** a registered, drivable arcade chase camera with correct base framing and
  velocity-follow aim.
- **Scope:**
  - Relocate scratch files: camera into `lua/ge/extensions/core/cameraModes/arcadeOrbit.lua`,
    helpers into the sibling dir `lua/ge/extensions/core/arcadeOrbit/` (e.g. `perlin.lua`).
  - `arcadeOrbit.lua` from the orbit camera, **minus** the speed-based dynamic-pitch
    feature (§3).
  - Base framing: `cameraHeight` (above bbox) + `basePitch` (default 3° down) (§4.1).
  - Velocity-follow aim, `followVelocityWeight` 80/20 (§4).
  - Composition scaffolding: effect slots, a global "camera effect factor," and
    reset/suppression on `data.teleported` / vehicle switch.
  - Locales entry `ui.camera.mode.arcadeOrbit`.
  - Hardcoded defaults (no settings UI yet).
- **Definition of done:** appears in the camera menu as "Arcade Chase Camera"; follows
  the car; height/pitch/aim feel right; no spikes/NaNs on teleport or vehicle switch.
- **Depends on:** —

### Phase 2 — Settings UI + presets
- **Goal:** user-configurable parameters with presets, persisted.
- **Scope:**
  - Vue: `index.js`, `ArcadeOrbitSettings.vue`, `SettingSlider.vue` (§6).
  - Settings storage: single `arcadeOrbitSettings` JSON object; **Default** and
    **Smooth** presets.
  - Wire the Phase-1 params (`cameraHeight`, `basePitch`, `followVelocityWeight`) into
    the UI and the Lua side.
  - Pause-menu button.
- **Definition of done:** sliders update the camera live; presets switch (Smooth =
  calmer); settings persist across reloads; speeds shown in km/h or mph.
- **Depends on:** Phase 1

### Phase 3 — Shake (speed + drift/burnout)
- **Goal:** perlin shake at speed and during drift/burnout.
- **Scope:** `features/speedShake.lua` (§5.1), `features/driftShake.lua` (§5.2); perlin
  LUT sampling; drift angle + rear-slip burnout; UI sliders; Smooth preset disables
  shake.
- **Definition of done:** shake ramps with speed; drift/burnout shake; off in Smooth;
  no spikes on reset.
- **Depends on:** Phase 2 (UI)

### Phase 4 — G-force family (acceleration, collision jerk, lean-in)
- **Goal:** crest/valley response, sudden-impact jerk, sustained cornering lean-in.
- **Scope:** `features/accelResponse.lua` (§5.3, crest/valley — implemented),
  `features/brakePitch.lua` (§5.11, braking pitch-down), `features/decelJolt.lua` +
  `features/accelJolt.lua` (§5.12, impact jolts), `features/collisionJerk.lua`
  (§5.4), `features/leanInRoll.lua` (§5.5); computed acceleration; thresholds +
  `newTemporalSmoothingNonLinear`; UI sliders.
- **Definition of done:** valley/crest height+pitch; jerk on hard accel/brake/side
  impact; lean-in in corners; all reset cleanly.
- **Depends on:** Phase 2

### Phase 5 — Dynamic FOV + Tumble mode
- **Goal:** speed-based FOV and a stable tumble pose.
- **Scope:** `features/dynamicFov.lua` (§5.6), `tumbleDetection.lua` (carried over) +
  `features/tumbleMode.lua` (§5.7); FOV disabled while tumbling; UI sliders.
- **Definition of done:** FOV grows with speed; tumble pose (down/back/left) holds on
  the pre-tumble trajectory with smooth in/out; FOV off during tumble.
- **Depends on:** Phase 2

### Phase 6 — Turntable control modes

> **Status: implemented.** Delivered as `core/arcadeOrbit/features/turntable.lua` (input
> normalization + the four modes), dispatched from the manual-rotation block in
> `arcadeOrbit.lua`, with the ACC Settings panel's **Turntable** section for the
> UI. See `docs/chase/AGENTS.md` for the gotchas.
>
> **Refinements:** (1) Crank's vertical input (stick inside the fixed
> horizontal deadzone) is dead from +1 to -0.75 — the camera holds its
> target and does not move at all; past -0.75 the target jumps to the
> stick's direction at full deflection regardless of magnitude (a back pull
> lands at the full back pose, snapping instantly as a side effect of the
> target-flip rule). Horizontal/diagonal input is analog: the direction is
> always the true stick direction and the magnitude interpolates past a
> fixed 5 % deadzone constant (the `crankDeadzone` user setting was
> removed), so slow sweeps through any quadrant are monotonic.
> (2) A commanded-target
> flip of ~180° (±5°) from the camera's current direction is taken
> instantly (the input smoothing is skipped) — a stick flick from forward
> to back, releasing the stick from the back position, or the Look Back
> click; the snap is purely target-based, never the stick direction.
> (3) The game's **Look Back** action (right-stick click on gamepad
> layouts) emulates holding the stick at straight-back in Crank — the same
> full back pose through the same crank math (the stock look-back override
> is suppressed there); the other modes keep the stock look-back glance.

- **Goal:** Static / Static+ / Dynamic / Crank camera control.
- **Scope:** `turntable.lua` (input normalization + the four modes, §4.2);
  mouse-drag-as-stick; UI (`turntableMode` + related params).
- **Definition of done:** all four modes behave per spec with both stick and mouse;
  deadzone and idle-reset work.
- **Depends on:** Phase 1 (base camera), Phase 2 (UI)

### Phase 7 — Polish & packaging
- **Goal:** a shippable mod.
- **Scope:** `package.ps1`, README, final tuning, edge cases (VR/multiseat, damage,
  low FPS), preset re-tuning.
- **Definition of done:** `./package.ps1` produces a valid zip; installs and runs; all
  features work together; no Lua errors in the log.
- **Depends on:** Phases 1–6

> **Status:** Phases 1–4 and 6 are delivered. Remaining: collision jerk (§5.4),
> dynamic FOV (§5.6), tumble mode (§5.7), and the Phase 7 polish pass.
