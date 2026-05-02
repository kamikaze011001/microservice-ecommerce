<script setup lang="ts">
interface Props {
  tone?: 'ink' | 'spot' | 'paper';
  rotate?: number;
}
const props = withDefaults(defineProps<Props>(), { tone: 'ink' });
</script>

<template>
  <span
    :class="['b-tag', `tone-${props.tone}`]"
    :style="props.rotate ? { transform: `rotate(${props.rotate}deg)` } : undefined"
  >
    <slot />
  </span>
</template>

<style scoped>
.b-tag {
  display: inline-block;
  padding: var(--space-1) var(--space-3);
  border: var(--border-thin);
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.tone-ink {
  background: var(--ink);
  color: var(--paper);
  border-color: var(--ink);
}
.tone-spot {
  background: var(--spot);
  color: var(--ink);
  border-color: var(--ink);
}
.tone-paper {
  background: var(--paper);
  color: var(--ink);
  border-color: var(--ink);
}
</style>
