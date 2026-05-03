<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useProductListQuery } from '@/api/queries/products';
import { useDebouncedRef } from '@/composables/useDebouncedRef';
import { ApiError, classify } from '@/api/error';
import ProductCard from '@/components/ProductCard.vue';
import { BInput, BStamp, BButton } from '@/components/primitives';

const route = useRoute();
const router = useRouter();

const initialQ = typeof route.query.q === 'string' ? route.query.q : '';
const initialPage = (() => {
  const p = typeof route.query.page === 'string' ? parseInt(route.query.page, 10) : 1;
  return Number.isFinite(p) && p >= 1 ? p : 1;
})();

const inputValue = ref(initialQ);
const debouncedKeyword = useDebouncedRef<string>(initialQ, 400);
const currentPage = ref(initialPage);
const PAGE_SIZE = 12;

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

watch(
  () => route.query.page,
  (p) => {
    const n = typeof p === 'string' ? parseInt(p, 10) : 1;
    const safe = Number.isFinite(n) && n >= 1 ? n : 1;
    if (safe !== currentPage.value) currentPage.value = safe;
  },
);

watch(debouncedKeyword, (k) => {
  const current = typeof route.query.q === 'string' ? route.query.q : '';
  if (k === current) return;
  currentPage.value = 1;
  router.replace({ query: { ...route.query, q: k || undefined, page: undefined } });
});

function goToPage(p: number) {
  if (p === currentPage.value) return;
  currentPage.value = p;
  router.replace({ query: { ...route.query, page: p === 1 ? undefined : String(p) } });
}

const query = useProductListQuery(() => ({
  page: currentPage.value,
  size: PAGE_SIZE,
  keyword: debouncedKeyword.value || undefined,
}));

const items = computed(() => query.data.value?.data ?? []);
const total = computed(() => query.data.value?.total ?? 0);
const totalPages = computed(() => Math.max(1, Math.ceil(total.value / PAGE_SIZE)));
const isFirstLoad = computed(() => query.isLoading.value && !query.data.value);
const isFetching = computed(() => query.isFetching.value && !!query.data.value);
const hasKeyword = computed(() => (debouncedKeyword.value ?? '').trim() !== '');
const isEmptyCatalog = computed(
  () => !isFirstLoad.value && total.value === 0 && !hasKeyword.value && !query.isError.value,
);
const isEmptySearch = computed(
  () => !isFirstLoad.value && total.value === 0 && hasKeyword.value && !query.isError.value,
);
const heroItems = computed(() => (currentPage.value === 1 ? items.value.slice(0, 3) : []));
const gridItems = computed(() => items.value);

const errorClass = computed(() => {
  const err = query.error.value;
  if (!err) return null;
  if (err && typeof err === 'object' && 'status' in err && (err as { status: number }).status === 0)
    return 'network';
  if (err instanceof ApiError) return classify(err);
  return 'server';
});
const errorMessage = computed(() => {
  if (errorClass.value === 'network') return 'OFFLINE — RETRY?';
  if (errorClass.value === 'server') return 'SERVER STAMP MISSED — RETRY?';
  return null;
});

function clearSearch() {
  inputValue.value = '';
  router.replace({ query: { ...route.query, q: undefined, page: undefined } });
}

const pageButtons = computed<Array<number | 'gap'>>(() => {
  const last = totalPages.value;
  const cur = currentPage.value;
  if (last <= 7) return Array.from({ length: last }, (_, i) => i + 1);
  const out: Array<number | 'gap'> = [1];
  const winStart = Math.max(2, cur - 1);
  const winEnd = Math.min(last - 1, cur + 1);
  if (winStart > 2) out.push('gap');
  for (let i = winStart; i <= winEnd; i++) out.push(i);
  if (winEnd < last - 1) out.push('gap');
  out.push(last);
  return out;
});
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
      <BStamp v-if="isFetching" tone="ink" size="sm" class="home__fetching" :rotate="6">
        FETCHING
      </BStamp>

      <div v-if="errorMessage" class="home__error" role="alert">
        <p>{{ errorMessage }}</p>
        <BButton variant="ghost" @click="query.refetch?.()">RETRY</BButton>
      </div>
      <p v-else-if="isFirstLoad" class="home__placeholder">STAMPING…</p>
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

      <nav v-if="totalPages > 1" class="home__pager" aria-label="Pagination">
        <template v-for="(p, idx) in pageButtons" :key="`${p}-${idx}`">
          <span v-if="p === 'gap'" class="home__pager-gap">…</span>
          <button
            v-else
            class="home__pager-btn"
            :aria-current="p === currentPage ? 'page' : undefined"
            :data-active="p === currentPage ? 'true' : 'false'"
            @click="goToPage(p)"
          >
            {{ p }}
          </button>
        </template>
      </nav>
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
  gap: var(--space-4);
  grid-template-columns: 1fr;
}
@media (min-width: 30rem) {
  .home__hero-list,
  .home__grid {
    grid-template-columns: repeat(2, minmax(0, 1fr));
  }
}
@media (min-width: 48rem) {
  .home__hero-list,
  .home__grid {
    grid-template-columns: repeat(3, minmax(0, 1fr));
    gap: var(--space-6);
  }
}
@media (min-width: 80rem) {
  .home__grid {
    grid-template-columns: repeat(4, minmax(0, 1fr));
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
.home__grid-wrap {
  position: relative;
}
.home__fetching {
  position: absolute;
  top: 0;
  right: 0;
}
.home__error {
  border: var(--border-thick);
  padding: var(--space-4);
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: var(--space-4);
  font-family: var(--font-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
}
.home__pager {
  display: flex;
  justify-content: center;
  gap: var(--space-2);
  margin-top: var(--space-6);
  font-family: var(--font-mono);
}
.home__pager-btn {
  border: var(--border-thin);
  background: transparent;
  padding: var(--space-2) var(--space-3);
  cursor: pointer;
  font-family: inherit;
  font-size: var(--type-mono);
}
.home__pager-btn[data-active='true'] {
  background: var(--spot);
  color: var(--ink);
  border-color: var(--ink);
}
.home__pager-gap {
  align-self: center;
  color: var(--muted-ink);
}
</style>
