<script setup lang="ts">
interface Props {
  name: string;
}
defineProps<Props>();
</script>

<template>
  <div class="b-image-fallback" role="img" :aria-label="name || 'Image unavailable'">
    <svg
      class="b-image-fallback__x"
      viewBox="0 0 100 100"
      preserveAspectRatio="none"
      aria-hidden="true"
    >
      <line x1="0" y1="0" x2="100" y2="100" />
      <line x1="100" y1="0" x2="0" y2="100" />
    </svg>
    <span class="b-image-fallback__label">{{ name }}</span>
  </div>
</template>

<style scoped>
.b-image-fallback {
  position: relative;
  width: 100%;
  aspect-ratio: 1 / 1;
  background: var(--paper);
  border: var(--border-thin);
  display: flex;
  align-items: center;
  justify-content: center;
  overflow: hidden;
}
.b-image-fallback__x {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  stroke: var(--ink);
  stroke-width: 1.5;
  vector-effect: non-scaling-stroke;
}
.b-image-fallback__label {
  position: relative;
  z-index: 1;
  font-family: var(--font-display);
  font-weight: 800;
  font-size: clamp(1rem, 2.4vw, 1.6rem);
  text-transform: lowercase;
  color: var(--ink);
  opacity: 0.4;
  text-align: center;
  padding: var(--space-3);
  max-width: 90%;
  line-height: 1.05;
  word-break: break-word;
}
</style>
