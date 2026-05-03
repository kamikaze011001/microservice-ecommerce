<script setup lang="ts">
import { ref, computed } from 'vue';
import { useRoute, useRouter } from 'vue-router';
import { useOrderDetailBffQuery, useCancelOrderMutation } from '@/api/queries/orders';
import { useAddToCartMutation } from '@/api/queries/cart';
import { useToast } from '@/composables/useToast';
import OrderItemRow from '@/components/domain/OrderItemRow.vue';
import OrderStatusStamp from '@/components/domain/OrderStatusStamp.vue';
import { BButton, BCropmarks, BDialog, ToastViewport } from '@/components/primitives';

const route = useRoute();
const router = useRouter();
const toast = useToast();

const orderId = computed(() => route.params.id as string);
const query = useOrderDetailBffQuery(orderId);

const order = computed(() => query.data.value?.order ?? null);
const shortId = computed(() => {
  const rawId =
    order.value?.id ?? (Array.isArray(orderId.value) ? orderId.value[0] : orderId.value) ?? '';
  return rawId.slice(0, 8).toUpperCase();
});
const is404 = computed(
  () => query.isError.value && (query.error.value as { status?: number })?.status === 404,
);

const canCancel = computed(() => {
  const s = order.value?.status;
  return s === 'PENDING' || s === 'PROCESSING';
});

const totalAmount = computed(() => {
  if (!order.value) return 0;
  return order.value.items.reduce((sum, i) => sum + i.price * i.quantity, 0);
});

const formattedDate = computed(() => {
  if (!order.value) return '';
  return new Intl.DateTimeFormat('en-US', { dateStyle: 'long' })
    .format(new Date(order.value.created_at))
    .toUpperCase();
});

const fmt = (n: number) =>
  new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(n);

// --- cancel flow ---
const cancelDialogOpen = ref(false);
const { mutateAsync: cancelMutate, isPending: cancelPending } = useCancelOrderMutation();

async function confirmCancel() {
  if (!order.value) return;
  try {
    await cancelMutate(order.value.id);
    cancelDialogOpen.value = false;
    toast.success('ORDER VOIDED');
  } catch {
    toast.error('VOID FAILED', 'Could not cancel this order.');
  }
}

// --- reorder flow ---
const { mutateAsync: addToCartMutate, isPending: reorderPending } = useAddToCartMutation();

async function reorder() {
  if (!order.value) return;
  const items = order.value.items;
  const results = await Promise.allSettled(
    items.map((item) =>
      addToCartMutate({ product_id: item.product_id, quantity: item.quantity, price: item.price }),
    ),
  );

  const added = results.filter((r) => r.status === 'fulfilled').length;
  const skipped = items.filter((_, i) => results[i].status === 'rejected');

  if (skipped.length === 0) {
    toast.success(`${added} ITEM(S) STAMPED INTO CART`);
    router.push('/cart');
  } else {
    const names = skipped.map((i) => i.product_name ?? 'UNKNOWN').join(', ');
    toast.info(`${added} STAMPED, ${skipped.length} OUT OF PRESS`, names);
    if (added > 0) {
      router.push('/cart');
    }
  }
}
</script>

<template>
  <main class="receipt">
    <!-- Loading -->
    <p v-if="query.isLoading.value" class="receipt__loading">INKING…</p>

    <!-- 404 panel -->
    <div v-else-if="is404" class="receipt__404" role="alert">
      <p class="receipt__404-copy">NO RECEIPT FOR Nº{{ shortId }}</p>
      <RouterLink to="/account/orders" class="receipt__back">BACK TO LEDGER</RouterLink>
    </div>

    <!-- Generic error -->
    <div v-else-if="query.isError.value" class="receipt__error" role="alert">
      <p>PRESS JAMMED</p>
      <BButton variant="ghost" @click="query.refetch()">RETRY</BButton>
    </div>

    <!-- Main receipt -->
    <template v-else-if="order">
      <!-- Header -->
      <header class="receipt__header">
        <div class="receipt__header-top">
          <span class="receipt__numeral" aria-hidden="true">Nº{{ shortId }}</span>
          <OrderStatusStamp :status="order.status" />
        </div>
        <h1 class="receipt__title">RECEIPT</h1>
        <p class="receipt__uuid">{{ order.id }}</p>
        <p class="receipt__stamped">STAMPED {{ formattedDate }}</p>
      </header>

      <!-- Items section wrapped in BCropmarks -->
      <BCropmarks inset="0.5rem" />

      <section class="receipt__items" aria-label="Order items">
        <OrderItemRow
          v-for="(item, idx) in order.items"
          :key="item.id"
          :item="item"
          :index="idx + 1"
        />
      </section>

      <BCropmarks inset="0.5rem" />

      <!-- Total block (ink on spot) -->
      <div class="receipt__total">
        <span class="receipt__total-label">TOTAL</span>
        <span class="receipt__total-amount">{{ fmt(totalAmount) }}</span>
      </div>

      <!-- Address / meta -->
      <div class="receipt__meta">
        <p><span class="receipt__meta-key">SHIP TO</span> {{ order.address }}</p>
        <p v-if="order.phone_number">
          <span class="receipt__meta-key">PHONE</span> {{ order.phone_number }}
        </p>
      </div>

      <!-- Actions -->
      <div class="receipt__actions">
        <BButton variant="spot" :disabled="reorderPending" @click="reorder"> STAMP AGAIN </BButton>
        <BButton
          v-if="canCancel"
          variant="ghost"
          :disabled="cancelPending"
          @click="cancelDialogOpen = true"
        >
          VOID THIS RECEIPT
        </BButton>
      </div>
    </template>

    <!-- Cancel confirmation dialog -->
    <BDialog
      :open="cancelDialogOpen"
      title="Void this order?"
      :description="`Void order Nº${shortId}? Stamp is permanent.`"
      @update:open="cancelDialogOpen = $event"
    >
      <template #footer>
        <BButton variant="ghost" @click="cancelDialogOpen = false">KEEP ORDER</BButton>
        <BButton variant="spot" :disabled="cancelPending" @click="confirmCancel">
          CONFIRM VOID
        </BButton>
      </template>
    </BDialog>
  </main>

  <ToastViewport />
</template>

<style scoped>
.receipt {
  display: grid;
  gap: var(--space-6);
  padding: var(--space-4);
  max-width: 800px;
  margin: 0 auto;
}

/* Loading / error states */
.receipt__loading {
  font-family: var(--font-mono);
  text-transform: uppercase;
  letter-spacing: 0.12em;
  color: var(--muted-ink);
  text-align: center;
  padding: var(--space-8);
}

/* 404 */
.receipt__404 {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: var(--space-4);
  padding: var(--space-8);
  text-align: center;
}
.receipt__404-copy {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-h2);
  text-transform: uppercase;
  margin: 0;
}
.receipt__back {
  font-family: var(--font-display);
  font-weight: 700;
  text-transform: uppercase;
  color: var(--ink);
  border-bottom: 2px solid var(--spot);
  padding-bottom: 2px;
  text-decoration: none;
}

.receipt__error {
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

/* Header */
.receipt__header {
  border-bottom: var(--border-thick);
  padding-bottom: var(--space-4);
  display: grid;
  gap: var(--space-2);
}
.receipt__header-top {
  display: flex;
  align-items: center;
  justify-content: space-between;
}
.receipt__numeral {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-display);
  line-height: 1;
  color: transparent;
  -webkit-text-stroke: 2px var(--ink);
}
.receipt__title {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-h1);
  line-height: var(--leading-tight);
  letter-spacing: -0.02em;
  text-transform: uppercase;
  text-shadow: 4px 4px 0 var(--spot);
  margin: 0;
}
.receipt__uuid {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  color: var(--muted-ink);
  margin: 0;
  word-break: break-all;
}
.receipt__stamped {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted-ink);
  margin: 0;
}

/* Items */
.receipt__items {
  display: flex;
  flex-direction: column;
  border-top: var(--border-thin);
  border-bottom: var(--border-thin);
}

/* Total — ink on spot */
.receipt__total {
  display: flex;
  align-items: baseline;
  justify-content: space-between;
  background: var(--spot);
  color: var(--ink);
  padding: var(--space-4) var(--space-6);
  border: var(--border-thick);
}
.receipt__total-label {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-h2);
  text-transform: uppercase;
  letter-spacing: 0.04em;
}
.receipt__total-amount {
  font-family: var(--font-display);
  font-weight: 900;
  font-size: var(--type-display);
  line-height: 1;
}

/* Meta */
.receipt__meta {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  display: grid;
  gap: var(--space-2);
  padding: var(--space-4) 0;
  border-top: var(--border-thin);
}
.receipt__meta p {
  margin: 0;
}
.receipt__meta-key {
  font-weight: 700;
  text-transform: uppercase;
  letter-spacing: 0.08em;
  color: var(--muted-ink);
  margin-right: var(--space-2);
}

/* Actions */
.receipt__actions {
  display: flex;
  gap: var(--space-3);
  flex-wrap: wrap;
}

@media (max-width: 47.99rem) {
  .receipt {
    padding: var(--space-3);
    gap: var(--space-4);
  }
  .receipt__title {
    font-size: var(--type-h2);
  }
  .receipt__numeral {
    font-size: 3rem;
  }
  .receipt__total {
    flex-direction: column;
    align-items: flex-start;
    gap: var(--space-2);
    padding: var(--space-3) var(--space-4);
  }
  .receipt__total-amount {
    font-size: var(--type-h1);
  }
  .receipt__actions :deep(.b-button) {
    flex: 1 1 auto;
  }
}
</style>
