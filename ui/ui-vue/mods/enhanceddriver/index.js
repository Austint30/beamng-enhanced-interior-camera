import { lua } from "@/bridge"

const BUTTON_ID = "enhanceddriver.eic-settings"
const COMPONENT_PATH = "/ui/ui-vue/mods/enhanceddriver/EICSettings.vue"

export async function onLoad() {
  const result = await lua.extensions.ui_pause_actions.registerModButton({
    id: BUTTON_ID,
    tabId: "mods",
    label: "EIC Settings",
    icon: "wrench",
    componentName: COMPONENT_PATH,
  })

  if (!result?.success) {
    console.error("[Enhanced Driver] Failed to register the EIC pause-menu button", result?.reason)
  }
}

export async function onUnload() {
  const result = await lua.extensions.ui_pause_actions.unregisterModButton(BUTTON_ID)

  if (!result?.success && result?.reason !== "not_found") {
    console.error("[Enhanced Driver] Failed to unregister the EIC pause-menu button", result?.reason)
  }
}
