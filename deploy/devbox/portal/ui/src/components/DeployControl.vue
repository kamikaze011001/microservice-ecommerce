<script setup>
import { computed, ref } from 'vue'

// The old page fetched tags on the select's focus — the browser opened the
// list before they arrived (empty on first click), and the 30s refresh could
// close it. Now the parent loads every service's tags up front and passes
// them in; the choice lives here, so a refresh doesn't touch it.
const props = defineProps({
  env: { type: String, required: true },
  service: { type: String, required: true },
  current: { type: String, default: '' },
  tags: { type: Array, default: () => [] },
  busy: { type: Boolean, default: false },
})
const emit = defineEmits(['deploy'])

const choice = ref('')
const options = computed(() => props.tags.map((t) => ({
  tag: t.tag,
  label: t.tag + (t.tag === props.current ? '  (running here)' : t.used_by.length ? `  · in ${t.used_by.join(', ')}` : ''),
})))
const canDeploy = computed(() => choice.value && choice.value !== props.current && !props.busy)

function deploy() {
  emit('deploy', { env: props.env, service: props.service, tag: choice.value, from: props.current })
  choice.value = ''
}
</script>

<template>
  <div class="deploy">
    <select v-model="choice" :aria-label="`Version of ${service} to deploy to ${env}`" :disabled="!tags.length">
      <option value="" disabled>{{ tags.length ? 'choose version…' : 'loading versions…' }}</option>
      <option v-for="o in options" :key="o.tag" :value="o.tag" :disabled="o.tag === current">{{ o.label }}</option>
    </select>
    <button class="primary" :disabled="!canDeploy" @click="deploy">Deploy</button>
  </div>
</template>

<style scoped>
.deploy { display: flex; gap: 6px; align-items: center; }
select { width: 210px; }
</style>
