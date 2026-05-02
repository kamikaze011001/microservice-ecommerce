<script setup lang="ts">
interface Props {
  tone?: 'red' | 'ink' | 'spot';
  rotate?: number;
  size?: 'sm' | 'md' | 'lg';
}
const props = withDefaults(defineProps<Props>(), {
  tone: 'red',
  size: 'md',
});
</script>

<template>
  <span
    :class="['b-stamp', `tone-${props.tone}`, `size-${props.size}`]"
    :style="props.rotate ? { transform: `rotate(${props.rotate}deg)` } : undefined"
    role="img"
  >
    <span class="b-stamp__inner"><slot /></span>
  </span>
</template>

<style scoped>
.b-stamp {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  border: 4px double currentColor;
  outline: 2px solid currentColor;
  outline-offset: 4px;
  border-radius: 50%;
  font-family: var(--font-display);
  font-weight: 800;
  letter-spacing: 0.06em;
  text-transform: uppercase;
  line-height: 1;
  padding: var(--space-3);
  text-align: center;
}
.size-sm {
  width: 4rem;
  height: 4rem;
  font-size: 0.7rem;
}
.size-md {
  width: 6rem;
  height: 6rem;
  font-size: 0.95rem;
}
.size-lg {
  width: 8rem;
  height: 8rem;
  font-size: 1.2rem;
}
.tone-red {
  color: var(--stamp-red);
}
.tone-ink {
  color: var(--ink);
}
.tone-spot {
  color: var(--spot);
}
.b-stamp__inner {
  display: block;
  max-width: 80%;
}
</style>
