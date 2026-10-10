<script setup>
import { onMounted, onUnmounted } from 'vue'

defineProps({ title: { type: String, required: true } })
const emit = defineEmits(['close'])

const onKey = (e) => { if (e.key === 'Escape') emit('close') }
onMounted(() => window.addEventListener('keydown', onKey))
onUnmounted(() => window.removeEventListener('keydown', onKey))
</script>

<template>
  <div class="backdrop" @click.self="emit('close')">
    <div class="dialog panel" role="dialog" aria-modal="true" :aria-label="title">
      <header>
        <h2>{{ title }}</h2>
        <button class="x" @click="emit('close')" aria-label="Close">✕</button>
      </header>
      <div class="body"><slot /></div>
      <footer><slot name="actions" /></footer>
    </div>
  </div>
</template>

<style scoped>
.backdrop {
  position: fixed; inset: 0; background: rgba(0, 0, 0, .45); display: grid; place-items: center; z-index: 40; padding: 16px;
}
.dialog { width: min(520px, 100%); box-shadow: 0 18px 50px rgba(0, 0, 0, .3); }
header { display: flex; justify-content: space-between; align-items: center; padding: 14px 18px; border-bottom: 1px solid var(--line); }
.x { border: none; background: transparent; padding: 2px 6px; }
.body { padding: 16px 18px; display: flex; flex-direction: column; gap: 12px; }
footer { padding: 12px 18px; border-top: 1px solid var(--line); display: flex; justify-content: flex-end; gap: 8px; }
</style>
