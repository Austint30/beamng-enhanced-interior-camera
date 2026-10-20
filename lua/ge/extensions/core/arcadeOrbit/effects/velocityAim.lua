-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- velocityAim — velocity-based aim (drift look).
--
-- If the car is drifting (velocity differs from forward), the aim point is offset
-- slightly toward the drift direction. The offset is applied along the car's LOCAL
-- X (left) axis, computed in the car's local space so pitch never bleeds into yaw.
-- The offset is along the left axis (already in world space), so no feedback loop.
-- The angle is temporally smoothed, and the effect is scaled down at low speeds
-- (where noise is amplified).

local C = {}
C.__index = C

local velLocal = vec3()

function C:init()
  self.scale = 1 -- aim offset (m) per radian of drift angle (0 = stock orbit)
  self.minSpeed = 1 -- speed (m/s) below which the effect is fully suppressed
  self.maxSpeed = 20 -- speed (m/s) at which the effect is fully active
  self.smoo = newTemporalSmoothingNonLinear(6, 6, 0)
  self.aimDir = vec3()
end

function C:reset()
  self.smoo:set(0)
end

function C:setScale(v)
  self.scale = v
end

function C:setMinSpeed(v)
  self.minSpeed = v
end

function C:setMaxSpeed(v)
  self.maxSpeed = v
end

-- ctx = { targetPos = vec3, left = vec3, back = vec3 } (world space)
-- Returns the final aim point (self.aimDir).
function C:update(data, ctx)
  local aimDir = self.aimDir
  aimDir:set(ctx.targetPos)
  local driftSin = 0
  if self.scale ~= 0 and data.vel:squaredLength() > 1e-8 then
    velLocal:set(
      push3(data.vel):dot(ctx.left),
      push3(data.vel):dot(ctx.back),
      0)
    -- Only apply the aim while the car is moving forward (velLocal.y < 0).
    -- Near 180° the angle sits at the ±π wrap point where atan2 flips sign on
    -- tiny velocity noise, so zero the target whenever the car isn't going forward.
    if velLocal.y < 0 then
      local driftAngle = -math.atan2(velLocal.x, -velLocal.y)
      driftSin = math.sin(driftAngle)
    end
  end
  local smoothDriftSin = self.smoo:get(driftSin, data.dt)
  if math.abs(smoothDriftSin) > 1e-4 then
    local speed = data.vel:length()
    local speedFactor = smoothstep(inverseLerp(self.minSpeed, self.maxSpeed, speed))
    aimDir:setAdd(push3(ctx.left) * (smoothDriftSin * self.scale * speedFactor))
  end
  return aimDir
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
