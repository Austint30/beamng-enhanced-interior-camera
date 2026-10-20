<template>
  <BngRow class="setting-row">
    <template #label>
      <div class="setting-copy">
        <div class="setting-label">{{ label }}</div>
        <div class="setting-description">{{ description }}</div>
      </div>
    </template>

    <!-- Inside a BngRow the slider registers itself with the row: the row owns
         controller focus, OK opens/commits, and left/right step the value. -->
    <BngSlider
      class="setting-control"
      :model-value="modelValue"
      :min="min"
      :max="max"
      :step="step"
      :input-step="step"
      :unit="unit"
      :debounce="100"
      with-input
      @update:model-value="value => emit('update:modelValue', value)"
    />
  </BngRow>
</template>

<script setup>
import { BngRow, BngSlider } from "@/common/components/base"

defineProps({
  modelValue: {
    type: Number,
    required: true,
  },
  label: {
    type: String,
    required: true,
  },
  description: {
    type: String,
    required: true,
  },
  min: {
    type: Number,
    required: true,
  },
  max: {
    type: Number,
    required: true,
  },
  step: {
    type: Number,
    required: true,
  },
  unit: {
    type: String,
    default: "",
  },
})

const emit = defineEmits(["update:modelValue"])
</script>

<style scoped lang="scss">
// Compact row: smaller type + label/control column split close to the
// arcadeOrbit layout. BngRow owns focus and control sizing.
.setting-row {
  --bng-row-breakpoint: 38%;
}

.setting-copy {
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.setting-label {
  color: var(--bng-off-white);
  font-size: 0.95rem;
  font-weight: 600;
}

.setting-description {
  margin-top: 0.1rem;
  color: rgba(var(--bng-off-white-rgb), 0.68);
  font-size: 0.78rem;
  line-height: 1.25;
}

.setting-control {
  width: 100%;
  min-width: 0;
  max-width: 26em;
}
</style>
