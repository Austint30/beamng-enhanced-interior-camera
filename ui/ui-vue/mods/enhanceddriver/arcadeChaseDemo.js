import { lua } from "@/bridge"
import { runRaw } from "@/bridge/libs/Lua.js"

// The bundled Arcade Chase Camera demo reuses its original pause-menu id and
// settings page (copied into this mod's UI folder).
export const ARCADE_CHASE_BUTTON_ID = "arcadeOrbit.settings"
export const ARCADE_CHASE_COMPONENT_PATH = "/ui/ui-vue/mods/enhanceddriver/ArcadeChaseSettings.vue"

async function registerArcadeChaseButton() {
  const result = await lua.extensions.ui_pause_actions.registerModButton({
    id: ARCADE_CHASE_BUTTON_ID,
    tabId: "mods",
    label: "ACC Settings",
    icon: "aperture",
    componentName: ARCADE_CHASE_COMPONENT_PATH,
  })
  if (!result?.success) {
    console.error("[Enhanced Driver] Failed to register the Arcade Chase Camera button", result?.reason)
  }
}

export async function unregisterArcadeChaseButton() {
  const result = await lua.extensions.ui_pause_actions.unregisterModButton(ARCADE_CHASE_BUTTON_ID)
  if (!result?.success && result?.reason !== "not_found") {
    console.error("[Enhanced Driver] Failed to unregister the Arcade Chase Camera button", result?.reason)
  }
}

export async function readArcadeChaseEnabled() {
  try {
    return (await runRaw("arcadeChaseDemoIsEnabled()")) === true
  } catch (error) {
    console.warn("[Enhanced Driver] Could not read the Arcade Chase Camera demo state", error)
    return false
  }
}

export async function setArcadeChaseEnabled(enabled) {
  const on = enabled === true
  try {
    // Updates the live camera instances and the camera-cycle configuration.
    await runRaw(`arcadeChaseDemoApply(${on ? "true" : "false"})`)
  } catch (error) {
    console.warn("[Enhanced Driver] Could not apply the Arcade Chase Camera demo state", error)
  }
  if (on) await registerArcadeChaseButton()
  else await unregisterArcadeChaseButton()
}

// Called by the mod's UI entry point on load: mirror the persisted setting.
export async function syncArcadeChaseFromSettings() {
  await setArcadeChaseEnabled(await readArcadeChaseEnabled())
}
