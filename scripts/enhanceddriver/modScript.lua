-- Runs when this mod is activated, including when it is re-enabled at runtime
-- through the mod manager.
--
-- Enabling a mod does not reload Lua modules that were already required while
-- the mod was disabled: the stock occupant/driver camera modules stay in
-- package.loaded, so core_camera keeps building stock cameras even though the
-- mod's files are now mounted. Drop the cached modules here -- before the mod
-- manager's file-change notification invalidates core_camera's constructor
-- cache -- so the next camera build requires the mod versions again.

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

for _, name in ipairs(modules) do
  package.loaded[name] = nil
end

-- Clearing package.loaded is not enough if core_camera already built camera
-- constructors from the stock modules. Invalidate its cache here as well; a
-- runtime activation (BeamMP joins) can otherwise keep the stock occupant
-- camera even though the mod files are mounted.
if core_camera and type(core_camera.onFileChanged) == 'function' then
  core_camera.onFileChanged('/lua/ge/extensions/core/cameraModes/occupant.lua', 'deleted')
  core_camera.onFileChanged('/lua/ge/extensions/core/cameraModes/driver.lua', 'deleted')
  log('I', 'enhanceddriver', 'Invalidated core camera constructor cache after mod activation')
end

log('I', 'enhanceddriver', 'Cleared cached camera modules after mod activation')

-- The hook extension handles the inverse transition (mod deactivated) by
-- clearing the same modules before core_camera rebuilds its cameras.
if type(setExtensionUnloadMode) == 'function' then
  setExtensionUnloadMode('enhanceddriver_cameraHooks', 'manual')
end
if extensions and type(extensions.load) == 'function' then
  pcall(extensions.load, 'enhanceddriver_cameraHooks')
end
