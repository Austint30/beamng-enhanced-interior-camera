-- Keeps the cached camera modules in sync with the mod's mounted state.
--
-- Loaded by scripts/enhanceddriver/modScript.lua when the mod is activated.
-- The extension stays loaded while the game runs, so it can react when the mod
-- is disabled: the cached occupant/driver constructors must be dropped before
-- core_camera rebuilds its cameras, otherwise the modded constructors stay in
-- use without their files (and without their defaults JSON).

local M = {}

local modules = {
  'core/cameraModes/arcadeOrbit',
  'core/cameraModes/driver',
  'core/cameraModes/occupant',
  'core/cameraModes/speedshake',
  'core/enhancedoccupant/cameraFeatures',
  'core/enhancedoccupant/perlin',
  'core/enhancedoccupant/profiler',
  'core/enhancedoccupant/steeringLookAhead',
  'core/enhancedoccupant/tumbleDetection',
  'core/arcadeOrbit/perlin',
  'core/arcadeOrbit/refNodes',
  'core/arcadeOrbit/vehicleMeasure',
  'core/arcadeOrbit/effects/accelDistance',
  'core/arcadeOrbit/effects/accelJolt',
  'core/arcadeOrbit/effects/accelResponse',
  'core/arcadeOrbit/effects/brakePitch',
  'core/arcadeOrbit/effects/decelJolt',
  'core/arcadeOrbit/effects/driftShake',
  'core/arcadeOrbit/effects/followSmoothing',
  'core/arcadeOrbit/effects/leanInRoll',
  'core/arcadeOrbit/effects/speedDistance',
  'core/arcadeOrbit/effects/speedShake',
  'core/arcadeOrbit/effects/velocityAim',
}

local function clearCameraModules()
  for _, name in ipairs(modules) do
    package.loaded[name] = nil
  end
  if core_camera and type(core_camera.onFileChanged) == 'function' then
    core_camera.onFileChanged('/lua/ge/extensions/core/cameraModes/occupant.lua', 'deleted')
    core_camera.onFileChanged('/lua/ge/extensions/core/cameraModes/driver.lua', 'deleted')
  end
end

local function isOurMod(mod)
  if type(mod) ~= 'table' then return false end
  local id = tostring(mod.modname or mod.name or mod.fullpath or ''):lower()
  return id:find('enhanceddriver', 1, true) ~= nil
    or id:find('austint30', 1, true) ~= nil
    or id:find('enhanced-interior-camera', 1, true) ~= nil
end

function M.onModDeactivated(mod)
  if not isOurMod(mod) then return end
  clearCameraModules()
end

function M.clearCameraModules()
  clearCameraModules()
end

return M
