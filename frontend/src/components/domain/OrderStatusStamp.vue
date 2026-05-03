<script setup lang="ts">
defineProps<{
  state: 'verifying' | 'paid' | 'still-processing' | 'canceled';
}>();
</script>

<template>
  <div class="stamp" :class="`stamp--${state}`" role="status">
    <span v-if="state === 'verifying'">VERIFYING…</span>
    <span v-else-if="state === 'paid'">PAID</span>
    <span v-else-if="state === 'still-processing'">STILL PROCESSING</span>
    <span v-else>PAYMENT CANCELED</span>
  </div>
</template>

<style scoped>
.stamp {
  display: inline-block;
  padding: var(--space-3) var(--space-5);
  border: 4px solid currentColor;
  font-family: var(--font-display);
  font-size: 2em;
  letter-spacing: 0.05em;
}
.stamp--verifying {
  color: var(--color-ink);
  animation: pulse 1.2s ease-in-out infinite;
}
.stamp--paid {
  color: var(--color-ink);
  animation: stamp-in 200ms ease forwards;
}
.stamp--still-processing {
  color: var(--color-ink);
}
.stamp--canceled {
  color: var(--color-spot);
}
@keyframes pulse {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.55;
  }
}
@keyframes stamp-in {
  from {
    transform: rotate(-12deg) scale(1.5);
    opacity: 0;
  }
  to {
    transform: rotate(-4deg) scale(1);
    opacity: 1;
  }
}
</style>
