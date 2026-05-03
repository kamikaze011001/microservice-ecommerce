<script setup lang="ts">
import { computed, onUnmounted, ref, watch } from 'vue';
import { useRoute, useRouter, RouterLink } from 'vue-router';
import { useOrderQuery, useCancelOrderMutation } from '@/api/queries/orders';
import { useCreatePaymentMutation } from '@/api/queries/payments';
import OrderStatusStamp from '@/components/domain/OrderStatusStamp.vue';

const PENDING_KEY = 'aibles.checkout.pendingOrderId';
const MAX_POLLS = 10;

const route = useRoute();
const router = useRouter();

const orderId = computed(() => String(route.query.orderId ?? ''));
const variant = computed<'success' | 'cancel'>(() =>
  route.path === '/payment/cancel' ? 'cancel' : 'success',
);

const order = useOrderQuery(orderId, { polling: variant.value === 'success' });
const cancelOrder = useCancelOrderMutation();
const createPayment = useCreatePaymentMutation();

const pollCount = ref(0);
const errorBanner = ref<string | null>(null);

watch(
  () => order.data?.value?.status,
  (status) => {
    if (status && status !== 'PROCESSING') pollCount.value = MAX_POLLS;
    else pollCount.value++;
  },
);

const stampState = computed<'verifying' | 'paid' | 'still-processing' | 'canceled'>(() => {
  if (variant.value === 'cancel') return 'canceled';
  const status = order.data?.value?.status;
  if (status === 'PAID') return 'paid';
  if (pollCount.value >= MAX_POLLS) return 'still-processing';
  return 'verifying';
});

watch(stampState, (s) => {
  if (s === 'paid') localStorage.removeItem(PENDING_KEY);
});

onUnmounted(() => {
  if (stampState.value === 'paid') localStorage.removeItem(PENDING_KEY);
});

async function retryPayment() {
  errorBanner.value = null;
  try {
    const { approvalUrl } = await createPayment.mutateAsync({ orderId: orderId.value });
    window.location.href = approvalUrl;
  } catch {
    errorBanner.value = 'PAYMENT NOT STARTED — RETRY';
  }
}

async function cancelPending() {
  try {
    await cancelOrder.mutateAsync(orderId.value);
  } catch {
    errorBanner.value = "COULDN'T CANCEL — TRY AGAIN";
    return;
  }
  localStorage.removeItem(PENDING_KEY);
  router.push('/');
}
</script>

<template>
  <main class="result">
    <OrderStatusStamp :state="stampState" />

    <p v-if="variant === 'success' && stampState === 'paid'" class="result__copy">
      Order #{{ orderId }} is locked in.
    </p>
    <p v-else-if="variant === 'success' && stampState === 'still-processing'" class="result__copy">
      Saga is still settling. Check Orders.
    </p>
    <p v-else-if="variant === 'cancel'" class="result__copy">
      Your order is on hold. Pick up where you left off, or cancel.
    </p>

    <p v-if="errorBanner" class="result__error" role="alert">{{ errorBanner }}</p>

    <div class="result__actions">
      <template v-if="variant === 'success'">
        <RouterLink :to="`/orders?selected=${orderId}`" class="result__cta">VIEW ORDER</RouterLink>
      </template>
      <template v-else>
        <button type="button" class="result__cta" @click="retryPayment">RETRY PAYMENT</button>
        <button type="button" class="result__cta result__cta--ghost" @click="cancelPending">
          CANCEL ORDER
        </button>
      </template>
    </div>
  </main>
</template>

<style scoped>
.result {
  max-width: 720px;
  margin: 0 auto;
  padding: var(--space-10) var(--space-6);
  text-align: center;
}
.result__copy {
  font-family: var(--font-mono);
  margin-top: var(--space-4);
}
.result__error {
  background: var(--color-spot);
  color: var(--color-paper);
  padding: var(--space-3);
  margin-top: var(--space-4);
}
.result__actions {
  display: flex;
  gap: var(--space-4);
  justify-content: center;
  margin-top: var(--space-6);
}
.result__cta {
  background: var(--color-spot);
  color: var(--color-paper);
  border: 2px solid var(--color-ink);
  padding: var(--space-3) var(--space-5);
  font-family: var(--font-display);
  cursor: pointer;
  text-decoration: none;
}
.result__cta--ghost {
  background: var(--color-paper);
  color: var(--color-ink);
}
</style>
