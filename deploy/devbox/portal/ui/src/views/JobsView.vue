<script setup>
import { onMounted, onUnmounted, ref } from 'vue'
import { api } from '../api'
import { ago, duration } from '../format'
import StatusPill from '../components/StatusPill.vue'

const jobs = ref([])
const error = ref('')
const loaded = ref(false)
let timer

async function load() {
  try { jobs.value = await api.jobs(); error.value = '' } catch (e) { error.value = e.message } finally { loaded.value = true }
}
onMounted(() => { load(); timer = setInterval(load, 3000) })
onUnmounted(() => clearInterval(timer))
</script>

<template>
  <h1>Jobs</h1>
  <p class="muted">Everything the portal runs for you — creating and deleting envs — with its full log. Kept for 7 days.</p>
  <p v-if="error" class="error">Couldn't load jobs: {{ error }}</p>
  <div class="panel tablewrap">
    <table>
      <thead><tr><th>What</th><th>Env</th><th>Status</th><th>Started</th><th>Took</th><th></th></tr></thead>
      <tbody>
        <tr v-for="j in jobs" :key="j.name">
          <td>{{ j.title }}</td>
          <td><code>{{ j.target }}</code></td>
          <td><StatusPill :value="j.status" /></td>
          <td :title="j.started_at">{{ ago(j.started_at) }}</td>
          <td>{{ duration(j.started_at, j.finished_at) }}</td>
          <td><RouterLink :to="`/jobs/${j.name}`" class="btn">Log ›</RouterLink></td>
        </tr>
        <tr v-if="loaded && !jobs.length"><td colspan="6" class="muted">No jobs yet — create a preview env from Environments.</td></tr>
      </tbody>
    </table>
  </div>
</template>

<style scoped>
h1 + p { margin: 4px 0 18px; }
.error { color: var(--bad); }
</style>
