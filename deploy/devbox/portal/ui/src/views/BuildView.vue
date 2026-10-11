<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { api, isActive } from '../api'
import { ago } from '../format'
import { notify } from '../toast'
import SecretField from '../components/SecretField.vue'
import StatusPill from '../components/StatusPill.vue'

const router = useRouter()
const branches = ref([])
const envs = ref([])
const jobs = ref([])
const error = ref('')
const loaded = ref(false)
const form = ref({ ref: '', service: 'product-service', env: 'prod-like' })

// JVM services ship from source; the static frontend and mock PayPal too.
const SERVICES = ['authorization-server', 'bff-service', 'frontend', 'gateway', 'inventory-service', 'mock-paypal-service',
  'orchestrator-service', 'order-service', 'payment-service', 'product-service']
const REMOTE = 'http://devbox:devbox-local@gitea.microecom.local/devbox/microecom.git'

const running = computed(() => jobs.value.find((j) => isActive(j.status)))
const builds = computed(() => jobs.value.filter((j) => j.kind === 'build'))

async function load() {
  try {
    const [b, e, j] = await Promise.all([api.branches(), api.envs(), api.jobs()])
    branches.value = b
    envs.value = e.map((x) => x.name)
    jobs.value = j
    if (!form.value.ref && b.length) form.value.ref = b[0].name
    error.value = ''
  } catch (err) { error.value = err.message } finally { loaded.value = true }
}

async function build() {
  try {
    const job = await api.startJob('build', form.value.env, { service: form.value.service, ref: form.value.ref })
    router.push(`/jobs/${job.name}`)
  } catch (e) { notify(e.message, 'err') }
}

let timer
onMounted(() => { load(); timer = setInterval(load, 10000) })
onUnmounted(() => clearInterval(timer))
</script>

<template>
  <h1>Build &amp; deploy your code</h1>
  <p class="muted lead">Push a branch to the devbox, pick it here, and the platform builds the image <b>inside the cluster</b>,
    tags it with your commit, and deploys it to the env you choose — then runs the API contract suite against it.
    The version shows up everywhere else (deploy, rollback, perf compare).</p>

  <section class="panel setup">
    <h2>1 · Push your branch to the devbox <span class="muted">(plain git — once per laptop for the remote)</span></h2>
    <label>Add the devbox as a git remote</label>
    <SecretField :value="`git remote add devbox ${REMOTE}`" />
    <label>Then, whenever you want to try your work</label>
    <SecretField value="git push devbox HEAD:my-feature" />
    <p class="muted small">Needs <code>gitea.microecom.local</code> in /etc/hosts and the tunnel (see Platform tools). The devbox
      Gitea is local to your laptop — nothing goes to GitHub.</p>
  </section>

  <section class="panel form">
    <h2>2 · Build &amp; deploy</h2>
    <p v-if="error" class="error">{{ error }}</p>
    <div class="fields">
      <label>Branch
        <select v-model="form.ref" :disabled="!branches.length">
          <option v-for="b in branches" :key="b.name" :value="b.name">{{ b.name }} — {{ b.sha.slice(0, 7) }}</option>
        </select>
      </label>
      <label>Service
        <select v-model="form.service"><option v-for="s in SERVICES" :key="s">{{ s }}</option></select>
      </label>
      <label>Deploy to
        <select v-model="form.env"><option v-for="e in envs" :key="e">{{ e }}</option></select>
      </label>
      <button class="primary" :disabled="!form.ref || !!running" @click="build">Build &amp; deploy</button>
    </div>
    <p v-if="running" class="muted small">Waiting for “{{ running.title }} {{ running.target }}” —
      <RouterLink :to="`/jobs/${running.name}`">watch it ›</RouterLink></p>
    <p class="muted small">A first build compiles the shared core modules too (several minutes); after that only your
      service. Same commit = same tag = no rebuild.</p>
  </section>

  <h2 class="section">Branches on the devbox</h2>
  <div class="panel tablewrap">
    <table>
      <thead><tr><th>Branch</th><th>Last commit</th><th>Author</th><th>When</th></tr></thead>
      <tbody>
        <tr v-for="b in branches" :key="b.name" :class="{ sel: b.name === form.ref }" @click="form.ref = b.name">
          <td><code>{{ b.name }}</code></td><td><code>{{ b.sha.slice(0, 7) }}</code> {{ b.message }}</td>
          <td>{{ b.author }}</td><td>{{ ago(b.date) }}</td>
        </tr>
        <tr v-if="loaded && !branches.length"><td colspan="4" class="muted">No branches yet — push one (step 1).</td></tr>
      </tbody>
    </table>
  </div>

  <h2 class="section">Recent builds</h2>
  <div class="panel tablewrap">
    <table>
      <thead><tr><th>Build</th><th>Env</th><th>Status</th><th>When</th><th></th></tr></thead>
      <tbody>
        <tr v-for="j in builds" :key="j.name">
          <td>{{ j.title.replace('Build & deploy · ', '') }}</td><td><code>{{ j.target }}</code></td>
          <td><StatusPill :value="j.status" /></td><td>{{ ago(j.started_at) }}</td>
          <td><RouterLink :to="`/jobs/${j.name}`" class="btn">Log ›</RouterLink></td>
        </tr>
        <tr v-if="loaded && !builds.length"><td colspan="5" class="muted">No builds yet.</td></tr>
      </tbody>
    </table>
  </div>
</template>

<style scoped>
.lead { margin: 4px 0 16px; max-width: 780px; }
.setup, .form { padding: 14px 16px; margin-bottom: 16px; display: flex; flex-direction: column; gap: 8px; }
.setup label { font-size: 12px; color: var(--ink2); margin-top: 4px; }
.setup p, .form p { margin: 0; }
.fields { display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-end; }
.fields label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: var(--ink2); }
.primary { background: var(--acc); border-color: var(--acc); color: #fff; }
.small { font-size: 12.5px; }
.section { margin: 20px 0 8px; }
tbody tr { cursor: pointer; }
tr.sel td { background: var(--panel2); }
.error { color: var(--bad); }
</style>
