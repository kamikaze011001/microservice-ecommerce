<script setup>
import { ref } from 'vue'
import { copyText } from '../format'

// A credential with show/hide and copy. Copy falls back to select + execCommand:
// navigator.clipboard needs a secure context, and http://devbox.microecom.local isn't one.
const props = defineProps({ value: { type: String, default: '' }, secret: { type: Boolean, default: false } })
const shown = ref(!props.secret)
const copied = ref(false)
const input = ref(null)

async function copy() {
  copied.value = await copyText(props.value, input.value)
  setTimeout(() => (copied.value = false), 1500)
}
</script>

<template>
  <div class="field">
    <input ref="input" class="mono" readonly :type="shown ? 'text' : 'password'" :value="value" @focus="(e) => e.target.select()" />
    <button v-if="secret" @click="shown = !shown" :aria-label="shown ? 'Hide' : 'Show'">{{ shown ? 'Hide' : 'Show' }}</button>
    <button @click="copy">{{ copied ? 'Copied ✓' : 'Copy' }}</button>
  </div>
</template>

<style scoped>
.field { display: flex; gap: 6px; }
input { flex: 1; min-width: 0; }
</style>
