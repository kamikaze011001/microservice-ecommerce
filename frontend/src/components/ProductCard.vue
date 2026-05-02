<script setup lang="ts">
import { computed, ref } from 'vue';
import { RouterLink } from 'vue-router';
import { BCard, BStamp } from '@/components/primitives';
import BImageFallback from '@/components/BImageFallback.vue';
import type { ProductDto } from '@/api/queries/products';

interface Props {
  product: ProductDto;
}
const props = defineProps<Props>();

const imageBroken = ref(false);

// Deterministic rotation in [-2, +2] degrees from the id string.
const rotateDeg = computed(() => {
  let h = 0;
  const s = props.product.id;
  for (let i = 0; i < s.length; i++) h = (h * 31 + s.charCodeAt(i)) | 0;
  return (((h % 5) + 5) % 5) - 2; // 0..4 → -2..+2
});

const formattedPrice = computed(() =>
  new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' }).format(
    props.product.price ?? 0,
  ),
);

const soldOut = computed(() => (props.product.quantity ?? 0) <= 0);
</script>

<template>
  <RouterLink :to="`/products/${product.id}`" class="product-card-link">
    <BCard hover-misregister :rotate="rotateDeg">
      <div class="product-card__media">
        <img
          v-if="product.image_url && !imageBroken"
          :src="product.image_url"
          :alt="product.name"
          class="product-card__img"
          @error="imageBroken = true"
        />
        <BImageFallback v-else :name="product.name" />
        <BStamp v-if="soldOut" tone="red" size="sm" :rotate="-8" class="product-card__stamp">
          SOLD OUT
        </BStamp>
      </div>
      <h3 class="product-card__name">{{ product.name }}</h3>
      <p class="product-card__price">{{ formattedPrice }}</p>
    </BCard>
  </RouterLink>
</template>

<style scoped>
.product-card-link {
  text-decoration: none;
  color: inherit;
  display: block;
}
.product-card__media {
  position: relative;
  aspect-ratio: 1 / 1;
  margin-bottom: var(--space-4);
  background: var(--paper);
  overflow: hidden;
}
.product-card__img {
  width: 100%;
  height: 100%;
  object-fit: cover;
  display: block;
}
.product-card__stamp {
  position: absolute;
  top: var(--space-3);
  right: var(--space-3);
}
.product-card__name {
  font-family: var(--font-display);
  font-weight: 800;
  text-transform: uppercase;
  margin: 0 0 var(--space-2);
  font-size: var(--type-h3);
}
.product-card__price {
  font-family: var(--font-mono);
  font-size: var(--type-mono);
  margin: 0;
  color: var(--muted-ink);
}
</style>
