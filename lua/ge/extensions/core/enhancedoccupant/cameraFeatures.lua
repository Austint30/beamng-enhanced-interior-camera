-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local vecY = vec3(0, 1, 0)
local vecZ = vec3(0, 0, 1)
local min, max, abs = math.min, math.max, math.abs

local qtmp = quat()
local function rotateEuler(x, y, z, q)
  q = q or quat()
  qtmp:setFromEuler(0, z, 0)
  q:setMul2(qtmp, q)
  qtmp:setFromEuler(0, 0, x)
  q:setMul2(qtmp, q)
  qtmp:setFromEuler(y, 0, 0)
  q:setMul2(qtmp, q)
  return q
end

local shake = require('core/cameraModes/speedshake')
local profiler = require('core/enhancedoccupant/profiler')
local steeringLookAhead = require('core/enhancedoccupant/steeringLookAhead')
local tumbleDetection = require('core/enhancedoccupant/tumbleDetection')

-- BeamNG's core only injects per-seat occupant camera data (camNodeID, seatSide,
-- shoulder offsets, seat-specific ref nodes, ...) into instances of its built-in
-- multicam modes ('onboard', 'occupant'). Custom camera modes like this one are
-- constructed with an empty config, so the seat data has to be mirrored from the
-- occupant camera instance core built for the seat the player currently occupies.
-- Returns the best matching camera instance, or nil when nothing is available.
local function findSeatCamera(vehId, player)
  if not vehId or vehId == -1 or not core_camera or not core_camera.getCameraDataById then
    return nil
  end
  local ctxId = core_camera.getContextIdForPlayer
    and core_camera.getContextIdForPlayer(player) or nil
  local cameras = core_camera.getCameraDataById(vehId, ctxId)
  if not cameras then return nil end

  -- Preferred: the occupant camera of the seat this player is physically in.
  local seatOcc = rawget(_G, 'gameplay_seatOccupants')
  if seatOcc and seatOcc.getPlayerPresence then
    local presence = seatOcc.getPlayerPresence(player or 0)
    if presence and presence.vehicleId == vehId and presence.seatId then
      local seatCam = cameras['occupant.' .. presence.seatId]
      if seatCam then return seatCam end
    end
  end

  -- No presence (unseated, or the seat system is unavailable): use the driver
  -- seat's occupant camera if the vehicle has one.
  for camName, cam in pairs(cameras) do
    if camName:find('^occupant%.', 1) and cam.defaultPermissionMode == 'driver' then
      return cam
    end
  end

  -- Legacy vehicles without occupant slots: the 'driver' alias instance and the
  -- 'onboard.driver' instance carry the JBeam driver-camera seat data.
  if cameras.driver and cameras.driver.camNodeID then return cameras.driver end
  if cameras['onboard.driver'] and cameras['onboard.driver'].camNodeID then
    return cameras['onboard.driver']
  end
end

-- Seat label used for the camera-switch toast, mirroring core_camera's occupant
-- naming: displayName from JBeam, falling back to driver/passenger seat strings.
local function getEnhancedSeatLabel(vehId, player)
  local seatCam = findSeatCamera(vehId, player)
  if not seatCam then return nil end
  local isDriver = seatCam.defaultPermissionMode == 'driver'
    or seatCam.seatId == 'driver'
    or seatCam.name == 'driver'
  return seatCam.displayName
    or (isDriver and 'ui.gameplay.seatOccupants.driverSeat'
      or 'ui.gameplay.seatOccupants.passengerSeat')
end

-- Normalize camera UI events so enhancedoccupant looks like occupant to the UI.
-- Fixes cockpit UI showing when this camera is active.
do
  local gh = rawget(_G, 'guihooks')
  if type(gh) == 'table' and type(gh.trigger) == 'function' and not gh._edc_wrapped then
    local orig = gh.trigger
    gh.trigger = function(evt, payload, ...)
      -- onCameraNameChanged drives cockpit app hide/show
      if evt == 'onCameraNameChanged' then
        if type(payload) ~= 'table' then payload = { name = payload } end
        if payload.name == 'enhancedoccupant' then
          payload.name = 'occupant'
        end
        -- Options > Cameras and other UI consumers
      elseif evt == 'CameraConfigChanged' and type(payload) == 'table' then
        if payload.focusedCamName == 'enhancedoccupant' then
          payload.focusedCamName = 'occupant'
        end
        -- Toast parity with the built-in occupant camera: core names its seat
        -- cameras "Occupant Camera - <seat>", while this camera would otherwise
        -- announce as the plain mode label. Swap the message for the occupant
        -- variant with the current seat's name.
      elseif evt == 'Message' and type(payload) == 'table'
          and payload.txt == 'ui.camera.switched'
          and type(payload.context) == 'table'
          and payload.context.name == 'ui.camera.mode.enhancedoccupant' then
        local veh = be and be.getPlayerVehicle and be:getPlayerVehicle(0)
        local occupantName = veh and getEnhancedSeatLabel(veh:getId(), 0)
        if occupantName then
          payload.txt = 'ui.camera.switchedOccupant'
          payload.context = { occupantName = occupantName }
        end
      end
      return orig(evt, payload, ...)
    end
    gh._edc_wrapped = true
  end
end

-- Also normalize extensions.hook('onCameraModeChanged', camName)
do
  local ex = rawget(_G, 'extensions')
  if type(ex) == 'table' and type(ex.hook) == 'function' and not ex._edc_cam_wrap then
    local origHook = ex.hook
    ex.hook = function(evt, ...)
      if evt == 'onCameraModeChanged' then
        local camName = select(1, ...)
        if camName == 'enhancedoccupant' then
          -- replace first arg and forward remaining args intact
          return origHook(evt, 'occupant', select(2, ...))
        end
      end
      return origHook(evt, ...)
    end
    ex._edc_cam_wrap = true
  end
end

local cameraEffectSuppressionDuration = 0.5
local cameraEffectRecoveryRate = 8

local forcePitchAxis, forcePitchRot = vec3(), quat()
local camUp, attachedCamRot = vec3(), quat()
local normalCamFwd, normalCamUp = vec3(), vec3()
local attachedCamFwd, attachedCamUp = vec3(), vec3()
local blendedCamFwd, blendedCamUp = vec3(), vec3()
local nRockPos, projectedRockPos = vec3(), vec3()

local function initEnhancedOccupant(self)
  self.steeringLookAhead = steeringLookAhead()
  self.tumbleDetection = tumbleDetection()
  self.gForceFwdSmoother = newTemporalSmoothingNonLinear(4, 4)
  self.gForceSideSmoother = newTemporalSmoothingNonLinear(4, 4)
  self.gForceSideLeanSmoother = newTemporalSmoothingNonLinear(4, 4)
  self.gForceUpSmoother = newTemporalSmoothingNonLinear(5, 5)
  self.velSmootherX = newTemporalSmoothingNonLinear(12, 16)
  self.velSmootherY = newTemporalSmoothingNonLinear(12, 16)
  self.velSmootherZ = newTemporalSmoothingNonLinear(12, 16)
  self.cameraEffectSuppressionTimer = cameraEffectSuppressionDuration
  self.cameraEffectRecoverySmoother = newTemporalSmoothingNonLinear(
    cameraEffectRecoveryRate,
    cameraEffectRecoveryRate,
    0
  )

  self.gForceYBase = 0.45
  self.gForceSideYawBase = 0.3
  self.gForceSideRollBase = 0.3
  self.gForceSideLeanRollBase = 0.3
  self.gForceZBase = 0.8

  self.speedshake = shake()
  self.speedshake:init()

  self.driftshake = shake()
  self.driftshake:init(vec3(0.3, 0.1, 0.1), vec3(5.0, 5.0, 5.0), true)
  self.hasResetted = false

  self.defaultSettings = jsonReadFile('/lua/ge/extensions/core/cameraModes/enhancedoccupantDefaults.json')
  self.edcSettings = {}
  self:initEnhancedOccupantSettings()

  self.lastCarFwd = vec3()
  self.lastCarLeft = vec3()
  self.currFov = 0
  self.lastSmoothRate = 0
  self.disabledCockpitApps = false
end

local function onEnhancedCameraChanged(self)
  self.disabledCockpitApps = false
end

local function disableCockpitApps(self)
  if not self.disabledCockpitApps then
    -- Disable cockpit gui apps
    guihooks.trigger('onCameraNameChanged', { name = 'occupant' })
    self.disabledCockpitApps = true
  end
end

local function initEnhancedOccupantSettings(self)
  for k, v in pairs(self.defaultSettings.presets['Default']) do
    self.edcSettings[k] = v
  end
end

local function resetTransientCameraEffects(self)
  self.rockPos:set(0, 0, 0)
  self.fwdSpeed = 0
  self.steeringLookAhead:reset()
  self.tumbleDetection:reset()
  self.cameraEffectRecoverySmoother:set(0)

  self.gForceFwdSmoother:reset()
  self.gForceSideSmoother:reset()
  self.gForceSideLeanSmoother:reset()
  self.gForceUpSmoother:reset()
  self.velSmootherX:reset()
  self.velSmootherY:reset()
  self.velSmootherZ:reset()

  if self.fovSmoother then self.fovSmoother:set(0) end
end

local function suppressCameraEffects(self)
  self.cameraEffectSuppressionTimer = cameraEffectSuppressionDuration
  self:resetTransientCameraEffects()
end

local function updateCameraEffectFactor(self, dt)
  if self.cameraEffectSuppressionTimer > 0 then
    self.cameraEffectSuppressionTimer = max(self.cameraEffectSuppressionTimer - dt, 0)
    return 0
  end

  return self.cameraEffectRecoverySmoother:get(1, dt)
end

local function onEnhancedVehicleCameraConfigChanged(self)
  self.steeringLookAhead:invalidateRegistration()
  self:suppressCameraEffects()
end

local function loadSettingsPreset(self)
  profiler.start('LoadPreset') -- enhancedoccupant: dynamic preset merge
  local defaultPresets = {
    ['Default'] = true,
    ['Lookahead'] = true,
    ['Intense'] = true,
    ['Smooth'] = true,
    ['VR (Comfort)'] = true,
    ['VR (Thrill)'] = true
  }

  local edcSettings = self.defaultSettings

  local loadedSettings = settings.getValue('edcSettings')

  if loadedSettings then
    if loadedSettings.chosenPreset then
      edcSettings.chosenPreset = loadedSettings.chosenPreset
    end
    if loadedSettings.presets then
      for loadedPreset, _ in pairs(loadedSettings.presets) do
        if not defaultPresets[loadedPreset] then
          edcSettings.presets[loadedPreset] = loadedSettings.presets[loadedPreset]
        end
      end
    end
  end

  if edcSettings == nil then
    log("E", "", "Failed to load Enhanced Interior Camera settings!")
    return {}
  end

  local activePreset = edcSettings.presets[edcSettings.chosenPreset]

  -- Merge activePreset with default settings
  -- This is so old settings get updated with new default settings if updating to a new version
  local defaultPreset = self.defaultSettings.presets['Default']
  local mergedPreset = {}

  for key, value in pairs(defaultPreset) do
    mergedPreset[key] = value
  end

  if activePreset then
    for key, value in pairs(activePreset) do
      mergedPreset[key] = value
    end
  end
  profiler.stop('LoadPreset')
  return mergedPreset
end

local function onEnhancedSettingsChanged(self)
  self.edcSettings = self:loadSettingsPreset()
  self.speedshake:setAmpMultiplier(self:getSettingsValue('speedShakeAmp'))
  self.speedshake:setFreqMultiplier(self:getSettingsValue('speedShakeFreq'))
  self.speedshake:setOctaves(self:getSettingsValue('speedShakeDetail'))
  self.speedshake:setMinSpeed(self:getSettingsValue('speedShakeMinSpeed'))
  self.speedshake:setMaxSpeed(self:getSettingsValue('speedShakeMaxSpeed'))

  self.driftshake:setAmpMultiplier(self:getSettingsValue('driftShakeAmp'))
  self.driftshake:setFreqMultiplier(self:getSettingsValue('driftShakeFreq'))

  local fovSmoothRate = lerp(10, 0.5, self:getSettingsValue('fovSmoothRate') / 100)
  if abs(fovSmoothRate - self.lastSmoothRate) > 0.1 then
    -- Prevents a jutter effect when any setting is changed other than the FOV.
    self.fovSmoother = newTemporalSmoothingNonLinear(fovSmoothRate, fovSmoothRate, self.currFov)
  end
  self.lastSmoothRate = fovSmoothRate
end

local function getSettingsValue(self, key, fallback)
  if not self.edcSettings or self.edcSettings[key] == nil then
    return fallback == nil and 1 or fallback
  end
  return self.edcSettings[key]
end

local function resetEnhancedOccupant(self)
  self.steeringLookAhead:invalidateRegistration()
  self:suppressCameraEffects()
end

local function updateEnhancedFov(self, data, cameraEffectFactor, zoomSmoothed)
  profiler.start('FOVSpeedMod')
  self.currFov = data.res.fov
  if cameraEffectFactor <= 0 then
    data.res.fov = self.manualzoom.fov
    data.res.fov = zoomSmoothed * 27 + (1 - zoomSmoothed) * data.res.fov
    profiler.stop('FOVSpeedMod')
    return
  end

  local speed = data.vel:length()

  -- if speed < self.minSpeedFovMod then
  --   data.res.fov = self.manualzoom.fovDefault
  --   return
  -- end

  local high = self.edcSettings.fovMaxSpeed
  local low = self.edcSettings.fovMinSpeed

  local rawFovScale = clamp((speed - low) / (high - low), 0, 1)

  local smoothedFovScale = self.fovSmoother:get(rawFovScale, data.dt)

  local addedFov = smoothedFovScale * self.edcSettings.fovAddDegrees * cameraEffectFactor

  local newFov = self.manualzoom.fov + addedFov
  data.res.fov = newFov
  data.res.fov = zoomSmoothed * 27 + (1 - zoomSmoothed) * data.res.fov
  profiler.stop('FOVSpeedMod')
end

local function getEnhancedPhysicsFactor(self, cameraEffectFactor)
  return self.physicsFactor * cameraEffectFactor
end

local function beginEnhancedPhysicsTransform(self)
  profiler.start('PhysicsTransform')
end

local function endEnhancedPhysicsTransform(self)
  profiler.stop('PhysicsTransform')
end

local function updateEnhancedCameraRotation(self, data, cameraEffectFactor, carLeft, carFwd, carUp, carRot, carRotInverse, camRot)
  -- The camera looks along -carFwd, so its vehicle-relative pitch axis is -carLeft.
  -- Capture it before camera orientation smoothing modifies carLeft.
  forcePitchAxis:set(-push3(carLeft))
  local detectedTumbleFactor = self.tumbleDetection:getGForceFactor(carUp, data.dt)
  local gForceTumbleFactor = lerp(1, detectedTumbleFactor, cameraEffectFactor)

  local attachToCarWhileTumbling = self:getSettingsValue('disableHorizonLockWhileTumbling', false)
  local pitchHorizonLock = self:getSettingsValue('lockPitchToHorizon', 0)
  local rollHorizonLock = self:getSettingsValue('lockRollToHorizon', 0)

  -- Smooth velocity using rock on a string algorithm
  self.rockPos:set(push3(self.rockPos) - push3(data.vel) * data.dt)
  projectedRockPos:setProjectToOriginPlane(carUp, self.rockPos)
  projectedRockPos:resize(min(self.rockPos:length(), self.lookAheadSmoothness))
  -- When vehicle flips, left and right sides of it flip aswell. To prevent this from happening
  -- We tempereraly stop projecting the rock position
  if self.rockPos:distance(projectedRockPos) < 0.1 then
    self.rockPos:set(projectedRockPos)
  else
    self.rockPos:resize(min(self.rockPos:length(), self.lookAheadSmoothness))
  end

  -- Smooth car fwd direction
  -- Full tumble attachment raises the follow factor to 1, removing orientation lag.
  local pitchSmoothingFactor = (1 - self:getSettingsValue('pitchSmoothing', 0)) * data.dt * 20
  local pitchFollowFactor = lerp(1, pitchSmoothingFactor, gForceTumbleFactor)
  pitchFollowFactor = lerp(1, pitchFollowFactor, cameraEffectFactor)
  local lerpedCarFwd = lerp(self.lastCarFwd, carFwd, pitchFollowFactor)
  carFwd.z = lerpedCarFwd.z
  self.lastCarFwd:set(carFwd)

  -- Smooth car left direction
  local rollSmoothingFactor = (1 - self:getSettingsValue('rollSmoothing', 0)) * data.dt * 20
  local rollFollowFactor = lerp(1, rollSmoothingFactor, gForceTumbleFactor)
  rollFollowFactor = lerp(1, rollFollowFactor, cameraEffectFactor)
  local lerpedCarLeft = lerp(self.lastCarLeft, carLeft, rollFollowFactor)
  carLeft.z = lerpedCarLeft.z
  self.lastCarLeft:set(carLeft)

  -- Stable horizon
  carRot:setFromDir(carFwd, carUp)
  camRot:setFromDir(-push3(carFwd))
  camUp:setRotate(camRot, vecZ)
  local carRoll = math.atan2(push3(camUp):dot(-push3(carLeft)), camUp:dot(carUp))
  local carRollFactor = 1 - rollHorizonLock * smootheststep(clamp(1.42 * carUp.z, 0, 1))
  local camRoll = carRoll * carRollFactor

  local carPitch = math.atan2(push3(vecZ):dot(-push3(carFwd)), camUp:dot(carUp))
  local carPitchFactor = pitchHorizonLock * smoothstep(clamp(1.2 * carUp.z, 0, 1))
  local camPitch = carPitch * carPitchFactor

  -- Look-ahead angle
  self.fwdSpeed = lerp(self.fwdSpeed, -data.vel:length() * push3(data.vel):normalized():dot(carFwd),
    data.dt * (1.5 - self.lookAheadSmoothness))
  nRockPos:set(push3(carFwd) * (1 - self.rockPos:length() / self.lookAheadSmoothness) + self.rockPos)
  nRockPos:normalize()
  local lookAheadAngle = data.openxrSessionRunning and 0 or self.lookAheadAngle -- disable LookAhead while in VR
  local lookAheadAngleOffset = math.atan2(nRockPos.x * carFwd.y - nRockPos.y * carFwd.x,
    nRockPos.x * carFwd.x + nRockPos.y * carFwd.y)
  self.rockPos:setScaled((1 - data.dt * 0.1) * clamp(self.fwdSpeed / 20, 0, 1))
  lookAheadAngleOffset = clamp(lookAheadAngleOffset, -1.1, 1.1) * lookAheadAngle * clamp(self.fwdSpeed / 15, 0, 1)
  lookAheadAngleOffset = lookAheadAngleOffset * cameraEffectFactor

  -- Steering look-ahead follows the supported, normalized vehicle steering input.
  -- Keep it separate from BeamNG's velocity-based look-ahead so users can tune it independently.
  local steeringLookAheadAngleOffset = self.steeringLookAhead:getAngleOffset(
    data,
    self:getSettingsValue('steeringLookAheadAngle', 0),
    self:getSettingsValue('steeringLookAheadSmoothness', 50)
  )
  steeringLookAheadAngleOffset = steeringLookAheadAngleOffset * cameraEffectFactor

  -- Rotate the camera in response to longitudinal, lateral, and vertical g-forces.
  profiler.start('GForce') -- Added g-force smoothing and rotation blending (enhancedoccupant)
  local rawFwdForce, rawSideForce, rawUpForce = 0, 0, 0
  if cameraEffectFactor > 0 and data.dt > 1e-6 then
    local accel = carRotInverse * data.vel - carRotInverse * data.prevVel

    -- Smooth acceleration data
    accel.x = self.velSmootherX:get(accel.x, data.dt)
    accel.y = self.velSmootherY:get(accel.y, data.dt)
    accel.z = self.velSmootherZ:get(accel.z, data.dt)

    rawFwdForce = -accel.y / (data.dt * 100) * cameraEffectFactor
    -- Vehicle-space +X points left, while positive camera yaw looks right.
    rawSideForce = accel.x / (data.dt * 100) * cameraEffectFactor
    rawUpForce = -accel.z / (data.dt * 100) * cameraEffectFactor
  end

  -- Reduce impact of braking being detected as upward acceleration
  rawUpForce = lerp(0, rawUpForce, clamp(rawUpForce / -0.3, 0, 1))

  -- Reduce shaking while idle by blending the g-force effect in at speed
  local gForceEffectFactor = clamp(data.vel:length() / 4, 0, 1)
  rawFwdForce = lerp(0, rawFwdForce, gForceEffectFactor)
  rawSideForce = lerp(0, rawSideForce, gForceEffectFactor)
  rawUpForce = lerp(0, rawUpForce, gForceEffectFactor)
  local rawSideLeanForce = rawSideForce

  local gForceZThreshold = self:getSettingsValue('gForceZThreshold', 0) / 100
  local gForceYThreshold = self:getSettingsValue('gForceYThreshold', 0) / 100
  local gForceXThreshold = self:getSettingsValue('gForceXThreshold', 0) / 100
  local gForceSideLeanRollThreshold = self:getSettingsValue('gForceSideLeanRollThreshold', 0) / 100

  -- Add an activation threshold to forces ------------------------
  if rawUpForce < -gForceZThreshold then
    rawUpForce = rawUpForce + gForceZThreshold
  else
    rawUpForce = 0
  end

  if rawFwdForce > 0 and rawFwdForce > gForceYThreshold then
    rawFwdForce = rawFwdForce - gForceYThreshold
  elseif rawFwdForce < 0 and rawFwdForce < -gForceYThreshold then
    rawFwdForce = rawFwdForce + gForceYThreshold
  else
    rawFwdForce = 0
  end

  if rawSideForce > gForceXThreshold then
    rawSideForce = rawSideForce - gForceXThreshold
  elseif rawSideForce < -gForceXThreshold then
    rawSideForce = rawSideForce + gForceXThreshold
  else
    rawSideForce = 0
  end

  if rawSideLeanForce > gForceSideLeanRollThreshold then
    rawSideLeanForce = rawSideLeanForce - gForceSideLeanRollThreshold
  elseif rawSideLeanForce < -gForceSideLeanRollThreshold then
    rawSideLeanForce = rawSideLeanForce + gForceSideLeanRollThreshold
  else
    rawSideLeanForce = 0
  end
  -----------------------------------------------------------------

  local smoothedFwdForce = self.gForceFwdSmoother:get(rawFwdForce, data.dt)
  local smoothedSideForce = self.gForceSideSmoother:get(rawSideForce, data.dt)
  local sideLeanSmoothness = clamp(self:getSettingsValue('gForceSideLeanRollSmoothness', 75) / 100, 0, 1)
  local sideLeanSmoothingRate = lerp(8, 0.25, smootheststep(sideLeanSmoothness))
  local smoothedSideLeanForce = self.gForceSideLeanSmoother:getWithRate(
    rawSideLeanForce,
    data.dt,
    sideLeanSmoothingRate
  )
  local smoothedUpForce = self.gForceUpSmoother:get(rawUpForce, data.dt)

  if self.hasResetted then
    smoothedFwdForce = 0
    smoothedSideForce = 0
    smoothedSideLeanForce = 0
    smoothedUpForce = 0
  end

  local sideImpactYawAngleFromForces = math.atan2(
    smoothedSideForce * self.gForceSideYawBase * self:getSettingsValue('gForceSideYaw'),
    1
  )
  local sideImpactRollAngleFromForces = math.atan2(
    -smoothedSideForce * self.gForceSideRollBase * self:getSettingsValue('gForceSideRoll'),
    1
  )
  -- Impact roll follows the inertial head yank; lean-in roll follows the applied lateral force.
  local sideLeanRollAngleFromForces = math.atan2(
    smoothedSideLeanForce * self.gForceSideLeanRollBase * self:getSettingsValue('gForceSideLeanRoll', 0),
    1
  ) * gForceTumbleFactor
  local scaledUpForce = smoothedUpForce * self.gForceZBase * self:getSettingsValue('gForceZ')
  local scaledFwdForce = 0
  if smoothedFwdForce >= 0 then
    scaledFwdForce = smoothedFwdForce * self.gForceYBase * self:getSettingsValue('gForceAccel')
  else
    scaledFwdForce = smoothedFwdForce * self.gForceYBase * self:getSettingsValue('gForceDecel')
  end

  local pitchAngleFromForces = -math.atan2(scaledUpForce + scaledFwdForce, 1)

  local horizonPitchOffset = lerp(0, camPitch, pitchHorizonLock)

  local cameraYawOffset = math.rad(self.camRot.x) + lookAheadAngleOffset +
    steeringLookAheadAngleOffset + sideImpactYawAngleFromForces
  local cameraPitchOffset = math.rad(self.camRot.y) + horizonPitchOffset
  local cameraRollOffset = camRoll + sideImpactRollAngleFromForces + sideLeanRollAngleFromForces

  camRot = rotateEuler(
    cameraYawOffset,
    cameraPitchOffset,
    cameraRollOffset,
    camRot
  ) -- stable hood line

  -- Normal-force and acceleration/deceleration pitch belongs to the vehicle frame,
  -- not the potentially horizon-locked camera frame.
  forcePitchRot:setFromAxisAngle(forcePitchAxis, pitchAngleFromForces)
  camRot:setMul2(camRot, forcePitchRot)

  if attachToCarWhileTumbling and gForceTumbleFactor < 1 then
    -- Blend the forward and up axes separately instead of switching algorithms or
    -- interpolating whole quaternions. This preserves a gradual attachment while
    -- avoiding the unwanted yaw arc produced by quaternion interpolation.
    normalCamFwd:setRotate(camRot, vecY)
    normalCamUp:setRotate(camRot, vecZ)

    attachedCamRot:setFromDir(-push3(carFwd), carUp)
    rotateEuler(
      cameraYawOffset,
      math.rad(self.camRot.y),
      sideImpactRollAngleFromForces + sideLeanRollAngleFromForces,
      attachedCamRot
    )
    attachedCamRot:setMul2(attachedCamRot, forcePitchRot)
    attachedCamFwd:setRotate(attachedCamRot, vecY)
    attachedCamUp:setRotate(attachedCamRot, vecZ)

    local attachmentFactor = 1 - gForceTumbleFactor
    blendedCamFwd:setLerp(normalCamFwd, attachedCamFwd, attachmentFactor)
    blendedCamUp:setLerp(normalCamUp, attachedCamUp, attachmentFactor)

    -- A near-opposite vector pair can briefly collapse a linear blend. Falling back
    -- to the attached axis keeps the result valid at extreme tumble orientations.
    if blendedCamFwd:squaredLength() < 1e-8 then blendedCamFwd:set(attachedCamFwd) end
    if blendedCamUp:squaredLength() < 1e-8 then blendedCamUp:set(attachedCamUp) end
    blendedCamFwd:normalize()
    blendedCamUp:normalize()
    camRot:setFromDir(blendedCamFwd, blendedCamUp)
  end
  profiler.stop('GForce')
end

local function updateEnhancedShakes(self, data, cameraEffectFactor, carRotInverse, carRot)
  profiler.start('SpeedShake') -- Added speed-dependent shake effect (enhancedoccupant)
  local speedShakeStrength = cameraEffectFactor > 0 and self.speedshake:getShakeStrength(data) * cameraEffectFactor or 0
  self.speedshake:update(data, speedShakeStrength)
  profiler.stop('SpeedShake')

  -- Detect angle of drift and apply camera shake
  -- (Is it possible to do apply this with wheel slip instead?)
  profiler.start('DriftShake') -- Added drift angle shake effect (enhancedoccupant)
  local driftAngle = 0
  if cameraEffectFactor > 0 then
    local flatVelocity = carRotInverse * data.vel
    flatVelocity.z = 0
    flatVelocity = carRot * flatVelocity

    if flatVelocity:squaredLength() > 1e-8 then
      driftAngle = carRot:dot(quatFromDir(flatVelocity))

      if driftAngle >= 0.5 then
        driftAngle = 1 - driftAngle
      end

      driftAngle = driftAngle * 1.5
      driftAngle = lerp(0, driftAngle, clamp(flatVelocity:length() / 10, 0, 1))
    end
  end

  self.driftshake:update(data, driftAngle * cameraEffectFactor)
  self.hasResetted = false
  profiler.stop('DriftShake')
  profiler.frame(data.dt)
end

-- Bind (or re-bind) the camera to the occupant seat core currently places the
-- player in. All seat-specific state lives on the built-in camera instance core
-- created for that seat, so mirror it onto this instance and re-anchor when the
-- seat changes.
--
-- Shoulder profile fallbacks, mirroring the base occupant camera defaults:
-- legacy vehicles without occupant slots have no profiles on their camera
-- instance, and the base update() indexes shoulder.startYaw unconditionally.
local shoulderInteriorDefaults = {
  startYaw = 70,
  lateralOffset = 0.26,
  forwardOffset = -0.075,
  verticalOffset = -0.02,
  forwardMultiplier = 1,
  verticalMultiplier = 1,
}

local shoulderExteriorDefaults = {
  startYaw = 70,
  lateralOffset = 0.6,
  forwardOffset = -0.3,
  verticalOffset = -0.1,
  forwardMultiplier = 1.75,
  verticalMultiplier = 1,
}

local function resolveShoulder(side, seatSide, configured)
  local exterior = side == seatSide and seatSide ~= 'center'
  local profile = deepcopy(exterior and shoulderExteriorDefaults or shoulderInteriorDefaults)
  tableMergeRecursive(profile, configured or {})
  return profile
end

local function bindSeatCamera(self, data, seatCam)
  local previous = self._boundSeatCam
  local sameSeat = previous ~= nil and previous.seatId == (seatCam and seatCam.seatId)
  self._boundSeatCam = seatCam

  if seatCam then
    local seatSide = seatCam.seatSide
    if not seatSide and seatCam.rightHandCamera ~= nil then
      -- Legacy onboard driver camera: rightHandCamera names the seat side.
      seatSide = seatCam.rightHandCamera and 'right' or 'left'
    end
    seatSide = seatSide or 'center'
    self.camNodeID = seatCam.camNodeID
    self.seatId = seatCam.seatId
    self.seatSide = seatSide
    self.shoulderLeft = resolveShoulder('left', seatSide, seatCam.shoulderLeft)
    self.shoulderRight = resolveShoulder('right', seatSide, seatCam.shoulderRight)
    self.lookBack = seatCam.lookBack or { side = 'auto', yaw = 160 }
    self.idRefOccupant = seatCam.idRefOccupant
    self.idLeftOccupant = seatCam.idLeftOccupant
    self.idBackOccupant = seatCam.idBackOccupant
    self.occupantRefNodes = {
      ref = seatCam.idRefOccupant,
      left = seatCam.idLeftOccupant,
      back = seatCam.idBackOccupant,
    }
    if seatCam.refNodes then
      -- Copy the seat's ref node ids instead of sharing the table: the base
      -- setRefNodes() mutates self.refNodes in place when core rebuilds the
      -- vehicle cameras, and must not write through to the seat instance.
      self.refNodes = self.refNodes or {}
      self.refNodes.ref = seatCam.refNodes.ref
      self.refNodes.left = seatCam.refNodes.left
      self.refNodes.back = seatCam.refNodes.back
    end
  else
    self.camNodeID = nil
    self.seatId = nil
    self.seatSide = 'center'
    self.idRefOccupant = nil
    self.idLeftOccupant = nil
    self.idBackOccupant = nil
    self.occupantRefNodes = { ref = nil, left = nil, back = nil }
    self._seatBoundOnce = false
  end

  if sameSeat then return end
  if seatCam then
    -- Re-anchor: reload the seat position for the new seat key, re-capture the
    -- static camera position and suppress transient effects during the jump.
    self:onVehicleCameraConfigChanged()
    -- Parity with the built-in camera: announce the seat when the binding
    -- changes mid-session (the initial bind is already announced by core's own
    -- focus toast).
    if self._seatBoundOnce then
      core_camera.displayCameraNameUI(data.player or 0)
    end
    self._seatBoundOnce = true
  end
end

local function syncEnhancedSeat(self, data)
  local vehId = data.veh and data.veh:getId()
  local seatCam = findSeatCamera(vehId, data.player)
  if seatCam then
    -- Core forwards occupant detachment to its own seat cameras; mirror the flag
    -- so this instance switches to the occupant ref nodes as well.
    self.occupantDetached = seatCam.occupantDetached == true
    if seatCam == self._boundSeatCam then return end
  elseif self._boundSeatCam == nil then
    return
  end
  bindSeatCamera(self, data, seatCam)
end

local function beginEnhancedUpdate(self, data)
  -- BeamNG marks vehicle rewinds and teleports in the supported camera data.
  -- Vehicle respawns/reloads also reach suppressCameraEffects through reset().
  if data.teleported then self:suppressCameraEffects() end

  syncEnhancedSeat(self, data)

  self:disableCockpitApps()
end

local M = {}

function M.install(C)
  C.initEnhancedOccupant = initEnhancedOccupant
  C.onEnhancedCameraChanged = onEnhancedCameraChanged
  C.disableCockpitApps = disableCockpitApps
  C.initEnhancedOccupantSettings = initEnhancedOccupantSettings
  C.resetTransientCameraEffects = resetTransientCameraEffects
  C.suppressCameraEffects = suppressCameraEffects
  C.updateCameraEffectFactor = updateCameraEffectFactor
  C.onEnhancedVehicleCameraConfigChanged = onEnhancedVehicleCameraConfigChanged
  C.loadSettingsPreset = loadSettingsPreset
  C.onEnhancedSettingsChanged = onEnhancedSettingsChanged
  C.getSettingsValue = getSettingsValue
  C.resetEnhancedOccupant = resetEnhancedOccupant
  C.updateEnhancedFov = updateEnhancedFov
  C.getEnhancedPhysicsFactor = getEnhancedPhysicsFactor
  C.beginEnhancedPhysicsTransform = beginEnhancedPhysicsTransform
  C.endEnhancedPhysicsTransform = endEnhancedPhysicsTransform
  C.updateEnhancedCameraRotation = updateEnhancedCameraRotation
  C.updateEnhancedShakes = updateEnhancedShakes
  C.beginEnhancedUpdate = beginEnhancedUpdate
end

return M
