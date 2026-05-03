<script setup lang="ts">
interface Props {
  tone?: 'info' | 'success' | 'error';
  title: string;
  body?: string;
}
const props = withDefaults(defineProps<Props>(), { tone: 'info', body: undefined });
defineEmits<{ dismiss: [] }>();
</script>

<template>
  <div
    :class="['b-toast', `tone-${props.tone}`]"
    :role="props.tone === 'error' ? 'alert' : 'status'"
    :aria-live="props.tone === 'error' ? 'assertive' : 'polite'"
  >
    <div class="b-toast__text">
      <p class="b-toast__title">{{ props.title }}</p>
      <p v-if="props.body" class="b-toast__body">{{ props.body }}</p>
    </div>
    <button class="b-toast__close" type="button" aria-label="Close" @click="$emit('dismiss')">
      ×
    </button>
  </div>
</template>

<style scoped>
.b-toast {
  display: flex;
  align-items: flex-start;
  gap: var(--space-3);
  border: var(--border-thick);
  background: var(--paper);
  box-shadow: var(--shadow-md);
  padding: var(--space-3) var(--space-4);
  min-width: 16rem;
  max-width: 24rem;
}
.tone-info {
  border-color: var(--ink);
}
.tone-success {
  border-color: var(--ink);
  background: color-mix(in srgb, var(--spot) 15%, var(--paper));
}
.tone-error {
  border-color: var(--stamp-red);
}
.b-toast__title {
  font-family: var(--font-display);
  font-weight: 800;
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.b-toast__body {
  font-family: var(--font-body);
  color: var(--muted-ink);
  margin-top: var(--space-1);
}
.b-toast__close {
  background: transparent;
  border: none;
  font-size: 1.25rem;
  cursor: pointer;
  line-height: 1;
}
</style>
