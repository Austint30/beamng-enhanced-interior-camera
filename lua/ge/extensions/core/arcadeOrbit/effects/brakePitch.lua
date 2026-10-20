-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- brakePitch — Phase-4 g-force family: braking pitch-down.
-- Sustained, moderate: silent below minG (default 0 = engages from the first
-- brake), ramping 0 → maxOffset between minG and maxG.
-- Mixed convention: the FORCE is measured in the camera's frame — the
-- longitudinal deceleration g (frame-to-frame velocity change projected onto
-- the camera's look direction, so a hard brake registers whether the car is
-- driving forward or in reverse — the chase cam faces the direction of
-- travel) —
-- while the DIRECTION moves the aim TARGET up/down in camera space:
-- arcadeOrbit.lua shifts the look point by the returned offset (metres) and
-- re-aims with the camera position fixed (the reference enhanceddriver
-- g-force feel).
-- Smoothness: time constant in seconds (higher = smoother / lazier), used for
-- both attack (braking) and release (coasting).

local C = {}
C.__index = C

local G = 9.81          -- reference gravity (m/s²)
local MIN_RANGE_G = 0.05 -- g: lower bound on the (maxG − minG) range so the ramp division stays finite

local function rate(s)
  if s <= 0 then return 1000 end
  return 1 / s
end

function C:init()
  self.enabled = true
  self.minG = 0.0       -- g: dead zone — no pitch below this deceleration (0 = engages from the first brake)
  self.maxG = 2.0       -- g of deceleration at which the full max offset is reached
  self.maxOffset = 2    -- m: how far the aim target moves down (camera space) at full deceleration
  self.smoothness = 0.5 -- s: time constant for pitching down and back up
  self._smoother = newTemporalSmoothingNonLinear(rate(self.smoothness), rate(self.smoothness), 0)
  self._offsetM = 0
end

function C:reset()
  self._smoother:reset()
  self._offsetM = 0
end

function C:setEnabled(v) self.enabled = v end
function C:setMinG(v) self.minG = v end
function C:setMaxG(v) self.maxG = v end
function C:setMaxOffset(v) self.maxOffset = v end
function C:setSmoothness(v)
  self.smoothness = v
  local r = rate(v)
  self._smoother = newTemporalSmoothingNonLinear(r, r, 0)
end

-- ctx.camFwd: unit vec3, the camera's look direction (world space). The g is
-- measured in the camera frame: the chase cam flips to face the direction of
-- travel when reversing, so "forward" for the viewer is the view direction.
-- Returns this frame's aim-target offset in METERS (positive = target down /
-- aim down; 0 = none).
function C:update(data, ctx)
  if not self.enabled then
    self._offsetM = 0
    return 0
  end
  if data.dtSim <= 0 then
    return self._offsetM
  end

  if data.teleported then
    -- A teleport (rewind, recover, vehicle switch) zeroed data.vel while
    -- data.prevVel still holds the old speed — a phantom single-frame "brake"
    -- of hundreds of g. Don't let it push the offset.
    self._smoother:reset()
    self._offsetM = 0
    return 0
  end

  -- Vehicle longitudinal acceleration (m/s², + = accelerating forward).
  local fwd = ctx.camFwd
  local accLong = ((data.vel.x - data.prevVel.x) * fwd.x
                 + (data.vel.y - data.prevVel.y) * fwd.y
                 + (data.vel.z - data.prevVel.z) * fwd.z) / data.dtSim

  local decel = -accLong -- m/s², + = braking (decelerating)
  if decel < 0 then decel = 0 end
  local g = decel / G

  -- Silent below minG; ramps to full strength at maxG (both g). If maxG <= minG
  -- this degrades to a hard on/off at minG.
  local t = 0
  if g >= self.minG then
    t = (g - self.minG) / math.max(self.maxG - self.minG, MIN_RANGE_G)
    if t > 1 then t = 1 end
  end

  self._offsetM = self._smoother:get(t, data.dt) * self.maxOffset
  return self._offsetM
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
