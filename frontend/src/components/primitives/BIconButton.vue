<script setup lang="ts">
interface Props {
  type?: 'button' | 'submit' | 'reset';
  disabled?: boolean;
}
const props = withDefaults(defineProps<Props>(), {
  type: 'button',
  disabled: false,
});
// Everything else (aria-label, aria-expanded, @click, class) falls through to
// the native <button> root via Vue's default attribute inheritance. Icon buttons
// have no text label, so the consumer MUST supply an accessible name via
// `aria-label` — pass it as a plain attribute and it lands on the button.
</script>

<template>
  <button :type="props.type" :disabled="props.disabled" class="b-icon-button">
    <slot />
  </button>
</template>

<style scoped>
.b-icon-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  background: transparent;
  border: 0;
  color: var(--ink);
  cursor: pointer;
}
.b-icon-button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
</style>
