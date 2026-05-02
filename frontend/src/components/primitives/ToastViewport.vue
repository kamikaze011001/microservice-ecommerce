<script setup lang="ts">
import { useToastStore } from '@/stores/toast';
import BToast from './BToast.vue';
const store = useToastStore();
</script>

<template>
  <TransitionGroup tag="ol" name="toast" class="b-toast-viewport" aria-label="Notifications">
    <li v-for="item in store.items" :key="item.id" class="b-toast-viewport__item">
      <BToast
        :tone="item.tone"
        :title="item.title"
        :body="item.body"
        @dismiss="store.dismiss(item.id)"
      />
    </li>
  </TransitionGroup>
</template>

<style scoped>
.b-toast-viewport {
  position: fixed;
  top: var(--space-4);
  right: var(--space-4);
  list-style: none;
  margin: 0;
  padding: 0;
  display: flex;
  flex-direction: column;
  gap: var(--space-3);
  z-index: 70;
}
.toast-enter-from {
  transform: translateX(100%);
  opacity: 0;
}
.toast-enter-active {
  transition:
    transform 200ms ease-out,
    opacity 200ms ease-out;
}
.toast-leave-to {
  opacity: 0;
}
.toast-leave-active {
  transition: opacity 150ms ease-in;
}
</style>
