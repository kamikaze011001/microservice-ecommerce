<script setup lang="ts">
interface Props {
  numeral: string;
  side?: 'left' | 'right';
}
const props = withDefaults(defineProps<Props>(), { side: 'left' });
</script>

<template>
  <span :class="['b-margin-numeral', `side-${props.side}`]" aria-hidden="true">
    {{ props.numeral }}
  </span>
</template>

<style scoped>
.b-margin-numeral {
  display: block;
  font-family: var(--font-display);
  font-weight: 900;
  font-size: clamp(4rem, 10vw, 9rem);
  line-height: 0.85;
  color: transparent;
  -webkit-text-stroke: 2px var(--ink);
  letter-spacing: -0.05em;
}
.side-left {
  text-align: left;
  margin-left: calc(-1 * var(--space-4));
}
.side-right {
  text-align: right;
  margin-right: calc(-1 * var(--space-4));
}
</style>
