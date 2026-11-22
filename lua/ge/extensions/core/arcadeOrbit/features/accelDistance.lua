-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- accelDistance — adjusts camera boom length based on vehicle acceleration
-- projected onto the camera's forward axis (previous frame).
-- Accelerating → camera pulls back (+delta); decelerating → pushes closer (-delta).
--
-- The offset is eased toward the target with a true exponential time constant,
-- so it is framerate-independent:
--   offset += (target - offset) * (1 - exp(-dt / smoothness))
-- `smoothness` is stored in milliseconds (matching the settings slider); the
-- original implementation ignored it and moved at hard-coded rates.
-- Deceleration uses a slower constant than acceleration, preserving the
-- original faster-attack / slower-release feel.

local C = {}
C.__index = C

local G_REF = 9.81 * 5  -- full maxDist reached at 5 g forward acceleration
local DECAY_SCALE = 2.5 -- release responds 2.5x slower than attack

local function responseAlpha(dt, tau)
  if tau <= 0 then return 1 end
  if dt <= 0 then return 0 end
  return 1 - math.exp(-dt / tau)
end

function C:init()
  self.maxDist = 0.3
  self.smoothness = 1300 -- ms, time constant
  self.enabled = true
  self._offset = 0
end

function C:reset()
  self._offset = 0
end

function C:setMaxDist(v) self.maxDist = v end
function C:setSmoothness(v) self.smoothness = v end
function C:setEnabled(v) self.enabled = v end

-- ctx.camForward: unit vec3, direction from camera toward aim point (previous frame).
-- Returns a scalar delta (m) to add to the boom length this frame.
function C:update(data, ctx)
  if not self.enabled then return 0 end
  if data.dtSim < 1e-6 then return self._offset end

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

  local tau = self.smoothness / 1000
  if target < 0 then tau = tau * DECAY_SCALE end
  self._offset = self._offset + (target - self._offset) * responseAlpha(data.dt, tau)
  return self._offset
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
