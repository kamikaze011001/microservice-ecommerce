<script setup lang="ts">
interface Props {
  variant?: 'spot' | 'ink' | 'ghost' | 'danger';
  type?: 'button' | 'submit' | 'reset';
  disabled?: boolean;
  loading?: boolean;
}
const props = withDefaults(defineProps<Props>(), {
  variant: 'ink',
  type: 'button',
  disabled: false,
  loading: false,
});
</script>

<template>
  <button
    :type="props.type"
    :disabled="props.disabled || props.loading"
    :aria-busy="props.loading || undefined"
    :class="['b-button', `b-button--${props.variant}`, { 'is-loading': props.loading }]"
  >
    <span
      v-if="props.loading"
      class="b-button__spinner"
      data-testid="b-button-spinner"
      aria-hidden="true"
    />
    <span v-else class="b-button__label"><slot /></span>
  </button>
</template>

<style scoped>
.b-button {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: var(--space-2);
  padding: var(--space-3) var(--space-6);
  border: var(--border-thick);
  background: var(--paper);
  color: var(--ink);
  font-family: var(--font-display);
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  box-shadow: var(--shadow-md);
  cursor: pointer;
  transition:
    transform var(--transition-snap),
    box-shadow var(--transition-snap);
}
.b-button:active:not(:disabled) {
  transform: translate(var(--press-translate), var(--press-translate));
  box-shadow: var(--shadow-sm);
}
.b-button:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}
.b-button--spot {
  background: var(--spot);
  color: var(--ink);
}
.b-button--ghost {
  background: transparent;
  box-shadow: none;
}
.b-button--danger {
  background: var(--stamp-red);
  color: var(--paper);
}
.b-button__spinner {
  width: 1em;
  height: 1em;
  border: 2px solid currentColor;
  border-right-color: transparent;
  border-radius: 50%;
  animation: b-button-spin 0.8s steps(8) infinite;
}
@keyframes b-button-spin {
  to {
    transform: rotate(360deg);
  }
}
</style>
