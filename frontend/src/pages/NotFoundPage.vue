<script setup lang="ts">
import { BCropmarks } from '@/components/primitives';
</script>

<template>
  <main class="not-found">
    <BCropmarks inset="0.5rem" />
    <p class="not-found__numeral" aria-hidden="true">Nº —</p>
    <h1 class="not-found__title">NOT IN THIS ISSUE</h1>
    <p class="not-found__sub">The page you're after isn't in the press run.</p>
    <RouterLink to="/" class="not-found__home">← BACK TO ISSUE Nº01</RouterLink>
  </main>
</template>

<style scoped>
.not-found {
  max-width: 36rem;
  margin: 0 auto;
  padding: var(--space-8) var(--space-6);
  text-align: center;
}
.not-found__numeral {
  font-family: var(--font-display);
  font-size: var(--type-display);
  font-weight: 900;
  color: transparent;
  -webkit-text-stroke: 2px var(--ink);
  margin: 0;
  line-height: 1;
}
.not-found__title {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-h1);
  margin: var(--space-4) 0;
  text-transform: uppercase;
}
.not-found__sub {
  font-family: var(--font-body);
  color: var(--muted-ink);
  margin: 0 0 var(--space-6);
}
.not-found__home {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--spot);
}
</style>
