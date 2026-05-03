<script setup lang="ts">
import { reactive, computed, onUnmounted } from 'vue';
import { RouterLink } from 'vue-router';
import {
  useCartQuery,
  useUpdateCartItemMutation,
  useRemoveCartItemMutation,
} from '@/api/queries/cart';
import CartLineItem from '@/components/domain/CartLineItem.vue';
import CartSummary from '@/components/domain/CartSummary.vue';
import BButton from '@/components/primitives/BButton.vue';

const cart = useCartQuery();
const update = useUpdateCartItemMutation();
const remove = useRemoveCartItemMutation();

const pendingQty = reactive<Record<string, number>>({});
const debounceTimers: Record<string, ReturnType<typeof setTimeout>> = {};

function onQtyChange(itemId: string, quantity: number) {
  pendingQty[itemId] = quantity;
  if (debounceTimers[itemId]) clearTimeout(debounceTimers[itemId]);
  debounceTimers[itemId] = setTimeout(() => {
    update.mutate({ shopping_cart_item_id: itemId, quantity });
    delete debounceTimers[itemId];
  }, 400);
}

function onRemove(itemId: string) {
  remove.mutate({ shopping_cart_item_id: itemId });
}

onUnmounted(() => {
  Object.values(debounceTimers).forEach(clearTimeout);
});

const items = computed(() => cart.data.value?.items ?? []);
const isEmpty = computed(
  () => !cart.isLoading.value && !cart.isError.value && items.value.length === 0,
);
const hasOverStock = computed(() =>
  items.value.some((i) => (pendingQty[i.shopping_cart_item_id] ?? i.quantity) > i.available_stock),
);
</script>

<template>
  <main class="cart">
    <header class="cart__header">
      <span class="cart__numeral">02</span>
      <h1 class="cart__title">CART</h1>
    </header>

    <p v-if="cart.isLoading.value" class="cart__state">LOADING…</p>
    <p v-else-if="cart.isError.value" class="cart__state">
      COULDN'T LOAD CART —
      <button class="cart__retry" @click="cart.refetch?.()">RETRY</button>
    </p>

    <section v-else-if="isEmpty" class="cart__empty">
      <span class="cart__empty-numeral">00</span>
      <h2 class="cart__empty-headline">YOUR CART IS EMPTY</h2>
      <RouterLink to="/" class="cart__empty-cta">BACK TO HOME</RouterLink>
    </section>

    <section v-else class="cart__body">
      <div class="cart__lines">
        <CartLineItem
          v-for="item in items"
          :key="item.shopping_cart_item_id"
          :item="item"
          :pending-quantity="pendingQty[item.shopping_cart_item_id]"
          @qty-change="onQtyChange"
          @remove="onRemove"
        />
      </div>
      <div class="cart__side">
        <CartSummary :items="items" />
        <BButton
          variant="spot"
          class="cart__checkout"
          :disabled="hasOverStock || items.length === 0"
          @click="$router.push('/checkout')"
        >
          PROCEED TO CHECKOUT
        </BButton>
      </div>
    </section>
  </main>
</template>

<style scoped>
.cart {
  max-width: var(--container-max);
  margin: 0 auto;
  padding: var(--space-4);
}
@media (min-width: 48rem) {
  .cart {
    padding: var(--space-6);
  }
}
.cart__header {
  display: flex;
  align-items: baseline;
  gap: var(--space-4);
}
.cart__numeral {
  font-family: var(--font-mono);
  color: var(--color-spot);
  font-size: 0.9em;
}
.cart__title {
  font-family: var(--font-display);
  font-size: 3em;
  margin: 0;
}
.cart__state {
  font-family: var(--font-mono);
}
.cart__retry {
  background: none;
  border: none;
  color: var(--color-spot);
  text-decoration: underline;
  cursor: pointer;
}
.cart__empty {
  text-align: center;
  padding: var(--space-10) 0;
}
.cart__empty-numeral {
  display: block;
  font-family: var(--font-mono);
  color: var(--color-spot);
  font-size: 1.5em;
}
.cart__empty-headline {
  font-family: var(--font-display);
  font-size: 2em;
  margin: var(--space-4) 0;
}
.cart__empty-cta {
  color: var(--color-ink);
  text-decoration: underline;
  font-family: var(--font-display);
}
.cart__body {
  display: grid;
  grid-template-columns: 1fr 320px;
  gap: var(--space-6);
  align-items: start;
}
@media (max-width: 768px) {
  .cart__body {
    grid-template-columns: 1fr;
  }
}
.cart__side {
  position: sticky;
  top: var(--space-6);
  display: flex;
  flex-direction: column;
  gap: var(--space-4);
}
.cart__checkout {
  width: 100%;
}
</style>
