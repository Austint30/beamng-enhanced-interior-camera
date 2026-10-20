-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- speedShake — perlin noise shake on camera yaw/pitch/roll, ramping with vehicle speed.
-- Independent amplitude per axis. Roll defaults to 0 (off).

local perlin = require('core/arcadeOrbit/perlin')
local DEG2RAD = math.pi / 180

local LUT_SAMPLES = 512
local PERLIN_PERIOD = 256
local MAX_OCTAVES = 10
local BASE_FREQ = 15.0

local C = {}
C.__index = C

function C:init()
  self.yawAmp = 0.825
  self.pitchAmp = 0.825
  self.rollAmp = 0
  self.freq = 0.6
  self.octaves = 3
  self.minSpeed = 15.199334805583
  self.maxSpeed = 70.79733922233
  self.maxStrength = 6
  self.enabled = true
  self.time = 0
  self.timeOffsetX = math.random()
  self.timeOffsetY = math.random()
  self.timeOffsetZ = math.random()
  self:_rebuildLUTs()
end

function C:reset()
  self.time = 0
end

function C:setYawAmp(v) self.yawAmp = v end
function C:setPitchAmp(v) self.pitchAmp = v end
function C:setRollAmp(v) self.rollAmp = v end
function C:setFreq(v) self.freq = v end
function C:setOctaves(v) self.octaves = math.min(math.max(1, v), MAX_OCTAVES) end
function C:setMinSpeed(v) self.minSpeed = v end
function C:setMaxSpeed(v) self.maxSpeed = v end
function C:setMaxStrength(v) self.maxStrength = v end
function C:setEnabled(v) self.enabled = v end

function C:_rebuildLUTs()
  local S = LUT_SAMPLES
  local step = PERLIN_PERIOD / S
  self._lutX = {}
  self._lutY = {}
  self._lutZ = {}
  for i = 1, MAX_OCTAVES do
    local arrX = {}
    local arrY = {}
    local arrZ = {}
    for s = 0, S - 1 do
      local t = s * step
      arrX[s] = perlin:noise(t, 0, 0)
      arrY[s] = perlin:noise(0, t, 0)
      arrZ[s] = perlin:noise(0, 0, t)
    end
    self._lutX[i] = arrX
    self._lutY[i] = arrY
    self._lutZ[i] = arrZ
  end
end

local function sampleLUT(lut, coord)
  local S = LUT_SAMPLES
  local x = coord % PERLIN_PERIOD
  local pos = x * S / PERLIN_PERIOD
  local i = math.floor(pos)
  local f = pos - i
  local a = lut[i]
  local b = lut[(i + 1) % S]
  return a + (b - a) * f
end

function C:update(data)
  if not self.enabled then return end

  local speed = data.vel:length()
  if speed < self.minSpeed then return end

  local ramp = (speed - self.minSpeed) / (self.maxSpeed - self.minSpeed)
  if ramp > 1 then ramp = 1 end
  local strength = self.maxStrength * ramp
  if strength <= 0 then return end

  self.time = self.time + data.dt * be:getSimulationTimeScale()

  local fx = BASE_FREQ * self.freq
  local fy = BASE_FREQ * self.freq * 0.71
  local fz = BASE_FREQ * self.freq * 0.53
  local oct = self.octaves

  local ox = 0
  local oy = 0
  local oz = 0
  for i = 1, oct do
    local ampMul = 0.5 ^ (i - 1)
    local freqMul = 2 ^ (i - 1)
    ox = ox + sampleLUT(self._lutX[i], self.time * fx * freqMul + self.timeOffsetX) * ampMul
    oy = oy + sampleLUT(self._lutY[i], self.time * fy * freqMul + self.timeOffsetY) * ampMul
    oz = oz + sampleLUT(self._lutZ[i], self.time * fz * freqMul + self.timeOffsetZ) * ampMul
  end

  local scale = ramp * DEG2RAD
  local q = quatFromEuler(oz * self.rollAmp * scale, oy * self.pitchAmp * scale, ox * self.yawAmp * scale)
  data.res.rot = data.res.rot * q
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
