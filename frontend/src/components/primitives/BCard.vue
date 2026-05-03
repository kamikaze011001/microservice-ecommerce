<script setup lang="ts">
import { ref } from 'vue';

interface Props {
  rotate?: number;
  hoverMisregister?: boolean;
  as?: string;
}
const props = withDefaults(defineProps<Props>(), {
  rotate: undefined,
  hoverMisregister: false,
  as: 'article',
});

const hovered = ref(false);
</script>

<template>
  <component
    :is="props.as"
    :class="['b-card', { 'is-misregister': props.hoverMisregister && hovered }]"
    :style="props.rotate ? { transform: `rotate(${props.rotate}deg)` } : undefined"
    @mouseenter="hovered = true"
    @mouseleave="hovered = false"
  >
    <header v-if="$slots.header" class="b-card__header"><slot name="header" /></header>
    <div class="b-card__body"><slot /></div>
    <footer v-if="$slots.footer" class="b-card__footer"><slot name="footer" /></footer>
  </component>
</template>

<style scoped>
.b-card {
  background: var(--paper);
  border: var(--border-thick);
  box-shadow: var(--shadow-md);
  padding: var(--space-6);
  transition: text-shadow var(--transition-snap);
}
.b-card.is-misregister :deep(h1),
.b-card.is-misregister :deep(h2),
.b-card.is-misregister :deep(h3) {
  text-shadow: 2px 2px 0 var(--spot);
}
.b-card__header {
  margin-bottom: var(--space-4);
  border-bottom: var(--border-thin);
  padding-bottom: var(--space-3);
}
.b-card__footer {
  margin-top: var(--space-4);
  border-top: var(--border-thin);
  padding-top: var(--space-3);
}
</style>
