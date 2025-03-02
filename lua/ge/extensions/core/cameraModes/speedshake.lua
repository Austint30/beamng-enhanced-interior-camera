-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local perlin = require('core/enhanceddriver/perlin')

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
end

function C:getShakeStrength(data)

  local speed = data.vel:length() -- magnitude

  if speed < self.minSpeed then
    return 0
  end
  
  local strengthScale = math.min((speed-self.minSpeed) / (self.maxSpeed-self.minSpeed), 1)
  return self.maxStrength * strengthScale
end

function C:update(data, shakeStrength)

  local amp = self.amp * self.ampMult
  local freq = self.freq * self.freqMult

  self.time = self.time + (data.dt * be:getSimulationTimeScale())
  local offset = vec3(
      perlin:OctavePerlin(self.time, 0, 0, self.octaves, amp.x, freq.x),
      perlin:OctavePerlin(0, self.time, 0, self.octaves, amp.y, freq.y),
      perlin:OctavePerlin(0, 0, self.time, self.octaves, amp.z, freq.z)
  )

  local strength = shakeStrength or self:getShakeStrength(data)

  -- Reduce shake effects while falling
  if self.disableWhileFalling then
    local acc = data.vel.z - data.prevVel.z
    local fallFactor = clamp(acc/-0.1, 0, 1)
    if fallFactor > 0.9 then
      -- We're falling!
      strength = strength * (1-fallFactor)
    end
  end
  
  local rotEuler = vec3(
    offset.x * strength * math.pi / 180,
    offset.y * strength * math.pi / 180,
    offset.z * strength * math.pi / 180
  )
  local q = quatFromEuler(rotEuler.x, rotEuler.y, rotEuler.z)

  data.res.rot = data.res.rot * q
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
