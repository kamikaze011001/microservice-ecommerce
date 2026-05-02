<script setup lang="ts">
import { computed } from 'vue';
import { useProductListQuery } from '@/api/queries/products';
import ProductCard from '@/components/ProductCard.vue';
import { BStamp } from '@/components/primitives';

const params = computed(() => ({ page: 1, size: 12 }));
const query = useProductListQuery(params);

const items = computed(() => query.data.value?.data ?? []);
const total = computed(() => query.data.value?.total ?? 0);
const isFirstLoad = computed(() => query.isLoading.value && !query.data.value);
const isEmpty = computed(() => !isFirstLoad.value && total.value === 0);
const heroItems = computed(() => items.value.slice(0, 3));
const gridItems = computed(() => items.value);
</script>

<template>
  <main class="home">
    <header class="home__masthead">
      <span class="home__numeral" aria-hidden="true">01</span>
      <p class="home__kicker">Issue Nº01 — Everything in stock</p>
    </header>

    <section v-if="heroItems.length" class="home__hero" aria-label="Spotlight">
      <h1 class="home__title">EVERYTHING<br />IN STOCK.</h1>
      <ul class="home__hero-list">
        <li v-for="item in heroItems" :key="item.id" class="home__hero-item">
          <ProductCard :product="item" />
        </li>
      </ul>
    </section>

    <section class="home__grid-wrap" aria-label="Catalog">
      <p v-if="isFirstLoad" class="home__placeholder">STAMPING…</p>
      <div v-else-if="isEmpty" class="home__empty">
        <BStamp tone="ink" size="lg" :rotate="-4"> ISSUE Nº01 / COMING SOON </BStamp>
      </div>
      <ul v-else class="home__grid">
        <li v-for="item in gridItems" :key="item.id" class="home__grid-item">
          <ProductCard :product="item" />
        </li>
      </ul>
    </section>
  </main>
</template>

<style scoped>
.home {
  max-width: var(--container-max);
  margin: 0 auto;
  padding: var(--space-8) var(--space-6);
  display: grid;
  gap: var(--space-8);
}
.home__masthead {
  display: flex;
  align-items: baseline;
  gap: var(--space-4);
  border-bottom: var(--border-thick);
  padding-bottom: var(--space-4);
}
.home__numeral {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-display);
  line-height: 1;
  color: transparent;
  -webkit-text-stroke: 2px var(--ink);
}
.home__kicker {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted-ink);
  margin: 0;
}
.home__title {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-display);
  line-height: var(--leading-tight);
  letter-spacing: -0.02em;
  margin: 0 0 var(--space-6);
  text-transform: uppercase;
  text-shadow: 4px 4px 0 var(--spot);
}
.home__hero-list,
.home__grid {
  list-style: none;
  padding: 0;
  margin: 0;
  display: grid;
  gap: var(--space-6);
}
.home__hero-list {
  grid-template-columns: repeat(3, minmax(0, 1fr));
}
.home__grid {
  grid-template-columns: repeat(3, minmax(0, 1fr));
}
@media (max-width: 900px) {
  .home__hero-list,
  .home__grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}
@media (max-width: 560px) {
  .home__hero-list,
  .home__grid {
    grid-template-columns: 1fr;
  }
}
.home__placeholder {
  font-family: var(--font-mono);
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--muted-ink);
  text-align: center;
  padding: var(--space-8);
}
.home__empty {
  display: flex;
  justify-content: center;
  padding: var(--space-8);
}
</style>
