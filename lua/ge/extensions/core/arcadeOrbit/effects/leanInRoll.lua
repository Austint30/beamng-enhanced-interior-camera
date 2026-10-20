-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- leanInRoll — Phase-4 g-force family: lean-in roll under sustained cornering
-- (§5.5). A SUSTAINED camera roll that leans the camera into a corner while the
-- vehicle is under a sustained lateral (side) acceleration — the "driver
-- leaning into the turn" feel.
-- Mixed convention: the FORCE is measured in the CAMERA's frame — the vehicle's
-- acceleration projected onto the camera's right axis (the view's left/right),
-- so "left/right" for the lean is the viewer's left/right at any orbit /
-- turntable angle. The DIRECTION is a roll of the camera around its own aim
-- axis (the aim line itself is untouched; only the horizon tilts), mirroring
-- the body roll into the corner: acceleration toward the camera's right rolls
-- the view clockwise (right side down).
-- The smoothed signed lateral g maps 0 → maxRoll between minG and maxG
-- (symmetric: a leftward acceleration rolls the other way) via a SMOOTHSTEP
-- curve, so the roll levels out (zero slope) as it engages near minG and as
-- it saturates near maxG. newTemporalSmoothingNonLinear smooths the g itself
-- so the lean gradually enters and exits.

local C = {}
C.__index = C

local G = 9.81            -- reference gravity (m/s²)
local MIN_RANGE_G = 0.05  -- g: lower bound on (maxG − minG) so the ramp division stays finite
local CAM_RIGHT_EPS = 1e-4 -- horizontal look-length below which no camera right axis exists (aiming straight up/down)

local function rate(s)
  if s <= 0 then return 1000 end
  return 1 / s
end

function C:init()
  self.enabled = true
  self.minG = 0.2       -- g: dead zone — no roll below this lateral g
  self.maxG = 1.5       -- g: lateral g at which the full max roll is reached
  self.maxRoll = 5      -- degrees of camera roll at full lateral g
  self.smoothness = 0.3 -- s: time constant for the lean in and out
  self._smoother = newTemporalSmoothingNonLinear(rate(self.smoothness), rate(self.smoothness), 0)
  self._outRad = 0
end

function C:reset()
  self._smoother:reset()
  self._outRad = 0
end

function C:setEnabled(v) self.enabled = v end
function C:setMinG(v) self.minG = v end
function C:setMaxG(v) self.maxG = v end
function C:setMaxRoll(v) self.maxRoll = v end
function C:setSmoothness(v)
  self.smoothness = v
  local r = rate(v)
  self._smoother = newTemporalSmoothingNonLinear(r, r, 0)
end

-- ctx.camFwd: unit vec3, the camera's look direction (world space).
-- Returns this frame's roll angle in radians (positive = roll toward the
-- camera's right — clockwise as the player sees it; 0 = none).
function C:update(data, ctx)
  if not self.enabled then
    self._outRad = 0
    return 0
  end
  if data.dtSim <= 0 then
    return self._outRad
  end

  if data.teleported then
    -- A teleport (rewind, recover, vehicle switch) zeroed data.vel while
    -- data.prevVel still holds the old speed — a phantom single-frame "impact"
    -- of hundreds of g. Don't let it roll the camera.
    self._smoother:reset()
    self._outRad = 0
    return 0
  end

  -- Lateral acceleration in the camera frame: acc · camRight, where
  -- camRight = normalize(camFwd × worldUp) = (fy, −fx, 0) / |horizontal fwd|
  -- — computed component-wise to avoid a per-frame allocation.
  local fwd = ctx.camFwd
  local fx, fy = fwd.x, fwd.y
  local fh = math.sqrt(fx * fx + fy * fy)
  local gSide = 0
  if fh > CAM_RIGHT_EPS then
    local rx, ry = fy / fh, -fx / fh
    local accx = (data.vel.x - data.prevVel.x) / data.dtSim
    local accy = (data.vel.y - data.prevVel.y) / data.dtSim
    gSide = (accx * rx + accy * ry) / G
  end

  -- Smoothed signed lateral g, mapped 0 → maxRoll between minG and maxG, sign
  -- preserved (a leftward acceleration rolls the other way). The mapping is a
  -- smoothstep, so the roll LEVELS OUT (zero slope) as it engages near minG
  -- and as it saturates near maxG — a gentle S-curve, not a hard linear ramp.
  local s = self._smoother:get(gSide, data.dtSim)
  local a = math.abs(s)
  local roll = 0
  if a > self.minG then
    local t = (a - self.minG) / math.max(self.maxG - self.minG, MIN_RANGE_G)
    if t < 0 then t = 0 end
    if t > 1 then t = 1 end
    t = t * t * (3 - 2 * t) -- smoothstep: flattens near 0 and 1
    roll = t * math.rad(self.maxRoll)
  end
  self._outRad = s >= 0 and roll or -roll
  return self._outRad
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
