<script setup>
import { computed } from 'vue'

const props = defineProps({ value: { type: String, default: '' } })

// Argo CD sync/health + job states → one colour vocabulary.
const KIND = {
  Synced: 'good', Healthy: 'good', SUCCEEDED: 'good',
  OutOfSync: 'warn', Progressing: 'warn', Suspended: 'warn', PENDING: 'warn',
  RUNNING: 'info',
  Degraded: 'bad', Missing: 'bad', Unknown: 'bad', FAILED: 'bad',
}
const LABEL = { SUCCEEDED: 'succeeded', FAILED: 'failed', RUNNING: 'running', PENDING: 'starting' }
const kind = computed(() => KIND[props.value] || 'ghost')
</script>

<template>
  <span class="pill" :class="kind">{{ LABEL[value] || value || '—' }}</span>
</template>
