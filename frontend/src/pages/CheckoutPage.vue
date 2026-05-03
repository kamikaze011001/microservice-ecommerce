<script setup lang="ts">
import { computed, onMounted, ref } from 'vue';
import { useRouter } from 'vue-router';
import { useCartQuery } from '@/api/queries/cart';
import { useCreateOrderMutation, useCancelOrderMutation } from '@/api/queries/orders';
import { useCreatePaymentMutation } from '@/api/queries/payments';
import AddressForm from '@/components/domain/AddressForm.vue';
import CartSummary from '@/components/domain/CartSummary.vue';
import type { AddressInput } from '@/lib/zod-schemas';

const PENDING_KEY = 'aibles.checkout.pendingOrderId';
const ADDRESS_KEY = 'aibles.checkout.lastAddress';

const router = useRouter();
const cart = useCartQuery();
const createOrder = useCreateOrderMutation();
const createPayment = useCreatePaymentMutation();
const cancelOrder = useCancelOrderMutation();

const banner = ref<string | null>(null);
const errorBanner = ref<string | null>(null);
const stamping = ref(false);
const initialAddress = ref<AddressInput | undefined>(undefined);

onMounted(() => {
  const pending = localStorage.getItem(PENDING_KEY);
  if (pending) banner.value = pending;
  const stored = localStorage.getItem(ADDRESS_KEY);
  if (stored) {
    try {
      initialAddress.value = JSON.parse(stored) as AddressInput;
    } catch {
      /* ignore */
    }
  }
});

async function onSubmit(payload: { structured: AddressInput; address: string; phone: string }) {
  errorBanner.value = null;
  stamping.value = true;
  let orderId: string | null = null;
  try {
    const result = await createOrder.mutateAsync({
      address: payload.address,
      phone_number: payload.phone,
      items: (cart.data.value?.items ?? []).map((i) => ({
        product_id: i.product_id,
        quantity: i.quantity,
      })),
    });
    orderId = result.orderId;
    localStorage.setItem(PENDING_KEY, orderId);
    localStorage.setItem(ADDRESS_KEY, JSON.stringify(payload.structured));
  } catch {
    stamping.value = false;
    errorBanner.value = 'ORDER NOT CREATED — TRY AGAIN';
    return;
  }
  try {
    const { approvalUrl } = await createPayment.mutateAsync({ orderId });
    window.location.href = approvalUrl;
  } catch {
    stamping.value = false;
    errorBanner.value = 'PAYMENT NOT STARTED — RETRY';
  }
}

async function resumePayment() {
  if (!banner.value) return;
  errorBanner.value = null;
  try {
    const { approvalUrl } = await createPayment.mutateAsync({ orderId: banner.value });
    window.location.href = approvalUrl;
  } catch {
    errorBanner.value = 'PAYMENT NOT STARTED — RETRY';
  }
}

async function cancelPending() {
  if (!banner.value) return;
  try {
    await cancelOrder.mutateAsync(banner.value);
  } catch {
    errorBanner.value = "COULDN'T CANCEL — TRY AGAIN";
    return;
  }
  localStorage.removeItem(PENDING_KEY);
  banner.value = null;
}

const cartItems = computed(() => cart.data.value?.items ?? []);
const cartEmpty = computed(() => !cart.isLoading.value && cartItems.value.length === 0);

if (cartEmpty.value) router.replace('/cart');
</script>

<template>
  <main class="checkout">
    <header class="checkout__header">
      <span class="checkout__numeral">03</span>
      <h1 class="checkout__title">CHECKOUT</h1>
    </header>

    <div v-if="banner" class="checkout__banner" role="alert">
      ORDER #{{ banner }} IS PENDING PAYMENT
      <div class="checkout__banner-actions">
        <button type="button" @click="resumePayment">RESUME PAYMENT</button>
        <button type="button" @click="cancelPending">CANCEL ORDER</button>
      </div>
    </div>

    <p v-if="errorBanner" class="checkout__error" role="alert">{{ errorBanner }}</p>

    <div class="checkout__body">
      <AddressForm :initial="initialAddress" :pending="stamping" @submit="onSubmit" />
      <CartSummary :items="cartItems" />
    </div>
  </main>
</template>

<style scoped>
.checkout {
  max-width: var(--container-max);
  margin: 0 auto;
  padding: var(--space-6);
}
.checkout__header {
  display: flex;
  align-items: baseline;
  gap: var(--space-4);
}
.checkout__numeral {
  font-family: var(--font-mono);
  color: var(--color-spot);
  font-size: 0.9em;
}
.checkout__title {
  font-family: var(--font-display);
  font-size: 3em;
  margin: 0;
}
.checkout__banner {
  background: var(--color-paper);
  border: 2px solid var(--color-spot);
  padding: var(--space-3);
  margin-bottom: var(--space-4);
  font-family: var(--font-mono);
}
.checkout__banner-actions {
  display: flex;
  gap: var(--space-3);
  margin-top: var(--space-2);
}
.checkout__banner-actions button {
  background: var(--color-spot);
  color: var(--color-paper);
  border: none;
  padding: var(--space-2) var(--space-3);
  font-family: var(--font-display);
  cursor: pointer;
}
.checkout__error {
  background: var(--color-spot);
  color: var(--color-paper);
  padding: var(--space-3);
  font-family: var(--font-mono);
  margin: var(--space-4) 0;
}
.checkout__body {
  display: grid;
  grid-template-columns: 1fr 320px;
  gap: var(--space-6);
  align-items: start;
}
@media (max-width: 768px) {
  .checkout__body {
    grid-template-columns: 1fr;
  }
}
</style>
