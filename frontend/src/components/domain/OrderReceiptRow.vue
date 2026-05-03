<script setup lang="ts">
import { computed } from 'vue';
import { RouterLink } from 'vue-router';
import OrderStatusStamp from './OrderStatusStamp.vue';
import BImageFallback from '@/components/BImageFallback.vue';
import type { OrderSummary } from '@/api/queries/orders';

const props = defineProps<{ summary: OrderSummary }>();

const shortId = computed(() => props.summary.id.slice(0, 8).toUpperCase());

const total = computed(() =>
  new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(
    props.summary.total_amount,
  ),
);

const dateStr = computed(() =>
  new Date(props.summary.created_at)
    .toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: '2-digit' })
    .toUpperCase(),
);

const itemLabel = computed(
  () => `${props.summary.item_count} ITEM${props.summary.item_count === 1 ? '' : 'S'}`,
);
</script>

<template>
  <RouterLink :to="`/account/orders/${summary.id}`" class="receipt-row">
    <div class="receipt-row__id">
      <span class="receipt-row__numeral">Nº{{ shortId }}</span>
      <span class="receipt-row__date">{{ dateStr }}</span>
    </div>
    <div class="receipt-row__thumb">
      <img
        v-if="summary.first_item_image_url"
        :src="summary.first_item_image_url"
        alt=""
        width="80"
        height="80"
        loading="lazy"
      />
      <BImageFallback v-else :name="summary.id" />
    </div>
    <div class="receipt-row__count">{{ itemLabel }}</div>
    <div class="receipt-row__status">
      <OrderStatusStamp :status="summary.status" />
    </div>
    <div class="receipt-row__total">{{ total }}</div>
  </RouterLink>
</template>

<style scoped>
.receipt-row {
  display: grid;
  grid-template-columns: minmax(140px, auto) 56px minmax(80px, auto) auto auto;
  align-items: center;
  gap: var(--space-4);
  padding: var(--space-4) var(--space-2);
  border-top: var(--border-thin);
  text-decoration: none;
  color: var(--ink);
}
.receipt-row:hover {
  background: rgba(0, 0, 0, 0.02);
}
.receipt-row__id {
  display: flex;
  flex-direction: column;
  gap: 2px;
}
.receipt-row__numeral {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-h2);
  line-height: 1;
}
.receipt-row__date {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  color: var(--muted-ink);
  letter-spacing: 0.08em;
}
.receipt-row__thumb {
  width: 56px;
  height: 56px;
  overflow: hidden;
  border: var(--border-thin);
}
.receipt-row__thumb img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.receipt-row__count {
  font-family: var(--font-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted-ink);
}
.receipt-row__status {
  display: flex;
  justify-content: center;
}
.receipt-row__total {
  font-family: var(--font-mono);
  font-weight: 700;
  font-size: var(--type-h3);
  text-align: right;
}

@media (max-width: 37.49rem) {
  .receipt-row {
    grid-template-columns: 56px 1fr auto;
    grid-template-areas:
      'thumb id status'
      'thumb count total';
    column-gap: var(--space-3);
    row-gap: var(--space-1);
    align-items: start;
    padding: var(--space-3);
  }
  .receipt-row__thumb {
    grid-area: thumb;
  }
  .receipt-row__id {
    grid-area: id;
  }
  .receipt-row__status {
    grid-area: status;
    justify-content: flex-end;
  }
  .receipt-row__count {
    grid-area: count;
  }
  .receipt-row__total {
    grid-area: total;
  }
  .receipt-row__numeral {
    font-size: var(--type-h3);
  }
}
</style>
