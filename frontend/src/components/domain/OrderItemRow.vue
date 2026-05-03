<script setup lang="ts">
import { computed } from 'vue';
import { RouterLink } from 'vue-router';
import BImageFallback from '@/components/BImageFallback.vue';
import type { OrderDetailItem } from '@/api/queries/orders';

const props = defineProps<{ item: OrderDetailItem; index: number }>();
const fmt = (n: number) =>
  new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(n);
const subtotal = computed(() => fmt(props.item.price * props.item.quantity));
const unit = computed(() => fmt(props.item.price));
</script>

<template>
  <div class="row">
    <span class="row__index">{{ String(index).padStart(2, '0') }}</span>
    <div class="row__thumb">
      <img
        v-if="item.image_url"
        :src="item.image_url"
        :alt="item.product_name ?? 'Product'"
        width="80"
        height="80"
        loading="lazy"
      />
      <BImageFallback v-else :name="item.product_name ?? 'Product'" />
    </div>
    <div class="row__name">
      <RouterLink v-if="item.product_name" :to="`/products/${item.product_id}`">{{
        item.product_name
      }}</RouterLink>
      <span v-else class="row__missing">PRODUCT UNAVAILABLE</span>
    </div>
    <span class="row__leader" aria-hidden="true"></span>
    <span class="row__qty">{{ item.quantity }} × {{ unit }}</span>
    <span class="row__sub">{{ subtotal }}</span>
  </div>
</template>

<style scoped>
.row {
  display: grid;
  grid-template-columns: 32px 56px minmax(120px, 1fr) 1fr auto auto;
  align-items: center;
  gap: var(--space-3);
  padding: var(--space-2) 0;
  font-family: var(--font-mono);
}
.row__index {
  font-weight: 700;
  color: var(--muted-ink);
}
.row__thumb {
  width: 56px;
  height: 56px;
  overflow: hidden;
  border: var(--border-thin);
}
.row__thumb img {
  width: 100%;
  height: 100%;
  object-fit: cover;
}
.row__name {
  font-family: var(--font-display);
  font-weight: 700;
  text-transform: uppercase;
}
.row__name a {
  color: var(--ink);
  text-decoration: none;
  border-bottom: 1px dotted var(--ink);
}
.row__missing {
  color: var(--muted-ink);
}
.row__leader {
  border-bottom: 2px dotted var(--ink);
  align-self: end;
  height: 0;
  transform: translateY(-6px);
}
.row__qty {
  color: var(--muted-ink);
  white-space: nowrap;
}
.row__sub {
  font-weight: 700;
  white-space: nowrap;
}

@media (max-width: 29.99rem) {
  .row {
    grid-template-columns: 56px 1fr auto;
    grid-template-areas:
      'thumb name sub'
      'thumb qty qty';
    column-gap: var(--space-3);
    row-gap: var(--space-1);
    align-items: start;
  }
  .row__index {
    display: none;
  }
  .row__thumb {
    grid-area: thumb;
  }
  .row__name {
    grid-area: name;
  }
  .row__leader {
    display: none;
  }
  .row__qty {
    grid-area: qty;
  }
  .row__sub {
    grid-area: sub;
    text-align: right;
  }
}
</style>
