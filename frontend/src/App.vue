<script setup lang="ts">
const buildVersion = '0.0.0';
const buildDate = new Date().toISOString().slice(0, 10);
</script>

<template>
  <main class="page">
    <header class="masthead">
      <span class="numeral">01</span>
      <p class="kicker">Issue Nº01 — Storefront</p>
    </header>

    <section class="hero">
      <h1 class="title">FOUNDATION<br />LAID.</h1>
      <p class="lede">
        Tokens render. Fonts load. The press is warm.<br />
        Phase 2 starts here.
      </p>
      <div class="stamp">PHASE 1 ✓</div>
    </section>

    <footer class="colophon">
      <span>v{{ buildVersion }}</span>
      <span>{{ buildDate }}</span>
      <span>aibles ecommerce</span>
    </footer>
  </main>
</template>

<style scoped>
.page {
  position: relative;
  z-index: 2;
  max-width: var(--container-max);
  margin: 0 auto;
  padding: var(--space-8) var(--space-6);
  min-height: 100vh;
  display: grid;
  grid-template-rows: auto 1fr auto;
  gap: var(--space-8);
}

.masthead {
  display: flex;
  align-items: baseline;
  gap: var(--space-4);
  border-bottom: var(--border-thick);
  padding-bottom: var(--space-4);
}

.numeral {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-display);
  line-height: 1;
  color: transparent;
  -webkit-text-stroke: 2px var(--ink);
}

.kicker {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted-ink);
  margin: 0;
}

.hero {
  align-self: center;
  display: grid;
  gap: var(--space-6);
  position: relative;
}

.title {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-display);
  line-height: var(--leading-tight);
  letter-spacing: -0.02em;
  margin: 0;
  text-transform: uppercase;
  text-shadow: 4px 4px 0 var(--spot);
}

.lede {
  font-family: var(--font-body);
  font-size: var(--type-h2);
  line-height: var(--leading-body);
  max-width: 32ch;
  margin: 0;
}

.stamp {
  justify-self: start;
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--stamp-red);
  border: 3px double var(--stamp-red);
  padding: var(--space-2) var(--space-4);
  transform: rotate(-3deg);
}

.colophon {
  display: flex;
  justify-content: space-between;
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  color: var(--muted-ink);
  border-top: var(--border-thin);
  padding-top: var(--space-3);
}
</style>
