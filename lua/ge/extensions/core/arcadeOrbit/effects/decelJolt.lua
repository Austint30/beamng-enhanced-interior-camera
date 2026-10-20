-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- decelJolt — Phase-4 g-force family: sudden deceleration jolt (crash impact).
-- Event-triggered ANIMATION, driven by the CHANGE in acceleration (jerk), not
-- its level:
--   1. The camera-frame longitudinal deceleration (g — the vehicle's
--      acceleration projected onto the camera's look direction) is smoothed
--      (time constant `accelSmooth`).
--   2. The frame-to-frame change of that estimate is the jerk (g/s). A jerk
--      above `minJerk` TRIGGERS the animation; its strength = the jerk ramped
--      0→1 between minJerk and `fullJerk` — the impact's blend-in amount.
--   3. The animation: a FAST dart to `maxRotation` (down) over the first
--      `attack` fraction of `duration`, then a DAMPED-COSINE settle back to
--      basis over the rest — the aim returns, swings past baseline by
--      ~`wobble` (the rebound) and stills (the decay envelope reaches 1 % at
--      the end of the duration). Wobble 0 = a plain exponential return with
--      no swing. A stronger impact mid-play deepens the in-flight animation
--      instead of restarting it (no visible cut-off).
-- Finally, a small amount of temporal smoothing is applied to the final value
-- (`smooth`, seconds; 0 = bypassed entirely, the raw animation value is used
-- unchanged).
-- Returns the signed aim ROTATION in radians (positive = aim down; 0 = idle).
-- arcadeOrbit.lua adds it to the g-force target offset's rotation, camera
-- position fixed.

local C = {}
C.__index = C

local G = 9.81              -- reference gravity (m/s²)
local MIN_JERK_RANGE = 1.0  -- g/s: lower bound on (fullJerk − minJerk) so the strength division stays finite
local ATTACK_MIN = 0.05     -- min attack fraction: keeps the climb window from collapsing to zero
local ATTACK_MAX = 0.95     -- max attack fraction: keeps the settle window from collapsing to zero
local SETTLE_TAIL = math.log(100) -- the settle envelope decays to 1 % over the settle phase
local WOBBLE_MIN = 0.011    -- below this the wobble is sub-degree — treat as plain decay
local WOBBLE_MAX = 0.999    -- keeps log(1/wobble) finite (a ~100 % rebound is the extreme setting)

local function rate(s)
  if s <= 0 then return 1000 end
  return 1 / s
end

local function smoothstep(x)
  return x * x * (3 - 2 * x)
end

-- Damped-cosine settle: 1 at u=0, decaying to 1 % at u=dur. The first rebound
-- undershoot (where cos first hits -1) is ~`wobble` of the peak; wobble below
-- WOBBLE_MIN is a plain exponential decay.
local function settle(u, dur, wobble)
  if dur <= 0 or u >= dur then return 0 end
  local tau = dur / SETTLE_TAIL
  local env = math.exp(-u / tau)
  if wobble >= WOBBLE_MIN then
    local w = math.min(WOBBLE_MAX, wobble)
    local omega = math.pi / (tau * math.log(1 / w))
    return env * math.cos(omega * u)
  end
  return env
end

function C:init()
  self.enabled = true
  self.minJerk = 20         -- g/s: change in acceleration needed to trigger the jolt (hard braking is ~5–10)
  self.fullJerk = 50        -- g/s: jerk at which the animation blends in at 100 %
  self.maxRotation = 45     -- degrees: how far the aim rotates down at a full-strength jolt
  self.duration = 0.8       -- s: full animation length (dart + settle)
  self.attack = 0.25        -- fraction of duration (0..1): the fast dart to the max angle; the rest settles back
  self.wobble = 0.3         -- fraction of the peak: how far past baseline the first rebound swings (0 = plain decay)
  self.accelSmooth = 0.15   -- s: time constant of the acceleration estimate used for jerk detection
  self.smooth = 0.1         -- s: temporal smoothing over the final value (0 = off, raw value passes through)
  self._accelSmoother = newTemporalSmoothingNonLinear(rate(self.accelSmooth), rate(self.accelSmooth), 0)
  self._outSmoother = newTemporalSmoothingNonLinear(rate(self.smooth), rate(self.smooth), 0)
  self._animT = -1          -- animation progress 0..1, -1 = idle
  self._animStrength = 0    -- 0..1 blend-in amount of the current animation
  self._outRad = 0
end

function C:reset()
  self._accelSmoother:reset()
  if self._outSmoother then self._outSmoother:reset() end
  self._animT = -1
  self._animStrength = 0
  self._outRad = 0
end

function C:setEnabled(v) self.enabled = v end
function C:setMinJerk(v) self.minJerk = v end
function C:setFullJerk(v) self.fullJerk = v end
function C:setMaxRotation(v) self.maxRotation = v end
function C:setDuration(v) self.duration = v end
function C:setAttack(v) self.attack = v end
function C:setWobble(v) self.wobble = v end
function C:setAccelSmooth(v)
  self.accelSmooth = v
  local r = rate(v)
  self._accelSmoother = newTemporalSmoothingNonLinear(r, r, 0)
end
function C:setSmooth(v)
  self.smooth = v
  if v > 0 then
    local r = rate(v)
    self._outSmoother = newTemporalSmoothingNonLinear(r, r, 0)
  else
    -- 0 = bypass: the raw animation value is used unchanged.
    self._outSmoother = nil
  end
end

-- ctx.camFwd: unit vec3, the camera's look direction (world space). The g is
-- measured in the camera frame: the chase cam flips to face the direction of
-- travel when reversing, so "forward" for the viewer is the view direction.
-- Returns this frame's signed aim rotation in radians (positive = down).
function C:update(data, ctx)
  if not self.enabled then
    self._animT = -1
    self._animStrength = 0
    self._outRad = 0
    return 0
  end
  if data.dtSim <= 0 then
    return self._outRad
  end

  if data.teleported then
    -- A teleport (rewind, recover, vehicle switch) zeroed data.vel while
    -- data.prevVel still holds the old speed — a phantom single-frame "impact"
    -- of hundreds of g. Don't let it trigger: drop the estimate and hold.
    self._accelSmoother:reset()
    return self._outRad
  end

  -- NOTE: everything below runs on data.dtSim (PHYSICS time), not data.dt
  -- (render dt). A crash reliably hitches the render frame; advancing the
  -- animation with render dt made the timer jump over the taper mid-play and
  -- snap the camera back to basis. Sim time advances only as the simulated
  -- crash advances (and slows correctly under slow motion).

  -- 1) Smoothed deceleration estimate (g) and its change (jerk, g/s).
  local fwd = ctx.camFwd
  local accLong = ((data.vel.x - data.prevVel.x) * fwd.x
                 + (data.vel.y - data.prevVel.y) * fwd.y
                 + (data.vel.z - data.prevVel.z) * fwd.z) / data.dtSim
  local g = -accLong / G -- g, + = decelerating
  if g < 0 then g = 0 end -- sudden acceleration belongs to accelJolt
  local prevAccel = self._accelSmoother:value()
  local newAccel = self._accelSmoother:get(g, data.dtSim)
  local jerk = (newAccel - prevAccel) / data.dtSim -- g/s

  -- 2) Trigger: jerk ramped 0→1 between minJerk and fullJerk. A stronger
  -- impact while the animation is playing DEEPENS it (no timer reset — a hard
  -- restart would cut the visible dip off mid-taper).
  if jerk > self.minJerk then
    local strength = (jerk - self.minJerk) / math.max(self.fullJerk - self.minJerk, MIN_JERK_RANGE)
    if strength > 1 then strength = 1 end
    if self._animT < 0 then
      self._animT = 0
      self._animStrength = strength
    elseif strength > self._animStrength then
      self._animStrength = strength
    end
  end

  -- 3) Animation: a fast dart to the max angle over the first `attack`
  -- fraction of the duration, then a damped-cosine SETTLE back to basis —
  -- the aim returns, swings past baseline by ~`wobble` (the rebound), and
  -- stills (the decay envelope reaches 1 % at the end of the duration).
  if self._animT >= 0 then
    self._animT = self._animT + data.dtSim / math.max(self.duration, 0.05)
    if self._animT >= 1 then
      self._animT = -1
      self._outRad = 0
    else
      local at = math.max(ATTACK_MIN, math.min(ATTACK_MAX, self.attack))
      local curve
      if self._animT < at then
        curve = smoothstep(self._animT / at)
      else
        local u = (self._animT - at) * self.duration -- s since the dart ended
        curve = settle(u, self.duration * (1 - at), self.wobble)
      end
      local raw = curve * self._animStrength * math.rad(self.maxRotation)
      self._outRad = self._outSmoother and self._outSmoother:get(raw, data.dtSim) or raw
    end
  end
  return self._outRad
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
