-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- speedDistance — speed-based camera distance modulation (§5.10).
-- The boom distance grows with vehicle speed and eases back on the brakes:
--   target = maxDist * min(speed / maxSpeed, 1)
-- Smoothness is a TIME CONSTANT in seconds, integrated as a true exponential:
--   offset += (target - offset) * (1 - exp(-dt / smoothness))
-- so the response is the same at any framerate (the stock
-- newTemporalSmoothingNonLinear step is framerate-dependent):
--   0.1  → snappy
--   0.5  → moderate
--   2.0  → very smooth / lazy
-- Higher = more smoothing = slower response.
-- Speed comes from the vehicle velocity — `data.speed` is the UI camera-speed
-- modifier (2–100) and must NOT be used.
--
-- Brake cancellation: while the car is decelerating, the offset is scaled
-- down so the camera eases back toward the car during braking:
--   cancel = strength * min(deceleration / brakeDecel, 1)
--   offset *= (1 - cancel)
-- `strength` is a fraction 0..1 (settings store it as 0..100 %);
-- `brakeDecel` is the deceleration in g at which the cancellation is fully
-- applied. 0 g decel → no cancellation; above brakeDecel → full cancellation
-- (clamped).

local C = {}
C.__index = C

-- dtSim guard (s): below this the simulation step is degenerate and the
-- smoother must not integrate.
local DT_MIN = 1e-6
-- Gravity reference (m/s²): brakeDecel is configured in g.
local G_REF = 9.81
-- Brake input smoothing (s): time constant on the raw deceleration signal;
-- filters per-frame sim jitter without adding noticeable lag (0.1 s).
local BRAKE_INPUT_SMOOTH = 0.1

-- Framerate-independent exponential approach factor for a time constant (s).
-- Returns the fraction of the remaining offset to cover this frame.
local function responseAlpha(dt, timeConstant)
  if timeConstant <= 0 then return 1 end
  if dt <= 0 then return 0 end
  return 1 - math.exp(-dt / timeConstant)
end

function C:init()
  self.maxDist = 0.2
  self.maxSpeed = 134.74
  self.smoothness = 0.5
  self.brakeDecel = 1.0
  self.brakeStrength = 1.0
  self.enabled = true
  self._offset = 0
  self._brakeDecel = 0
  self._prevDtSim = nil
  self._initialized = false
end

function C:reset()
  self._offset = 0
  self._brakeDecel = 0
  self._prevDtSim = nil
  self._initialized = false
end

function C:setMaxDist(v) self.maxDist = v end
function C:setMaxSpeed(v) self.maxSpeed = v end
function C:setBrakeDecel(v) self.brakeDecel = v end
function C:setBrakeStrength(v) self.brakeStrength = v end

function C:setSmoothness(v)
  self.smoothness = v
end

function C:setEnabled(v) self.enabled = v end

-- Returns a scalar delta (m) to add to the boom length this frame.
-- Applied in arcadeOrbit.lua BEFORE the accel/decel distance modifier, which
-- then stacks on top of this offset.
function C:update(data)
  if not self.enabled then return 0 end
  if data.dtSim < DT_MIN then return self._offset end

  local speed = data.vel:length()
  local target
  if self.maxSpeed <= 0 then
    -- "Reach full offset at any non-zero speed."
    target = (speed > 0) and self.maxDist or 0
  else
    local ratio = speed / self.maxSpeed
    if ratio > 1 then ratio = 1 end
    target = self.maxDist * ratio
  end

  -- First frame after init/reset: adopt the current target so the offset
  -- never ramps in from the wrong side.
  if not self._initialized then
    self._offset = target
    self._initialized = true
    self._prevDtSim = data.dtSim
    return self:brakeCancel(self._offset, data, nil)
  end

  local prevDtSim = self._prevDtSim
  self._prevDtSim = data.dtSim

  self._offset = self._offset + (target - self._offset) * responseAlpha(data.dt, self.smoothness)
  return self:brakeCancel(self._offset, data, prevDtSim)
end

-- Brake cancellation (§5.10): scale the offset down while the car is
-- decelerating: cancel = strength * min(decel / brakeDecel, 1), where decel
-- is the (smoothed) loss of speed in g. No cancellation from 0 g up; the
-- scaling reaches `strength` at `brakeDecel` and stays clamped above it.
function C:brakeCancel(offset, data, prevDtSim)
  if self.brakeStrength <= 0 or offset == 0 then return offset end
  if self.brakeDecel <= 0 then return 0 end

  -- data.vel / data.prevVel are averages over consecutive camera intervals,
  -- so the time between those two samples is the mean of their sim deltas.
  -- Dividing by only the current dtSim would make the deceleration (and thus
  -- the cancellation) depend on the framerate.
  local decel = 0
  if prevDtSim then
    local span = (prevDtSim + data.dtSim) * 0.5
    if span > DT_MIN then
      decel = (data.prevVel:length() - data.vel:length()) / span
    end
  end
  if decel < 0 then decel = 0 end

  self._brakeDecel = self._brakeDecel
    + (decel - self._brakeDecel) * responseAlpha(data.dt, BRAKE_INPUT_SMOOTH)

  local ratio = (self._brakeDecel / G_REF) / self.brakeDecel
  if ratio > 1 then ratio = 1 end
  return offset * (1 - self.brakeStrength * ratio)
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
