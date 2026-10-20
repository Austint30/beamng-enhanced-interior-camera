-- This Source Code Form is subject to the terms of the bCDDL, v. 1.1.
-- If a copy of the bCDDL was not distributed with this
-- file, You can obtain one at http://beamng.com/bCDDL-1.1.txt

-- refNodes — ref-node sync for mod cameras.
--
-- BeamNG only populates cameraRefNodes for cameras listed in the vehicle JBeam.
-- Mod cameras (like arcadeOrbit) fall back to vmvd.refNodes[0], and their JBeam
-- camera config (offset/distance/fov) is empty. This module re-reads the vehicle
-- JBeam data on the first update frame and adopts the stock orbit camera's ref
-- nodes and config so the mod camera tracks the same point as orbit.

local C = {}
C.__index = C

function C:init()
  self.synced = false
  self.nodes = nil
end

-- Call on vehicle switch: allow the one-shot sync to run again.
function C:reset()
  self.synced = false
end

-- Store the node IDs BeamNG passed via setRefNodes (fallback values until sync).
function C:store(ref, left, back)
  self.nodes = { ref = ref, left = left, back = back }
end

-- One-shot sync against the vehicle JBeam data. Returns true if it ran this call.
function C:sync(camera, vid)
  if self.synced then return false end
  log("D", "arcadeOrbit refNodes sync: data.vid=" .. tostring(vid)
    .. "  camera.refNodes before = " .. tostring(camera.refNodes))
  local vdata = extensions.core_vehicle_manager.getVehicleData(vid)
  log("D", "  vdata = " .. tostring(vdata))
  if not vdata then
    log("D", "  FAILED: getVehicleData returned nil")
    return false
  end
  local vmvd = vdata.vdata
  local crn = vmvd.cameraRefNodes
  log("D", "  cameraRefNodes = " .. tostring(crn))
  if crn then
    local keys = {}
    for k in pairs(crn) do table.insert(keys, k) end
    log("D", "  cameraRefNodes keys = " .. table.concat(keys, ", "))
    local orbit = crn["orbit"]
    log("D", "  cameraRefNodes.orbit = " .. tostring(orbit))
    if orbit then
      log("D", "    orbit.ref=" .. tostring(orbit.ref)
        .. " orbit.left=" .. tostring(orbit.left)
        .. " orbit.back=" .. tostring(orbit.back))
    end
  end
  local rn0 = vmvd.refNodes and vmvd.refNodes[0]
  log("D", "  refNodes[0] = " .. tostring(rn0))
  if rn0 then
    log("D", "    refNodes[0].ref=" .. tostring(rn0.ref)
      .. " .left=" .. tostring(rn0.left)
      .. " .back=" .. tostring(rn0.back))
  end

  local rn = (crn and crn["orbit"]) or rn0
  if not rn then
    log("D", "  FAILED: no ref nodes found from any source")
    return false
  end

  self.nodes = { ref = rn.ref, left = rn.left, back = rn.back }
  camera.refNodes = self.nodes
  log("D", "  SYNCED OK: ref=" .. tostring(rn.ref)
    .. " left=" .. tostring(rn.left)
    .. " back=" .. tostring(rn.back))

  -- Adopt the orbit camera's per-vehicle JBeam config (offset, distance, fov).
  -- arcadeOrbit has no JBeam entry so it would otherwise use hardcoded defaults.
  -- The offset is critical: it shifts the look target up/forward relative to the
  -- ref node so the camera looks at mid-car height rather than the chassis floor.
  local orbitCfg = vmvd.cameraData and vmvd.cameraData["orbit"]
  log("D", "  orbitCfg = " .. tostring(orbitCfg))
  if orbitCfg then
    if orbitCfg.offset   then camera.offset   = orbitCfg.offset   end
    if orbitCfg.distance then camera.distance = orbitCfg.distance end
    if orbitCfg.fov      then camera.fov      = orbitCfg.fov      end
    camera.camBase = nil -- force camOffset2 to be recomputed from new offset
    camera:onVehicleCameraConfigChanged()
    log("D", "  adopted orbit cfg: offset=("
      .. tostring(camera.offset.x) .. ","
      .. tostring(camera.offset.y) .. ","
      .. tostring(camera.offset.z) .. ")"
      .. " distance=" .. tostring(camera.distance)
      .. " fov=" .. tostring(camera.fov))
  end

  self.synced = true
  return true
end

-- DO NOT CHANGE CLASS IMPLEMENTATION BELOW
return function(...)
  local o = ... or {}
  setmetatable(o, C)
  o:init()
  return o
end
