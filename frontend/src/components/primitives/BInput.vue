<script setup lang="ts">
import { computed, useId } from 'vue';

interface Props {
  modelValue: string;
  type?: string;
  label?: string;
  error?: string;
  id?: string;
  placeholder?: string;
  disabled?: boolean;
}
const props = withDefaults(defineProps<Props>(), {
  type: 'text',
  disabled: false,
});

const emit = defineEmits<{
  'update:modelValue': [value: string];
  blur: [event: FocusEvent];
}>();

const autoId = useId();
const inputId = computed(() => props.id ?? `b-input-${autoId}`);

function onInput(e: Event) {
  emit('update:modelValue', (e.target as HTMLInputElement).value);
}
</script>

<template>
  <div :class="['b-input', { 'has-error': !!props.error }]">
    <label v-if="props.label" :for="inputId" class="b-input__label">{{ props.label }}</label>
    <input
      :id="inputId"
      :type="props.type"
      :value="props.modelValue"
      :placeholder="props.placeholder"
      :disabled="props.disabled"
      :aria-invalid="!!props.error || undefined"
      :aria-describedby="props.error ? `${inputId}-err` : undefined"
      class="b-input__control"
      @input="onInput"
      @blur="emit('blur', $event)"
    />
    <p v-if="props.error" :id="`${inputId}-err`" class="b-input__error" role="alert">
      {{ props.error }}
    </p>
  </div>
</template>

<style scoped>
.b-input {
  display: flex;
  flex-direction: column;
  gap: var(--space-2);
}
.b-input__label {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.b-input__control {
  border: var(--border-thick);
  background: var(--paper);
  padding: var(--space-3);
  font-family: var(--font-body);
  font-size: var(--type-body);
  color: var(--ink);
  transition:
    transform var(--transition-snap),
    outline-color var(--transition-snap);
}
.b-input__control:focus {
  outline: 2px solid var(--spot);
  outline-offset: 2px;
  transform: translate(2px, 0);
}
.b-input.has-error .b-input__control {
  border-color: var(--stamp-red);
}
.b-input__error {
  color: var(--stamp-red);
  font-family: var(--font-mono);
  font-size: var(--type-mono);
}
</style>
