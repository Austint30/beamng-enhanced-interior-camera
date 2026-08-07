-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local vecY = vec3(0,1,0)
local vecZ = vec3(0,0,1)
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
local enhancedDriver = require('core/enhanceddriver/cameraFeatures')

local C = {}
C.__index = C
enhancedDriver.install(C)

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
  self.zoomSmoother = newTemporalSmoothing(20)
  self.dxSmoother = newTemporalSmoothing(3,1)
  self.dySmoother = newTemporalSmoothing(3,1)
  self.dzSmoother = newTemporalSmoothing(3,1)
  self.prevCarPos = vec3()
  self.icon = "personSolid"
  self.canUseVehicleTriggerCrosshair = true
  self:initEnhancedDriver()
  self:onVehicleCameraConfigChanged()
  self:onSettingsChanged()
  self.vehicleIsMoving = false
end

function C:onVehicleCameraConfigChanged()
  --trigger reloading of new vehicle from settings
  self.seatPosition = nil
  self.seatRotation = 0
  --trigger gathering of new initial node position
  self.camPosInitialLocal = nil
  self.marginX = nil
  self.cameraResetted = 3
  self:onEnhancedVehicleCameraConfigChanged()
end
function C:onCameraChanged(focused)
  if focused then
    self._driverZoomActionMapPushed = pushActionMap("DriverCameraZoom")
  else
    if self._driverZoomActionMapPushed then
      popActionMap("DriverCameraZoom")
    end
    self._driverZoomActionMapPushed = nil
    core_camera.setCameraDriverZoom(0, self.player)
  end
  self.zoomSmoother:reset()
  core_camera.setCameraDriverZoom(0, self.player)
  self:onEnhancedCameraChanged()
end

function C:onSettingsChanged()
  self.physicsFactor = settings.getValue('cameraDriverPhysics') / 100 -- 0..1 multiplier
  self.autocenter = settings.getValue('cameraDriverAutocenter')
  self.allowSeatAdjustments = settings.getValue('cameraDriverAllowSeatAdjustments')
  self.stableHorizonFactor = settings.getValue('cameraDriverStableHorizon') / 100 -- 0..1 multiplier
  self.stablePitchFactor = settings.getValue('cameraDriverStablePitch') / 100 -- 0..1 multiplier
  self.lookAheadAngle = settings.getValue("cameraDriverLookAheadAngle") / 100
  self.lookAheadSmoothness = settings.getValue("cameraDriverLookAheadSmoothness") / 100
  self.manualzoom:init(settings.getValue('cameraDriverFov'), nil, nil, "ui.camera.fovDriver")
  self.openXRsnapTurnDriver = settings.getValue('openXRsnapTurnDriver')
  self.openXRhorizonLockDriver = settings.getValue('openXRhorizonLockDriver')
  self:onEnhancedSettingsChanged()
end

function C:resetSeat()
  self.rockPos = vec3()
  self.seatPosition = vec3()
  self.seatRotation = 0
  self.saveTimeout = 0 -- trigger save instantaneously
  self.zoomSmoother:reset()
  core_camera.setCameraDriverZoom(0, self.player)
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
  self.zoomSmoother:reset()
  core_camera.setCameraDriverZoom(0, self.player)
  self:resetEnhancedDriver()
end

local currentCarPos = vec3()
local rot = vec3()
local left, ref, back = vec3(), vec3(), vec3()
local carLeft, carFwd, carUp, carRot, carRotInverse = vec3(), vec3(), vec3(), quat(), quat()
local nodePos = vec3()
local camUp, camRot = vec3(), quat()
local camPosLocal, combinedPos, rotationOffset = vec3(), vec3(), vec3()
local intermediateCamPos = vec3()
local nRockPos, projectedRockPos = vec3(), vec3()

local transitionStart = math.rad(50) -- full horizon lock within this margin
local transitionEnd = math.rad(70) -- start fully following vehicle beyond this angle

function C:update(data)
  self:beginEnhancedUpdate(data)

  local carPos = data.pos
  self.player = data.player -- remember which view/player this instance drives, for zoom resets
  -- retrieve camera node (except when resetting, because data is not reliable then)
  self.cameraResetted = max(self.cameraResetted - 1, 0)
  if self.cameraResetted > 0 then
    data.res.pos = carPos
    data.res.rot:setFromDir(vecY, vecZ)
    return
  end
  local cameraEffectFactor = self:updateCameraEffectFactor(data.dt)
  local camNodeID, rightHandDrive = core_camera.getDriverData(data.veh)

  local zoomSmoothed = self.zoomSmoother:get(data.driverZoom or 0, data.dtSim)
  local rotZoomMul = 1 - zoomSmoothed * 0.88

  -- read seat adjustment settings
  if self.seatPosition == nil then
    local vehicleName = data.veh:getJBeamFilename()
    local vehConfigs = settings.getValue('cameraDriverVehicleConfigs')
    if type(vehConfigs) ~= "string" then vehConfigs = "{}" end
    vehConfigs = vehConfigs:gsub("'",'"') -- fix INI values that passed through javascript (e.g. when opening Options menu)
    vehConfigs = jsonDecode(vehConfigs) -- and then deserialize, so we can follow the user settings
    local vehConfig = vehConfigs[vehicleName] or {0,0,0}
    self.seatPosition = vec3(0, vehConfig[2], vehConfig[3])
    self.seatRotation = vehConfig[1]
  end

  -- process mouse rotation input
  self.relativeYaw   = clamp(self.relativeYaw   + 0.1*MoveManager.yawRelative  , -1, 1)
  self.relativePitch = clamp(self.relativePitch - 0.3*MoveManager.pitchRelative, -1, 1)

  -- process kbd/pad rotation input
  local absYaw = 0
  local absPitch = 0
  local filter = core_camera.getLastFilter()

  if self.autocenter and data.veh then
    currentCarPos:set(data.veh:getPositionXYZ())
    local newValue = (self.prevCarPos:distance(currentCarPos) / data.dt) > 0.3
    if not self.mouseIsLocked and newValue and newValue ~= self.vehicleIsMoving then
      -- send back to center
      self.relativeYaw = 0
      self.relativePitch = 0
    end
    self.vehicleIsMoving = newValue
    self.prevCarPos:set(currentCarPos)
  end

  if data.openxrSessionRunning and self.openXRsnapTurnDriver then
    -- ensure the snapturn logic works normally regardless of vehicle speed, by disabling the stationary-car behaviour
    self.vehicleIsMoving = true
  end

  if self.autocenter and not self.mouseIsLocked and self.vehicleIsMoving then
    -- camera will go back to center as soon as the controller is released
    absPitch = (MoveManager.pitchDown - MoveManager.pitchUp) * rotZoomMul
    absYaw   = (MoveManager.yawRight  - MoveManager.yawLeft) * rotZoomMul
    if filter == FILTER_KBD or filter == FILTER_KBD2 then
      -- keyboard look-to-rear key combo (press both left+right to look back)
      absYaw = 0.5*(MoveManager.yawRight - MoveManager.yawLeft) * rotZoomMul
      if MoveManager.yawLeft > 0 and MoveManager.yawRight > 0 then
        absYaw = absYaw + sign(self.camRot.x)
      end
    end
  else
    -- camera will stay where it is when the controller is released
    self.relativeYaw   = self.relativeYaw   + (MoveManager.yawRight  - MoveManager.yawLeft) * 0.01 * data.dt * 60 * rotZoomMul
    self.relativePitch = self.relativePitch + (MoveManager.pitchDown - MoveManager.pitchUp) * 0.04 * data.dt * 60 * rotZoomMul
  end

  local sideInput = self.relativeYaw   + absYaw
  local vertInput = self.relativePitch + absPitch
  if data.openxrSessionRunning and self.openXRsnapTurnDriver then
    local amount = abs(sideInput)
    sideInput = sign(sideInput) * (amount > 0.9 and 1 or (amount > 0.1 and 0.5 or 0)) -- snap head yaw to 50% and 100% degrees
  end

  -- convert input into angles
  local maxAngleYaw = 160 -- max degrees the head will be looking back
  self.camRot.x = sideInput * maxAngleYaw
  if data.lookBack then self.camRot.x = rightHandDrive and -maxAngleYaw or maxAngleYaw end
  local maxAngleTiltUp = 40 -- max degrees the head will be looking up
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

  self:updateEnhancedCameraRotation(data, cameraEffectFactor, carLeft, carFwd, carUp, carRot, carRotInverse, camRot)

  local notifiedFov = self.manualzoom:update(data)
  if notifiedFov then
    self.saveTimeout = 1
  end
  self:updateEnhancedFov(data, cameraEffectFactor, zoomSmoothed)

  -- physics-based position
  self:beginEnhancedPhysicsTransform()
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
    self.marginX = (maxExt.x - minExt.x)*0.5 - abs(data.veh:getInitialNodePosition(camNodeID or 0).x-(maxExt.x + minExt.x)*0.5) -- distance to boundingbox lateral
  end

  -- physics+static position combination
  combinedPos:setLerp(self.camPosInitialLocal, camPosLocal, self:getEnhancedPhysicsFactor(cameraEffectFactor))

  -- left/right head sticking out position
  local minAngle = 70 -- starting angle when driver will start looking back
  local headOut = clamp(abs(self.camRot.x) - minAngle, 0, maxAngleYaw) / (maxAngleYaw - minAngle) -- how much the head is looking back, from 0 to 1
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
    forwardOffset * forwardFactor,                       -- dodge the B-pillar (or bucket seat/head rest)
    verticalOffset * verticalFactor -- dodge the roof
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
  local dr, dy, dz = 0, 0 ,0
  if self.allowSeatAdjustments then
    dr = self.dxSmoother:getCapped(MoveManager.left     - MoveManager.right  , data.dt)
    dy = self.dySmoother:getCapped(MoveManager.backward - MoveManager.forward, data.dt)
    dz = self.dzSmoother:getCapped(MoveManager.up       - MoveManager.down   , data.dt)
    local adjustedSpeed = data.fastSpeedModifier and data.speed * 3 or data.speed
    local pdr = dr * data.dt * adjustedSpeed * 2
    local pdy = dy * data.dt * adjustedSpeed / 50
    local pdz = dz * data.dt * adjustedSpeed / 50
    local posLimit = 0.4
    self.seatRotation   = clamp(self.seatRotation   + pdr, -30, 20)
    self.seatPosition.y = clamp(self.seatPosition.y + pdy, -posLimit, posLimit)
    self.seatPosition.z = clamp(self.seatPosition.z + pdz, -posLimit, posLimit)
  end
  if self.saveTimeout ~= nil then
    self.saveTimeout = self.saveTimeout - data.dt
  end
  if dr ~= 0 then
    ui_message({txt='ui.camera.driverTiltAdjusted', context={vehicleName = data.veh:getJBeamFilename(), angle=self.seatRotation}}, 2, 'cameramode')
    self.saveTimeout = 1
  end
  if dy ~= 0 or dz ~= 0 then
    ui_message({txt='ui.camera.driverPositionAdjusted', context={vehicleName = data.veh:getJBeamFilename(), y=self.seatPosition.y, z=self.seatPosition.z}}, 2, 'cameramode')
    self.saveTimeout = 1
  end

  -- application
  intermediateCamPos:set(push3(combinedPos) + self.seatPosition + rotationOffset)
  data.res.pos:setRotate(carRot, intermediateCamPos)
  data.res.pos:setAdd(carPos)
  data.res.rot:set(camRot)
  self:endEnhancedPhysicsTransform()

  -- save fov/seat settings on timeout
  if self.saveTimeout and self.saveTimeout <= 0 then
    local vehConfig = { self.seatRotation, self.seatPosition.y, self.seatPosition.z }
    if vehConfig[1] == 0 and vehConfig[2] == 0 and vehConfig[3] == 0 then vehConfig = nil end
    local vehicleName = data.veh:getJBeamFilename()
    local vehConfigs = settings.getValue('cameraDriverVehicleConfigs')
    if type(vehConfigs) ~= "string" then vehConfigs = "{}" end
    vehConfigs = vehConfigs:gsub("'",'"') -- fix INI values that passed through javascript (e.g. when opening Options menu)
    vehConfigs = jsonDecode(vehConfigs) -- and then deserialize, so we can follow the user settings
    vehConfigs[vehicleName] = vehConfig
    settings.setValue('cameraDriverVehicleConfigs', jsonEncode(vehConfigs))
    settings.setValue('cameraDriverFov', self.manualzoom.fov)
    self.saveTimeout = nil
  end

  self:updateEnhancedShakes(data, cameraEffectFactor, carRotInverse, carRot)
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
