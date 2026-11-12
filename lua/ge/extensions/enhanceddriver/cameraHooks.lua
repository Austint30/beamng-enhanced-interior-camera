-- Keeps the cached camera modules in sync with the mod's mounted state.
--
-- Loaded by scripts/enhanceddriver/modScript.lua when the mod is activated.
-- The extension stays loaded while the game runs, so it can react when the mod
-- is disabled: the cached occupant/driver constructors must be dropped before
-- core_camera rebuilds its cameras, otherwise the modded constructors stay in
-- use without their files (and without their defaults JSON).

local M = {}

function M.onExtensionLoaded()
  -- Stay loaded when the mod is disabled so onModDeactivated can drop the
  -- cached camera constructors before core_camera rebuilds its cameras.
  if type(setExtensionUnloadMode) == 'function' then
    setExtensionUnloadMode(M, 'manual')
  end
end

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

local function registerUiButtons()
  local pauseActions = extensions and extensions.ui_pause_actions
  if not pauseActions or type(pauseActions.registerModButton) ~= 'function' then
    log('W', 'enhanceddriver', 'ui_pause_actions unavailable; restart the game to load EIC settings')
    return
  end

  -- Register the pause-menu entry directly instead of reloading the UI. A UI
  -- reload during an active session can leave the game window unfocused, which
  -- makes BeamNG mute game audio (while CEF UI sounds keep playing).
  local eic = pauseActions.registerModButton({
    id = 'enhanceddriver.eic-settings',
    tabId = 'mods',
    label = 'EIC Settings',
    icon = 'wrench',
    componentName = '/ui/ui-vue/mods/enhanceddriver/EICSettings.vue',
  })
  if not (eic and eic.success) then
    log('W', 'enhanceddriver', 'failed to register the EIC settings button: ' .. tostring(eic and eic.reason))
  end

  local arcadeEnabled = false
  if type(arcadeChaseDemoIsEnabled) == 'function' then
    arcadeEnabled = arcadeChaseDemoIsEnabled()
  elseif type(settings) == 'table' and type(settings.getValue) == 'function' then
    local edc = settings.getValue('edcSettings')
    arcadeEnabled = type(edc) == 'table' and edc.arcadeChaseEnabled == true
  end

  if arcadeEnabled then
    local arcade = pauseActions.registerModButton({
      id = 'arcadeOrbit.settings',
      tabId = 'mods',
      label = 'ACC Settings',
      icon = 'aperture',
      componentName = '/ui/ui-vue/mods/enhanceddriver/ArcadeChaseSettings.vue',
    })
    if not (arcade and arcade.success) then
      log('W', 'enhanceddriver', 'failed to register the Arcade Chase settings button: ' .. tostring(arcade and arcade.reason))
    end
  end
end

local function unregisterUiButtons()
  local pauseActions = extensions and extensions.ui_pause_actions
  if not pauseActions or type(pauseActions.unregisterModButton) ~= 'function' then return end
  -- The UI module is not unloaded with the mod, so drop its pause-menu buttons
  -- explicitly. Re-enabling the mod registers them again.
  pcall(pauseActions.unregisterModButton, 'enhanceddriver.eic-settings')
  pcall(pauseActions.unregisterModButton, 'arcadeOrbit.settings')
end

function M.onModDeactivated(mod)
  if not isOurMod(mod) then return end
  clearCameraModules()
  unregisterUiButtons()
end

function M.onModActivated(mod)
  if not isOurMod(mod) then return end
  log('I', 'enhanceddriver', 'camera hook: mod activated')
  clearCameraModules()
  -- Enabling a mod at runtime does not load its UI module, so index.js never
  -- runs. Register its pause-menu buttons here without reloading the UI.
  registerUiButtons()
end

function M.clearCameraModules()
  clearCameraModules()
end

return M
