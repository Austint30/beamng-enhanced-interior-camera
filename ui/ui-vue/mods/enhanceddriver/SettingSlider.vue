<template>
  <div class="setting-slider">
    <div class="setting-copy">
      <div class="setting-label">{{ label }}</div>
      <div class="setting-description">{{ description }}</div>
    </div>

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
  </div>
</template>

<script setup>
import { BngSlider } from "@/common/components/base"

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
.setting-slider {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  align-items: stretch;
  gap: 0.45rem;
  padding: 0.65rem 0.8rem;
  border-radius: var(--bng-corners-1);
  background: rgba(var(--bng-cool-gray-700-rgb), 0.26);
}

.setting-copy {
  min-width: 0;
}

.setting-label {
  color: var(--bng-off-white);
  font-size: 1rem;
  font-weight: 600;
}

.setting-description {
  margin-top: 0.15rem;
  color: rgba(var(--bng-off-white-rgb), 0.68);
  font-size: 0.82rem;
  line-height: 1.25;
}

.setting-control {
  min-width: 0;
  width: 100%;
  max-width: 100%;
  flex: 1 1 auto;
}
</style>
