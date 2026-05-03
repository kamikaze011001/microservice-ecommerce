<script setup lang="ts">
import { computed, ref } from 'vue';
import { useRoute, RouterLink } from 'vue-router';
import { useProductDetailQuery } from '@/api/queries/products';
import { useAddToCartMutation } from '@/api/queries/cart';
import BImageFallback from '@/components/BImageFallback.vue';
import NotFoundPage from '@/pages/NotFoundPage.vue';
import { BCropmarks, BButton, BStamp } from '@/components/primitives';
import { ApiError, classify } from '@/api/error';
import { useAuthStore } from '@/stores/auth';
import { useToast } from '@/composables/useToast';

const route = useRoute();
const id = computed(() => String(route.params.id));
const query = useProductDetailQuery(id);
const imageBroken = ref(false);

const product = computed(() => query.data.value);
const formattedPrice = computed(() =>
  new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(
    product.value?.price ?? 0,
  ),
);
const attributeRows = computed(() => {
  const a = product.value?.attributes;
  if (!a || typeof a !== 'object') return [];
  return Object.entries(a).map(([k, v]) => [k, String(v)] as const);
});

const errorClass = computed(() => {
  const err = query.error.value;
  if (!err) return null;
  if (err && typeof err === 'object' && 'status' in err) {
    const s = (err as { status: number }).status;
    if (s === 404) return 'not-found';
    if (s === 0) return 'network';
  }
  if (err instanceof ApiError) return classify(err);
  return 'server';
});
const isNotFound = computed(() => errorClass.value === 'not-found');
const otherError = computed(() => {
  if (!errorClass.value || isNotFound.value) return null;
  if (errorClass.value === 'network') return 'OFFLINE — RETRY?';
  return 'SERVER STAMP MISSED — RETRY?';
});

const auth = useAuthStore();
const soldOut = computed(() => (product.value?.quantity ?? 0) <= 0);
const isGuest = computed(() => !auth.isLoggedIn);
const loginHref = computed(() => `/login?next=/products/${id.value}`);

const addToCart = useAddToCartMutation();
const toast = useToast();

function handleAddToCart() {
  if (!product.value) return;
  addToCart.mutate(
    { product_id: product.value.id, quantity: 1, price: product.value.price },
    {
      onSuccess: () => toast.success('Added to cart', `${product.value?.name} is in your cart.`),
      onError: () => toast.error('Could not add to cart', 'Please try again.'),
    },
  );
}
</script>

<template>
  <NotFoundPage v-if="isNotFound" />
  <main v-else class="pdp">
    <BCropmarks inset="0.5rem" />
    <div v-if="!product && !otherError" class="pdp__placeholder">STAMPING…</div>
    <div v-else-if="otherError" class="pdp__error" role="alert">
      <p>{{ otherError }}</p>
      <button class="pdp__retry" @click="query.refetch?.()">RETRY</button>
    </div>
    <article v-else-if="product" class="pdp__article">
      <div class="pdp__media">
        <img
          v-if="product.image_url && !imageBroken"
          :src="product.image_url"
          :alt="product.name"
          class="pdp__img"
          @error="imageBroken = true"
        />
        <BImageFallback v-else :name="product.name" />
      </div>
      <div class="pdp__info">
        <h1 class="pdp__name">{{ product.name }}</h1>
        <p class="pdp__price">{{ formattedPrice }}</p>
        <dl v-if="attributeRows.length" class="pdp__attrs">
          <template v-for="[k, v] in attributeRows" :key="k">
            <dt>{{ k }}</dt>
            <dd>{{ v }}</dd>
          </template>
        </dl>
        <div class="pdp__cta">
          <BStamp v-if="soldOut" tone="red" size="md" :rotate="-6">SOLD OUT</BStamp>
          <template v-else-if="isGuest">
            <RouterLink :to="loginHref" class="pdp__cta-link"> LOGIN TO BUY </RouterLink>
          </template>
          <template v-else>
            <BButton variant="spot" :disabled="addToCart.isPending.value" @click="handleAddToCart">
              {{ addToCart.isPending.value ? 'ADDING…' : 'ADD TO CART' }}
            </BButton>
          </template>
        </div>
      </div>
    </article>
  </main>
</template>

<style scoped>
.pdp {
  max-width: var(--container-max);
  margin: 0 auto;
  padding: var(--space-6);
}
.pdp__article {
  display: grid;
  grid-template-columns: 1fr 1fr;
  gap: var(--space-8);
  align-items: start;
}
@media (max-width: 800px) {
  .pdp__article {
    grid-template-columns: 1fr;
  }
}
.pdp__media {
  border: var(--border-thick);
  position: relative;
  aspect-ratio: 1 / 1;
  overflow: hidden;
}
.pdp__img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.pdp__name {
  font-family: var(--font-display);
  font-weight: 900;
  text-transform: uppercase;
  font-size: var(--type-display);
  margin: 0;
  line-height: 1;
}
.pdp__price {
  font-family: var(--font-mono);
  font-size: var(--type-h2);
  margin: var(--space-3) 0 var(--space-6);
}
.pdp__attrs {
  display: grid;
  grid-template-columns: max-content 1fr;
  gap: var(--space-2) var(--space-4);
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  margin: 0 0 var(--space-6);
}
.pdp__attrs dt {
  text-transform: uppercase;
  letter-spacing: 0.06em;
  color: var(--muted-ink);
}
.pdp__attrs dd {
  margin: 0;
}
.pdp__placeholder {
  font-family: var(--font-mono);
  text-align: center;
  padding: var(--space-8);
}
.pdp__error {
  border: var(--border-thick);
  padding: var(--space-4);
  display: flex;
  justify-content: space-between;
  align-items: center;
  gap: var(--space-4);
  font-family: var(--font-mono);
  text-transform: uppercase;
}
.pdp__retry {
  border: var(--border-thin);
  background: transparent;
  padding: var(--space-2) var(--space-3);
  cursor: pointer;
  font-family: inherit;
}
.pdp__cta {
  display: flex;
  align-items: center;
  gap: var(--space-4);
  margin-top: var(--space-6);
}
.pdp__cta-link {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  padding: var(--space-3) var(--space-6);
  border: var(--border-thick);
  background: var(--spot);
  color: var(--ink);
  font-family: var(--font-display);
  font-weight: 700;
  letter-spacing: 0.04em;
  text-transform: uppercase;
  text-decoration: none;
  box-shadow: var(--shadow-md);
}
</style>
