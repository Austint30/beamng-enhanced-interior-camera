-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- turntable — §4.2 camera control modes + input normalization for the arcade
-- chase camera. The user's camera-rotation input (gamepad right stick or
-- mouse right-click drag) is interpreted by one of four selectable modes:
--
--   Static   — stock orbit behaviour: rotate with stick/mouse and the camera
--              stays where you leave it (no auto-centre). Handled entirely by
--              the stock manual-rotation path in arcadeOrbit.lua; this module
--              is not involved.
--   Static+  — same as Static, but after an adjustable idle delay the camera
--              eases back to the default (forward) rotation.
--   Dynamic  — the stick *position* maps directly to the camera pose: x is
--              yaw (0 = straight, ±1 = ±dynamicMaxYaw — 180° = looking
--              backwards), y is pitch (stick up = pitch down from above,
--              stick down = pitch up from near ground level). Returns to
--              straight when centered.
--   Crank    — the camera points where the stick points: yaw ≈ atan2(x, y)
--              (up = forward, right = +90°, down = 180°, left = -90°), no
--              pitch. VERTICAL input (stick inside the horizontal deadzone)
--              is dead from +1 down to -0.75: the camera does not move at
--              all (it holds its target) — partial vertical pulls never
--              produce partial dial angles. Past -0.75 the target changes
--              to the direction of the joystick regardless of magnitude
--              (full deflection — a back pull lands at the full back pose,
--              and the jump from the held target snaps instantly as a side
--              effect of the target-flip rule). Horizontal/diagonal input
--              (outside the horizontal deadzone) is analog: the direction
--              is always the true stick direction and the magnitude
--              interpolates from the fixed 5 % engagement deadzone, so
--              slow sweeps through any quadrant are monotonic (no
--              reversal, no hitch at back). crankMaxYaw stretches the dial
--              (it is the yaw at a full right/left deflection). The game's
--              Look Back action (right-stick click on gamepad layouts)
--              EMULATES holding the stick at straight-back: the same full
--              back pose through the same crank math; releasing returns to
--              the stick pose.
--
-- Target-flip snap (Crank only): the camera takes the commanded pose
-- INSTANTLY (the input smoothing is skipped; the caller adopts the pose in
-- camLastRot) when the commanded target flips ~180° (±5°) from its current
-- direction in one frame — flicking the stick from forward to back,
-- releasing the stick from the back position (±180 → 0), or the Look Back
-- click from forward. The snap is purely TARGET-based (never the stick
-- direction): spinning the dial smoothly through back never trips it. Every
-- other stick movement keeps the stock input smoothing.
--
-- Input normalization (shared by Dynamic/Crank): a 2D stick vector (x, y) in
-- [-1, 1]².
--   - gamepad right stick / keyboard (absolute, 0–1 axes):
--       x = yawRight - yawLeft, y = pitchUp - pitchDown
--   - mouse right-click drag (relative, per-frame deltas): the deltas are
--     integrated into a virtual stick position (clamped to [-1, 1]²) and
--     decay back to centre on release / idle.

local C = {}
C.__index = C

-- Sign convention: the stock orbit camera rotates camRot.x in the direction
-- that a rightward input produces (yawRight / mouse-right both move camRot.x
-- downward in arcadeOrbit.lua's accumulation), so the spec's yaw maps onto
-- camRot.x with this factor to keep the same rotational feel. The ±180°
-- poses are sign-agnostic (identical either way). Flip to 1 if in-game
-- verification shows a mirrored feel.
local INPUT_RIGHT_SIGN = -1

local PITCH_RANGE_DEG = 85     -- matches the stock orbit camRot.y clamp (±85°)
local MOUSE_STICK_PER_UNIT = 1.0 -- virtual-stick units per unit of accumulated relative delta (fov-scaled: a full deflection ≈ a ~100 px drag)
local MOUSE_DECAY_RATE = 3.0  -- virtual-stick units re-centred per second after release
local STATIC_PLUS_TAU = 0.8    -- s; ease time constant of the Static+ idle reset
local STATIC_PLUS_SNAP_DEG = 0.05 -- °; below this the eased rotation snaps to the target
local CRANK_YAW_RIGHT_DEG = 90 -- °; crankMaxYaw is defined as the yaw at a full right deflection
local CRANK_STICK_DEADZONE = 0.05 -- horizontal deadzone / engagement deadzone (5 %, deliberately NOT user-facing — tune this constant here)
local CRANK_FB_TRIGGER = 0.75 -- vertical back threshold: stick y in [+1, -0.75] (inside the horizontal deadzone) is dead (hold); past -0.75 the target jumps to the stick direction at full deflection (NOT user-facing — tune here)
local CRANK_FLIP_WINDOW_DEG = 5 -- °; a commanded-target flip within ±5° of exactly 180° snaps instantly (skips the input smoothing)

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function easeAlpha(dt, tau)
  if dt <= 0 then return 0 end
  return 1 - math.exp(-dt / tau)
end

function C:init()
  self.mode = 'Static'
  self.staticPlusResetDelay = 4
  self.dynamicMaxYaw = 180
  self.dynamicMaxPitch = 70
  self.crankMaxYaw = 90
  self.mouseDragSensitivity = 1
  self.stickX = 0
  self.stickY = 0
  self.active = false
  self.snapBack = false
  self.stickAbsolute = false
  self.prevCrankYaw = nil
end

function C:reset()
  self.stickX = 0
  self.stickY = 0
  self.active = false
  self.snapBack = false
  self.stickAbsolute = false
  self.prevCrankYaw = nil
end

function C:setMode(v)
  self.mode = v
  -- The pose mapping changes with the mode: forget the previous crank target
  -- so the first frame of the new mode is not misread as a target flip.
  self.prevCrankYaw = nil
end
function C:setStaticPlusResetDelay(v) self.staticPlusResetDelay = v end
function C:setDynamicMaxYaw(v) self.dynamicMaxYaw = v end
function C:setDynamicMaxPitch(v) self.dynamicMaxPitch = v end
function C:setCrankMaxYaw(v) self.crankMaxYaw = v end
function C:setMouseDragSensitivity(v) self.mouseDragSensitivity = v end

-- Dynamic/Crank replace the stock manual-rotation accumulation with a
-- stick-driven absolute pose.
function C:isDirectMode()
  return self.mode == 'Dynamic' or self.mode == 'Crank'
end

-- Input normalization (§4.2). Maintains self.stickX / self.stickY in
-- [-1, 1]² and self.active (input or re-centre animation in progress this
-- frame — the camera keeps its input rate limit open while active).
-- Absolute sources (gamepad stick / keyboard) are read positionally and
-- RE-CENTRE IMMEDIATELY on release (their rest position is 0) — the
-- exponential decay is only for the mouse's virtual stick, so a released
-- pad flips the commanded target in a single frame.
function C:updateStick(data)
  local yawRel = MoveManager.yawRelative or 0
  local pitchRel = MoveManager.pitchRelative or 0
  if yawRel ~= 0 or pitchRel ~= 0 then
    -- relative source (mouse RMB drag): integrate into the virtual stick
    local scale = self.mouseDragSensitivity * MOUSE_STICK_PER_UNIT
    self.stickX = clamp(self.stickX + yawRel * scale, -1, 1)
    self.stickY = clamp(self.stickY - pitchRel * scale, -1, 1)
    self.stickAbsolute = false
    self.active = true
    return
  end

  local padX = (MoveManager.yawRight or 0) - (MoveManager.yawLeft or 0)
  local padY = (MoveManager.pitchUp or 0) - (MoveManager.pitchDown or 0)
  if padX ~= 0 or padY ~= 0 then
    -- absolute source (gamepad stick / keyboard): read the position directly
    self.stickX = clamp(padX, -1, 1)
    self.stickY = clamp(padY, -1, 1)
    self.stickAbsolute = true
    self.active = true
    return
  end

  if self.stickAbsolute then
    -- The absolute source (gamepad/keyboard) was released: its rest position
    -- IS 0, so take that immediately instead of decaying — the release
    -- flips the commanded target in one frame (e.g. back → forward), which
    -- the target-flip snap in update() turns into an instant return.
    self.stickX = 0
    self.stickY = 0
    self.stickAbsolute = false
    self.active = false
    return
  end

  -- No input: let the virtual (mouse) stick decay back to centre.
  if self.stickX ~= 0 or self.stickY ~= 0 then
    local decay = MOUSE_DECAY_RATE * data.dt
    if math.abs(self.stickX) <= decay then self.stickX = 0
    else self.stickX = self.stickX - sign(self.stickX) * decay end
    if math.abs(self.stickY) <= decay then self.stickY = 0
    else self.stickY = self.stickY - sign(self.stickY) * decay end
    self.active = true
  else
    self.active = false
  end
end

-- Direct modes (Dynamic/Crank): returns yawDeg (the camRot.x target),
-- pitchDeg (the camRot.y target, nil for Crank), active, snapBack (Crank
-- only: true when the commanded target flipped ~180° (±5°) from the previous
-- frame's target — the camera should take the commanded pose INSTANTLY,
-- skipping the input smoothing).
function C:update(data)
  self:updateStick(data)
  self.snapBack = false
  if self.mode == 'Dynamic' then
    -- x = 0 → straight; x → ±1 → ±dynamicMaxYaw (180° = looking backwards).
    local yawDeg = self.stickX * self.dynamicMaxYaw * INPUT_RIGHT_SIGN
    -- y → +1 (stick up) → pitch down: camera above looking down (negative
    -- camRot.y); y → -1 → pitch up: camera drops toward ground level.
    local pitchDeg = -self.stickY * (self.dynamicMaxPitch / 100) * PITCH_RANGE_DEG
    return yawDeg, pitchDeg, self.active, false
  end

  -- Crank: yaw ≈ atan2(x, y) (up = forward, right = +90°, down = 180°,
  -- left = -90°), no pitch. VERTICAL input (stick inside the horizontal
  -- deadzone) is dead from +1 down to -0.75: the camera does not move at
  -- all — it holds its target, so partial vertical pulls never produce
  -- partial dial angles (an at-rest stick is not a hold: it commands
  -- forward, so releasing the dial returns to centre and the release-from-
  -- back flip still snaps). Past -0.75 the target changes to the direction
  -- of the joystick regardless of magnitude (full deflection): the jump
  -- from the held target flips ~180° and the target-flip rule below takes
  -- it instantly — the snap works as a side effect, no special handling.
  -- Horizontal/diagonal input is analog: the direction is always the true
  -- stick direction (slow sweeps through any quadrant are monotonic — no
  -- reversal, no hitch at back) and the magnitude interpolates from the
  -- 5 % engagement deadzone to full deflection.
  -- The Look Back action (stick click) EMULATES holding the stick at
  -- straight-back: it commands the identical full back pose through the same
  -- crank math and overrides the stick while held; on release the
  -- stick-commanded pose resumes. Whether it snaps is decided by the
  -- target-flip rule below, exactly like any stick command.
  local yawDeg = 0
  if data.lookBack then
    yawDeg = 180 * (self.crankMaxYaw / CRANK_YAW_RIGHT_DEG) * INPUT_RIGHT_SIGN
    self.active = true -- keep the camera's input rate limit open during the glance
  else
    local sx = self.stickX
    local sy = self.stickY
    local m = math.sqrt(sx * sx + sy * sy)
    if math.abs(sx) <= CRANK_STICK_DEADZONE and sy >= -CRANK_FB_TRIGGER and m > CRANK_STICK_DEADZONE then
      -- Vertical dead band: hold the current target — the camera does not
      -- move at all.
      yawDeg = self.prevCrankYaw or 0
    elseif m > CRANK_STICK_DEADZONE then
      local t = clamp((m - CRANK_STICK_DEADZONE) / (1 - CRANK_STICK_DEADZONE), 0, 1)
      if math.abs(sy) > CRANK_FB_TRIGGER then
        t = 1 -- past the vertical threshold: the full target for the stick's direction, regardless of magnitude
      end
      local thetaDeg = math.deg(math.atan2(sx, sy))
      yawDeg = thetaDeg * t * (self.crankMaxYaw / CRANK_YAW_RIGHT_DEG) * INPUT_RIGHT_SIGN
    end
  end

  -- Target-flip snap: if the commanded target flips ~180° (±5°) from its
  -- current direction in one frame — flicking the stick from forward to
  -- back, releasing the stick from the back position (±180 → 0), or the
  -- Look Back click from forward — the camera takes the new target
  -- instantly instead of easing around to it. Purely target-based: a smooth
  -- spin (even a fast one) changes the target gradually and never trips it.
  if self.prevCrankYaw ~= nil
    and math.abs(((yawDeg - self.prevCrankYaw + 180) % 360) - 180) >= 180 - CRANK_FLIP_WINDOW_DEG then
    self.snapBack = true
  end
  self.prevCrankYaw = yawDeg
  return yawDeg, nil, self.active, self.snapBack
end

-- Static+ (§4.2 mode 2): after `staticPlusResetDelay` seconds without
-- rotation input, ease camRot back to the default (forward) rotation.
-- `hasInput` mirrors the raw-input presence the camera already computed: the
-- idle timer alone is not enough, because a held analog stick stops firing
-- input events, so timeSinceLastRotation grows even while the stick is held.
-- Returns true while the ease is animating (the camera keeps its input rate
-- limit open for it).
function C:updateStaticPlus(data, cam, hasInput)
  if hasInput then return false end
  if core_camera.timeSinceLastRotation(data.player) <= self.staticPlusResetDelay * 1000 then
    return false
  end

  local targetX = cam.defaultRotation and cam.defaultRotation.x or 0
  local targetY = cam.defaultRotation and cam.defaultRotation.y or 0
  local a = easeAlpha(data.dt, STATIC_PLUS_TAU)

  -- shortest wrap for the yaw
  local diffX = (targetX - cam.camRot.x + 180) % 360 - 180
  if math.abs(diffX) <= STATIC_PLUS_SNAP_DEG then
    cam.camRot.x = targetX
  else
    cam.camRot.x = cam.camRot.x + diffX * a
  end

  local diffY = targetY - cam.camRot.y
  if math.abs(diffY) <= STATIC_PLUS_SNAP_DEG then
    cam.camRot.y = targetY
  else
    cam.camRot.y = cam.camRot.y + diffY * a
  end
  return true
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
