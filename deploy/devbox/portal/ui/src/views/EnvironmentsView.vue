<script setup>
import { computed, onMounted, onUnmounted, ref } from 'vue'
import { useRouter } from 'vue-router'
import { api, isActive } from '../api'
import { notify } from '../toast'
import EnvCard from '../components/EnvCard.vue'
import ModalDialog from '../components/ModalDialog.vue'

const router = useRouter()
const envs = ref([])
const history = ref({})
const tags = ref({})
const jobs = ref([])
const info = ref({ max_previews: 1, jobs_enabled: false })
const error = ref('')
const loaded = ref(false)
const busy = ref(false)
let timer

// Dialog state: one dialog at a time.
const creating = ref(false)
const newName = ref('')
const deleting = ref('')
const deleteConfirm = ref('')
const deploying = ref(null)

const NAME = /^[a-z0-9]([a-z0-9-]{0,18}[a-z0-9])?$/
const previews = computed(() => envs.value.filter((e) => e.name.startsWith('preview-')))
const activeJob = computed(() => jobs.value.find((j) => isActive(j.status)))
const atCap = computed(() => previews.value.length >= info.value.max_previews)
const createBlocked = computed(() => {
  if (!info.value.jobs_enabled) return 'Jobs are disabled on this portal (no runner image).'
  if (activeJob.value) return `Wait for "${activeJob.value.title} ${activeJob.value.target}" to finish.`
  if (atCap.value) return `Limit reached: ${info.value.max_previews} preview env(s) — each is a full copy of the app (~3 GB). Delete one first.`
  return ''
})
const nameError = computed(() => {
  const n = newName.value.replace(/^preview-/, '')
  if (!n) return ''
  if (!NAME.test(n)) return 'Use 1–20 lowercase letters, digits or "-" (not at the start or end).'
  if (envs.value.some((e) => e.name === 'preview-' + n)) return 'That env already exists.'
  return ''
})
const jobFor = (env) => jobs.value.find((j) => isActive(j.status) && j.target === env)

async function load() {
  try {
    const [e, j] = await Promise.all([api.envs(), api.jobs()])
    envs.value = e
    jobs.value = j
    error.value = ''
    const hs = await Promise.all(e.map((x) => api.history(x.name).catch(() => [])))
    history.value = Object.fromEntries(e.map((x, i) => [x.name, hs[i]]))
  } catch (err) {
    error.value = err.message
  } finally {
    loaded.value = true
  }
}

async function loadTags() {
  const services = [...new Set(envs.value.flatMap((e) => e.services.filter((s) => s.desired_tag).map((s) => s.name)))]
  const all = await Promise.all(services.map((s) => api.tags(s).catch(() => [])))
  tags.value = Object.fromEntries(services.map((s, i) => [s, all[i]]))
}

async function startJob(kind, target) {
  busy.value = true
  try {
    const job = await api.startJob(kind, target)
    router.push(`/jobs/${job.name}`)
  } catch (err) {
    notify(err.message, 'err')
  } finally {
    busy.value = false
  }
}

function create() {
  const name = newName.value.replace(/^preview-/, '')
  creating.value = false
  newName.value = ''
  startJob('env-create', name)
}

function remove() {
  const env = deleting.value
  deleting.value = ''
  deleteConfirm.value = ''
  startJob('env-delete', env)
}

async function deploy() {
  const d = deploying.value
  deploying.value = null
  busy.value = true
  try {
    const r = await api.deploy(d.env, d.service, d.tag)
    notify(r.changed
      ? `${d.service} ${r.previous_tag} → ${r.tag} committed to ${d.env} (${r.commit.slice(0, 7)}). Argo CD is rolling it out.`
      : `${d.env} already runs ${d.service} ${d.tag}.`)
    await load()
    await loadTags()
  } catch (err) {
    notify(err.message, 'err')
  } finally {
    busy.value = false
  }
}

onMounted(async () => {
  try { info.value = await api.info() } catch { /* defaults */ }
  await load()
  await loadTags()
  timer = setInterval(load, 10000)
})
onUnmounted(() => clearInterval(timer))
</script>

<template>
  <div class="head">
    <div>
      <h1>Environments</h1>
      <p class="muted">Each env is a full copy of the app. <b>prod-like</b> is your baseline; previews are
        throw-away copies with their own databases, topics and Redis.</p>
    </div>
    <div class="create">
      <button class="primary" :disabled="!!createBlocked || busy" @click="creating = true">+ New preview env</button>
      <div v-if="createBlocked && loaded" class="muted small">{{ createBlocked }}</div>
    </div>
  </div>

  <p v-if="error" class="error">Couldn't load environments: {{ error }}</p>
  <p v-else-if="!loaded" class="muted">Loading…</p>

  <EnvCard v-for="e in envs" :key="e.name" :env="e" :history="history[e.name] || []" :tags="tags"
           :job="jobFor(e.name)" :busy="busy"
           @deploy="(d) => (deploying = d)" @delete="(n) => { deleting = n; deleteConfirm = '' }" />

  <!-- A create job for an env that has no files yet: show it as a placeholder card. -->
  <section v-for="j in jobs.filter((x) => isActive(x.status) && x.kind === 'env-create' && !envs.some((e) => e.name === x.target))"
           :key="j.name" class="panel pending">
    <b>{{ j.target }}</b> <span class="muted">is being created…</span>
    <RouterLink :to="`/jobs/${j.name}`" class="btn">Watch progress ›</RouterLink>
  </section>

  <ModalDialog v-if="creating" title="New preview env" @close="creating = false">
    <label class="field">
      <span>Name</span>
      <div class="prefixed"><span class="mono muted">preview-</span>
        <input v-model.trim="newName" autofocus placeholder="cart" maxlength="28" @keydown.enter="!nameError && newName && create()" />
      </div>
      <span v-if="nameError" class="error small">{{ nameError }}</span>
    </label>
    <div v-if="newName && !nameError" class="muted small what">
      Creates namespace <code>apps-preview-{{ newName.replace(/^preview-/, '') }}</code>, its own MySQL &amp; Mongo
      databases, Kafka topics, CDC connector and Redis, seeds data and test users, then deploys every service at
      prod-like's versions. Takes about 5–10 minutes — you can watch every step.
    </div>
    <template #actions>
      <button @click="creating = false">Cancel</button>
      <button class="primary" :disabled="!newName || !!nameError" @click="create">Create</button>
    </template>
  </ModalDialog>

  <ModalDialog v-if="deleting" :title="`Delete ${deleting}?`" @close="deleting = ''">
    <p>This removes the env and <b>all its data</b>: namespace, MySQL &amp; Mongo databases, Kafka topics,
      consumer groups, schemas and connector. prod-like is not touched.</p>
    <label class="field">
      <span>Type <code>{{ deleting }}</code> to confirm</span>
      <input v-model.trim="deleteConfirm" autofocus />
    </label>
    <template #actions>
      <button @click="deleting = ''">Cancel</button>
      <button class="danger solid" :disabled="deleteConfirm !== deleting" @click="remove">Delete env</button>
    </template>
  </ModalDialog>

  <ModalDialog v-if="deploying" :title="`Deploy ${deploying.service}`" @close="deploying = null">
    <p><b>{{ deploying.env }}</b>: <code>{{ deploying.from }}</code> → <code>{{ deploying.tag }}</code></p>
    <p class="muted">This commits the new version to the env repo; Argo CD rolls it out in about a minute.
      To undo, deploy <code>{{ deploying.from }}</code> again — that's a rollback.</p>
    <template #actions>
      <button @click="deploying = null">Cancel</button>
      <button class="primary" @click="deploy">Deploy</button>
    </template>
  </ModalDialog>
</template>

<style scoped>
.head { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 16px; align-items: flex-start; margin-bottom: 18px; }
.head p { margin: 4px 0 0; max-width: 640px; }
.create { display: flex; flex-direction: column; align-items: flex-end; gap: 6px; max-width: 320px; text-align: right; }
.small { font-size: 12.5px; }
.error { color: var(--bad); }
.pending { padding: 14px 16px; margin-bottom: 20px; display: flex; gap: 10px; align-items: center; }
.field { display: flex; flex-direction: column; gap: 6px; }
.prefixed { display: flex; align-items: center; gap: 4px; }
.prefixed input { flex: 1; }
.what { line-height: 1.55; }
</style>
