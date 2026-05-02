<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useProductListQuery } from '@/api/queries/products';
import { useDebouncedRef } from '@/composables/useDebouncedRef';
import ProductCard from '@/components/ProductCard.vue';
import { BInput, BStamp, BButton } from '@/components/primitives';

const route = useRoute();
const router = useRouter();

const initialQ = typeof route.query.q === 'string' ? route.query.q : '';
const inputValue = ref(initialQ);
const debouncedKeyword = useDebouncedRef<string>(initialQ, 400);

watch(inputValue, (v) => {
  debouncedKeyword.value = v;
});

watch(
  () => route.query.q,
  (q) => {
    const next = typeof q === 'string' ? q : '';
    if (next !== inputValue.value) inputValue.value = next;
  },
);

watch(debouncedKeyword, (k) => {
  const current = typeof route.query.q === 'string' ? route.query.q : '';
  if (k === current) return;
  router.replace({ query: { ...route.query, q: k || undefined, page: undefined } });
});

const query = useProductListQuery(() => ({
  page: 1,
  size: 12,
  keyword: debouncedKeyword.value || undefined,
}));

const items = computed(() => query.data.value?.data ?? []);
const total = computed(() => query.data.value?.total ?? 0);
const isFirstLoad = computed(() => query.isLoading.value && !query.data.value);
const hasKeyword = computed(() => (debouncedKeyword.value ?? '').trim() !== '');
const isEmptyCatalog = computed(() => !isFirstLoad.value && total.value === 0 && !hasKeyword.value);
const isEmptySearch = computed(() => !isFirstLoad.value && total.value === 0 && hasKeyword.value);
const heroItems = computed(() => items.value.slice(0, 3));
const gridItems = computed(() => items.value);

function clearSearch() {
  inputValue.value = '';
  router.replace({ query: { ...route.query, q: undefined, page: undefined } });
}
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

    <section class="home__search">
      <BInput v-model="inputValue" label="Search" placeholder="SEARCH THE ISSUE" />
    </section>

    <section class="home__grid-wrap" aria-label="Catalog">
      <p v-if="isFirstLoad" class="home__placeholder">STAMPING…</p>
      <div v-else-if="isEmptyCatalog" class="home__empty">
        <BStamp tone="ink" size="lg" :rotate="-4">ISSUE Nº01 / COMING SOON</BStamp>
      </div>
      <div v-else-if="isEmptySearch" class="home__empty">
        <p class="home__nomatch">NO MATCHES FOR "{{ debouncedKeyword }}"</p>
        <BButton variant="ghost" @click="clearSearch">CLEAR SEARCH</BButton>
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
.home__search {
  max-width: 32rem;
}
.home__nomatch {
  font-family: var(--font-display);
  font-size: var(--type-h2);
  text-transform: uppercase;
  letter-spacing: 0.04em;
  margin: 0 0 var(--space-4);
}
</style>
