<script setup lang="ts">
import { RouterLink, RouterView } from 'vue-router';
</script>

<template>
  <main class="account">
    <header class="account__masthead">
      <span class="account__numeral" aria-hidden="true">02</span>
      <p class="account__kicker">Issue Nº02 — The Account</p>
    </header>
    <nav class="account__strip" aria-label="Account sections">
      <RouterLink to="/account/profile" class="account__link" active-class="account__link--active"
        >MASTHEAD</RouterLink
      >
      <RouterLink to="/account/orders" class="account__link" active-class="account__link--active"
        >LEDGER</RouterLink
      >
    </nav>
    <section class="account__main">
      <RouterView />
    </section>
  </main>
</template>

<style scoped>
.account {
  max-width: var(--container-max);
  margin: 0 auto;
  padding: var(--space-8) var(--space-6);
  display: grid;
  gap: var(--space-6);
}
.account__masthead {
  display: flex;
  align-items: baseline;
  gap: var(--space-4);
  border-bottom: var(--border-thick);
  padding-bottom: var(--space-4);
}
.account__numeral {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-display);
  line-height: 1;
  color: transparent;
  -webkit-text-stroke: 2px var(--ink);
}
.account__kicker {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted-ink);
  margin: 0;
}
.account__strip {
  display: flex;
  gap: var(--space-6);
  border-bottom: var(--border-thin);
  padding-bottom: var(--space-3);
}
.account__link {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--muted-ink);
  text-decoration: none;
  padding-bottom: var(--space-2);
  border-bottom: 4px solid transparent;
}
.account__link:hover {
  border-bottom-color: var(--spot);
  color: var(--ink);
}
.account__link--active {
  color: var(--ink);
  border-bottom-color: var(--spot);
}

@media (max-width: 47.99rem) {
  .account {
    padding: var(--space-6) var(--space-4);
  }
  .account__masthead {
    flex-direction: column;
    align-items: flex-start;
    gap: var(--space-2);
  }
  .account__numeral {
    font-size: 4rem;
  }
  .account__strip {
    width: 100%;
    justify-content: flex-start;
    gap: var(--space-4);
  }
}

@media (max-width: 29.99rem) {
  .account__kicker {
    display: none;
  }
}
</style>
