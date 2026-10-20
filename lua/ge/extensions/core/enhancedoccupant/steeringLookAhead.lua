-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

local C = {}
C.__index = C

function C:init()
  self.smoother = newTemporalSmoothingNonLinear(8, 8, 0)
  self.vehicleId = nil
end

function C:reset()
  self.smoother:reset()
end

function C:invalidateRegistration()
  -- Vehicle Lua reloads discard their notification list while the GE bridge can retain
  -- its registration bookkeeping. Unregistering lets the next update subscribe again.
  if self.vehicleId then
    local vehicle = getObjectByID(self.vehicleId)
    if vehicle then
      core_vehicleBridge.unregisterValueChangeNotification(vehicle, 'steering_input')
    end
  end

  self.vehicleId = nil
  self:reset()
end

function C:getInput(data)
  local vehicleId = data.veh:getId()
  if self.vehicleId ~= vehicleId then
    core_vehicleBridge.registerValueChangeNotification(data.veh, 'steering_input')
    self.vehicleId = vehicleId
    self:reset()
  end

  local steeringInput = core_vehicleBridge.getCachedVehicleData(vehicleId, 'steering_input') or 0
  return clamp(tonumber(steeringInput) or 0, -1, 1)
end

function C:getAngleOffset(data, angle, smoothness)
  angle = tonumber(angle) or 0
  if data.openxrSessionRunning or angle == 0 then
    self.smoother:set(0)
    return 0
  end

  smoothness = clamp((tonumber(smoothness) or 50) / 100, 0, 1)
  local smoothingRate = lerp(20, 0.5, smootheststep(smoothness))
  local smoothedSteeringInput = self.smoother:getWithRate(
    self:getInput(data),
    data.dt,
    smoothingRate
  )

  return math.rad(smoothedSteeringInput * angle)
end

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
