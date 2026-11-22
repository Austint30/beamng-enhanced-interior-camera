-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- driftShake — perlin noise shake on the camera yaw/pitch/roll while the
-- vehicle is sliding (drifting).
--
-- Drift metric (slip-angle technique modeled on the reference
-- enhanceddriver.lua:833-848): the velocity is rotated into the car's local
-- frame (local Y = vehicle forward, local Z = vehicle up) and its vertical
-- component dropped. The slip angle is the angle between the vehicle forward
-- and the flattened velocity, folded so a drift of the same angle in forward
-- or reverse gives the same strength. The effect ramps from 0 to 100% as the
-- slip angle reaches maxAngle, and fades in with speed up to maxSpeed, so
-- parked / sliding-in-place motion stays quiet.
--
-- Burnout (rear-wheel spin) is deferred: no publicly exposed wheel-slip API
-- (spec §5.2 allows the delay; a velocity proxy was considered and rejected).
--
-- Falling gate: while the car's z acceleration is at or below -1 g the shake
-- multiplier is 0 (spec §5.2).
--
-- ctx (preallocated by the camera, no per-frame allocation):
--   carRot        quat — car frame (setFromDir(carFwd, carUp), carFwd = ny, carUp = nz)
--   carRotInv     quat — inverse of carRot
--   flatVelocity  vec3 — scratch, velocity in the car frame with the vertical component dropped

local perlin = require('core/arcadeOrbit/perlin')
local DEG2RAD = math.pi / 180

local LUT_SAMPLES = 512
local PERLIN_PERIOD = 256 -- period of the permutation table in lattice space
local MAX_OCTAVES = 10
local BASE_FREQ = 15.0    -- base perlin frequency (LUT-units per second), scaled by freq
local AXIS_DESYNC_Y = 0.71 -- per-axis frequency desync so the noise channels are uncorrelated
local AXIS_DESYNC_Z = 0.53
local FLATVEL_MIN_SQ = 1e-8 -- m²/s² gate on the flattened velocity (reference:839)
local ANGLE_EPS_RAD = 1e-4  -- floor for maxAngle (rad) to avoid divide-by-zero; the UI never goes below 5°
local FALL_ACCEL = 9.8      -- m/s² (≈1 g): z acceleration ≤ -FALL_ACCEL means falling → shake × 0

local C = {}
C.__index = C

function C:init()
  self.yawAmp = 0.8    -- degrees
  self.pitchAmp = 0.5  -- degrees
  self.rollAmp = 0     -- degrees, 0 = off
  self.freq = 0.6
  self.octaves = 3
  self.maxSpeed = 10   -- m/s: speed where the shake reaches full strength (fades in linearly from 0)
  self.minAngle = 0    -- degrees: slip angle needed for the shake to start (0 = no dead zone)
  self.maxAngle = 30   -- degrees: slip angle where the shake reaches full strength (same forward or reverse)
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
function C:setMaxSpeed(v) self.maxSpeed = v end
function C:setMinAngle(v) self.minAngle = v end
function C:setMaxAngle(v) self.maxAngle = v end
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

function C:update(data, ctx)
  if not self.enabled then return end

  -- Falling gate: no shake while the car is in free fall (z acceleration ≤ -1 g).
  if data.dtSim > 0 then
    local az = (data.vel.z - data.prevVel.z) / data.dtSim
    if az <= -FALL_ACCEL then return end
  end

  -- Slip metric: velocity in the car frame (local Y = vehicle forward),
  -- vertical (local Z) component dropped.
  local v = ctx.flatVelocity
  v:setRotate(ctx.carRotInv, data.vel)
  v.z = 0
  if v:squaredLength() < FLATVEL_MIN_SQ then return end

  local vlen = v:length()

  -- Slip angle between vehicle forward and velocity; folded so a drift of the
  -- same angle in forward or reverse gives the same strength.
  local beta = math.acos(clamp(v.y / vlen, -1, 1))
  local alpha = math.min(beta, math.pi - beta)

  -- No shake below minAngle; then a linear ramp to full strength at maxAngle
  -- (both degrees). If maxAngle <= minAngle this degrades to a hard on/off
  -- at minAngle.
  local minRad = math.rad(self.minAngle)
  local range = math.max(math.rad(self.maxAngle) - minRad, ANGLE_EPS_RAD)
  local ramp = 0
  if alpha >= minRad then
    ramp = (alpha - minRad) / range
    if ramp > 1 then ramp = 1 end
  end

  -- Fades in from 0 to maxSpeed (m/s) so parked/sliding-in-place motion stays quiet.
  local fade = vlen / self.maxSpeed
  if fade > 1 then fade = 1 end
  local strength = ramp * fade
  if strength <= 0 then return end

  self.time = self.time + data.dt * be:getSimulationTimeScale()

  local fx = BASE_FREQ * self.freq
  local fy = BASE_FREQ * self.freq * AXIS_DESYNC_Y
  local fz = BASE_FREQ * self.freq * AXIS_DESYNC_Z
  local oct = self.octaves

  local ox, oy, oz = 0, 0, 0
  for i = 1, oct do
    local ampMul = 0.5 ^ (i - 1)
    local freqMul = 2 ^ (i - 1)
    ox = ox + sampleLUT(self._lutX[i], self.time * fx * freqMul + self.timeOffsetX) * ampMul
    oy = oy + sampleLUT(self._lutY[i], self.time * fy * freqMul + self.timeOffsetY) * ampMul
    oz = oz + sampleLUT(self._lutZ[i], self.time * fz * freqMul + self.timeOffsetZ) * ampMul
  end

  local scale = strength * DEG2RAD
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
