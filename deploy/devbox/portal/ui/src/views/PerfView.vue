<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { api, isActive } from '../api'
import { notify } from '../toast'

const router = useRouter()
const runs = ref([])
const envs = ref(['prod-like'])
const scenarios = ref({})
const jobs = ref([])
const error = ref('')
const loaded = ref(false)

const form = ref({ env: 'prod-like', scenario: 'storefront', profile: 'smoke' })
const picked = ref([])           // two run ids to compare
const comparison = ref(null)
const comparing = ref(false)

const HELP = {
  payment: 'login → order → pay (mock PayPal) → saga. Exercises every service + Kafka.',
  storefront: 'browse + product detail through the BFF. Read-heavy.',
  smoke: 'a few users for ~30s — "does it work at all".',
  load: 'the full ramp (minutes) — realistic pressure.',
  soak: 'steady load for longer — leaks and slow drifts.',
  stress: 'ramp past comfortable — where does it break?',
}
const profiles = computed(() => [...(scenarios.value[form.value.scenario] || [])].sort())
const running = computed(() => jobs.value.find((j) => isActive(j.status)))
const perfJob = computed(() => jobs.value.find((j) => j.kind === 'perf' && isActive(j.status)))

async function load() {
  try {
    const [r, j] = await Promise.all([api.perfRuns(), api.jobs()])
    runs.value = r
    jobs.value = j
    error.value = ''
  } catch (e) { error.value = e.message } finally { loaded.value = true }
}

async function start() {
  try {
    const job = await api.startJob('perf', form.value.env, { scenario: form.value.scenario, profile: form.value.profile })
    router.push(`/jobs/${job.name}`)
  } catch (e) { notify(e.message, 'err') }
}

function toggle(run) {
  picked.value = picked.value.includes(run) ? picked.value.filter((r) => r !== run) : [...picked.value, run].slice(-2)
  comparison.value = null
}

async function compare() {
  comparing.value = true
  // Oldest first, so "B" is the newer run and Δ reads as "what changed since".
  const [a, b] = [...picked.value].sort()
  try { comparison.value = await api.perfCompare(a, b) } catch (e) { notify(e.message, 'err') } finally { comparing.value = false }
}

const ms = (v) => (v == null ? '–' : `${Math.round(v * 1000)} ms`)
const pct = (v) => (v == null ? '–' : `${Math.round(v * 1000) / 10}%`)
function delta(a, b) {
  if (a == null || b == null || a === 0) return { text: '–', cls: '' }
  const d = Math.round(((b - a) / a) * 100)
  return { text: `${d > 0 ? '+' : ''}${d}%`, cls: d >= 20 ? 'worse' : d <= -20 ? 'better' : '' }
}

let timer
onMounted(async () => {
  try { scenarios.value = await api.perfScenarios() } catch { /* form shows nothing */ }
  try { envs.value = (await api.envs()).map((e) => e.name) } catch { /* default */ }
  await load()
  timer = setInterval(load, 10000)
})
onUnmounted(() => clearInterval(timer))
</script>

<template>
  <h1>Performance</h1>
  <p class="muted lead">Run a k6 load test against any env. Each run is recorded with the exact version of every service,
    so comparing two runs tells you whether a change made things faster or slower — and which version changed.</p>

  <section class="panel runform">
    <h2>Run a test</h2>
    <div class="fields">
      <label>Env <select v-model="form.env"><option v-for="e in envs" :key="e">{{ e }}</option></select></label>
      <label>Scenario
        <select v-model="form.scenario" @change="form.profile = 'smoke'">
          <option v-for="s in Object.keys(scenarios).sort()" :key="s">{{ s }}</option>
        </select>
      </label>
      <label>Profile <select v-model="form.profile"><option v-for="p in profiles" :key="p">{{ p }}</option></select></label>
      <button class="primary" :disabled="!!running" @click="start">▶ Run</button>
    </div>
    <p class="muted small">{{ HELP[form.scenario] }} <b>{{ form.profile }}</b>: {{ HELP[form.profile] }}</p>
    <p v-if="running" class="muted small">
      Waiting for “{{ running.title }} {{ running.target }}” —
      <RouterLink :to="`/jobs/${running.name}`">watch it ›</RouterLink></p>
  </section>

  <p v-if="error" class="error">Couldn't load runs: {{ error }}</p>

  <div class="runs-head">
    <h2>Recorded runs</h2>
    <button class="primary" :disabled="picked.length !== 2 || comparing" @click="compare">
      Compare {{ picked.length }}/2 selected</button>
  </div>
  <div class="panel tablewrap">
    <table>
      <thead><tr><th></th><th>Run</th><th>Env</th><th>Scenario</th><th>Profile</th><th>Result</th><th>Took</th></tr></thead>
      <tbody>
        <tr v-if="perfJob"><td></td><td colspan="6"><RouterLink :to="`/jobs/${perfJob.name}`">{{ perfJob.title }} on {{ perfJob.target }} — running ›</RouterLink></td></tr>
        <tr v-for="r in runs" :key="r.run" :class="{ sel: picked.includes(r.run) }" @click="toggle(r.run)">
          <td><input type="checkbox" :checked="picked.includes(r.run)" @click.stop="toggle(r.run)" :aria-label="`Select ${r.run}`" /></td>
          <td><code>{{ r.run }}</code></td><td>{{ r.env }}</td><td>{{ r.scenario }}</td><td>{{ r.profile }}</td>
          <td><span class="pill" :class="r.exit_code === 0 ? 'good' : 'bad'">{{ r.exit_code === 0 ? 'thresholds held' : 'thresholds failed' }}</span></td>
          <td>{{ r.duration_seconds }}s</td>
        </tr>
        <tr v-if="loaded && !runs.length"><td colspan="7" class="muted">No runs yet — start one above.</td></tr>
      </tbody>
    </table>
  </div>

  <section v-if="comparison" class="panel compare">
    <h2>A → B</h2>
    <p class="muted small">A <code>{{ comparison.a.run }}</code> ({{ comparison.a.env }}, {{ comparison.a.profile }}) ·
      B <code>{{ comparison.b.run }}</code> ({{ comparison.b.env }}, {{ comparison.b.profile }})</p>
    <h3>What changed between them</h3>
    <ul v-if="comparison.version_changes.length" class="changes">
      <li v-for="c in comparison.version_changes" :key="c.service"><b>{{ c.service }}</b>
        <code>{{ c.a || '–' }}</code> → <code>{{ c.b || '–' }}</code></li>
    </ul>
    <p v-else class="muted small">No version changed — same code, so any difference below is noise or the environment.</p>
    <p v-if="comparison.a.env !== comparison.b.env" class="muted small">Different envs — previews run smaller pods.</p>
    <div class="tablewrap">
      <table>
        <thead><tr><th>Request</th><th>p95 A</th><th>p95 B</th><th>Δ p95</th><th>errors A</th><th>errors B</th><th>reqs A / B</th></tr></thead>
        <tbody>
          <tr v-for="r in comparison.requests" :key="r.name" :class="{ noise: r.few_requests }">
            <td>{{ r.name }} <span v-if="r.few_requests" class="muted small" title="Under 30 requests: p95 swings a lot between identical runs">· few requests</span></td>
            <td>{{ ms(r.p95_a) }}</td><td>{{ ms(r.p95_b) }}</td>
            <td :class="delta(r.p95_a, r.p95_b).cls">{{ delta(r.p95_a, r.p95_b).text }}</td>
            <td>{{ pct(r.err_a) }}</td><td>{{ pct(r.err_b) }}</td>
            <td>{{ r.reqs_a ?? '–' }} / {{ r.reqs_b ?? '–' }}</td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>
</template>

<style scoped>
.lead { margin: 4px 0 16px; max-width: 760px; }
.runform { padding: 14px 16px; margin-bottom: 20px; display: flex; flex-direction: column; gap: 10px; }
.runform p { margin: 0; }
.fields { display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-end; }
.fields label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: var(--ink2); }
.primary { background: var(--acc); border-color: var(--acc); color: #fff; }
.small { font-size: 12.5px; }
.runs-head { display: flex; justify-content: space-between; align-items: center; margin: 0 0 8px; }
tbody tr { cursor: pointer; }
tr.sel td { background: var(--panel2); }
.compare { padding: 14px 16px; margin-top: 20px; }
.compare h3 { font-size: 13px; text-transform: uppercase; letter-spacing: .05em; color: var(--ink2); margin: 14px 0 6px; }
.changes { margin: 0 0 8px; padding-left: 18px; }
.worse { color: var(--bad); font-weight: 700; }
.better { color: var(--good); font-weight: 700; }
tr.noise td { color: var(--ink2); }
.error { color: var(--bad); }
</style>
