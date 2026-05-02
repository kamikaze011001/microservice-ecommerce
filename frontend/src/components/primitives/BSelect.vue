<script setup lang="ts">
import {
  SelectRoot,
  SelectTrigger,
  SelectValue,
  SelectIcon,
  SelectPortal,
  SelectContent,
  SelectViewport,
  SelectItem,
  SelectItemText,
  SelectItemIndicator,
} from 'reka-ui';

export interface BSelectOption {
  value: string;
  label: string;
}

interface Props {
  modelValue: string;
  options: BSelectOption[];
  placeholder?: string;
  error?: string;
  disabled?: boolean;
}
const props = withDefaults(defineProps<Props>(), { disabled: false });
defineEmits<{ 'update:modelValue': [value: string] }>();
</script>

<template>
  <SelectRoot
    :model-value="props.modelValue"
    :disabled="props.disabled"
    @update:model-value="$emit('update:modelValue', String($event ?? ''))"
  >
    <SelectTrigger :class="['b-select__trigger', { 'has-error': !!props.error }]">
      <SelectValue :placeholder="props.placeholder ?? ''" />
      <SelectIcon class="b-select__chev">▾</SelectIcon>
    </SelectTrigger>
    <SelectPortal>
      <SelectContent class="b-select__content" position="popper" side="bottom" align="start">
        <SelectViewport class="b-select__viewport">
          <SelectItem
            v-for="opt in props.options"
            :key="opt.value"
            :value="opt.value"
            class="b-select__item"
          >
            <SelectItemText>{{ opt.label }}</SelectItemText>
            <SelectItemIndicator class="b-select__check">✓</SelectItemIndicator>
          </SelectItem>
        </SelectViewport>
      </SelectContent>
    </SelectPortal>
  </SelectRoot>
</template>

<style scoped>
.b-select__trigger {
  display: inline-flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-3);
  min-width: 14rem;
  padding: var(--space-3) var(--space-4);
  border: var(--border-thick);
  background: var(--paper);
  font-family: var(--font-body);
  color: var(--ink);
  box-shadow: var(--shadow-md);
  cursor: pointer;
}
.b-select__trigger.has-error {
  border-color: var(--stamp-red);
}
.b-select__chev {
  font-family: var(--font-mono);
}

.b-select__content {
  background: var(--paper);
  border: var(--border-thick);
  box-shadow: var(--shadow-lg);
  z-index: 60;
  min-width: var(--reka-select-trigger-width);
}
.b-select__viewport {
  padding: var(--space-1);
}
.b-select__item {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-3);
  padding: var(--space-2) var(--space-4);
  cursor: pointer;
  outline: none;
  user-select: none;
}
.b-select__item[data-highlighted] {
  background: var(--spot);
  color: var(--ink);
}
.b-select__check {
  font-family: var(--font-mono);
}
</style>
