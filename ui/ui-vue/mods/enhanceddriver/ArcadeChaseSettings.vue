<template>
  <section class="aoc-settings">
    <header class="aoc-header">
      <div>
        <h2>Arcade Chase Camera</h2>
        <p>Configure camera motion, shake, acceleration response, and smoothing.</p>
      </div>
      <span class="save-status" :class="{ error: saveError }">
        {{ saveError || saveStatus }}
      </span>
    </header>

    <div v-if="loading" class="state-message">Loading settings…</div>
    <div v-else-if="loadError" class="state-message error">{{ loadError }}</div>

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

      <div class="aoc-body">
        <nav class="aoc-nav" aria-label="Settings sections">
          <BngButton
            v-for="(section, index) in SECTIONS"
            :key="section.id"
            class="aoc-nav-btn"
            :class="{ 'aoc-nav-btn--active': activeSection === index }"
            @click="activeSection = index"
          >
            {{ section.label }}
          </BngButton>
        </nav>

        <div class="aoc-panel">
          <template v-for="(group, groupIndex) in SECTIONS[activeSection].groups" :key="groupIndex">
            <h3 v-if="group.title">{{ group.title }}</h3>
            <p v-if="group.hint" class="settings-hint">{{ group.hint }}</p>
            <SettingSlider
              v-for="f in group.sliders"
              :key="f.key"
              v-bind="f"
              :min="displayMin(f)"
              :max="displayMax(f)"
              :step="displayStep(f)"
              :model-value="displayValue(f)"
              :unit="f.speed ? speedUnit.label : (f.unit || '')"
              @update:model-value="v => updateSetting(f, v)"
            />
          </template>
        </div>
      </div>

      <div v-if="chosenPreset === CUSTOM_PRESET" class="create-preset">
        <BngInput
          v-model="presetName"
          class="preset-name"
          placeholder="New preset name"
          :maxlength="48"
          @keyup.enter="createPreset"
        />
        <BngButton :accent="ACCENTS.main" :disabled="!canCreatePreset" @click="createPreset">
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
  BngInput,
} from "@/common/components/base"
import { lua } from "@/bridge"
import { runRaw } from "@/bridge/libs/Lua.js"
import { useSettings } from "@/services/settings"
import SettingSlider from "./ArcadeChaseSettingSlider.vue"

const DEFAULTS_PATH = "/lua/ge/extensions/core/arcadeOrbit/arcadeOrbitDefaults.json"
const SETTINGS_PATH = "/arcadeOrbitSettings.json"
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

// --- Field definitions ---

const cameraFields = [
  { key: "screenFill", label: "Screen Fill", description: "How much of the screen height the vehicle occupies. Higher = closer camera.", min: 20, max: 90, step: 1, unit: "%" },
  { key: "fov", label: "Field of View", description: "Base field of view angle.", min: 40, max: 120, step: 1, unit: "°" },
  { key: "basePitch", label: "Base Pitch", description: "Constant look-down angle.", min: -30, max: 45, step: 1, unit: "°" },
  { key: "targetHeight", label: "Target Height", description: "Aim point height above the roof. Positive = above.", min: -1, max: 2, step: 0.05, unit: "m" },
]

const velocityAimFields = [
  { key: "velocityAim_scale", label: "Aim Offset", description: "Drift aim offset in metres per radian of drift angle.", min: 0, max: 3, step: 0.1, unit: "m" },
  { key: "velocityAim_minSpeed", label: "Min Speed", description: "Speed where the aim effect begins.", min: 0, max: 100, step: 0.5, speed: true },
  { key: "velocityAim_maxSpeed", label: "Max Speed", description: "Speed where the aim effect is fully active.", min: 0, max: 100, step: 1, speed: true },
]

const speedShakeFields = [
  { key: "speedShake_yawAmp", label: "Yaw Amplitude", description: "Horizontal shake strength.", min: 0, max: 3, step: 0.05 },
  { key: "speedShake_pitchAmp", label: "Pitch Amplitude", description: "Vertical shake strength.", min: 0, max: 3, step: 0.05 },
  { key: "speedShake_rollAmp", label: "Roll Amplitude", description: "Roll shake strength (0 = off).", min: 0, max: 3, step: 0.05 },
  { key: "speedShake_freq", label: "Frequency", description: "Shake oscillation speed multiplier.", min: 0.1, max: 2, step: 0.05 },
  { key: "speedShake_octaves", label: "Detail (Octaves)", description: "Perlin-noise octaves. More = finer detail.", min: 1, max: 6, step: 1 },
  { key: "speedShake_minSpeed", label: "Min Speed", description: "Speed where shake begins.", min: 0, max: 100, step: 0.5, speed: true },
  { key: "speedShake_maxSpeed", label: "Max Speed", description: "Speed where shake reaches full intensity.", min: 0, max: 100, step: 1, speed: true },
  { key: "speedShake_maxStrength", label: "Max Strength", description: "Overall shake intensity multiplier.", min: 0, max: 15, step: 0.5 },
]

const driftShakeFields = [
  { key: "driftShake_yawAmp", label: "Yaw Amplitude", description: "Horizontal shake strength while drifting (degrees).", min: 0, max: 3, step: 0.05 },
  { key: "driftShake_pitchAmp", label: "Pitch Amplitude", description: "Vertical shake strength while drifting (degrees).", min: 0, max: 3, step: 0.05 },
  { key: "driftShake_rollAmp", label: "Roll Amplitude", description: "Roll shake strength while drifting (0 = off).", min: 0, max: 3, step: 0.05 },
  { key: "driftShake_freq", label: "Frequency", description: "Shake oscillation speed multiplier.", min: 0.1, max: 2, step: 0.05 },
  { key: "driftShake_octaves", label: "Detail (Octaves)", description: "Perlin-noise octaves. More = finer detail.", min: 1, max: 6, step: 1 },
  { key: "driftShake_minAngle", label: "Min Angle", description: "Minimum drift angle needed for the shake to start; it ramps from here to Max Angle.", min: 0, max: 85, step: 1, unit: "°" },
  { key: "driftShake_maxAngle", label: "Max Angle", description: "Slip angle where the shake is at full strength; identical for a forward or a reverse drift.", min: 5, max: 90, step: 1, unit: "°" },
  { key: "driftShake_maxSpeed", label: "Max Speed", description: "Speed where the shake is at full strength (fades in from 0).", min: 0, max: 100, step: 0.5, speed: true },
]

const speedDistanceFields = [
  { key: "speedDistance_maxDist", label: "Max Distance", description: "How far the camera pulls back at max speed (metres).", min: 0, max: 5, step: 0.1, unit: "m" },
  { key: "speedDistance_maxSpeed", label: "Max Speed", description: "Speed where the full distance offset is reached.", min: 0, max: 150, step: 1, speed: true },
  { key: "speedDistance_smoothness", label: "Smoothness", description: "Time constant for the distance response (seconds). Higher = smoother / lazier.", min: 0.05, max: 10, step: 0.05, unit: "s" },
  { key: "speedDistance_brakeDecel", label: "Brake Max Deceleration", description: "Deceleration where the brake cancellation reaches full strength (g).", min: 0.1, max: 5, step: 0.1, unit: "g" },
  { key: "speedDistance_brakeStrength", label: "Brake Cancellation", description: "How much of the speed distance is cancelled at max deceleration. Scales down from 0 while braking.", min: 0, max: 100, step: 5, unit: "%" },
]

const accelDistFields = [
  { key: "accelDistance_maxDist", label: "Max Distance Shift", description: "Maximum camera boom change under acceleration (metres).", min: 0, max: 2, step: 0.05, unit: "m" },
  { key: "accelDistance_smoothness", label: "Smoothness", description: "Response speed. Lower = snappier.", min: 200, max: 5000, step: 100 },
]

const accelRespFields = [
  { key: "accelResponse_gThreshold", label: "G-Threshold", description: "Dead zone around 1 g before the effect activates.", min: 0.01, max: 0.5, step: 0.01, unit: "g" },
  { key: "accelResponse_inputSmooth", label: "Input Smoothing", description: "Time constant for smoothing raw acceleration (seconds).", min: 0.02, max: 1, step: 0.02, unit: "s" },
  { key: "accelResponse_outputSmooth", label: "Output Smoothing", description: "Time constant for the camera offset response (seconds).", min: 0.1, max: 3, step: 0.1, unit: "s" },
  { key: "accelResponse_valleyStrength", label: "Valley Strength", description: "Effect strength going over a valley (>1 g up).", min: 0, max: 2, step: 0.05 },
  { key: "accelResponse_valleyMaxHeight", label: "Valley Max Height", description: "Maximum height drop in a valley (metres).", min: 0, max: 5, step: 0.1, unit: "m" },
  { key: "accelResponse_valleyMaxPitch", label: "Valley Max Pitch", description: "Maximum pitch-up in a valley.", min: 0, max: 1, step: 0.01, unit: "rad" },
  { key: "accelResponse_crestStrength", label: "Crest Strength", description: "Effect strength going over a crest (<1 g up).", min: 0, max: 2, step: 0.05 },
  { key: "accelResponse_crestMaxHeight", label: "Crest Max Height", description: "Maximum height rise on a crest (metres).", min: 0, max: 5, step: 0.1, unit: "m" },
  { key: "accelResponse_crestMaxPitch", label: "Crest Max Pitch", description: "Maximum pitch-down on a crest.", min: 0, max: 1, step: 0.01, unit: "rad" },
]

const brakePitchFields = [
  { key: "brakePitch_minG", label: "Min G-Force", description: "Minimum braking g-force before the effect starts; it ramps from here to Max G-Force.", min: 0, max: 4.5, step: 0.1, unit: "g" },
  { key: "brakePitch_maxG", label: "Max G-Force", description: "Braking g-force where the effect reaches full pitch (g).", min: 0.1, max: 5, step: 0.1, unit: "g" },
  { key: "brakePitch_maxOffset", label: "Max Target Offset", description: "How far the aim target moves down (in camera space) at full braking. The camera stays put and re-aims — closer camera = bigger pitch.", min: 0, max: 10, step: 0.5, unit: "m" },
  { key: "brakePitch_smoothness", label: "Smoothness", description: "Time constant for pitching down and back up (seconds). Higher = smoother / lazier.", min: 0.05, max: 2, step: 0.05, unit: "s" },
]

const decelJoltFields = [
  { key: "decelJolt_minJerk", label: "Min Jerk", description: "Change in deceleration (g/s) needed to trigger the jolt. Hard braking is ~5–10, impacts are far higher.", min: 0, max: 100, step: 5, unit: "g/s" },
  { key: "decelJolt_fullJerk", label: "Full Jerk", description: "Jerk (g/s) at which the animation blends in at 100 %; strength ramps from Min Jerk to here.", min: 1, max: 200, step: 5, unit: "g/s" },
  { key: "decelJolt_maxRotation", label: "Max Rotation", description: "How far the aim rotates down at a full-strength jolt before returning.", min: 0, max: 90, step: 1, unit: "°" },
  { key: "decelJolt_duration", label: "Duration", description: "Length of the down-and-back animation (seconds).", min: 0.2, max: 3, step: 0.1, unit: "s" },
  { key: "decelJolt_attack", label: "Attack", description: "Share of the duration spent darting to the max angle; the rest settles back.", min: 5, max: 95, step: 5, unit: "%" },
  { key: "decelJolt_wobble", label: "Wobble", description: "How far past baseline the camera swings on the first rebound (percent of the max angle). 0 = a smooth exponential return.", min: 0, max: 100, step: 5, unit: "%" },
  { key: "decelJolt_accelSmooth", label: "Accel Smoothing", description: "Time constant of the acceleration estimate used for jerk detection (seconds).", min: 0.05, max: 0.5, step: 0.01, unit: "s" },
  { key: "decelJolt_smooth", label: "Result Smoothing", description: "Temporal smoothing over the final jolt value (seconds). 0 = off (raw animation).", min: 0, max: 1, step: 0.05, unit: "s" },
]

const accelJoltFields = [
  { key: "accelJolt_minJerk", label: "Min Jerk", description: "Change in acceleration (g/s) needed to trigger the jolt — e.g. being hit from behind.", min: 0, max: 100, step: 5, unit: "g/s" },
  { key: "accelJolt_fullJerk", label: "Full Jerk", description: "Jerk (g/s) at which the animation blends in at 100 %; strength ramps from Min Jerk to here.", min: 1, max: 200, step: 5, unit: "g/s" },
  { key: "accelJolt_maxRotation", label: "Max Rotation", description: "How far the aim rotates up at a full-strength jolt before returning.", min: 0, max: 90, step: 1, unit: "°" },
  { key: "accelJolt_duration", label: "Duration", description: "Length of the up-and-back animation (seconds).", min: 0.2, max: 3, step: 0.1, unit: "s" },
  { key: "accelJolt_attack", label: "Attack", description: "Share of the duration spent darting to the max angle; the rest settles back.", min: 5, max: 95, step: 5, unit: "%" },
  { key: "accelJolt_wobble", label: "Wobble", description: "How far past baseline the camera swings on the first rebound (percent of the max angle). 0 = a smooth exponential return.", min: 0, max: 100, step: 5, unit: "%" },
  { key: "accelJolt_accelSmooth", label: "Accel Smoothing", description: "Time constant of the acceleration estimate used for jerk detection (seconds).", min: 0.05, max: 0.5, step: 0.01, unit: "s" },
  { key: "accelJolt_smooth", label: "Result Smoothing", description: "Temporal smoothing over the final jolt value (seconds). 0 = off (raw animation).", min: 0, max: 1, step: 0.05, unit: "s" },
]

const leanInRollFields = [
  { key: "leanInRoll_minG", label: "Min G-Force", description: "Minimum lateral g (in the camera's frame) before the roll starts.", min: 0, max: 5, step: 0.1, unit: "g" },
  { key: "leanInRoll_maxG", label: "Max G-Force", description: "Lateral g where the roll is at full strength (g).", min: 0.1, max: 10, step: 0.1, unit: "g" },
  { key: "leanInRoll_maxRoll", label: "Max Roll", description: "Maximum camera roll at full lateral g (degrees).", min: 0, max: 30, step: 0.5, unit: "°" },
  { key: "leanInRoll_smoothness", label: "Smoothness", description: "Time constant for the roll in and out (seconds). Higher = smoother / lazier.", min: 0.05, max: 2, step: 0.05, unit: "s" },
]

const followFields = [
  { key: "relaxation", label: "Follow vehicle direction", description: "How tightly the camera follows the vehicle's direction. Lower = tighter camera behavior.", min: 1, max: 10, step: 0.5 },
  { key: "followSmoothing_pitchSmooth", label: "Pitch Smoothness", description: "How lazily the camera boom's pitch follows the car (bumps, crests). Higher = smoother / slower response.", min: 0.1, max: 10, step: 0.1, unit: "s" },
]

const SECTIONS = [
  {
    id: "camera",
    label: "Camera",
    groups: [{ sliders: cameraFields }],
  },
  {
    id: "velocityAim",
    label: "Velocity Aim",
    groups: [{ sliders: velocityAimFields }],
  },
  {
    id: "speedShake",
    label: "Speed Shake",
    groups: [{ sliders: speedShakeFields }],
  },
  {
    id: "driftShake",
    label: "Drift Shake",
    groups: [{ sliders: driftShakeFields }],
  },
  {
    id: "acceleration",
    label: "Acceleration",
    groups: [
      {
        title: "Speed Distance",
        hint: "Smoothness is a time constant in seconds — higher = smoother / lazier response.",
        sliders: speedDistanceFields,
      },
      { title: "Distance Boost", sliders: accelDistFields },
      { title: "Crest / Valley Response", sliders: accelRespFields },
      {
        title: "Brake Pitch",
        hint: "Sustained braking: force is measured in the camera's frame (longitudinal decel vs the view direction, forward or reverse); the pitch is applied relative to the camera's view.",
        sliders: brakePitchFields,
      },
      {
        title: "Decel Jolt",
        hint: "Sudden deceleration (e.g. hitting something) — much higher g threshold than Brake Pitch, more intense pitch-down.",
        sliders: decelJoltFields,
      },
      {
        title: "Accel Jolt",
        hint: "Sudden acceleration (e.g. being hit from behind) — much higher g threshold, intense pitch-UP.",
        sliders: accelJoltFields,
      },
      {
        title: "Lean-In Roll",
        hint: "Sustained cornering: lateral g in the camera's frame (left/right in the view) rolls the camera around its aim axis, mirroring the body roll into the corner.",
        sliders: leanInRollFields,
      },
    ],
  },
  {
    id: "smoothing",
    label: "Smoothing",
    groups: [
      {
        title: "Follow Smoothing",
        hint: "Pitch Smoothness is a time constant in seconds — higher = smoother / lazier response.",
        sliders: followFields,
      },
    ],
  },
]

// --- State ---

const gameSettings = useSettings()
const route = useRoute()
const loading = ref(true)
const loadError = ref("")
const saveError = ref("")
const saveStatus = ref("")
const activeSection = ref(0)
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
    console.warn(`[ACC] Could not ${paused ? "pause" : "unpause"} the simulation.`, error)
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

const speedUnit = computed(() => {
  if (gameSettings.values.uiUnitLength === "imperial") {
    return { label: "mph", multiplier: 2.23694 }
  }
  return { label: "km/h", multiplier: 3.6 }
})

const presetItems = computed(() =>
  Object.keys(presets).map(name => ({ label: name, value: name }))
)

const canDeletePreset = computed(() => chosenPreset.value === CUSTOM_PRESET)

const normalizedPresetName = computed(() => presetName.value.trim())
const presetNameError = computed(() => {
  const name = normalizedPresetName.value
  if (!name) return ""
  if (Object.keys(presets).includes(name) && name !== CUSTOM_PRESET) {
    return "A preset with that name already exists."
  }
  return ""
})
const canCreatePreset = computed(
  () => chosenPreset.value === CUSTOM_PRESET && normalizedPresetName.value.length > 0 && !presetNameError.value
)

// --- Helpers ---

function clone(value) {
  return JSON.parse(JSON.stringify(value))
}

function replaceReactive(target, source) {
  for (const key of Object.keys(target)) delete target[key]
  Object.assign(target, source)
}

function normalizedPreset(value) {
  return {
    ...defaults.presets.Default,
    ...(value && typeof value === "object" ? value : {}),
  }
}

function loadActivePreset(name) {
  const resolvedName = Object.prototype.hasOwnProperty.call(presets, name) ? name : "Default"
  const normalized = normalizedPreset(presets[resolvedName])
  chosenPreset.value = resolvedName
  replaceReactive(activeValues, normalized)
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
  return field.speed ? Math.round(value * speedUnit.value.multiplier * 10) / 10 : value
}

function displayMin(field) {
  if (!field.speed) return field.min
  return Math.max(0, Math.round(field.min * speedUnit.value.multiplier * 10) / 10)
}

function displayMax(field) {
  if (!field.speed) return field.max
  return Math.round(field.max * speedUnit.value.multiplier * 10) / 10
}

function displayStep(field) {
  if (!field.speed) return field.step
  return Math.max(0.1, Math.round(field.step * speedUnit.value.multiplier * 10) / 10)
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

// --- Persistence (separate file, not BeamNG settings) ---

function settingsSnapshot() {
  const customPresets = {}
  for (const [name, value] of Object.entries(presets)) {
    if (name !== "Default" && name !== "Smooth" && name !== "Intense") {
      customPresets[name] = clone(value)
    }
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
    .then(async () => {
      const jsonStr = JSON.stringify(snapshot)
      await runRaw(`jsonWriteFile('${SETTINGS_PATH}', jsonDecode('${jsonStr.replace(/'/g, "\\'")}'))`)
      await runRaw("arcadeOrbitReloadSettings()")
    })
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
    defaults = clone(await runRaw(`jsonReadFile('${DEFAULTS_PATH}')`))
    if (!defaults?.presets?.Default) {
      throw new Error("Default settings file is invalid")
    }

    replaceReactive(presets, clone(defaults.presets))

    // Load user overrides from the settings file
    let userConfig = null
    try {
      userConfig = await runRaw(`jsonReadFile('${SETTINGS_PATH}')`)
    } catch {
      userConfig = null
    }

    if (userConfig?.presets && typeof userConfig.presets === "object") {
      for (const [name, value] of Object.entries(userConfig.presets)) {
        if (name !== "Default" && name !== "Smooth" && name !== "Intense") {
          presets[name] = normalizedPreset(value)
        }
      }
    }

    const initialPreset =
      userConfig?.chosenPreset && Object.prototype.hasOwnProperty.call(presets, userConfig.chosenPreset)
        ? userConfig.chosenPreset
        : defaults.chosenPreset || "Default"
    loadActivePreset(initialPreset)
  } catch (error) {
    loadError.value = `Unable to load settings: ${error?.message || error}`
  } finally {
    loading.value = false
  }
}

onMounted(() => {
  queueSimulationPause(false)
  void loadSettings()
})

onBeforeUnmount(() => {
  if (shouldPauseForRoute(route.name)) {
    queueSimulationPause(true)
  }
})
</script>

<style scoped lang="scss">
.aoc-settings {
  display: flex;
  flex: 1 1 auto;
  flex-direction: column;
  min-height: 0;
  gap: 0.75rem;
  color: var(--bng-off-white);
}

.aoc-header {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 1rem;
  padding: 1rem 1rem 0.25rem;

  h2 { margin: 0; font-size: 1.45rem; }
  p { margin: 0.15rem 0 0; color: rgba(var(--bng-off-white-rgb), 0.72); }
}

.save-status {
  flex: 0 0 auto;
  min-height: 1.25rem;
  color: rgba(var(--bng-off-white-rgb), 0.7);
  font-size: 0.85rem;

  &.error { color: var(--bng-add-red-300); }
}

.state-message {
  display: flex;
  flex: 1 1 auto;
  align-items: center;
  justify-content: center;
  padding: 2rem;
  text-align: center;

  &.error { color: var(--bng-add-red-300); }
}

.preset-toolbar {
  display: flex;
  align-items: flex-end;
  gap: 0.75rem;
  padding: 0.7rem 1rem;
  border-radius: var(--bng-corners-1);
  background: rgba(var(--bng-cool-gray-700-rgb), 0.42);

  .bng-button { margin: 0; }
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

  .bng-dropdown { margin: 0; }
}

.aoc-body {
  display: flex;
  flex: 1 1 auto;
  align-items: stretch;
  gap: 0.75rem;
  min-height: 0;
  padding: 0.25rem 1rem 0.5rem;
}

.aoc-nav {
  display: flex;
  flex-direction: column;
  flex: 0 0 auto;
  gap: 0.5rem;
  min-width: 8.75rem;
  max-width: 9.5rem;
}

.aoc-nav-btn {
  --bng-button-min-width: auto;
  --bng-button-max-width: 100%;
  --bng-button-margin: 0;
  --bng-button-padding: 0.5rem;
  --bng-button-padding-top: 0.4rem;
  --bng-button-padding-bottom: 0.4rem;

  --bng-bg-border-radius: var(--bng-corners-1);
  --bng-bg-border-width: 0.0625em;

  --bng-bg-enabled: var(--bng-cool-gray-750);
  --bng-bg-hover: var(--bng-cool-gray-700);
  --bng-bg-active: var(--bng-cool-gray-700);
  --bng-bg-disabled: var(--bng-cool-gray-700);
  --bng-bg-focus: var(--bng-cool-gray-700);

  --bng-bg-enabled-opacity: 0.60;
  --bng-bg-hover-opacity: 0.75;
  --bng-bg-active-opacity: 0.9;
  --bng-bg-disabled-opacity: 0.55;
  --bng-bg-focus-opacity: 0.85;

  --bng-bg-border-enabled: var(--bng-cool-gray-500);
  --bng-bg-border-hover: var(--bng-cool-gray-500);
  --bng-bg-border-active: var(--bng-cool-gray-500);
  --bng-bg-border-disabled: var(--bng-cool-gray-500);
  --bng-bg-border-focus: var(--bng-cool-gray-300);
}

.aoc-nav-btn--active {
  --bng-bg-enabled-opacity: 1;
  --bng-bg-hover-opacity: 1;
  --bng-bg-active-opacity: 1;
  --bng-bg-focus-opacity: 1;
  --bng-bg-image: linear-gradient(90deg, rgba(255, 102, 0, 0.35) 0%, rgba(255, 255, 255, 0) 100%);
}

.aoc-panel {
  display: flex;
  flex-direction: column;
  flex: 1 1 auto;
  gap: 0.5rem;
  min-width: 0;
  overflow-y: auto;
  padding: 0;

  h3 {
    margin: 0.3rem 0 0.1rem;
    padding-bottom: 0.25rem;
    border-bottom: 0.1rem solid rgba(var(--bng-orange-500-rgb), 0.75);
    color: var(--bng-off-white);
    font-size: 1.05rem;
  }
}

.settings-hint {
  margin: 0;
  font-size: 0.82rem;
  color: rgba(var(--bng-off-white-rgb), 0.65);
}

.create-preset {
  display: grid;
  grid-template-columns: minmax(12rem, 1fr) auto;
  align-items: center;
  gap: 0.5rem;
  padding: 0.65rem 1rem;
  border-radius: var(--bng-corners-1);
  background: rgba(var(--bng-cool-gray-700-rgb), 0.42);
}

.preset-name { min-width: 0; }

.preset-name-error {
  grid-column: 1 / -1;
  color: var(--bng-add-red-300);
  font-size: 0.8rem;
}

@media (max-width: 58rem) {
  .aoc-header, .preset-toolbar {
    align-items: stretch;
    flex-direction: column;
  }
  .create-preset { grid-template-columns: 1fr; }
  .preset-name-error { grid-column: 1; }
}
</style>

<style lang="scss">
// Pause-menu mod cards are hard-limited to 28em wide by the game layout.
// Widen the host card only when it contains this panel (must be global CSS:
// the component sits inside the card, and the mod-tab branch passes no width class).
// !important because the game's scoped rule out-specifies this one in this CEF build.
.pause-layout .menu-content-card-1:has(> .card-cnt > .pause-main-card > .aoc-settings) {
  width: clamp(34em, 38vw, 46em) !important;
}
</style>
