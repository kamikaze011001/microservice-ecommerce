<script setup lang="ts">
import { ref } from 'vue';
import BButton from './BButton.vue';

interface Props {
  accept?: string;
  loading?: boolean;
  disabled?: boolean;
  variant?: 'spot' | 'ink' | 'ghost' | 'danger';
  /** Accessible name for the visually-hidden file input. */
  inputAriaLabel?: string;
}
const props = withDefaults(defineProps<Props>(), {
  accept: undefined,
  loading: false,
  disabled: false,
  variant: 'spot',
  inputAriaLabel: 'Upload file',
});

const emit = defineEmits<{ (e: 'select', file: File): void }>();

const inputRef = ref<HTMLInputElement | null>(null);

function trigger() {
  inputRef.value?.click();
}

function onChange(e: Event) {
  const file = (e.target as HTMLInputElement).files?.[0];
  // Reset immediately so picking the SAME file again still fires `change`.
  // The File reference is already captured above, so this is safe.
  if (inputRef.value) inputRef.value.value = '';
  if (file) emit('select', file);
}
</script>

<template>
  <span class="b-file-button">
    <input
      ref="inputRef"
      type="file"
      :accept="props.accept"
      class="b-file-button__input"
      tabindex="-1"
      :aria-label="props.inputAriaLabel"
      @change="onChange"
    />
    <BButton
      :variant="props.variant"
      :loading="props.loading"
      :disabled="props.disabled"
      @click="trigger"
    >
      <slot />
    </BButton>
  </span>
</template>

<style scoped>
.b-file-button__input {
  position: absolute;
  width: 1px;
  height: 1px;
  opacity: 0;
  pointer-events: none;
}
</style>
