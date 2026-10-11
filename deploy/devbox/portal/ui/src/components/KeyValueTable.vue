<script setup>
// Editable key/value rows. The parent owns `rows` ([{key, value}]) via v-model.
const props = defineProps({
  modelValue: { type: Array, required: true },
  keyPlaceholder: { type: String, default: 'key' },
  valuePlaceholder: { type: String, default: 'value' },
  original: { type: Object, default: () => ({}) },   // saved values, to mark changed rows
})
const emit = defineEmits(['update:modelValue'])

const update = (rows) => emit('update:modelValue', rows)
const set = (i, field, v) => update(props.modelValue.map((r, j) => (j === i ? { ...r, [field]: v } : r)))
const remove = (i) => update(props.modelValue.filter((_, j) => j !== i))
const add = () => update([...props.modelValue, { key: '', value: '' }])
const state = (r) => (!(r.key in props.original) ? 'added' : props.original[r.key] !== r.value ? 'changed' : '')
</script>

<template>
  <div class="kv">
    <div v-for="(r, i) in modelValue" :key="i" class="row" :class="state(r)">
      <input class="mono k" :value="r.key" :placeholder="keyPlaceholder" @input="(e) => set(i, 'key', e.target.value.trim())" />
      <input class="mono v" :value="r.value" :placeholder="valuePlaceholder" @input="(e) => set(i, 'value', e.target.value)" />
      <button class="danger" @click="remove(i)" aria-label="Remove">✕</button>
    </div>
    <button class="add" @click="add">+ Add</button>
  </div>
</template>

<style scoped>
.kv { display: flex; flex-direction: column; gap: 6px; }
.row { display: grid; grid-template-columns: minmax(0, 1.2fr) minmax(0, 1fr) auto; gap: 6px; padding-left: 8px; border-left: 3px solid transparent; }
.row.added { border-left-color: var(--good); }
.row.changed { border-left-color: var(--warn); }
.add { align-self: flex-start; }
@media (max-width: 640px) { .row { grid-template-columns: 1fr auto; } .row .v { grid-column: 1; } }
</style>
