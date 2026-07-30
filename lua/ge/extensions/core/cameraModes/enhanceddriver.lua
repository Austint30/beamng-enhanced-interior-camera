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

local manualzoom = require('core/cameraModes/manualzoom')
local shake = require('core/cameraModes/speedshake')
local profiler = require('core/enhanceddriver/profiler')

-- Normalize camera UI events so enhanceddriver looks like driver to the UI.
-- Fixes cockpit UI showing when this camera is active.
do
  local gh = rawget(_G, 'guihooks')
  if type(gh) == 'table' and type(gh.trigger) == 'function' and not gh._edc_wrapped then
    local orig = gh.trigger
    gh.trigger = function(evt, payload, ...)
      -- onCameraNameChanged drives cockpit app hide/show
      if evt == 'onCameraNameChanged' then
        if type(payload) ~= 'table' then payload = { name = payload } end
        if payload.name == 'enhanceddriver' then
          payload.name = 'driver'
        end
        -- Options > Cameras and other UI consumers
      elseif evt == 'CameraConfigChanged' and type(payload) == 'table' then
        if payload.focusedCamName == 'enhanceddriver' then
          payload.focusedCamName = 'driver'
        end
      end
      return orig(evt, payload, ...)
    end
    gh._edc_wrapped = true
  else
    log("E", "guihooks.trigger", "Unable to install UI normalizer (guihooks missing or already wrapped)")
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
        if camName == 'enhanceddriver' then
          -- replace first arg and forward remaining args intact
          return origHook(evt, 'driver', select(2, ...))
        end
      end
      return origHook(evt, ...)
    end
    ex._edc_cam_wrap = true
  else
    log("E", "extensions.hook", "Unable to install normalizer (extensions.hook missing or already wrapped)")
  end
end

local gForceFwdSmoother = newTemporalSmoothingNonLinear(4, 4)
local gForceSideSmoother = newTemporalSmoothingNonLinear(4, 4)
local gForceSideLeanSmoother = newTemporalSmoothingNonLinear(4, 4)
local gForceUpSmoother = newTemporalSmoothingNonLinear(5, 5)

local velSmootherX = newTemporalSmoothingNonLinear(12, 16)
local velSmootherY = newTemporalSmoothingNonLinear(12, 16)
local velSmootherZ = newTemporalSmoothingNonLinear(12, 16)

local C = {}
C.__index = C

function C:init()
  self.saveTimeout = nil
  self.camLastRot = vec3()
  self.rockPos = vec3()
  self.cameraResetted = 3
  self.camRot = vec3(0, 0, 0)
  self.relativeYaw = 0
  self.relativePitch = 0
  self.fwdSpeed = 0
  self.manualzoom = manualzoom()
  self:onVehicleCameraConfigChanged()
  self.vehicleIsMoving = false
  self.steeringLookAheadSmoother = newTemporalSmoothingNonLinear(8, 8, 0)
  self.steeringLookAheadVehicleId = nil

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

  self.defaultSettings = jsonReadFile('/lua/ge/extensions/core/cameraModes/enhanceddriverDefaults.json')
  self.edcSettings = {}
  self:initEnhancedDriverSettings()

  self.lastCarFwd = vec3()
  self.lastCarLeft = vec3()
  self.currFov = 0
  self.lastSmoothRate = 0
  self.disabledCockpitApps = false
  -- Keep-alive to reassert cockpit UI state after external toggles (UI close, BeamMP, etc.)
  self._uiKeepAliveTimer = 0

  self:onSettingsChanged()
end

function C:onCameraChanged()
  self.disabledCockpitApps = false
  -- force immediate reassert next frame after any camera change
  self._uiKeepAliveTimer = 0
end

function C:disableCockpitApps()
  if not self.disabledCockpitApps then
    -- Disable cockpit gui apps
    guihooks.trigger('onCameraNameChanged', { name = 'driver' })
    self.disabledCockpitApps = true
  end
end

function C:initEnhancedDriverSettings()
  for k, v in pairs(self.defaultSettings.presets['Default']) do
    self.edcSettings[k] = v
  end
end

function C:onVehicleCameraConfigChanged()
  --trigger reloading of new vehicle from settings
  self.seatPosition = nil
  self.seatRotation = 0
  self.steeringLookAheadVehicleId = nil
  if self.steeringLookAheadSmoother then
    self.steeringLookAheadSmoother:reset()
  end
  --trigger gathering of new initial node position
  self.camPosInitialLocal = nil
  self.marginX = nil
  self.cameraResetted = 3
end

function C:loadSettingsPreset()
  profiler.start('LoadPreset') -- enhanceddriver: dynamic preset merge
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

function C:onSettingsChanged()
  self.physicsFactor = settings.getValue('cameraDriverPhysics') / 100 -- 0..1 multiplier
  self.autocenter = settings.getValue('cameraDriverAutocenter')
  self.allowSeatAdjustments = settings.getValue('cameraDriverAllowSeatAdjustments')
  -- self.stableHorizonFactor = settings.getValue('cameraDriverStableHorizon') / 100 -- 0..1 multiplier
  self.lookAheadAngle = settings.getValue("cameraDriverLookAheadAngle") / 100
  self.lookAheadSmoothness = settings.getValue("cameraDriverLookAheadSmoothness") / 100
  self.manualzoom:init(settings.getValue('cameraDriverFov'), nil, nil, "ui.camera.fovDriver")
  self.openXRsnapTurnDriver = settings.getValue('openXRsnapTurnDriver')
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

function C:getSettingsValue(key, fallback)
  if not self.edcSettings or self.edcSettings[key] == nil then
    return fallback == nil and 1 or fallback
  end
  return self.edcSettings[key]
end

function C:resetSeat()
  self.rockPos = vec3()
  self.seatPosition = vec3()
  self.seatRotation = 0
  self.saveTimeout = 0 -- trigger save instantaneously
end

function C:resetSeatAll()
  self.rockPos = vec3()
  self.seatPosition = vec3()
  self.seatRotation = 0
  self.saveTimeout = nil -- disable any ongoing auto-save
  settings.setValue('cameraDriverVehicleConfigs', "{}")
end

function C:reset()
  self.relativeYaw = 0
  self.relativePitch = 0
  self.rockPos = vec3()
  self.steeringLookAheadSmoother:reset()
end

function C:updateFovSpeedMod(data)
  self.currFov = data.res.fov
  local speed = data.vel:length()

  -- if speed < self.minSpeedFovMod then
  --   data.res.fov = self.manualzoom.fovDefault
  --   return
  -- end

  local high = self.edcSettings.fovMaxSpeed
  local low = self.edcSettings.fovMinSpeed

  local rawFovScale = clamp((speed - low) / (high - low), 0, 1)

  local smoothedFovScale = self.fovSmoother:get(rawFovScale, data.dt)

  local addedFov = smoothedFovScale * self.edcSettings.fovAddDegrees

  local newFov = self.manualzoom.fov + addedFov
  data.res.fov = newFov
end

local dxSmoother = newTemporalSmoothing(3, 1)
local dySmoother = newTemporalSmoothing(3, 1)
local dzSmoother = newTemporalSmoothing(3, 1)

local currentCarPos, prevCarPos = vec3(), vec3()
local rot = vec3()
local left, ref, back = vec3(), vec3(), vec3()
local carLeft, carFwd, carUp, carRot, carRotInverse = vec3(), vec3(), vec3(), quat(), quat()
local nodePos = vec3()
local camUp, camRot = vec3(), quat()
local camPosLocal, combinedPos, rotationOffset = vec3(), vec3(), vec3()
local intermediateCamPos = vec3()
local nRockPos, projectedRockPos = vec3(), vec3()

function C:update(data)
  -- Reassert cockpit-hide periodically while this camera is active
  profiler.start('UIKeepAlive') -- enhanceddriver: periodic UI reassert
  self._uiKeepAliveTimer = (self._uiKeepAliveTimer or 0) - data.dt
  if self._uiKeepAliveTimer <= 0 then
    guihooks.trigger('onCameraNameChanged', { name = 'driver' })
    self._uiKeepAliveTimer = 0.5 -- every 0.5s while active
  end
  profiler.stop('UIKeepAlive')

  self:disableCockpitApps()

  local carPos = data.pos
  -- retrieve camera node (except when resetting, because data is not reliable then)
  self.cameraResetted = max(self.cameraResetted - 1, 0)
  if self.cameraResetted > 0 then
    data.res.pos = carPos
    data.res.rot:setFromDir(vecY, vecZ)
    return
  end
  local camNodeID, rightHandDrive = core_camera.getDriverData(data.veh)

  -- read seat adjustment settings
  if self.seatPosition == nil then
    local vehicleName = data.veh:getJBeamFilename()
    local vehConfigs = settings.getValue('cameraDriverVehicleConfigs')
    if type(vehConfigs) ~= "string" then vehConfigs = "{}" end
    vehConfigs = vehConfigs:gsub("'", '"') -- fix INI values that passed through javascript (e.g. when opening Options menu)
    vehConfigs = jsonDecode(vehConfigs)    -- and then deserialize, so we can follow the user settings
    local vehConfig = vehConfigs[vehicleName] or { 0, 0, 0 }
    self.seatPosition = vec3(0, vehConfig[2], vehConfig[3])
    self.seatRotation = vehConfig[1]
  end

  -- process mouse rotation input
  self.relativeYaw   = clamp(self.relativeYaw + 0.1 * MoveManager.yawRelative, -1, 1)
  self.relativePitch = clamp(self.relativePitch - 0.3 * MoveManager.pitchRelative, -1, 1)

  -- process kbd/pad rotation input
  local absYaw       = 0
  local absPitch     = 0
  local filter       = core_camera.getLastFilter()

  if self.autocenter and data.veh then
    currentCarPos:set(data.veh:getPositionXYZ())
    if prevCarPos then
      local newValue = (prevCarPos:distance(currentCarPos) / data.dt) > 0.3
      if not self.mouseIsLocked and newValue and newValue ~= self.vehicleIsMoving then
        -- send back to center
        self.relativeYaw = 0
        self.relativePitch = 0
      end
      self.vehicleIsMoving = newValue
    end
    prevCarPos:set(currentCarPos)
  end

  if data.openxrSessionRunning and self.openXRsnapTurnDriver then
    -- ensure the snapturn logic works normally regardless of vehicle speed, by disabling the stationary-car behaviour
    self.vehicleIsMoving = true
  end

  if self.autocenter and not self.mouseIsLocked and self.vehicleIsMoving then
    -- camera will go back to center as soon as the controller is released
    absPitch = MoveManager.pitchDown - MoveManager.pitchUp
    absYaw   = MoveManager.yawRight - MoveManager.yawLeft
    if filter == FILTER_KBD or filter == FILTER_KBD2 then
      -- keyboard look-to-rear key combo (press both left+right to look back)
      absYaw = 0.5 * (MoveManager.yawRight - MoveManager.yawLeft)
      if MoveManager.yawLeft > 0 and MoveManager.yawRight > 0 then
        absYaw = absYaw + sign(self.camRot.x)
      end
    end
  else
    -- camera will stay where it is when the controller is released
    self.relativeYaw   = self.relativeYaw + (MoveManager.yawRight - MoveManager.yawLeft) * 0.01 * data.dt * 60
    self.relativePitch = self.relativePitch + (MoveManager.pitchDown - MoveManager.pitchUp) * 0.04 * data.dt * 60
  end

  local sideInput = self.relativeYaw + absYaw
  local vertInput = self.relativePitch + absPitch
  if data.openxrSessionRunning and self.openXRsnapTurnDriver then
    local amount = abs(sideInput)
    sideInput = sign(sideInput) *
        (amount > 0.9 and 1 or (amount > 0.1 and 0.5 or 0)) -- snap head yaw to 50% and 100% degrees
  end

  -- convert input into angles
  local maxAngleYaw = 160 -- max degrees the head will be looking back
  self.camRot.x = sideInput * maxAngleYaw
  if data.lookBack then self.camRot.x = rightHandDrive and -maxAngleYaw or maxAngleYaw end
  local maxAngleTiltUp = 40   -- max degrees the head will be looking up
  local maxAngleTiltDown = 60 -- max degrees the head will be looking down
  self.camRot.y = vertInput * (vertInput > 0 and maxAngleTiltDown or maxAngleTiltUp)

  -- orientation
  rot:set(math.rad(self.camRot.x), math.rad(self.camRot.y), math.rad(self.camRot.z))
  -- avoid physical discomfort by removing smoothers from VR
  if not data.openxrSessionRunning then
    local ratiox = 1 / (data.dt * 50)
    local ratioy = 1 / (data.dt * 10)
    if not self.autocenter then ratioy = 1 / (data.dt * 50) end
    rot.x = 1 / (ratiox + 1) * rot.x + (ratiox / (ratiox + 1)) * self.camLastRot.x
    rot.y = 1 / (ratioy + 1) * rot.y + (ratioy / (ratioy + 1)) * self.camLastRot.y
  end
  if data.openxrSessionRunning then
    rot.y = 0 -- remove manual head tilt
  end
  self.camLastRot:set(rot)
  local seatRotation = self.seatRotation
  if data.openxrSessionRunning then
    seatRotation = 0 -- remove manual seat tilting
  end
  self.camRot:set(math.deg(rot.x), math.deg(rot.y) - seatRotation, math.deg(rot.z))
  left:set(data.veh:getNodePositionXYZ(self.refNodes.left))
  ref:set(data.veh:getNodePositionXYZ(self.refNodes.ref))
  back:set(data.veh:getNodePositionXYZ(self.refNodes.back))

  carLeft:setSub2(left, ref); carLeft:normalize()
  carFwd:setSub2(back, ref); carFwd:normalize()
  carUp:setCross(carLeft, carFwd); carUp:normalize()

  -- Smooth velocity using rock on a string algorithm
  self.rockPos:set(push3(self.rockPos) - push3(data.vel) * data.dt)
  projectedRockPos:setProjectToOriginPlane(carUp, self.rockPos)
  projectedRockPos:resize(min(self.rockPos:length(), self.lookAheadSmoothness))
  -- When vehicle flips, left and right sides of it flip aswell. To prevent this from happening
  -- We tempereraly stop projecting the rock position
  if self.rockPos:distance(projectedRockPos) < 0.1 then
    self.rockPos = projectedRockPos
  else
    self.rockPos:resize(min(self.rockPos:length(), self.lookAheadSmoothness))
  end

  -- Smooth car fwd direction
  local lerpedCarFwd = lerp(self.lastCarFwd, carFwd, (1 - self.edcSettings.pitchSmoothing) * data.dt * 20)
  carFwd.z = lerpedCarFwd.z
  self.lastCarFwd:set(carFwd)

  -- Smooth car left direction
  local lerpedCarLeft = lerp(self.lastCarLeft, carLeft, (1 - self.edcSettings.rollSmoothing) * data.dt * 20)
  carLeft.z = lerpedCarLeft.z
  self.lastCarLeft:set(carLeft)

  -- Stable horizon
  carRot:setFromDir(carFwd, carUp)
  camRot:setFromDir(-push3(carFwd))
  camUp:setRotate(camRot, vecZ)
  local carRoll = math.atan2(push3(camUp):dot(-push3(carLeft)), camUp:dot(carUp))
  local carRollFactor = 1 - self.edcSettings.lockRollToHorizon * smootheststep(clamp(1.42 * carUp.z, 0, 1))
  local camRoll = carRoll * carRollFactor

  local carPitch = math.atan2(push3(vecZ):dot(-push3(carFwd)), camUp:dot(carUp))
  local carPitchFactor = self.edcSettings.lockPitchToHorizon * smoothstep(clamp(1.2 * carUp.z, 0, 1))
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

  -- Steering look-ahead follows the supported, normalized vehicle steering input.
  -- Keep it separate from BeamNG's velocity-based look-ahead so users can tune it independently.
  local steeringLookAheadAngleOffset = 0
  local steeringLookAheadAngle = self:getSettingsValue('steeringLookAheadAngle', 0)
  if not data.openxrSessionRunning and steeringLookAheadAngle ~= 0 then
    local vehicleId = data.veh:getId()
    if self.steeringLookAheadVehicleId ~= vehicleId then
      core_vehicleBridge.registerValueChangeNotification(data.veh, 'steering_input')
      self.steeringLookAheadVehicleId = vehicleId
      self.steeringLookAheadSmoother:reset()
    end

    local steeringInput = core_vehicleBridge.getCachedVehicleData(vehicleId, 'steering_input') or 0
    steeringInput = clamp(tonumber(steeringInput) or 0, -1, 1)
    local steeringLookAheadSmoothness = clamp(
      self:getSettingsValue('steeringLookAheadSmoothness', 50) / 100,
      0,
      1
    )
    local steeringLookAheadRate = lerp(20, 0.5, smootheststep(steeringLookAheadSmoothness))
    local smoothedSteeringInput = self.steeringLookAheadSmoother:getWithRate(
      steeringInput,
      data.dt,
      steeringLookAheadRate
    )
    steeringLookAheadAngleOffset = math.rad(smoothedSteeringInput * steeringLookAheadAngle)
  else
    self.steeringLookAheadSmoother:set(0)
  end

  -- Rotate the camera in response to longitudinal, lateral, and vertical g-forces.
  profiler.start('GForce') -- Added g-force smoothing and rotation blending (enhanceddriver)
  local accel = carRotInverse * data.vel - carRotInverse * data.prevVel

  -- Smooth acceleration data
  accel.x = velSmootherX:get(accel.x, data.dt)
  accel.y = velSmootherY:get(accel.y, data.dt)
  accel.z = velSmootherZ:get(accel.z, data.dt)

  local rawFwdForce = -accel.y / (data.dt * 100)
  -- Vehicle-space +X points left, while positive camera yaw looks right.
  local rawSideForce = accel.x / (data.dt * 100)
  local rawUpForce = -accel.z / (data.dt * 100)

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

  local smoothedFwdForce = gForceFwdSmoother:get(rawFwdForce, data.dt)
  local smoothedSideForce = gForceSideSmoother:get(rawSideForce, data.dt)
  local sideLeanSmoothness = clamp(self:getSettingsValue('gForceSideLeanRollSmoothness', 75) / 100, 0, 1)
  local sideLeanSmoothingRate = lerp(8, 0.25, smootheststep(sideLeanSmoothness))
  local smoothedSideLeanForce = gForceSideLeanSmoother:getWithRate(
    rawSideLeanForce,
    data.dt,
    sideLeanSmoothingRate
  )
  local smoothedUpForce = gForceUpSmoother:get(rawUpForce, data.dt)

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
  )
  local scaledUpForce = smoothedUpForce * self.gForceZBase * self:getSettingsValue('gForceZ')
  local scaledFwdForce = 0
  if smoothedFwdForce >= 0 then
    scaledFwdForce = smoothedFwdForce * self.gForceYBase * self:getSettingsValue('gForceAccel')
  else
    scaledFwdForce = smoothedFwdForce * self.gForceYBase * self:getSettingsValue('gForceDecel')
  end

  local pitchAngleFromForces = -math.atan2(scaledUpForce + scaledFwdForce, 1)

  local finalCamPitch = lerp(
    pitchAngleFromForces,
    camPitch + pitchAngleFromForces,
    self.edcSettings.lockPitchToHorizon
  )

  camRot = rotateEuler(
    math.rad(self.camRot.x) + lookAheadAngleOffset + steeringLookAheadAngleOffset + sideImpactYawAngleFromForces,
    math.rad(self.camRot.y) + finalCamPitch,
    camRoll + sideImpactRollAngleFromForces + sideLeanRollAngleFromForces,
    camRot
  ) -- stable hood line
  profiler.stop('GForce')

  -- Pitch smoothing
  ----local roll, pitch, yaw = data.veh:getRollPitchYawAngularVelocity()
  --local pitch = 0
  --camDir = rotateEuler(math.rad(self.camRot.x) + lookAheadAngle, math.rad(self.camRot.y) - pitch, camRoll, camDir) -- stable hood line

  local notifiedFov = self.manualzoom:update(data)
  if notifiedFov then
    self.saveTimeout = 1
  end

  profiler.start('FOVSpeedMod') -- Added dynamic speed-based FOV modulation (enhanceddriver)
  self:updateFovSpeedMod(data)
  profiler.stop('FOVSpeedMod')

  -- physics-based position
  profiler.start('PhysicsTransform') -- Added physicsFactor blend + seat offsets persistence (enhanceddriver)
  nodePos:set(data.veh:getNodePositionXYZ(camNodeID or 0))
  carRotInverse:set(carRot)
  carRotInverse:inverse()
  camPosLocal:setRotate(carRotInverse, nodePos)

  -- static position
  if self.camPosInitialLocal == nil then ---- FIXME this can happen at any point, e.g. when vehicle is damaged
    self.camPosInitialLocal = vec3(camPosLocal)
    local origSpawnAABB = data.veh:getSpawnLocalAABB()
    local minExt = origSpawnAABB.minExtents
    local maxExt = origSpawnAABB.maxExtents
    self.marginX = (maxExt.x - minExt.x) * 0.5 -
        abs(data.veh:getInitialNodePosition(camNodeID or 0).x - (maxExt.x + minExt.x) * 0.5) -- distance to boundingbox lateral
  end

  -- physics+static position combination
  combinedPos:setLerp(self.camPosInitialLocal, camPosLocal, self.physicsFactor)

  -- left/right head sticking out position
  local minAngle = 70      -- starting angle when driver will start looking back
  local headOut = clamp(abs(self.camRot.x) - minAngle, 0, maxAngleYaw) /
      (maxAngleYaw - minAngle) -- how much the head is looking back, from 0 to 1
  local lateralFactor = headOut
  local forwardFactor = headOut
  local verticalFactor = headOut
  local lateralOffset = 0.26
  local forwardOffset = -0.075
  local verticalOffset = -0.02
  local lookingThroughWindow = rightHandDrive == (self.camRot.x > 0)
  if lookingThroughWindow then
    forwardFactor = clamp(forwardFactor * 1.75, 0, 1)
    verticalFactor = clamp(verticalFactor * 1.00, 0, 1)
    forwardOffset = -0.3
    lateralOffset = 0.5
    lateralOffset = min(0.6, self.marginX)
    verticalOffset = -0.1
  end
  rotationOffset:set(
    lateralOffset * lateralFactor * sign(-self.camRot.x), -- stick head out (or towards center)
    forwardOffset * forwardFactor,                        -- dodge the B-pillar (or bucket seat/head rest)
    verticalOffset * verticalFactor                       -- dodge the roof
  )

  -- up/down head bobbing, to more easily discover occluded switches in the cockpit
  local headWiggleZ = clamp(self.camRot.y / 20, -1, 1)
  local maxWiggleZ = 0.05
  local wiggleZ = headWiggleZ * maxWiggleZ
  rotationOffset.z = rotationOffset.z + wiggleZ

  -- left/right head bobbing, to more easily discover occluded switches in the cockpit
  local headWiggleX = clamp(self.camRot.x / 40, -1, 1)
  local maxWiggleX = 0.15
  local wiggleX = headWiggleX * maxWiggleX
  rotationOffset.x = sign(-self.camRot.x) * max(abs(rotationOffset.x), abs(wiggleX))

  -- apply seat adjustment
  local dr, dy, dz = 0, 0, 0
  if self.allowSeatAdjustments then
    dr                  = dxSmoother:getCapped(MoveManager.left - MoveManager.right, data.dt)
    dy                  = dySmoother:getCapped(MoveManager.backward - MoveManager.forward, data.dt)
    dz                  = dzSmoother:getCapped(MoveManager.up - MoveManager.down, data.dt)
    local adjustedSpeed = data.fastSpeedModifier and data.speed * 3 or data.speed
    local pdr           = dr * data.dt * adjustedSpeed * 2
    local pdy           = dy * data.dt * adjustedSpeed / 50
    local pdz           = dz * data.dt * adjustedSpeed / 50
    local posLimit      = 0.4
    self.seatRotation   = clamp(self.seatRotation + pdr, -30, 20)
    self.seatPosition.y = clamp(self.seatPosition.y + pdy, -posLimit, posLimit)
    self.seatPosition.z = clamp(self.seatPosition.z + pdz, -posLimit, posLimit)
  end
  if self.saveTimeout ~= nil then
    self.saveTimeout = self.saveTimeout - data.dt
  end
  if dr ~= 0 then
    ui_message(
      { txt = 'ui.camera.driverTiltAdjusted', context = { vehicleName = data.veh:getJBeamFilename(), angle = self.seatRotation } },
      2, 'cameramode')
    self.saveTimeout = 1
  end
  if dy ~= 0 or dz ~= 0 then
    ui_message(
      { txt = 'ui.camera.driverPositionAdjusted', context = { vehicleName = data.veh:getJBeamFilename(), y = self.seatPosition.y, z = self.seatPosition.z } },
      2, 'cameramode')
    self.saveTimeout = 1
  end

  -- application
  intermediateCamPos:set(push3(combinedPos) + self.seatPosition + rotationOffset)
  data.res.pos:setRotate(carRot, intermediateCamPos)
  data.res.pos:setAdd(carPos)
  data.res.rot:set(camRot)
  profiler.stop('PhysicsTransform')

  -- save fov/seat settings on timeout
  if self.saveTimeout and self.saveTimeout <= 0 then
    local vehConfig = { self.seatRotation, self.seatPosition.y, self.seatPosition.z }
    if vehConfig[1] == 0 and vehConfig[2] == 0 and vehConfig[3] == 0 then vehConfig = nil end
    local vehicleName = data.veh:getJBeamFilename()
    local vehConfigs = settings.getValue('cameraDriverVehicleConfigs')
    if type(vehConfigs) ~= "string" then vehConfigs = "{}" end
    vehConfigs = vehConfigs:gsub("'", '"') -- fix INI values that passed through javascript (e.g. when opening Options menu)
    vehConfigs = jsonDecode(vehConfigs)    -- and then deserialize, so we can follow the user settings
    vehConfigs[vehicleName] = vehConfig
    settings.setValue('cameraDriverVehicleConfigs', jsonEncode(vehConfigs))
    settings.setValue('cameraDriverFov', self.manualzoom.fov)
    self.saveTimeout = nil
  end

  profiler.start('SpeedShake') -- Added speed-dependent shake effect (enhanceddriver)
  self.speedshake:update(data)
  profiler.stop('SpeedShake')

  -- Detect angle of drift and apply camera shake
  -- (Is it possible to do apply this with wheel slip instead?)
  local flatVelocity = carRotInverse * data.vel
  profiler.start('DriftShake') -- Added drift angle shake effect (enhanceddriver)
  flatVelocity.z = 0
  flatVelocity = carRot * flatVelocity

  local driftAngle = carRot:dot(quatFromDir(flatVelocity))

  if driftAngle >= 0.5 then
    driftAngle = 1 - driftAngle
  end

  driftAngle = driftAngle * 1.5

  driftAngle = lerp(0, driftAngle, clamp(flatVelocity:length() / 10, 0, 1))

  self.driftshake:update(data, driftAngle)
  self.hasResetted = false
  profiler.stop('DriftShake')
  profiler.frame(data.dt)
end

function C:setRefNodes(centerNodeID, leftNodeID, backNodeID)
  self.refNodes = self.refNodes or {}
  self.refNodes.ref = centerNodeID
  self.refNodes.left = leftNodeID
  self.refNodes.back = backNodeID
end

function C:mouseLocked(locked)
  self.mouseIsLocked = locked
  if locked then return end
  if self.autocenter and self.vehicleIsMoving then
    self.relativeYaw = 0
    self.relativePitch = 0
  end
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
