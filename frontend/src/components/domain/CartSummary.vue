<script setup lang="ts">
import { computed } from 'vue';
import type { CartItem } from '@/api/queries/cart';
import { formatCurrency } from '@/lib/format';

const props = defineProps<{ items: CartItem[] }>();

const itemCount = computed(() => props.items.reduce((n, i) => n + i.quantity, 0));
const subtotal = computed(() => props.items.reduce((s, i) => s + i.unit_price * i.quantity, 0));
</script>

<template>
  <aside class="summary">
    <h2 class="summary__heading">SUMMARY</h2>
    <dl class="summary__rows">
      <div class="summary__row">
        <dt>Items</dt>
        <dd>{{ itemCount }}</dd>
      </div>
      <div class="summary__row summary__row--total">
        <dt>Subtotal</dt>
        <dd data-testid="subtotal">{{ formatCurrency(subtotal) }}</dd>
      </div>
    </dl>
  </aside>
</template>

<style scoped>
.summary {
  border: 2px solid var(--color-ink);
  padding: var(--space-4);
  background: var(--color-paper);
}
.summary__heading {
  font-family: var(--font-display);
  margin: 0 0 var(--space-3);
}
.summary__rows {
  margin: 0;
}
.summary__row {
  display: flex;
  justify-content: space-between;
  padding: var(--space-2) 0;
}
.summary__row--total {
  font-weight: bold;
  border-top: 2px solid var(--color-ink);
  margin-top: var(--space-2);
  padding-top: var(--space-3);
}
</style>
