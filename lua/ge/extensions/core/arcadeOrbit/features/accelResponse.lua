-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- accelResponse — crest/valley acceleration response.
-- Vertical acceleration (normal force) drives a height offset and a pitch offset:
--   Valley (>1g up): camera lowers + pitches up  (valley* params)
--   Crest  (<1g up): camera rises  + pitches down (crest*  params)
--
-- Both offsets are applied AFTER the pitch follow-smoothing as a crisp overlay,
-- so the smoothing time constant does not dampen the crest/valley response.
-- Height offset shifts the target (parallel boom shift); pitch tilts the aim.
--
-- Two-stage smoothing:
--   1. Input: smooth the raw acceleration to get a stable estimate.
--   2. Output: smooth the final offsets for gradual camera motion.
--
-- Smoothness parameters are TIME CONSTANTS in seconds (higher = more smoothing).

local C = {}
C.__index = C

local G = 9.81

local function rate(s)
  if s <= 0 then return 1000 end
  return 1 / s
end

function C:init()
  self.gThreshold = 0.05
  self.inputSmooth = 0.1
  self.outputSmooth = 0.6
  self.enabled = true

  -- Valley (>1g): camera lowers + pitches up.
  self.valleyStrength = 0.4
  self.valleyMaxHeight = 1.0
  self.valleyMaxPitch = 0.1745/2

  -- Crest (<1g): camera rises + pitches down.
  self.crestStrength = 0.5
  self.crestMaxHeight = 1.5
  self.crestMaxPitch = 0.1745*2

  self._azSmoother = newTemporalSmoothingNonLinear(rate(self.inputSmooth), rate(self.inputSmooth), 0)
  self._outSmoother = newTemporalSmoothingNonLinear(rate(self.outputSmooth), rate(self.outputSmooth), 0)
  self._heightOffset = 0
  self._pitchOffset = 0
end

function C:reset()
  self._azSmoother:reset()
  self._outSmoother:reset()
  self._heightOffset = 0
  self._pitchOffset = 0
end

function C:setGThreshold(v) self.gThreshold = v end

function C:setInputSmooth(v)
  self.inputSmooth = v
  local r = rate(v)
  self._azSmoother = newTemporalSmoothingNonLinear(r, r, 0)
end

function C:setOutputSmooth(v)
  self.outputSmooth = v
  local r = rate(v)
  self._outSmoother = newTemporalSmoothingNonLinear(r, r, 0)
end
function C:setEnabled(v) self.enabled = v end

function C:setValleyStrength(v) self.valleyStrength = v end
function C:setValleyMaxHeight(v) self.valleyMaxHeight = v end
function C:setValleyMaxPitch(v) self.valleyMaxPitch = v end

function C:setCrestStrength(v) self.crestStrength = v end
function C:setCrestMaxHeight(v) self.crestMaxHeight = v end
function C:setCrestMaxPitch(v) self.crestMaxPitch = v end

-- Returns (heightOffset, pitchOffset).
-- heightOffset: meters. Negative = camera lowers (valley), positive = rises (crest).
-- pitchOffset:  radians. Positive = pitch up (valley), negative = pitch down (crest).
function C:update(data)
  if not self.enabled then
    self._heightOffset = 0
    self._pitchOffset = 0
    return 0, 0
  end

  if data.dtSim <= 0 then
    return self._heightOffset, self._pitchOffset
  end

  -- Stage 1: smooth the raw acceleration (noisy single-frame derivative).
  local azRaw = (data.vel.z - data.prevVel.z) / data.dtSim
  local az = self._azSmoother:get(azRaw, data.dt)
  local deviation = az / G

  -- Apply threshold (dead zone around 1g).
  local target = 0
  if deviation > self.gThreshold then
    target = self.valleyStrength * (deviation - self.gThreshold)
  elseif deviation < -self.gThreshold then
    target = -self.crestStrength * (-deviation - self.gThreshold)
  end

  -- Stage 2: smooth the output.
  local s = self._outSmoother:get(target, data.dt)

  -- Use direction-appropriate max values.
  local maxH, maxP
  if s >= 0 then
    maxH, maxP = self.valleyMaxHeight, self.valleyMaxPitch
  else
    maxH, maxP = self.crestMaxHeight, self.crestMaxPitch
  end

  self._heightOffset = -s * maxH
  self._pitchOffset = s * maxP

  return self._heightOffset, self._pitchOffset
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
