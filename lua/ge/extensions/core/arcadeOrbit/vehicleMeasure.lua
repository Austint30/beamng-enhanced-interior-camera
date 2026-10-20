-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- vehicleMeasure — measures vehicle extent relative to the ref node
-- using a percentile statistical model to exclude small protrusions
-- (antennae, mirrors, exhaust tips, trailer hitches) that would
-- otherwise distort the measurement.
--
-- Two measurements:
--   measureRoofHeight(data)   — distance from ref node to the roof (Z-axis)
--   measureRearDistance(vehId) — distance from ref node to the rear (Y-axis)

local C = {}
C.__index = C

-- Rear distance fallbacks and clamps (meters).
local REAR_FALLBACK     = 1.5        -- returned when vehicle data is unavailable
local REAR_MIN_DISTANCE = 0.5        -- minimum plausible rear distance; below this return REAR_MIN_RETURN
local REAR_MIN_RETURN   = 1.0        -- returned when measured distance < REAR_MIN_DISTANCE
local REAR_MAX_DISTANCE = 8.0        -- maximum plausible rear distance (beyond = trailer/tow)

-- Height fallbacks and clamps (meters).
local HEIGHT_FALLBACK = 1.0         -- returned when vehicle data is unavailable
local HEIGHT_MIN      = 0.5         -- minimum plausible vehicle height
local HEIGHT_MAX      = 3.5         -- maximum plausible vehicle height (beyond = truck/van)

-- Pick the pct-th percentile value from an array (in-place sort).
local function percentile(values, pct)
  if #values == 0 then return nil end
  if #values == 1 then return values[1] end
  table.sort(values)
  local idx = math.ceil(pct * #values)
  if idx < 1 then idx = 1 end
  if idx > #values then idx = #values end
  return values[idx]
end

function C:init()
  self.roofHeight = 0
  self.measured = false
  self.roofPercentile = 0.99
  self.rearPercentile = 0.99
end

function C:reset()
  self.measured = false
  self.roofHeight = 0
end

function C:setRoofPercentile(v)
  self.roofPercentile = math.min(math.max(v, 0.5), 1.0)
end

function C:setRearPercentile(v)
  self.rearPercentile = math.min(math.max(v, 0.5), 1.0)
end

-- Measure the ref-node-to-roof distance using a percentile of node heights.
-- data: camera data (data.veh)
-- Returns the measured height (m). No-op if already measured.
function C:measureRoofHeight(data)
  if self.measured then return self.roofHeight end

  local vehId = data.veh:getID()
  local vehData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehData or not vehData.vdata or not vehData.vdata.nodes then
    self.measured = true
    return self.roofHeight
  end

  local vdata = vehData.vdata
  local nodes = vdata.nodes

  -- Get ref node Y position (vehicle-local up axis).
  local refNodeId
  if vdata.refNodes and vdata.refNodes[0] then
    refNodeId = vdata.refNodes[0].ref
  else
    refNodeId = 0
  end
  local refNode = nodes[refNodeId]
  if not refNode then
    self.measured = true
    return self.roofHeight
  end
  local refZ = refNode.pos.z

  -- Collect heights of all nodes above the ref node.
  local heights = {}
  for _, node in pairs(nodes) do
    local h = node.pos.z - refZ
    if h > 0 then
      heights[#heights + 1] = h
    end
  end

  if #heights == 0 then
    self.measured = true
    return self.roofHeight
  end

  local h = percentile(heights, self.roofPercentile)
  if not h then h = 0 end

  self.roofHeight = h
  self.measured = true
  return self.roofHeight
end

-- Measure the distance from the ref node to the rear of the car.
-- Collects distances of nodes behind the ref (pos.y < ref.pos.y, since Y=forward).
-- 99th percentile avoids trailing outliers (exhaust tips, trailer hitches).
-- Returns the rear distance in meters.
function C:measureRearDistance(vehId)
  local vehData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehData or not vehData.vdata or not vehData.vdata.nodes then
    return REAR_FALLBACK
  end

  local vdata = vehData.vdata
  local nodes = vdata.nodes

  -- Get ref node Y position.
  local refNodeId = (vdata.refNodes and vdata.refNodes[0]) and vdata.refNodes[0].ref or 0
  local refNode = nodes[refNodeId]
  if not refNode then
    return REAR_FALLBACK
  end
  local refY = refNode.pos.y

  -- Collect distances of nodes behind the ref.
  local dists = {}
  for _, node in pairs(nodes) do
    local d = refY - node.pos.y
    if d > 0 then
      dists[#dists + 1] = d
    end
  end

  if #dists < 2 then
    return REAR_FALLBACK
  end

  local dist = percentile(dists, self.rearPercentile)
  if not dist then return REAR_FALLBACK end
  if dist < REAR_MIN_DISTANCE then return REAR_MIN_RETURN end
  if dist > REAR_MAX_DISTANCE then return REAR_MAX_DISTANCE end
  return dist
end

-- Measure the vehicle height using a percentile of all node Z values.
-- Returns the height in meters.
function C:measureHeight(vehId)
  local vehData = extensions.core_vehicle_manager.getVehicleData(vehId)
  if not vehData or not vehData.vdata or not vehData.vdata.nodes then
    return HEIGHT_FALLBACK
  end

  local vdata = vehData.vdata
  local nodes = vdata.nodes

  -- Get ref node Z position.
  local refNodeId = (vdata.refNodes and vdata.refNodes[0]) and vdata.refNodes[0].ref or 0
  local refNode = nodes[refNodeId]
  if not refNode then
    return HEIGHT_FALLBACK
  end
  local refZ = refNode.pos.z

  -- Collect heights of all nodes above the ref.
  local heights = {}
  for _, node in pairs(nodes) do
    local h = node.pos.z - refZ
    if h > 0 then
      heights[#heights + 1] = h
    end
  end

  if #heights < 2 then
    return HEIGHT_FALLBACK
  end

  local h = percentile(heights, self.roofPercentile)
  if not h then return HEIGHT_FALLBACK end
  if h < HEIGHT_MIN then return HEIGHT_MIN end
  if h > HEIGHT_MAX then return HEIGHT_MAX end
  return h
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW

return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
