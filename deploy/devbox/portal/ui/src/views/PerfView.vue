<script setup>
import { onMounted, ref } from 'vue'
import { api } from '../api'

const runs = ref([])
const error = ref('')
const loaded = ref(false)

onMounted(async () => {
  try { runs.value = await api.perfRuns() } catch (e) { error.value = e.message } finally { loaded.value = true }
})
</script>

<template>
  <h1>Perf runs</h1>
  <p class="muted">k6 load runs, each tagged with the exact version of every service it ran against.
    Starting and comparing runs from here arrives in the next portal update (7c).</p>
  <p v-if="error" class="error">Couldn't load perf runs: {{ error }}</p>
  <div class="panel tablewrap">
    <table>
      <thead><tr><th>Run</th><th>Env</th><th>Scenario</th><th>Profile</th><th>Result</th><th>Seconds</th></tr></thead>
      <tbody>
        <tr v-for="r in runs" :key="r.run">
          <td><code>{{ r.run }}</code></td><td>{{ r.env }}</td><td>{{ r.scenario }}</td><td>{{ r.profile }}</td>
          <td><span class="pill" :class="r.exit_code === 0 ? 'good' : 'bad'">{{ r.exit_code === 0 ? 'PASS' : 'FAIL ' + r.exit_code }}</span></td>
          <td>{{ r.duration_seconds }}</td>
        </tr>
        <tr v-if="loaded && !runs.length"><td colspan="6" class="muted">No runs yet.</td></tr>
      </tbody>
    </table>
  </div>
</template>

<style scoped>
h1 + p { margin: 4px 0 18px; max-width: 680px; }
.error { color: var(--bad); }
</style>
