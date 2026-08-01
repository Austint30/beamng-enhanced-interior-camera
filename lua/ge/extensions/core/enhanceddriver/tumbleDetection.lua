-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- Fade g-force motion between 45 and 180 degrees per second of combined roll/pitch rotation.
-- Recorded tumbles sustained roughly 186-217 degrees per second, so effects are fully
-- suppressed just before the lower end of the observed tumble range.
local angularVelocityStart = math.rad(45)
local angularVelocityFull = math.rad(180)
local tumbleActivationDelay = 0.30
local logTag = 'enhanceddriver.tumbleDetection'

local C = {}
C.__index = C

function C:init()
  -- Suppression rises with the second rate and recovers with the first rate.
  -- Let sustained tumbles engage gradually, but restore normal camera effects
  -- promptly once the tumble ends.
  self.suppressionSmoother = newTemporalSmoothingNonLinear(6, 4, 0)
  self.previousUp = vec3()
  self.hasPreviousUp = false
  self.debugTimer = 0
  self.tumbleCandidateTime = 0
  self.tumbleCandidatePeak = 0
  self.tumbleDetected = false
end

function C:reset()
  self.suppressionSmoother:reset()
  self.hasPreviousUp = false
  self.debugTimer = 0
  self.tumbleCandidateTime = 0
  self.tumbleCandidatePeak = 0
  self.tumbleDetected = false
end

local function getRollPitchAngularVelocity(self, carUp, dt)
  if not self.hasPreviousUp then
    self.previousUp:set(carUp)
    self.hasPreviousUp = true
    return 0, 1, 0
  end

  local upDot = clamp(self.previousUp:dot(carUp), -1, 1)
  self.previousUp:set(carUp)

  if not dt or dt <= 0 then
    return 0, upDot, 0
  end

  -- The vehicle-up vector changes with roll and pitch, but remains unchanged by yaw.
  local upAngle = math.acos(upDot)
  return upAngle / dt, upDot, upAngle
end

function C:getGForceFactor(carUp, dt)
  local angularVelocity, upDot, upAngle = getRollPitchAngularVelocity(self, carUp, dt)

  -- Yaw is excluded so flat spins and drifting do not disable the effects.
  local angularVelocityRange = angularVelocityFull - angularVelocityStart
  local rawSuppressionTarget = smoothstep(clamp(
    (angularVelocity - angularVelocityStart) / angularVelocityRange,
    0,
    1
  ))
  local aboveThreshold = angularVelocity >= angularVelocityStart
  local previousCandidateTime = self.tumbleCandidateTime
  local previousCandidatePeak = self.tumbleCandidatePeak
  local wasTumbleDetected = self.tumbleDetected

  if aboveThreshold then
    self.tumbleCandidateTime = math.min(
      self.tumbleCandidateTime + math.max(dt or 0, 0),
      tumbleActivationDelay
    )
    self.tumbleCandidatePeak = math.max(self.tumbleCandidatePeak, angularVelocity)
    if self.tumbleCandidateTime >= tumbleActivationDelay then
      self.tumbleDetected = true
    end
  else
    self.tumbleCandidateTime = 0
    self.tumbleCandidatePeak = 0
    self.tumbleDetected = false
  end

  -- A brief rotation spike never reaches the smoother. Only a sustained tumble
  -- is allowed to begin suppressing camera effects.
  local suppressionTarget = self.tumbleDetected and rawSuppressionTarget or 0
  local suppression = self.suppressionSmoother:get(suppressionTarget, dt)
  local gForceFactor = 1 - clamp(suppression, 0, 1)

  if self.tumbleDetected ~= wasTumbleDetected then
    log(
      'D',
      logTag,
      string.format(
        'Tumble %s: angularVelocity=%.2f deg/s threshold=%.2f deg/s candidateTime=%.3f s suppressionTarget=%.4f',
        self.tumbleDetected and 'confirmed' or 'cleared',
        math.deg(angularVelocity),
        math.deg(angularVelocityStart),
        self.tumbleDetected and self.tumbleCandidateTime or previousCandidateTime,
        suppressionTarget
      )
    )
  elseif not aboveThreshold and previousCandidateTime > 0 then
    log(
      'D',
      logTag,
      string.format(
        'Tumble candidate ignored: duration=%.3f s required=%.3f s peakAngularVelocity=%.2f deg/s',
        previousCandidateTime,
        tumbleActivationDelay,
        math.deg(previousCandidatePeak)
      )
    )
  end

  if dt and dt > 0 then
    self.debugTimer = self.debugTimer + dt
  end
  if self.debugTimer >= 1 then
    self.debugTimer = 0
    log(
      'D',
      logTag,
      string.format(
        'Sample: dt=%.5f carUp=(%.4f, %.4f, %.4f) upDot=%.6f upDelta=%.3f deg angularVelocity=%.2f deg/s candidateTime=%.3f/%.3f s confirmed=%s rawSuppressionTarget=%.4f suppressionTarget=%.4f suppression=%.4f gForceFactor=%.4f',
        dt or 0,
        carUp.x,
        carUp.y,
        carUp.z,
        upDot,
        math.deg(upAngle),
        math.deg(angularVelocity),
        self.tumbleCandidateTime,
        tumbleActivationDelay,
        tostring(self.tumbleDetected),
        rawSuppressionTarget,
        suppressionTarget,
        suppression,
        gForceFactor
      )
    )
  end

  return gForceFactor
end

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
