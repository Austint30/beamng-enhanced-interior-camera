-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- ORBIT CAMERA
local collision = require('core/cameraModes/collision')
local refNodesSync = require('core/arcadeOrbit/refNodes')
local velocityAim = require('core/arcadeOrbit/effects/velocityAim')
local speedShake = require('core/arcadeOrbit/effects/speedShake')
local driftShake = require('core/arcadeOrbit/effects/driftShake')
local accelDistance = require('core/arcadeOrbit/effects/accelDistance')
local accelResponse = require('core/arcadeOrbit/effects/accelResponse')
local brakePitch = require('core/arcadeOrbit/effects/brakePitch')
local decelJolt = require('core/arcadeOrbit/effects/decelJolt')
local accelJolt = require('core/arcadeOrbit/effects/accelJolt')
local leanInRoll = require('core/arcadeOrbit/effects/leanInRoll')
local followSmoothing = require('core/arcadeOrbit/effects/followSmoothing')
local speedDistance = require('core/arcadeOrbit/effects/speedDistance')
local vehicleMeasure = require('core/arcadeOrbit/vehicleMeasure')

-- ---------------------------------------------------------------------------
-- Hidden demo gate
-- This camera ships bundled with the Enhanced Interior Camera mod as a hidden
-- demo. It stays out of the camera menu and the camera-cycle configuration
-- until "Enable Arcade Chase Camera" is turned on in the EIC settings panel.
local function isDemoEnabled()
  local edc = settings.getValue('edcSettings')
  return type(edc) == 'table' and edc.arcadeChaseEnabled == true
end

local C = {}
C.__index = C
local vecY = vec3(0,1,0)
local vecZ = vec3(0,0,1)
local lookBackVec = vec3(0,-0.3,0)

local function getRot(base, vf, vz)
  local vyn = vf:normalized()
  local nxn = vyn:cross(vz):projectToOriginPlane(vecZ):normalized()
  local nzn = nxn:cross(vyn):normalized()
  local nbase = base:normalized()
  return math.atan2(-nbase:dot(nxn), nbase:dot(vyn)), math.asin(nbase:dot(nzn))
end

-- Camera framing constants.
local FIT_DIST_MIN          = 1.5   -- closest the camera can be to the vehicle (m)
local FIT_DIST_MAX          = 50.0  -- farthest the camera can be (m)
local FIT_HEIGHT_SCALE      = 0.3   -- camera elevation above roof as a fraction of vehicle height
local FRAMING_PITCH_FACTOR  = 0.5   -- fraction of vehicle height below roof the camera aims at
local FIT_DIST_BASE         = 0.7   -- base distance added to height-based framing (m); gives small vehicles comfortable minimum clearance
local REAR_ASPECT_THRESHOLD = 2.0   -- rearDist/height ratio at which we cap the rear floor; prevents flat long-tailed cars (e.g. supercars) from pushing the camera too far
local STOP_FLIP_SPEED       = 0.3   -- m/s (~1 km/h): below this the parked-camera flip test only sees sim/suspension jitter — see the flip block below
local NODE_UP_EPS_SQ        = 1e-6  -- squaredLength gate for the vehicle up vector (nz); ~0 only with a broken ref-node layout
local MIN_AIM_DIST_M        = 0.5   -- m: floor on the camera-to-aim distance so a zeroed zoom can't amplify a g-force target offset into a 90° swing

function C:init()
  self.target = false
  self.camLastTargetPos = vec3()
  self.camLastTargetPos2 = vec3()
  self.camLastPos = vec3()
  self.camLastPos2 = vec3()
  self.camLastPosPerp = vec3()
  self.camVel = vec3()
  self.cameraResetted = 3
  self.lockCamera = false
  self.orbitOffset = vec3()
  self.targetHeight = 0.20 -- aim-point height relative to the vehicle roof (m); + above, - below
  self.basePitch = 12 -- constant look-down angle (degrees); + = looking down
  self.preResetPos = vec3(1e+300, 0, 0)
  self.targetCenter = vec3(0, 0, 0)
  self.targetLeft = vec3(0, 0, 0)
  self.targetBack = vec3(0, 0, 0)
  self.configChanged = false
  self.icon = "aperture"
  local demoEnabled = isDemoEnabled()
  self.hidden = not demoEnabled
  self.disabledByDefault = not demoEnabled
  self.fovModifier = 0
  self.maxDynamicFov = 0
  self.maxDynamicOffset = 0
  self.smoothingEnabled = true
  self.relaxation = 3
  self.collision = collision()
  self.collision:init()
  self.refNodesSync = refNodesSync()
  self.velocityAim = velocityAim()
  self.speedShake = speedShake()
  self.driftShake = driftShake()
  self.accelDistance = accelDistance()
  self.accelDistCtx = { camForward = vec3(0, 1, 0) }
  self.accelResponse = accelResponse()
  self.brakePitch = brakePitch()
  self.decelJolt = decelJolt()
  self.accelJolt = accelJolt()
  self.leanInRoll = leanInRoll()
  self.gForceCtx = { camFwd = vec3(0, 1, 0) }
  self.followSmoothing = followSmoothing()
  self.speedDistance = speedDistance()
  self.vehicleMeasure = vehicleMeasure()
  self.aimCtx = { targetPos = vec3(), left = vec3(), back = vec3() }
  self.driftCtx = { carRot = quat(), carRotInv = quat(), flatVelocity = vec3() }

  self:onVehicleCameraConfigChanged()
  self:onSettingsChanged()
  self:loadSettings()
  self:reset()
end

function C:onVehicleCameraConfigChanged()
  self.configChanged = true
  if self.defaultRotation == nil then
    self.defaultRotation = vec3(0, 0, 0)
  end
  self.defaultRotation = vec3(self.defaultRotation)
  self.offset = vec3(self.offset)
  if not self.camRot then self.camRot = vec3(self.defaultRotation) end
  self.camLastRot = vec3(math.rad(self.camRot.x), math.rad(self.camRot.y), 0)
  self.camDist = 1.0
  self.camLastDist = 1.0
  self.defaultDistance = 1.0
  self.screenFill = 0.5
  self.mode = self.mode or 'ref'
  self.skipFovModifier = self.skipFovModifier or false
  self.fov = self.fov or 65
  -- Re-apply user settings if they've been loaded (overrides JBeam defaults).
  if self._settingsLoaded then
    self:loadSettings()
  end
end

function C:onSettingsChanged()
  core_camera.clearInputs()
  -- Settings are now managed via the Vue panel + arcadeOrbitSettings.json.
  -- BeamNG stock settings are no longer the source of truth for this camera.
end

function C:onVehicleSwitched()
  self.collision:onVehicleSwitched()
  self.velocityAim:reset()
  self.speedShake:reset()
  self.driftShake:reset()
  self.accelDistance:reset()
  self.accelResponse:reset()
  self.brakePitch:reset()
  self.decelJolt:reset()
  self.accelJolt:reset()
  self.leanInRoll:reset()
  self.followSmoothing:reset()
  self.speedDistance:reset()
  self.vehicleMeasure:reset()
  self.refNodesSync:reset()
  self._fitDistDirty = true
  self._dbgLogged = false
end

function C:computeFitDist(vehId)
  local height   = self.vehicleMeasure:measureHeight(vehId)
  local rearDist = self.vehicleMeasure:measureRearDistance(vehId)

  local fovRad     = math.rad(self.fov) * 0.5
  local heightDist = height / (self.screenFill * math.tan(fovRad))

  -- Height floor: geometric screen-fill framing plus a base clearance so even
  -- small vehicles get a comfortable minimum distance.
  local heightFloor = FIT_DIST_BASE + heightDist

  -- Rear floor: ensures long vehicles (buses, trucks) push the camera back far
  -- enough. Capped at height * REAR_ASPECT_THRESHOLD so flat long-tailed cars
  -- (supercars with large r/h) don't push the camera excessively far.
  local rearCapped = math.min(rearDist, height * REAR_ASPECT_THRESHOLD)
  local rearFloor  = rearCapped / self.screenFill

  self.fitDist      = clamp(math.max(heightFloor, rearFloor), FIT_DIST_MIN, FIT_DIST_MAX)
  self.fitHeight    = height * FIT_HEIGHT_SCALE
  self.framingPitch = math.deg(math.atan(height * FRAMING_PITCH_FACTOR / self.fitDist))
end

function C:reset()
  if self.cameraResetted == 0 then
    self.preResetPos = vec3(self.camLastTargetPos2)
    self.cameraResetted = 3
    self.collision:init()
  end
end

function C:setRotation(rot)
  self.camRot = vec3(rot)
end

-- Persist/restore this camera's own state for the video-stream views (see core_camera
-- get/setContextCameraState): the orbit rotation, distance and zoom.
function C:serialize()
  return {
    rot = self.camRot and { x = self.camRot.x, y = self.camRot.y, z = self.camRot.z } or nil,
    dist = self.camDist,
    fov = self.fov,
  }
end

function C:deserialize(s)
  if type(s) ~= 'table' then return end
  if s.rot then
    self:setRotation(vec3(s.rot.x, s.rot.y, s.rot.z))
    if self.camLastRot then self.camLastRot:set(math.rad(s.rot.x), math.rad(s.rot.y), 0) end
  end
  if s.dist then self.camDist = s.dist; self.camLastDist = s.dist end
  if s.fov then self.fov = s.fov end
  self.cameraResetted = 0 -- keep the restored rotation/distance instead of snapping to the default next frame
end

function C:setFOV(fov)
  self.fov = fov
end

-- Settings are now controlled by the Vue settings panel (ArcadeOrbitSettings.vue).
-- applyConfig() consumes a flat config table (keys match arcadeOrbitDefaults.json).
function C:applyConfig(c)
  if not c then return end

  -- Camera core
  if c.screenFill then self.screenFill = clamp(c.screenFill / 100, 0.2, 0.95); self._fitDistDirty = true end
  self.camDist = 1.0
  if c.fov then self.fov = c.fov; self._fitDistDirty = true end
  if c.basePitch then self.basePitch = c.basePitch end
  if c.targetHeight then self.targetHeight = c.targetHeight end
  if c.relaxation then self.relaxation = c.relaxation end
  if c.smoothingEnabled ~= nil then
    self.smoothingEnabled = c.smoothingEnabled
    self.followSmoothing:setEnabled(c.smoothingEnabled)
  end

  -- Velocity aim
  if c.velocityAim_scale then self.velocityAim:setScale(c.velocityAim_scale) end
  if c.velocityAim_minSpeed then self.velocityAim:setMinSpeed(c.velocityAim_minSpeed) end
  if c.velocityAim_maxSpeed then self.velocityAim:setMaxSpeed(c.velocityAim_maxSpeed) end

  -- Speed shake
  if c.speedShake_yawAmp then self.speedShake:setYawAmp(c.speedShake_yawAmp) end
  if c.speedShake_pitchAmp then self.speedShake:setPitchAmp(c.speedShake_pitchAmp) end
  if c.speedShake_rollAmp then self.speedShake:setRollAmp(c.speedShake_rollAmp) end
  if c.speedShake_freq then self.speedShake:setFreq(c.speedShake_freq) end
  if c.speedShake_octaves then self.speedShake:setOctaves(c.speedShake_octaves) end
  if c.speedShake_minSpeed then self.speedShake:setMinSpeed(c.speedShake_minSpeed) end
  if c.speedShake_maxSpeed then self.speedShake:setMaxSpeed(c.speedShake_maxSpeed) end
  if c.speedShake_maxStrength then self.speedShake:setMaxStrength(c.speedShake_maxStrength) end

  -- Drift shake
  if c.driftShake_enabled ~= nil then self.driftShake:setEnabled(c.driftShake_enabled) end
  if c.driftShake_yawAmp then self.driftShake:setYawAmp(c.driftShake_yawAmp) end
  if c.driftShake_pitchAmp then self.driftShake:setPitchAmp(c.driftShake_pitchAmp) end
  if c.driftShake_rollAmp then self.driftShake:setRollAmp(c.driftShake_rollAmp) end
  if c.driftShake_freq then self.driftShake:setFreq(c.driftShake_freq) end
  if c.driftShake_octaves then self.driftShake:setOctaves(c.driftShake_octaves) end
  if c.driftShake_maxSpeed then self.driftShake:setMaxSpeed(c.driftShake_maxSpeed) end
  if c.driftShake_minAngle then self.driftShake:setMinAngle(c.driftShake_minAngle) end
  if c.driftShake_maxAngle then self.driftShake:setMaxAngle(c.driftShake_maxAngle) end

  -- Accel distance
  if c.accelDistance_maxDist then self.accelDistance:setMaxDist(c.accelDistance_maxDist) end
  if c.accelDistance_smoothness then self.accelDistance:setSmoothness(c.accelDistance_smoothness) end

  -- Accel response (crest/valley)
  if c.accelResponse_enabled ~= nil then self.accelResponse:setEnabled(c.accelResponse_enabled) end
  if c.accelResponse_gThreshold then self.accelResponse:setGThreshold(c.accelResponse_gThreshold) end
  if c.accelResponse_inputSmooth then self.accelResponse:setInputSmooth(c.accelResponse_inputSmooth) end
  if c.accelResponse_outputSmooth then self.accelResponse:setOutputSmooth(c.accelResponse_outputSmooth) end
  if c.accelResponse_valleyStrength then self.accelResponse:setValleyStrength(c.accelResponse_valleyStrength) end
  if c.accelResponse_valleyMaxHeight then self.accelResponse:setValleyMaxHeight(c.accelResponse_valleyMaxHeight) end
  if c.accelResponse_valleyMaxPitch then self.accelResponse:setValleyMaxPitch(c.accelResponse_valleyMaxPitch) end
  if c.accelResponse_crestStrength then self.accelResponse:setCrestStrength(c.accelResponse_crestStrength) end
  if c.accelResponse_crestMaxHeight then self.accelResponse:setCrestMaxHeight(c.accelResponse_crestMaxHeight) end
  if c.accelResponse_crestMaxPitch then self.accelResponse:setCrestMaxPitch(c.accelResponse_crestMaxPitch) end
  if c.brakePitch_enabled ~= nil then self.brakePitch:setEnabled(c.brakePitch_enabled) end
  if c.brakePitch_minG ~= nil then self.brakePitch:setMinG(c.brakePitch_minG) end
  if c.brakePitch_maxG then self.brakePitch:setMaxG(c.brakePitch_maxG) end
  if c.brakePitch_maxOffset ~= nil then self.brakePitch:setMaxOffset(c.brakePitch_maxOffset) end
  if c.brakePitch_smoothness then self.brakePitch:setSmoothness(c.brakePitch_smoothness) end
  if c.decelJolt_enabled ~= nil then self.decelJolt:setEnabled(c.decelJolt_enabled) end
  if c.decelJolt_minJerk ~= nil then self.decelJolt:setMinJerk(c.decelJolt_minJerk) end
  if c.decelJolt_fullJerk ~= nil then self.decelJolt:setFullJerk(c.decelJolt_fullJerk) end
  if c.decelJolt_maxRotation ~= nil then self.decelJolt:setMaxRotation(c.decelJolt_maxRotation) end
  if c.decelJolt_duration ~= nil then self.decelJolt:setDuration(c.decelJolt_duration) end
  if c.decelJolt_attack ~= nil then self.decelJolt:setAttack(c.decelJolt_attack / 100) end
  if c.decelJolt_wobble ~= nil then self.decelJolt:setWobble(c.decelJolt_wobble / 100) end
  if c.decelJolt_accelSmooth ~= nil then self.decelJolt:setAccelSmooth(c.decelJolt_accelSmooth) end
  if c.decelJolt_smooth ~= nil then self.decelJolt:setSmooth(c.decelJolt_smooth) end
  if c.accelJolt_enabled ~= nil then self.accelJolt:setEnabled(c.accelJolt_enabled) end
  if c.accelJolt_minJerk ~= nil then self.accelJolt:setMinJerk(c.accelJolt_minJerk) end
  if c.accelJolt_fullJerk ~= nil then self.accelJolt:setFullJerk(c.accelJolt_fullJerk) end
  if c.accelJolt_maxRotation ~= nil then self.accelJolt:setMaxRotation(c.accelJolt_maxRotation) end
  if c.accelJolt_duration ~= nil then self.accelJolt:setDuration(c.accelJolt_duration) end
  if c.accelJolt_attack ~= nil then self.accelJolt:setAttack(c.accelJolt_attack / 100) end
  if c.accelJolt_wobble ~= nil then self.accelJolt:setWobble(c.accelJolt_wobble / 100) end
  if c.accelJolt_accelSmooth ~= nil then self.accelJolt:setAccelSmooth(c.accelJolt_accelSmooth) end
  if c.accelJolt_smooth ~= nil then self.accelJolt:setSmooth(c.accelJolt_smooth) end
  if c.leanInRoll_enabled ~= nil then self.leanInRoll:setEnabled(c.leanInRoll_enabled) end
  if c.leanInRoll_minG ~= nil then self.leanInRoll:setMinG(c.leanInRoll_minG) end
  if c.leanInRoll_maxG then self.leanInRoll:setMaxG(c.leanInRoll_maxG) end
  if c.leanInRoll_maxRoll ~= nil then self.leanInRoll:setMaxRoll(c.leanInRoll_maxRoll) end
  if c.leanInRoll_smoothness then self.leanInRoll:setSmoothness(c.leanInRoll_smoothness) end

  -- Follow smoothing (pitch only; yaw smoothing was removed)
  if c.followSmoothing_pitchSmooth then self.followSmoothing:setPitchSmooth(c.followSmoothing_pitchSmooth) end

  -- Speed distance (§5.10)
  if c.speedDistance_maxDist then self.speedDistance:setMaxDist(c.speedDistance_maxDist) end
  if c.speedDistance_maxSpeed then self.speedDistance:setMaxSpeed(c.speedDistance_maxSpeed) end
  if c.speedDistance_smoothness then self.speedDistance:setSmoothness(c.speedDistance_smoothness) end
  if c.speedDistance_brakeDecel then self.speedDistance:setBrakeDecel(c.speedDistance_brakeDecel) end
  if c.speedDistance_brakeStrength then self.speedDistance:setBrakeStrength(c.speedDistance_brakeStrength / 100) end
end

-- Load settings from the user file + defaults, then apply.
function C:loadSettings()
  local settingsPath = "/arcadeOrbitSettings.json"
  local defaultsPath = "/lua/ge/extensions/core/arcadeOrbit/arcadeOrbitDefaults.json"

  local defaults = jsonReadFile(defaultsPath)
  if not defaults then return end

  local defaultPreset = defaults.presets and defaults.presets.Default or {}

  local userConfig = jsonReadFile(settingsPath)
  local chosenPreset = (userConfig and userConfig.chosenPreset) or "Default"
  local preset = (defaults.presets and defaults.presets[chosenPreset]) or defaultPreset

  -- Merge user custom presets on top
  if userConfig and userConfig.presets and userConfig.presets[chosenPreset] then
    preset = tableMerge(defaultPreset, userConfig.presets[chosenPreset])
  end

  self:applyConfig(preset)
  self._settingsLoaded = true
end

function C:setOffset(v)
  self.orbitOffset = vec3(v)
end

function C:setRefNodes(centerNodeID, leftNodeID, backNodeID, dynamicFovRearNodeID)
  log("D", "arcadeOrbit setRefNodes: center=" .. tostring(centerNodeID)
    .. " left=" .. tostring(leftNodeID)
    .. " back=" .. tostring(backNodeID))
  self.refNodesSync:store(centerNodeID, leftNodeID, backNodeID)
  self.refNodes = self.refNodesSync.nodes
  self.rearNodeID = dynamicFovRearNodeID
  self.refNodesSync:reset()
end

-- params in global coords
function C:setRef(center, left, back)
  local prevTarget = self.target
  self.target = center ~= nil and true or false
  self.targetCenter = center
  self.targetLeft = left
  self.targetBack = back
  if self.target ~= prevTarget then self:reset() end
end

function C:setTargetMode(targetMode, camBase)
  self.mode = targetMode
  self.camBase = camBase
end

function C:setDefaultDistance(d)
  self.defaultDistance = d
end

function C:setDistance(d)
  self.camDist = d
end

function C:setMaxDistance(d)
  self.camMaxDist = d
end

function C:setDefaultRotation(rot)
  self.defaultRotation = rot
end

function C:setSkipFovModifier(skip)
  self.skipFovModifier = skip
end

local ref, left, back, dirxy = vec3(), vec3(), vec3(), vec3()

local nx, ny, nz = vec3(), vec3(), vec3()

local targetPos, camdir, dir = vec3(), vec3(), vec3()

local lastCamPointVec, lastCamLastPerp, moveDir = vec3(), vec3(), vec3()

local rot, calculatedCamPos, camPos, updir = vec3(), vec3(), vec3(), vec3()

local resultPos, resultRot, tempQuatB = vec3(), quat(), quat()

local basePitchLookDir, basePitchAxis, pitchedLookDir = vec3(), vec3(), vec3()
local basePitchQuat = quat()
local gAimAxis = vec3()
local gAimQuat = quat()
local leanRollQuat = quat()
local leanRollUp = vec3(0, 0, 1)

function C:update(data)
  data.res.collisionCompatible = true

  -- One-shot: adopt the stock orbit camera's ref nodes + per-vehicle JBeam config.
  self.refNodesSync:sync(self, data.vid)

  if self.target then
    ref:set(self.targetCenter)
    left:set(self.targetLeft)
    back:set(self.targetBack)
  else
    if self.refNodes then
      ref:set(data.veh:getNodePositionXYZ(self.refNodes.ref))
      left:set(data.veh:getNodePositionXYZ(self.refNodes.left))
      back:set(data.veh:getNodePositionXYZ(self.refNodes.back))
    end
  end

  -- reset cam
  if self.cameraResetted == 3 then
    if self.lockCamera == false or self.configChanged == false then
      -- if a reload hasn't just happened
      self.camRot = vec3(self.defaultRotation)
      self.camDist = self.defaultDistance
      self.lockCamera = false
      self.accumManualYaw = 0
      core_camera.clearInputs()
    else
      self.cameraResetted = 0
    end
    self.configChanged = false
  end
  if data.teleported then
    self.velocityAim:reset()
    self.speedShake:reset()
    self.driftShake:reset()
    self.accelDistance:reset()
    self.accelResponse:reset()
    self.brakePitch:reset()
    self.decelJolt:reset()
    self.accelJolt:reset()
    self.leanInRoll:reset()
    self.followSmoothing:reset()
    self.speedDistance:reset()
  end

  -- calculate the camera offset: rotate with the vehicle
  nx:set(push3(left) - ref)
  ny:set(push3(back) - ref)
  nz:set(push3(nx):cross(ny))
  ny:set(push3(nx):cross(-push3(nz)))
  nx:normalize()
  ny:normalize()
  nz:normalize()

  -- One-shot: measure ref-node-to-roof distance so targetHeight is roof-relative.
  if not self.vehicleMeasure.measured then
    self.vehicleMeasure:measureRoofHeight(data)
  end

  if not self.camBase or self.cameraResetted > 0 then
    -- this needs to happen here as on init the node data is not existing yet
    if self.offset and self.offset.x and nx:length() ~= 0 and ny:length() ~= 0 then
      self.camBase = vec3(self.offset.x, self.offset.y, self.offset.z)
      self.camOffset2 = nx * self.camBase.x + ny * self.camBase.y + vecZ * (self.vehicleMeasure.roofHeight + self.targetHeight)
      if self.target then
        targetPos = data.pos + ref
      else
        targetPos = data.pos + ref + self.camOffset2
      end
    elseif self.camOffset2 then
      targetPos = data.pos + ref + self.camOffset2
      self.camOffset2 = nil -- we only use previous offset for only one frame when needed
    else
      targetPos = data.veh:getBBCenter() - (data.pos + ref)
    end
  else
    if not self.camOffset2 then self.camOffset2 = vec3() end
    self.camOffset2:set(push3(nx) * self.camBase.x + push3(ny) * self.camBase.y + vecZ * (self.vehicleMeasure.roofHeight + self.targetHeight))
    targetPos:set(push3(data.pos) + ref + self.camOffset2)
  end

  -- Crest/valley response (height + pitch offsets). Both are applied AFTER
  -- the pitch smoother further down, as a crisp overlay (so the 3.5s boom-pitch
  -- smoothing does not dampen the crest/valley). The locked-camera flip check
  -- below sees the raw (un-offset) targetPos, same as stock.
  local accelH, accelP = self.accelResponse:update(data)

  local yawDif = 0.1*(MoveManager.yawRight - MoveManager.yawLeft)
  local pitchDif = 0.1*(MoveManager.pitchDown - MoveManager.pitchUp)
  dir:set(vecY)

  local flipFired = false
  if self.cameraResetted == 0 then
    -- Stopped flip guard: this test compares per-frame displacement; when the
    -- car is stopped that displacement is ~0 and its sign is pure sim/
    -- suspension jitter, which toggles anchor/parity every frame and wobbles
    -- a tilted orbit visibly. Let the flip respond to real motion only —
    -- while driving the test is byte-identical to the stock orbit camera.
    if self.lockCamera == true and data.vel:length() > STOP_FLIP_SPEED then
      camdir:set(push3(self.camLastTargetPos) - self.camLastPos2)
      if sign((push3(targetPos) - self.camLastTargetPos):dot(camdir)) < 0 then
        self.camRot.x = self.camRot.x + 180
        self.camLastRot.x = self.camLastRot.x + math.pi
        self.camLastPos2:set(push3(targetPos) + camdir)
        self.camLastPosPerp:set(push3(vecZ):cross(camdir):normalized() * (self.relaxation * -0.8) + targetPos)
        flipFired = true
      end
    end
  else
    self.lockCamera = false
    if self.cameraResetted >= 1 then
      dir = ref - back
      if targetPos:distance(self.preResetPos) < 4 then
        self.camLastRot.x = select(1, getRot((self.camLastTargetPos - self.camLastPos), dir, nz))
        self.camRot.x = self.defaultRotation.x
      else
        self.camRot:set(self.defaultRotation)
        self.camLastRot:set(math.rad(self.camRot.x), math.rad(self.camRot.y) * 1.5, 0)
      end
      self.camLastPos2 = targetPos - dir
      self.camLastPosPerp = vecZ:cross(dir):normalized() * (self.relaxation * -0.8) + targetPos
      dir:normalize()
    end
  end

  local maxRot = 4.5
  if (math.abs(yawDif) + math.abs(pitchDif) + math.abs(MoveManager.yawRelative) + math.abs(MoveManager.pitchRelative) > 0) then
    maxRot = 1000
  end

  -- mouse rotation
  local dtfactor = data.dt * 1000
  local mouseYaw = sign(MoveManager.yawRelative) * math.min(math.abs(MoveManager.yawRelative * 10), maxRot * data.dt) + yawDif * dtfactor
  local mousePitch = sign(-MoveManager.pitchRelative) * math.min(math.abs(MoveManager.pitchRelative * 10), maxRot * data.dt) + pitchDif * dtfactor
  if mouseYaw ~= 0 or mousePitch ~= 0 then
    -- only lock the camera once enough horizontal movement has accumulated
    self.accumManualYaw = (self.accumManualYaw or 0) + mouseYaw
    if self.cameraResetted == 0 and math.abs(self.accumManualYaw) > 10 then
      self.lockCamera = true
    end
    self.camRot.x = self.camRot.x - mouseYaw
    self.camRot.y = self.camRot.y - mousePitch
    --self.camRot.z = self.camRot.z + 300*data.dt*(MoveManager.rollRight - MoveManager.rollLeft)
  end

  self.camRot.y = math.min(math.max(self.camRot.y, -85), 85)

  -- make sure the rotation is never bigger than 2 PI
  if self.camRot.x > 180 then
    self.camRot.x = self.camRot.x - 360
  elseif self.camRot.x < -180 then
    self.camRot.x = self.camRot.x + 360
  end

  if self.camLastRot.x > math.pi then
    self.camLastRot.x = self.camLastRot.x - math.pi * 2
  elseif self.camLastRot.x < -math.pi then
    self.camLastRot.x = self.camLastRot.x + math.pi * 2
  end

  -- Zoom: adjust the distance multiplier
  local zoomChange = MoveManager.zoomIn - MoveManager.zoomOut
  if zoomChange ~= 0 then
    local zoomStep = 1.05
    if zoomChange > 0 then
      self.camDist = self.camDist / zoomStep
    else
      self.camDist = self.camDist * zoomStep
    end
    self.camDist = clamp(self.camDist, 0.2, 4.0)
  end

  if nx:squaredLength() == 0 or ny:squaredLength() == 0 then
    data.res.pos = data.pos
    data.res.rot = quatFromDir(vecY, vecZ)
    return false
  end

  if self.cameraResetted ~= 1 then
    lastCamPointVec:set(push3(targetPos) - self.camLastPos2)
    lastCamLastPerp:set(push3(self.camLastPosPerp) - targetPos)
    if lastCamPointVec:length() < self.relaxation and lastCamLastPerp:length() > self.relaxation * 0.8 then
      moveDir:set(push3(targetPos) - self.camLastTargetPos); moveDir:normalize()
      if math.abs(push3(lastCamPointVec):normalized():dot(moveDir)) > math.abs(push3(lastCamLastPerp):normalized():dot(moveDir)) then
        self.camLastPos2:set(push3(lastCamPointVec):cross(lastCamLastPerp):cross(lastCamLastPerp):normalized() + targetPos)
        lastCamPointVec:set(push3(targetPos) - self.camLastPos2)
      end
    end
    dir:set(lastCamPointVec)
    dir:normalize()

    -- flatten the rotation plane when camera moves perpendicularly
    dirxy:set(dir.x, dir.y, 0)
    local dirxylen = dirxy:length()
    local coef = math.sqrt(math.max(0, 1 - dirxylen))
    dir:set(push3(dir) * math.max(0, 1 - coef) + push3(dirxy) * (coef / (dirxylen + 1e-30)))
    dir:normalize()
  end

  lastCamPointVec:set(push3(self.camLastPos2) - targetPos)
  self.camLastPos2:set(push3(lastCamPointVec) * (self.relaxation / (lastCamPointVec:length() + 1e-30)) + targetPos)

  rot:set(math.rad(self.camRot.x), math.rad(self.camRot.y), math.rad(self.camRot.z))

  -- Screen-fill based distance (must be computed before use)
  local vehId = data.veh:getID()
  if self._fitDistDirty or self._fitVehId ~= vehId then
    self:computeFitDist(vehId)
    self._fitVehId = vehId
    self._fitDistDirty = false
    self.camLastDist = self.fitDist * self.camDist
  end

  -- Input smoothing: stock orbit camera behaviour, verbatim semantics
  -- (~1/8 s exponential smoothing + yaw rate limit). Deliberately NOT
  -- user-configurable, like the stock camera. (Vehicle-driven boom motion is
  -- currently stock-instantaneous too — follow smoothing is disabled below.)
  local dist = self.fitDist * self.camDist
  if self.smoothingEnabled then
    local ratio = 1 / (data.dt * 8)
    local srdif = -sign(self.camLastRot.x - rot.x)
    if math.abs(self.camLastRot.x + srdif * 2 * math.pi - rot.x) < math.abs(self.camLastRot.x - rot.x) then
      self.camLastRot.x = self.camLastRot.x + srdif * 2 * math.pi
    end
    local rotxDiff = (1 / (ratio + 1) * rot.x + (ratio / (ratio + 1)) * self.camLastRot.x) - self.camLastRot.x
    rot.x = self.camLastRot.x + sign(rotxDiff) * math.min(math.abs(rotxDiff), maxRot * data.dt)
    rot.y = 1 / (ratio + 1) * rot.y + (ratio / (ratio + 1)) * self.camLastRot.y
    dist = 1 / (ratio + 1) * dist + (ratio / (ratio + 1)) * self.camLastDist
  end

  -- Follow smoothing (PITCH only): eases the boom's vertical follow motion
  -- (bumps) and runs BEFORE the crest/valley overlay (below), so the base
  -- boom stays smooth without dampening the crest/valley response. The boom
  -- azimuth stays stock-instant — smoothing it desynchronised the anchor/
  -- parity flip invariant and reintroduced the reverse-flip glitch.
  -- If the stock flip fired this frame, snap the pitch smoother to the new
  -- boom pitch so the flip stays atomic and invisible (see followSmoothing:adopt).
  if flipFired then self.followSmoothing:adopt(dir.x, dir.y, dir.z) end

  if self.smoothingEnabled then
    local sdx, sdy, sdz = self.followSmoothing:update(data, dir.x, dir.y, dir.z)
    dir:set(sdx, sdy, sdz)
  end

  -- Crest/valley: applied AFTER the pitch smoother as a crisp overlay, so the
  -- boom-pitch smoothing does not dampen the crest/valley response. The height
  -- offset is a parallel shift of the target (a translation, so it never turns
  -- the boom angle); the pitch offset is an aim tilt. The base boom (user
  -- orbit + vertical bump-follow) keeps its smoothing.
  if accelH ~= 0 then
    targetPos.z = targetPos.z + accelH
  end
  if accelP ~= 0 then
    dir.z = dir.z + accelP
  end

  -- Acceleration distance: update camera-forward from last frame, then apply delta.
  local adFwdX = self.camLastTargetPos.x - self.camLastPos.x
  local adFwdY = self.camLastTargetPos.y - self.camLastPos.y
  local adFwdZ = self.camLastTargetPos.z - self.camLastPos.z
  local adFwdLen = math.sqrt(adFwdX*adFwdX + adFwdY*adFwdY + adFwdZ*adFwdZ)
  if adFwdLen > 1e-6 then
    self.accelDistCtx.camForward:set(adFwdX/adFwdLen, adFwdY/adFwdLen, adFwdZ/adFwdLen)
  end

  -- Speed distance (§5.10): speed-based boom length, applied BEFORE the
  -- accel/decel distance modifier, which then stacks on top of this offset.
  dist = dist + self.speedDistance:update(data)

  -- Zoom multiplier (default 1.0, adjusted by mouse wheel)
  dist = dist + self.accelDistance:update(data, self.accelDistCtx)

  local fov = self.fov
  local fovModifier = self.skipFovModifier and 0 or self.fovModifier

  if (not self.target) and self.fov and fovModifier and self.maxDynamicFov then
    fov = self.fov + fovModifier + self.maxDynamicFov * (math.min(1, data.vel:length()/130))
  end

  local rotB = rot
  local dirB = dir

  if data.lookBack then
    rotB = lookBackVec
    dirB = back - ref
  end

  calculatedCamPos:set(
    math.sin(rotB.x) * math.cos(rotB.y)
    , -math.cos(rotB.x) * math.cos(rotB.y)
    , -math.sin(rotB.y))
  tempQuatB:setFromDir(dirB)
  calculatedCamPos:setRotate(tempQuatB)
  calculatedCamPos:setScaled(dist)

  camPos:set(push3(calculatedCamPos) + targetPos + self.orbitOffset + vecZ * (self.fitHeight or 0))
  updir:setCross(vecZ, dir)
  self.camLastPosPerp:set(push3(updir) * (self.relaxation * -0.8 / (updir:length() + 1e-30)) + targetPos)

  self.camLastTargetPos2:set(self.camLastTargetPos)
  self.camLastTargetPos:set(targetPos)
  self.camVel:set((push3(camPos) - self.camLastPos) / data.dt)
  self.camLastPos:set(camPos)
  self.camLastRot:set(rot)
  self.camLastDist = dist
  self.cameraResetted = math.max(self.cameraResetted - 1, 0)

  resultPos:set(camPos)

  -- velocity aim (drift look): offset the aim point toward the drift direction
  self.aimCtx.targetPos:set(targetPos)
  self.aimCtx.left:set(nx)
  self.aimCtx.back:set(ny)
  local aimDir = self.velocityAim:update(data, self.aimCtx)

  basePitchLookDir:set(push3(aimDir) - camPos)
  local aimDist = basePitchLookDir:length()
  basePitchLookDir:normalize()
  local effectivePitch = (self.framingPitch or 0) + (self.basePitch or 0)
  if effectivePitch ~= 0 then
    basePitchAxis:set(basePitchLookDir:cross(vecZ))
    if basePitchAxis:squaredLength() > 1e-6 then
      basePitchAxis:normalize()
      basePitchQuat:setFromAxisAngle(basePitchAxis, math.rad(effectivePitch))
      pitchedLookDir:set(basePitchLookDir)
      pitchedLookDir:setRotate(basePitchQuat)
    else
      pitchedLookDir:set(basePitchLookDir)
    end
  else
    pitchedLookDir:set(basePitchLookDir)
  end

  -- G-force aim offset (Phase 4): the AIM TARGET moves in camera space — the
  -- camera position stays put and simply re-aims (the reference enhanceddriver
  -- g-force feel). brakePitch contributes a sustained target offset in METRES
  -- (positive = target down) converted to the equivalent rotation via
  -- atan(offset / aim distance); the jolts are jerk-triggered ANIMATIONS that
  -- contribute their rotation directly (decelJolt down, accelJolt up). Force =
  -- each effect's longitudinal g in CAMERA space: projected onto the camera's
  -- look direction (basePitchLookDir), NOT the vehicle's forward — the chase
  -- cam flips to face the direction of travel when reversing, so "forward"
  -- for the viewer is the view direction (a reverse-into-wall is a camera-
  -- frame DECELERATION). leanInRoll (§5.5) measures the LATERAL g in the same
  -- camera frame (projected on the camera's right axis) and rolls the camera
  -- around its aim axis. Applied even while the user holds a manual camera
  -- lock (lockCamera): both the measured g and the aim tilt / roll are derived
  -- from the LIVE camera pose every frame, so the effects follow the camera
  -- wherever the user has moved it.
  self.gForceCtx.camFwd:set(basePitchLookDir)
  local gOffsetM = self.brakePitch:update(data, self.gForceCtx)
  local gJoltRad = self.decelJolt:update(data, self.gForceCtx)
                 + self.accelJolt:update(data, self.gForceCtx)
  local leanRollRad = self.leanInRoll:update(data, self.gForceCtx)
  if gOffsetM ~= 0 or gJoltRad ~= 0 then
    -- Axis = lookDir × worldUp (the camera's right); positive angle = aim
    -- DOWN (the basePitch convention, verified in-game).
    gAimAxis:set(pitchedLookDir.y, -pitchedLookDir.x, 0)
    if gAimAxis:squaredLength() > 1e-6 then
      gAimAxis:normalize()
      gAimQuat:setFromAxisAngle(gAimAxis, gJoltRad + math.atan(gOffsetM / math.max(aimDist, MIN_AIM_DIST_M)))
      pitchedLookDir:setRotate(gAimQuat)
    end
  end
  -- Lean-in roll (§5.5): roll the world up-vector about the aim axis, then build
  -- the orientation with setFromDir(aim, rolledUp). This applies the roll about
  -- the AIM axis in the engine's own convention. (A world-axis pre-multiply of the
  -- orientation renders as a roll about a FIXED world axis — it looked correct
  -- facing north/south but became a pitch facing east/west.)
  if leanRollRad ~= 0 then
    leanRollUp:set(0, 0, 1)
    leanRollQuat:setFromAxisAngle(pitchedLookDir, -leanRollRad)
    leanRollUp:setRotate(leanRollQuat)
    resultRot:setFromDir(pitchedLookDir, leanRollUp)
  else
    resultRot:setFromDir(pitchedLookDir)
  end
  data.res.pos:set(resultPos)
  data.res.rot:set(resultRot)

  -- Drift shake (§5.2): perlin shake scaled by the slip angle (velocity vs
  -- forward). Vehicle frame from the ref nodes: carUp = nz (nx×ny). ny
  -- (back node − ref) technically points toward the rear, but the slip angle is
  -- folded at 90° (min(β, π−β)) so the rear-vs-forward sign is irrelevant here.
  if nz:squaredLength() > NODE_UP_EPS_SQ then
    self.driftCtx.carRot:setFromDir(ny, nz)
    self.driftCtx.carRotInv:set(self.driftCtx.carRot)
    self.driftCtx.carRotInv:inverse()
    self.driftShake:update(data, self.driftCtx)
  end

  self.speedShake:update(data)
  data.res.fov = fov
  data.res.targetPos:set(targetPos)
  self.collision:update(data)
  return true
end

-- Global registry of all arcadeOrbit camera instances (for settings reload from JS).
local _instances = {}

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

-- Global function called from the Vue settings panel after saving.
function arcadeOrbitReloadSettings()
  for _, cam in ipairs(_instances) do
    cam:loadSettings()
  end
end

-- Global functions called from the EIC settings panel (demo toggle).
function arcadeChaseDemoIsEnabled()
  return isDemoEnabled()
end

function arcadeChaseDemoApply(enabled)
  enabled = enabled == true
  -- Keep the shared camera configuration's enabled flag in sync with the demo
  -- toggle so the camera is skipped while cycling cameras when disabled.
  local cfg = core_camera.getConfigurationReadOnly and core_camera.getConfigurationReadOnly()
  if cfg then
    for i, entry in ipairs(cfg) do
      if entry.name == 'arcadeOrbit' and entry.enabled ~= enabled then
        core_camera.toggleEnabledById(i)
        break
      end
    end
  end
  -- Update the live camera instances of the player's current vehicle so the
  -- camera menu reflects the new state immediately (other vehicles refresh
  -- their cameras when they are (re)configured).
  local vehicle = be and be:getPlayerVehicle(0)
  if vehicle then
    local ctxId = core_camera.getContextIdForPlayer and core_camera.getContextIdForPlayer(0)
    local cameras = core_camera.getCameraDataById(vehicle:getId(), ctxId)
    local cam = cameras and cameras['arcadeOrbit']
    if cam then
      cam.hidden = not enabled
      cam.disabledByDefault = not enabled
    end
  end
  return true
end

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  _instances[#_instances + 1] = o
  return o
end

