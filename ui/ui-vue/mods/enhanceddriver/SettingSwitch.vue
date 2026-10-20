<template>
  <BngRow class="setting-row">
    <template #label>
      <div class="setting-copy">
        <div class="setting-label">{{ label }}</div>
        <div class="setting-description">{{ description }}</div>
      </div>
    </template>

    <!-- Inside a BngRow the switch registers itself with the row and suppresses
         its own navigation: the row owns controller focus and OK/A toggles it. -->
    <BngSwitch
      :model-value="modelValue"
      :aria-label="label"
      @update:model-value="value => emit('update:modelValue', value)"
    />
  </BngRow>
</template>

<script setup>
import { BngRow, BngSwitch } from "@/common/components/base"

defineProps({
  modelValue: {
    type: Boolean,
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
})

const emit = defineEmits(["update:modelValue"])
</script>

<style scoped lang="scss">
.setting-row {
  --bng-row-breakpoint: 38%;
  // Match core settings toggles (OptionsCheckbox uses 1.1em; BngSwitch's
  // inline default is a much smaller 0.75em). Set on the row root and let it
  // inherit to the SwitchToggle, instead of depending on the toggle's
  // internal class name.
  --bng-switch-toggle-size: 1.1em;
  --bng-switch-toggle-radius: 2em;
  --bng-switch-toggle-knob-radius: 50%;
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
</style>
