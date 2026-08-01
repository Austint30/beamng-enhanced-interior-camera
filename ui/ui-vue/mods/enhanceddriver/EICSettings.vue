<template>
  <section class="eic-settings">
    <header class="eic-header">
      <div>
        <h2>Enhanced Interior Camera</h2>
        <p>Configure camera motion, shake, dynamic FOV, and horizon stabilization.</p>
      </div>
      <span class="save-status" :class="{ error: saveError }">
        {{ saveError || saveStatus }}
      </span>
    </header>

    <div v-if="loading" class="state-message">Loading EIC settings…</div>
    <div v-else-if="loadError" class="state-message error">
      {{ loadError }}
    </div>

    <template v-else>
      <div class="preset-toolbar">
        <label class="preset-picker">
          <span>Preset</span>
          <BngDropdown
            :model-value="chosenPreset"
            :items="presetItems"
            long-names="wrap"
            @update:model-value="selectPreset"
          />
        </label>

        <BngButton
          v-if="canDeletePreset"
          :accent="ACCENTS.destructive"
          @click="deletePreset"
        >
          Delete preset
        </BngButton>
      </div>

      <BngTabs
        v-model="activeTab"
        class="settings-tabs"
        :use-bindings="true"
      >
        <div tab-heading="G-Effects">
          <div class="settings-panel">
            <h3>Longitudinal Motion</h3>
            <SettingSlider
              v-for="field in longitudinalMotionFields"
              :key="field.key"
              v-bind="field"
              :model-value="displayValue(field)"
              @update:model-value="value => updateSetting(field, value)"
            />

            <h3>Vertical Motion</h3>
            <SettingSlider
              v-for="field in verticalMotionFields"
              :key="field.key"
              v-bind="field"
              :model-value="displayValue(field)"
              @update:model-value="value => updateSetting(field, value)"
            />

            <h3>Lateral Motion</h3>
            <SettingSlider
              v-for="field in lateralMotionFields"
              :key="field.key"
              v-bind="field"
              :model-value="displayValue(field)"
              @update:model-value="value => updateSetting(field, value)"
            />
          </div>
        </div>

        <div tab-heading="Shake">
          <div class="settings-panel">
            <h3>Speed Shake</h3>
            <SettingSlider
              v-for="field in speedShakeFields"
              :key="field.key"
              v-bind="field"
              :model-value="displayValue(field)"
              :unit="field.speed ? speedUnit.label : field.unit"
              @update:model-value="value => updateSetting(field, value)"
            />

            <h3>Drift Shake</h3>
            <SettingSlider
              v-for="field in driftShakeFields"
              :key="field.key"
              v-bind="field"
              :model-value="displayValue(field)"
              @update:model-value="value => updateSetting(field, value)"
            />
          </div>
        </div>

        <div tab-heading="FOV">
          <div class="settings-panel">
            <h3>Dynamic FOV</h3>
            <SettingSlider
              v-for="field in fovFields"
              :key="field.key"
              v-bind="field"
              :model-value="displayValue(field)"
              :unit="field.speed ? speedUnit.label : field.unit"
              @update:model-value="value => updateSetting(field, value)"
            />
          </div>
        </div>

        <div tab-heading="Other">
          <div class="settings-panel">
            <h3>Steering Look-Ahead</h3>
            <div class="settings-notice">
              <BngIcon class="settings-notice-icon" :type="icons.warning" />
              <div>
                <strong>BeamNG camera setting required</strong>
                <span>
                  Set Options &gt; Camera &gt; Camera - Driver &gt; Look-Ahead Angle
                  to 0%. Otherwise, BeamNG's built-in look-ahead can cause conflicting
                  camera movements.
                </span>
              </div>
            </div>
            <SettingSlider
              v-for="field in steeringLookAheadFields"
              :key="field.key"
              v-bind="field"
              :model-value="displayValue(field)"
              @update:model-value="value => updateSetting(field, value)"
            />

            <h3>Pitch and Roll</h3>
            <SettingSlider
              v-for="field in otherFields"
              :key="field.key"
              v-bind="field"
              :model-value="displayValue(field)"
              @update:model-value="value => updateSetting(field, value)"
            />
            <div class="setting-switch">
              <div class="setting-switch-copy">
                <div class="setting-switch-label">Disable Horizon Lock While Tumbling</div>
                <div class="setting-switch-description">
                  Gradually attaches the camera to the vehicle when the vehicle starts tumbling.
                </div>
              </div>
              <BngSwitch
                class="setting-switch-control"
                :model-value="activeValues.disableHorizonLockWhileTumbling === true"
                aria-label="Disable horizon lock while tumbling"
                @update:model-value="value => updateBooleanSetting('disableHorizonLockWhileTumbling', value)"
              />
            </div>
          </div>
        </div>
      </BngTabs>

      <div v-if="chosenPreset === CUSTOM_PRESET" class="create-preset">
        <BngInput
          v-model="presetName"
          class="preset-name"
          placeholder="New preset name"
          :maxlength="48"
          @keyup.enter="createPreset"
        />
        <BngButton
          :accent="ACCENTS.main"
          :disabled="!canCreatePreset"
          @click="createPreset"
        >
          Save as preset
        </BngButton>
        <span v-if="presetNameError" class="preset-name-error">{{ presetNameError }}</span>
      </div>
    </template>
  </section>
</template>

<script setup>
import { computed, onBeforeUnmount, onMounted, reactive, ref } from "vue"
import { useRoute } from "vue-router"
import {
  ACCENTS,
  BngButton,
  BngDropdown,
  BngIcon,
  BngInput,
  BngSwitch,
  BngTabs,
  icons,
} from "@/common/components/base"
import { lua } from "@/bridge"
import { runRaw } from "@/bridge/libs/Lua.js"
import { useSettings } from "@/services/settings"
import SettingSlider from "./SettingSlider.vue"

const DEFAULT_SETTINGS_PATH = "/lua/ge/extensions/core/cameraModes/enhanceddriverDefaults.json"
const DEFAULT_PRESETS = [
  "Default",
  "Lookahead",
  "Intense",
  "Smooth",
  "VR (Comfort)",
  "VR (Thrill)",
]
const CUSTOM_PRESET = "Custom"
const UNPAUSED_PAUSE_ROUTES = new Set([
  "pause.vehicle.parts",
  "pause.vehicle.configurationcombined",
  "pause.vehicle.configurationcombined.mirrors",
  "pause.vehicle.tuning",
  "pause.vehicle.debug",
  "pause.vehicle.paint",
  "pause.environment.weather",
  "pause.environment.simulation",
])
const PRESET_ORDER = new Map(
  [...DEFAULT_PRESETS, CUSTOM_PRESET].map((name, index) => [name, index])
)

const longitudinalMotionFields = [
  {
    key: "gForceAccel",
    label: "Acceleration Strength",
    description: "Strength of forward head movement under acceleration.",
    min: 0,
    max: 5,
    step: 0.1,
  },
  {
    key: "gForceDecel",
    label: "Deceleration Strength",
    description: "Strength of backward head movement under braking.",
    min: 0,
    max: 5,
    step: 0.1,
  },
  {
    key: "gForceYThreshold",
    label: "Acceleration / Deceleration Threshold",
    description: "Force required before longitudinal G-effects begin.",
    min: 0,
    max: 40,
    step: 0.01,
  },
]

const verticalMotionFields = [
  {
    key: "gForceZ",
    label: "Normal Force Strength",
    description: "Head movement caused by loops, crests, and landing impacts.",
    min: 0,
    max: 5,
    step: 0.1,
  },
  {
    key: "gForceZThreshold",
    label: "Normal Force Threshold",
    description: "Force required before vertical G-effects begin.",
    min: 0,
    max: 40,
    step: 0.01,
  },
]

const lateralMotionFields = [
  {
    key: "gForceSideYaw",
    label: "Impact Yaw Strength",
    description: "Head yaw caused by sudden lateral forces and side impacts.",
    min: 0,
    max: 5,
    step: 0.1,
  },
  {
    key: "gForceSideRoll",
    label: "Impact Roll Strength",
    description: "Head roll caused by sudden lateral forces and side impacts.",
    min: 0,
    max: 5,
    step: 0.1,
  },
  {
    key: "gForceXThreshold",
    label: "Impact Force Threshold",
    description: "Force required before impact yaw and roll effects begin.",
    min: 0,
    max: 100,
    step: 0.01,
  },
  {
    key: "gForceSideLeanRoll",
    label: "Lean-In Roll Strength",
    description: "Sustained head roll in the direction of the lateral force.",
    min: 0,
    max: 5,
    step: 0.1,
  },
  {
    key: "gForceSideLeanRollSmoothness",
    label: "Lean-In Roll Smoothness",
    description: "How gradually the camera enters and exits the lean.",
    min: 0,
    max: 100,
    step: 1,
  },
  {
    key: "gForceSideLeanRollThreshold",
    label: "Lean-In Roll Force Threshold",
    description: "Force required before lean-in roll begins.",
    min: 0,
    max: 40,
    step: 0.01,
  },
]

const speedShakeFields = [
  {
    key: "speedShakeAmp",
    label: "Amplitude",
    description: "Strength of the speed shake effect.",
    min: 0,
    max: 10,
    step: 0.1,
  },
  {
    key: "speedShakeFreq",
    label: "Frequency",
    description: "Speed of the speed shake effect.",
    min: 0,
    max: 10,
    step: 0.1,
  },
  {
    key: "speedShakeDetail",
    label: "Detail",
    description: "Perlin-noise detail used by the speed shake effect.",
    min: 1,
    max: 10,
    step: 1,
  },
  {
    key: "speedShakeMinSpeed",
    label: "Minimum Speed",
    description: "Speed where the shake effect begins.",
    min: 0,
    max: 400,
    step: 1,
    speed: true,
  },
  {
    key: "speedShakeMaxSpeed",
    label: "Maximum Speed",
    description: "Speed where the shake effect reaches full intensity.",
    min: 0,
    max: 400,
    step: 1,
    speed: true,
  },
]

const driftShakeFields = [
  {
    key: "driftShakeAmp",
    label: "Amplitude",
    description: "Strength of the drift shake effect.",
    min: 0,
    max: 10,
    step: 0.1,
  },
  {
    key: "driftShakeFreq",
    label: "Frequency",
    description: "Speed of the drift shake effect.",
    min: 0,
    max: 10,
    step: 0.1,
  },
  {
    key: "driftShakeDetail",
    label: "Detail",
    description: "Perlin-noise detail used by the drift shake effect.",
    min: 1,
    max: 10,
    step: 1,
  },
]

const fovFields = [
  {
    key: "fovMinSpeed",
    label: "Minimum FOV Speed",
    description: "Speed where dynamic FOV begins.",
    min: 0,
    max: 400,
    step: 1,
    speed: true,
  },
  {
    key: "fovMaxSpeed",
    label: "Maximum FOV Speed",
    description: "Speed where dynamic FOV reaches its maximum.",
    min: 0,
    max: 400,
    step: 1,
    speed: true,
  },
  {
    key: "fovAddDegrees",
    label: "FOV Increase",
    description: "Maximum field-of-view increase at speed.",
    min: 0,
    max: 50,
    step: 1,
    unit: "°",
  },
  {
    key: "fovSmoothRate",
    label: "FOV Smoothing",
    description: "Smoothing applied while the dynamic FOV changes.",
    min: 0,
    max: 100,
    step: 1,
  },
]

const steeringLookAheadFields = [
  {
    key: "steeringLookAheadAngle",
    label: "Steering Tracking Angle",
    description: "Maximum camera yaw applied at full steering input.",
    min: 0,
    max: 60,
    step: 1,
    unit: "°",
  },
  {
    key: "steeringLookAheadSmoothness",
    label: "Steering Tracking Smoothness",
    description: "How gradually the camera follows changes in steering input.",
    min: 0,
    max: 100,
    step: 1,
    unit: "%",
  },
]

const otherFields = [
  {
    key: "pitchSmoothing",
    label: "Pitch Smoothing",
    description: "Smoothing of pitch movement caused by bumps.",
    min: 0,
    max: 1,
    step: 0.01,
  },
  {
    key: "rollSmoothing",
    label: "Roll Smoothing",
    description: "Smoothing of roll movement caused by bumps.",
    min: 0,
    max: 1,
    step: 0.01,
  },
  {
    key: "lockPitchToHorizon",
    label: "Lock Pitch to Horizon",
    description: "Keeps camera pitch aligned with the horizon; useful in VR.",
    min: 0,
    max: 1,
    step: 0.01,
  },
  {
    key: "lockRollToHorizon",
    label: "Lock Roll to Horizon",
    description: "Keeps camera roll aligned with the horizon; useful in VR.",
    min: 0,
    max: 1,
    step: 0.01,
  },
]

const gameSettings = useSettings()
const route = useRoute()
const loading = ref(true)
const loadError = ref("")
const saveError = ref("")
const saveStatus = ref("")
const activeTab = ref(0)
const chosenPreset = ref("Default")
const presetName = ref("")
const presets = reactive({})
const activeValues = reactive({})

let defaults = null
let saveQueue = Promise.resolve()
let saveGeneration = 0
let simulationPauseQueue = Promise.resolve()

async function setSimulationPaused(paused) {
  try {
    const simTimeAuthority = lua?.simTimeAuthority
    if (typeof simTimeAuthority?.pause !== "function") {
      throw new Error("simTimeAuthority.pause is unavailable")
    }

    await simTimeAuthority.pause(paused)
  } catch (error) {
    console.warn(
      `[Enhanced Interior Camera] Could not ${paused ? "pause" : "unpause"} the simulation.`,
      error
    )
  }
}

function queueSimulationPause(paused) {
  simulationPauseQueue = simulationPauseQueue.then(() => setSimulationPaused(paused))
}

function shouldPauseForRoute(routeName) {
  if (typeof routeName !== "string") return false
  if (UNPAUSED_PAUSE_ROUTES.has(routeName)) return false
  if (routeName === "pause.replay" || routeName.startsWith("pause.replay.")) return false
  if (routeName === "pause.photomode" || routeName.startsWith("pause.photomode.")) return false
  return routeName === "pause" || routeName.startsWith("pause.")
}

onMounted(() => {
  queueSimulationPause(false)
})

onBeforeUnmount(() => {
  if (shouldPauseForRoute(route.name)) {
    queueSimulationPause(true)
  }
})

const speedUnit = computed(() => {
  if (gameSettings.values.uiUnitLength === "imperial") {
    return { label: "mph", multiplier: 2.23694 }
  }
  return { label: "km/h", multiplier: 3.6 }
})

const presetItems = computed(() =>
  Object.keys(presets)
    .sort((a, b) => {
      const aOrder = PRESET_ORDER.get(a) ?? Number.MAX_SAFE_INTEGER
      const bOrder = PRESET_ORDER.get(b) ?? Number.MAX_SAFE_INTEGER
      return aOrder - bOrder || a.localeCompare(b)
    })
    .map(name => ({ label: name, value: name }))
)

const canDeletePreset = computed(
  () => chosenPreset.value === CUSTOM_PRESET || !DEFAULT_PRESETS.includes(chosenPreset.value)
)

const normalizedPresetName = computed(() => presetName.value.trim())
const presetNameError = computed(() => {
  const name = normalizedPresetName.value
  if (!name) return ""
  if (DEFAULT_PRESETS.includes(name) || name === CUSTOM_PRESET) {
    return "That name is reserved."
  }
  if (Object.prototype.hasOwnProperty.call(presets, name)) {
    return "A preset with that name already exists."
  }
  return ""
})
const canCreatePreset = computed(
  () =>
    chosenPreset.value === CUSTOM_PRESET &&
    normalizedPresetName.value.length > 0 &&
    !presetNameError.value
)

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

function replaceReactive(target, source) {
  for (const key of Object.keys(target)) delete target[key]
  Object.assign(target, source)
}

function normalizeStoredSettings(value) {
  if (!value) return null
  if (typeof value === "string") {
    try {
      return JSON.parse(value)
    } catch {
      return null
    }
  }
  return typeof value === "object" ? value : null
}

function normalizedPreset(value) {
  return {
    ...defaults.presets.Default,
    ...(value && typeof value === "object" ? value : {}),
  }
}

function loadActivePreset(name) {
  const resolvedName = Object.prototype.hasOwnProperty.call(presets, name) ? name : "Default"
  const normalizedValues = normalizedPreset(presets[resolvedName])
  chosenPreset.value = resolvedName
  replaceReactive(activeValues, normalizedValues)
}

function selectPreset(name) {
  if (!Object.prototype.hasOwnProperty.call(presets, name)) return
  presetName.value = ""
  loadActivePreset(name)
  queueSave()
}

function displayValue(field) {
  const value = Number(activeValues[field.key])
  if (!Number.isFinite(value)) return 0
  return field.speed ? Math.round(value * speedUnit.value.multiplier) : value
}

function toStoredValue(field, value) {
  const number = Number(value)
  if (!Number.isFinite(number)) return 0
  return field.speed ? number / speedUnit.value.multiplier : number
}

function updateSetting(field, value) {
  if (chosenPreset.value !== CUSTOM_PRESET) {
    presets[CUSTOM_PRESET] = clone(activeValues)
    chosenPreset.value = CUSTOM_PRESET
    presetName.value = ""
  }

  activeValues[field.key] = toStoredValue(field, value)

  if (field.key === "speedShakeMinSpeed") {
    activeValues.speedShakeMaxSpeed = Math.max(
      activeValues.speedShakeMinSpeed,
      activeValues.speedShakeMaxSpeed
    )
  } else if (field.key === "speedShakeMaxSpeed") {
    activeValues.speedShakeMinSpeed = Math.min(
      activeValues.speedShakeMinSpeed,
      activeValues.speedShakeMaxSpeed
    )
  } else if (field.key === "fovMinSpeed") {
    activeValues.fovMaxSpeed = Math.max(activeValues.fovMinSpeed, activeValues.fovMaxSpeed)
  } else if (field.key === "fovMaxSpeed") {
    activeValues.fovMinSpeed = Math.min(activeValues.fovMinSpeed, activeValues.fovMaxSpeed)
  }

  presets[CUSTOM_PRESET] = clone(activeValues)
  queueSave()
}

function updateBooleanSetting(key, value) {
  if (chosenPreset.value !== CUSTOM_PRESET) {
    presets[CUSTOM_PRESET] = clone(activeValues)
    chosenPreset.value = CUSTOM_PRESET
    presetName.value = ""
  }

  activeValues[key] = value === true
  presets[CUSTOM_PRESET] = clone(activeValues)
  queueSave()
}

function createPreset() {
  if (!canCreatePreset.value) return
  const name = normalizedPresetName.value
  presets[name] = clone(activeValues)
  delete presets[CUSTOM_PRESET]
  chosenPreset.value = name
  presetName.value = ""
  queueSave()
}

function deletePreset() {
  if (!canDeletePreset.value) return
  delete presets[chosenPreset.value]
  presetName.value = ""
  loadActivePreset("Default")
  queueSave()
}

function settingsSnapshot() {
  const customPresets = {}
  for (const [name, value] of Object.entries(presets)) {
    if (!DEFAULT_PRESETS.includes(name)) customPresets[name] = clone(value)
  }
  return {
    chosenPreset: chosenPreset.value,
    presets: customPresets,
  }
}

function queueSave() {
  const snapshot = settingsSnapshot()
  const generation = ++saveGeneration
  saveError.value = ""
  saveStatus.value = "Saving…"

  saveQueue = saveQueue
    .catch(() => undefined)
    .then(() => gameSettings.waitForData())
    .then(() => gameSettings.apply({ edcSettings: snapshot }))
    .then(() => {
      if (generation === saveGeneration) saveStatus.value = "Saved"
    })
    .catch(error => {
      if (generation === saveGeneration) {
        saveStatus.value = ""
        saveError.value = `Could not save: ${error?.message || error}`
      }
    })
}

async function loadSettings() {
  try {
    defaults = clone(await runRaw(`jsonReadFile('${DEFAULT_SETTINGS_PATH}')`))
    if (!defaults?.presets?.Default) {
      throw new Error("The Enhanced Interior Camera default settings are invalid")
    }

    await gameSettings.waitForData()
    const stored = normalizeStoredSettings(gameSettings.getValue("edcSettings"))

    replaceReactive(presets, clone(defaults.presets))
    if (stored?.presets && typeof stored.presets === "object") {
      for (const [name, value] of Object.entries(stored.presets)) {
        if (!DEFAULT_PRESETS.includes(name)) presets[name] = normalizedPreset(value)
      }
    }

    const initialPreset =
      stored?.chosenPreset && Object.prototype.hasOwnProperty.call(presets, stored.chosenPreset)
        ? stored.chosenPreset
        : defaults.chosenPreset || "Default"
    loadActivePreset(initialPreset)
  } catch (error) {
    loadError.value = `Unable to load Enhanced Interior Camera settings: ${
      error?.message || error
    }`
  } finally {
    loading.value = false
  }
}

void loadSettings()
</script>

<style scoped lang="scss">
.eic-settings {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  min-height: 0;
  gap: 0.75rem;
  color: var(--bng-off-white);
}

.eic-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1rem;
  padding: 0.25rem 0.3rem;

  h2 {
    margin: 0;
    font-size: 1.45rem;
  }

  p {
    margin: 0.15rem 0 0;
    color: rgba(var(--bng-off-white-rgb), 0.72);
  }
}

.save-status {
  flex: 0 0 auto;
  min-height: 1.25rem;
  color: rgba(var(--bng-off-white-rgb), 0.7);
  font-size: 0.85rem;

  &.error {
    color: var(--bng-add-red-300);
  }
}

.state-message {
  display: flex;
  flex: 1 1 auto;
  align-items: center;
  justify-content: center;
  padding: 2rem;
  text-align: center;

  &.error {
    color: var(--bng-add-red-300);
  }
}

.preset-toolbar {
  display: flex;
  align-items: flex-end;
  gap: 0.75rem;
  padding: 0.7rem 0.8rem;
  border-radius: var(--bng-corners-1);
  background: rgba(var(--bng-cool-gray-700-rgb), 0.42);
}

.preset-picker {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  gap: 0.25rem;
  min-width: 12rem;

  > span {
    color: rgba(var(--bng-off-white-rgb), 0.72);
    font-size: 0.8rem;
    font-weight: 600;
    text-transform: uppercase;
  }
}

.settings-tabs {
  --bng-tabs-content-overflow: auto;
  flex: 1 1 auto;
  min-height: 0;
}

.settings-panel {
  display: flex;
  flex-direction: column;
  gap: 0.5rem;
  max-width: 100%;
  overflow-x: hidden;
  padding: 0.8rem;

  h3 {
    margin: 0.3rem 0 0.1rem;
    padding-bottom: 0.25rem;
    border-bottom: 0.1rem solid rgba(var(--bng-orange-500-rgb), 0.75);
    color: var(--bng-off-white);
    font-size: 1.05rem;
  }
}

.settings-notice {
  display: flex;
  align-items: flex-start;
  gap: 0.65rem;
  padding: 0.7rem 0.8rem;
  border: 1px solid var(--bng-orange-500);
  border-radius: var(--bng-corners-1);
  background: rgba(var(--bng-orange-500-rgb), 0.12);
  line-height: 1.3;

  > .settings-notice-icon {
    flex: 0 0 auto;
    color: var(--bng-orange-500);
    font-size: 1.4rem;
  }

  > div {
    display: flex;
    flex-direction: column;
    gap: 0.15rem;
  }

  strong {
    font-weight: 700;
  }

  span {
    color: rgba(var(--bng-off-white-rgb), 0.82);
    font-size: 0.86rem;
  }
}

.setting-switch {
  display: grid;
  grid-template-columns: minmax(0, 1fr) auto;
  align-items: center;
  gap: 0.75rem;
  padding: 0.65rem 0.8rem;
  border-radius: var(--bng-corners-1);
  background: rgba(var(--bng-cool-gray-700-rgb), 0.26);
}

.setting-switch-copy {
  min-width: 0;
}

.setting-switch-label {
  color: var(--bng-off-white);
  font-size: 1rem;
  font-weight: 600;
}

.setting-switch-description {
  margin-top: 0.15rem;
  color: rgba(var(--bng-off-white-rgb), 0.68);
  font-size: 0.82rem;
  line-height: 1.25;
}

.setting-switch-control {
  flex: 0 0 auto;
}

.create-preset {
  display: grid;
  grid-template-columns: minmax(12rem, 1fr) auto;
  align-items: center;
  gap: 0.5rem;
  padding: 0.65rem 0.8rem;
  border-radius: var(--bng-corners-1);
  background: rgba(var(--bng-cool-gray-700-rgb), 0.42);
}

.preset-name {
  min-width: 0;
}

.preset-name-error {
  grid-column: 1 / -1;
  color: var(--bng-add-red-300);
  font-size: 0.8rem;
}

@media (max-width: 58rem) {
  .eic-header,
  .preset-toolbar {
    align-items: stretch;
    flex-direction: column;
  }

  .create-preset {
    grid-template-columns: 1fr;
  }

  .preset-name-error {
    grid-column: 1;
  }
}
</style>
