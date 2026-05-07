<script setup lang="ts">
import { computed } from 'vue';
import { BStamp } from '@/components/primitives';

const props = defineProps<{ status: string }>();

const LABEL: Record<string, string> = {
  PROCESSING: 'IN PRESS',
  COMPLETED: 'PAID',
  CANCELED: 'VOIDED',
  FAILED: 'MISFIRE',
  REFUNDED: 'REFUNDED',
};
const ROTATE: Record<string, number> = {
  PROCESSING: 4,
  COMPLETED: -2,
  CANCELED: 6,
  FAILED: -5,
  REFUNDED: 3,
};

const label = computed(() => LABEL[props.status] ?? props.status);
const rotation = computed(() => ROTATE[props.status] ?? 0);
</script>

<template>
  <span role="img" :aria-label="`Order status: ${label}`">
    <BStamp tone="spot" size="sm" :rotate="rotation" aria-hidden="true">{{ label }}</BStamp>
  </span>
</template>
