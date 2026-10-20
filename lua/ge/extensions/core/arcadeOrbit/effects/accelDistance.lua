-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- accelDistance — adjusts camera boom length based on vehicle acceleration
-- projected onto the camera's forward axis (previous frame).
-- Accelerating → camera pulls back (+delta); decelerating → pushes closer (-delta).

local C = {}
C.__index = C

local G_REF = 9.81 * 5  -- full maxDist reached at 5 g forward acceleration

function C:init()
  self.maxDist = 0.3
  self.smoothness = 2000
  self.enabled = true
  self._smoother = newTemporalSigmoidSmoothing(2, 2, 2, 2)
end

function C:reset()
  self._smoother:reset()
end

function C:setMaxDist(v) self.maxDist = v end
function C:setSmoothness(v) self.smoothness = v end
function C:setEnabled(v) self.enabled = v end

-- ctx.camForward: unit vec3, direction from camera toward aim point (previous frame).
-- Returns a scalar delta (m) to add to the boom length this frame.
function C:update(data, ctx)
  if not self.enabled then return 0 end
  if data.dtSim < 1e-6 then return self._smoother:value() end

  -- Project dv onto camera forward without allocating a vec3.
  local dvx = data.vel.x - data.prevVel.x
  local dvy = data.vel.y - data.prevVel.y
  local dvz = data.vel.z - data.prevVel.z
  local accelFwd = (dvx * ctx.camForward.x
                  + dvy * ctx.camForward.y
                  + dvz * ctx.camForward.z) / data.dtSim

  -- Sigmoid-shaped mapping: linear near 0, saturates smoothly at ±maxDist.
  local t = accelFwd / G_REF
  local target = math.tanh(t) * self.maxDist

  -- Asymmetric: faster attack (accelerating), slower decay (decelerating)
  if target >= 0 then
    return self._smoother:getWithRateAccel(target, data.dt, 0.5, 0.5, 0.5)
  else
    return self._smoother:getWithRateAccel(target, data.dt, 0.2, 0.2, 0.2)
  end
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
