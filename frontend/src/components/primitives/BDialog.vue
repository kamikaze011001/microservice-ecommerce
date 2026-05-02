<script setup lang="ts">
import {
  DialogRoot,
  DialogPortal,
  DialogOverlay,
  DialogContent,
  DialogTitle,
  DialogDescription,
  DialogClose,
} from 'reka-ui';

interface Props {
  open: boolean;
  title: string;
  description?: string;
}
const props = defineProps<Props>();
defineEmits<{ 'update:open': [value: boolean] }>();
</script>

<template>
  <DialogRoot :open="props.open" @update:open="$emit('update:open', $event)">
    <DialogPortal>
      <DialogOverlay class="b-dialog__overlay" />
      <DialogContent class="b-dialog__content">
        <DialogTitle class="b-dialog__title">{{ props.title }}</DialogTitle>
        <DialogDescription v-if="props.description" class="b-dialog__desc">
          {{ props.description }}
        </DialogDescription>
        <div class="b-dialog__body"><slot /></div>
        <div v-if="$slots.footer" class="b-dialog__footer"><slot name="footer" /></div>
        <DialogClose class="b-dialog__x" aria-label="Close">×</DialogClose>
      </DialogContent>
    </DialogPortal>
  </DialogRoot>
</template>

<style scoped>
.b-dialog__overlay {
  position: fixed;
  inset: 0;
  background: rgba(28, 28, 28, 0.6);
  z-index: 50;
}
.b-dialog__content {
  position: fixed;
  top: 50%;
  left: 50%;
  transform: translate(-50%, -50%);
  background: var(--paper);
  border: var(--border-thick);
  box-shadow: var(--shadow-lg);
  padding: var(--space-8);
  min-width: 20rem;
  max-width: 40rem;
  z-index: 51;
}
.b-dialog__title {
  font-family: var(--font-display);
  font-size: var(--type-h2);
  font-weight: 800;
  text-transform: uppercase;
  letter-spacing: 0.04em;
  margin-bottom: var(--space-3);
}
.b-dialog__desc {
  color: var(--muted-ink);
  margin-bottom: var(--space-4);
}
.b-dialog__body {
  margin-bottom: var(--space-6);
}
.b-dialog__footer {
  display: flex;
  gap: var(--space-3);
  justify-content: flex-end;
  border-top: var(--border-thin);
  padding-top: var(--space-4);
}
.b-dialog__x {
  position: absolute;
  top: var(--space-3);
  right: var(--space-3);
  background: transparent;
  border: none;
  font-size: 1.5rem;
  cursor: pointer;
  line-height: 1;
}
</style>
