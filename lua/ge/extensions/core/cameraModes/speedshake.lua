-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local perlin = require('core/enhanceddriver/perlin')
local DEG2RAD = math.pi / 180

-- LUT configuration
local LUT_SAMPLES = 512
local PERLIN_PERIOD = 256 -- period of permutation table in lattice space

local C = {}
C.__index = C

function C:init(amp, freq, disableWhileFalling)
  self.isFilter = true
  self.hidden = true
  self.amp = amp or vec3(0.01, 0.007, 0.01)
  self.freq = freq or vec3(15.0, 15.0, 15.0)
  self.octaves = 3
  self.timeOffset = vec3(0, math.random(), math.random())
  self.time = 0
  self.minSpeed = 35
  self.maxSpeed = 65
  self.maxStrength = 13
  self.disableWhileFalling = disableWhileFalling or false
  self.ampMult = 1
  self.freqMult = 1

  self.randAmp = self.amp

  -- Precomputed sequences and LUTs
  self._ampSeq = {}
  self._freqSeq = {}
  self._lutX = {}
  self._lutY = {}
  self._lutZ = {}
  self:_rebuildSequences()
  self:_rebuildLUTs()
end

function C:setAmpMultiplier(mult)
  self.ampMult = mult
end

function C:setFreqMultiplier(mult)
  self.freqMult = mult
end

function C:setMinSpeed(speed)
  self.minSpeed = speed
end

function C:setMaxSpeed(speed)
  self.maxSpeed = speed
end

function C:setOctaves(octaves)
  self.octaves = octaves
  self:_rebuildSequences()
  -- LUTs cover up to 10 octaves; sequences updated to use first N
end

-- Build amp/freq progression up to 10 octaves
function C:_rebuildSequences()
  local maxOct = 10
  for i = 1, maxOct do
    self._ampSeq[i] = 0.5 ^ (i - 1)
    self._freqSeq[i] = 2 ^ (i - 1)
  end
end

-- Build axis-aligned noise LUTs once over a full period
function C:_rebuildLUTs()
  local S = LUT_SAMPLES
  local step = PERLIN_PERIOD / S
  -- X axis: (t,0,0)
  for i = 1, 10 do
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

function C:getShakeStrength(data)
  local speed = data.vel:length() -- magnitude

  if speed < self.minSpeed then
    return 0
  end

  local strengthScale = math.min((speed - self.minSpeed) / (self.maxSpeed - self.minSpeed), 1)
  return self.maxStrength * strengthScale
end

function C:update(data, shakeStrength)
  local strength = shakeStrength or self:getShakeStrength(data)

  -- Reduce shake effects while falling
  if self.disableWhileFalling then
    local acc = data.vel.z - data.prevVel.z
    local fallFactor = clamp(acc / -0.1, 0, 1)
    if fallFactor > 0.9 then
      -- We're falling!
      strength = strength * (1 - fallFactor)
    end
  end

  -- Advance time
  self.time = self.time + (data.dt * be:getSimulationTimeScale())

  -- Constant-cost LUT sampling across octaves
  local axBase = self.amp.x * self.ampMult
  local ayBase = self.amp.y * self.ampMult
  local azBase = self.amp.z * self.ampMult
  local fxBase = self.freq.x * self.freqMult
  local fyBase = self.freq.y * self.freqMult
  local fzBase = self.freq.z * self.freqMult

  local ox, oy, oz = 0, 0, 0
  local oct = self.octaves
  for i = 1, oct do
    local ampMul = self._ampSeq[i]
    local freqMul = self._freqSeq[i]
    ox = ox + sampleLUT(self._lutX[i], self.time * fxBase * freqMul) * (axBase * ampMul)
    oy = oy + sampleLUT(self._lutY[i], self.time * fyBase * freqMul) * (ayBase * ampMul)
    oz = oz + sampleLUT(self._lutZ[i], self.time * fzBase * freqMul) * (azBase * ampMul)
  end

  local radScale = strength * DEG2RAD
  local q = quatFromEuler(ox * radScale, oy * radScale, oz * radScale)
  data.res.rot = data.res.rot * q
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
