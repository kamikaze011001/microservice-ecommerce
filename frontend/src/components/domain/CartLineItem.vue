<script setup lang="ts">
import { computed } from 'vue';
import type { CartItem } from '@/api/queries/cart';
import { formatCurrency } from '@/lib/format';
import BImageFallback from '@/components/BImageFallback.vue';

const props = defineProps<{
  item: CartItem;
  pendingQuantity?: number;
}>();

const emit = defineEmits<{
  (e: 'qtyChange', shoppingCartItemId: string, quantity: number): void;
  (e: 'remove', shoppingCartItemId: string): void;
}>();

const displayedQty = computed(() => props.pendingQuantity ?? props.item.quantity);
const lineSubtotal = computed(() => props.item.unit_price * displayedQty.value);
const overStock = computed(() => displayedQty.value > props.item.available_stock);

function dec() {
  if (displayedQty.value > 1) {
    emit('qtyChange', props.item.shopping_cart_item_id, displayedQty.value - 1);
  }
}
function inc() {
  const next = Math.min(displayedQty.value + 1, props.item.available_stock);
  if (next !== displayedQty.value) {
    emit('qtyChange', props.item.shopping_cart_item_id, next);
  }
}
</script>

<template>
  <article class="line">
    <div class="line__media">
      <img
        v-if="item.image_url"
        :src="item.image_url"
        :alt="item.name"
        class="line__img"
        width="120"
        height="120"
        loading="lazy"
      />
      <BImageFallback v-else :name="item.name" />
    </div>
    <div class="line__info">
      <RouterLink :to="`/products/${item.product_id}`" class="line__name">{{
        item.name
      }}</RouterLink>
      <p class="line__price">{{ formatCurrency(item.unit_price) }}</p>
      <p v-if="overStock" class="line__warn">LOW STOCK — {{ item.available_stock }} AVAILABLE</p>
    </div>
    <div class="line__qty">
      <button
        type="button"
        class="line__step"
        :disabled="displayedQty <= 1"
        aria-label="Decrease quantity"
        @click="dec"
      >
        −
      </button>
      <span class="line__qty-value" data-testid="qty-value">{{ displayedQty }}</span>
      <button
        type="button"
        class="line__step"
        :disabled="displayedQty >= item.available_stock"
        aria-label="Increase quantity"
        @click="inc"
      >
        +
      </button>
    </div>
    <div class="line__subtotal">{{ formatCurrency(lineSubtotal) }}</div>
    <button
      type="button"
      class="line__remove"
      aria-label="Remove from cart"
      @click="emit('remove', item.shopping_cart_item_id)"
    >
      ×
    </button>
  </article>
</template>

<style scoped>
.line {
  display: grid;
  grid-template-columns: 80px 1fr auto auto auto;
  gap: var(--space-4);
  align-items: center;
  padding: var(--space-4) 0;
  border-bottom: 2px solid var(--color-ink);
}
.line__img {
  width: 80px;
  height: 80px;
  object-fit: cover;
}
.line__name {
  font-family: var(--font-display);
  text-decoration: none;
  color: var(--color-ink);
}
.line__name:hover {
  text-decoration: underline;
}
.line__price {
  font-family: var(--font-mono);
  margin: 0;
}
.line__warn {
  font-family: var(--font-mono);
  color: var(--color-spot);
  margin: 0;
  font-size: 0.85em;
}
.line__qty {
  display: flex;
  align-items: center;
  gap: var(--space-2);
}
.line__step {
  width: 2rem;
  height: 2rem;
  border: 2px solid var(--color-ink);
  background: var(--color-paper);
  font-family: var(--font-display);
  cursor: pointer;
}
.line__step:disabled {
  opacity: 0.4;
  cursor: not-allowed;
}
.line__qty-value {
  min-width: 2ch;
  text-align: center;
  font-family: var(--font-mono);
}
.line__subtotal {
  font-family: var(--font-display);
  font-size: 1.1em;
}
.line__remove {
  background: none;
  border: none;
  font-size: 1.5em;
  cursor: pointer;
  color: var(--color-ink);
}

@media (max-width: 37.49rem) {
  .line {
    grid-template-columns: 80px 1fr auto;
    grid-template-areas:
      'img info remove'
      'img qty qty'
      'img subtotal subtotal';
    column-gap: var(--space-3);
    row-gap: var(--space-2);
    align-items: start;
  }
  .line__media {
    grid-area: img;
  }
  .line__info {
    grid-area: info;
  }
  .line__qty {
    grid-area: qty;
    justify-self: start;
  }
  .line__subtotal {
    grid-area: subtotal;
    justify-self: start;
  }
  .line__remove {
    grid-area: remove;
    align-self: start;
  }
}
</style>
