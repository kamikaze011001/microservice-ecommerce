<script setup lang="ts">
import { ref, computed } from 'vue';
import { useOrdersListQuery } from '@/api/queries/orders';
import OrderReceiptRow from '@/components/domain/OrderReceiptRow.vue';
import { BButton, BStamp } from '@/components/primitives';
import { usePageMeta } from '@/composables/usePageMeta';

usePageMeta({ title: 'Orders — Issue Nº01', description: 'Your order history.' });

const PAGE_SIZE = 20;
const page = ref(1);
const query = useOrdersListQuery({ page, size: PAGE_SIZE });

const items = computed(() => query.data.value?.content ?? []);
const totalElements = computed(() => query.data.value?.total_elements ?? 0);
const totalPages = computed(() => Math.max(1, Math.ceil(totalElements.value / PAGE_SIZE)));
const isEmpty = computed(
  () =>
    !query.isLoading.value && items.value.length === 0 && page.value === 1 && !query.isError.value,
);

const pageButtons = computed<Array<number | 'gap'>>(() => {
  const last = totalPages.value;
  const cur = page.value;
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

function goToPage(p: number) {
  if (p === page.value) return;
  page.value = p;
}
</script>

<template>
  <main class="ledger">
    <header class="ledger__masthead">
      <span class="ledger__numeral" aria-hidden="true">Nº02</span>
      <p class="ledger__kicker">Vol. {{ page }} — Receipts on file</p>
    </header>

    <h1 class="ledger__title">THE LEDGER</h1>

    <p v-if="query.isLoading.value" class="ledger__placeholder">INKING…</p>

    <div v-else-if="query.isError.value" class="ledger__error" role="alert">
      <p>PRESS JAMMED — RETRY?</p>
      <BButton variant="ghost" @click="query.refetch()">RETRY</BButton>
    </div>

    <div v-else-if="isEmpty" class="ledger__empty">
      <BStamp tone="ink" size="lg" :rotate="-4">LEDGER UNPRINTED</BStamp>
      <p class="ledger__empty-copy">NO RECEIPTS HAVE BEEN STAMPED YET.</p>
      <RouterLink to="/" class="ledger__cta">BROWSE THE ISSUE</RouterLink>
    </div>

    <section v-else class="ledger__sheet" aria-label="Order receipts">
      <div class="ledger__columns" aria-hidden="true">
        <span>Nº</span><span>Date</span><span>Items</span><span>Status</span><span>Total</span>
      </div>
      <OrderReceiptRow v-for="o in items" :key="o.id" :summary="o" />
    </section>

    <nav v-if="totalPages > 1" class="ledger__pager" aria-label="Pagination">
      <template v-for="(p, idx) in pageButtons" :key="`${p}-${idx}`">
        <span v-if="p === 'gap'" class="ledger__pager-gap">…</span>
        <button
          v-else
          class="ledger__pager-btn"
          :aria-current="p === page ? 'page' : undefined"
          :data-active="p === page ? 'true' : 'false'"
          @click="goToPage(p)"
        >
          {{ p }}
        </button>
      </template>
    </nav>
  </main>
</template>

<style scoped>
.ledger {
  display: grid;
  gap: var(--space-6);
  padding: var(--space-2);
}
.ledger__masthead {
  display: flex;
  align-items: baseline;
  gap: var(--space-4);
  border-bottom: var(--border-thick);
  padding-bottom: var(--space-3);
}
.ledger__numeral {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-display);
  line-height: 1;
  color: transparent;
  -webkit-text-stroke: 2px var(--ink);
}
.ledger__kicker {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted-ink);
  margin: 0;
}
.ledger__title {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-h1);
  line-height: var(--leading-tight);
  letter-spacing: -0.02em;
  text-transform: uppercase;
  text-shadow: 4px 4px 0 var(--spot);
  margin: 0;
}
.ledger__placeholder {
  font-family: var(--font-mono);
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--muted-ink);
  text-align: center;
  padding: var(--space-8);
}
.ledger__empty {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: var(--space-4);
  padding: var(--space-8);
}
.ledger__empty-copy {
  font-family: var(--font-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted-ink);
  margin: 0;
}
.ledger__cta {
  font-family: var(--font-display);
  font-weight: 700;
  text-transform: uppercase;
  color: var(--ink);
  border-bottom: 2px solid var(--spot);
  padding-bottom: 2px;
  text-decoration: none;
}
.ledger__error {
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
.ledger__sheet {
  border-top: var(--border-thick);
}
.ledger__columns {
  display: grid;
  grid-template-columns: minmax(140px, auto) 56px minmax(80px, auto) auto auto;
  gap: var(--space-4);
  padding: var(--space-2);
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted-ink);
  border-bottom: var(--border-thin);
}
.ledger__pager {
  display: flex;
  justify-content: center;
  gap: var(--space-2);
  margin-top: var(--space-6);
  font-family: var(--font-mono);
}
.ledger__pager-btn {
  border: var(--border-thin);
  background: transparent;
  padding: var(--space-2) var(--space-3);
  cursor: pointer;
  font-family: inherit;
  font-size: var(--type-mono);
}
.ledger__pager-btn[data-active='true'] {
  background: var(--spot);
  color: var(--ink);
  border-color: var(--ink);
}
.ledger__pager-gap {
  align-self: center;
  color: var(--muted-ink);
}

@media (max-width: 37.49rem) {
  .ledger__columns {
    display: none;
  }
}
</style>
