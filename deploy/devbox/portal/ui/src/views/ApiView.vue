<script setup>
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import SwaggerUIBundle from 'swagger-ui-dist/swagger-ui-es-bundle.js'
import 'swagger-ui-dist/swagger-ui.css'
import { api, isActive } from '../api'
import { notify } from '../toast'
import SecretField from '../components/SecretField.vue'
import { remember } from '../format'

// Every call goes through the portal's proxy into the chosen env's gateway
// (/api/envs/<env>/gateway/...): works on localhost, no CORS, no hosts file.
const router = useRouter()
const envs = ref([])
const env = ref(remember.get('api.env', 'prod-like'))
const user = ref(remember.get('api.user', 'perftest_user_1'))
const spec = ref(remember.get('api.spec', 'product-service'))
const token = ref('')
const loggingIn = ref(false)
const jobs = ref([])
const host = ref(null)
let ui = null

// Seeded on every env by env-create / bootstrap (perftest-users.sql).
const USERS = [
  ...Array.from({ length: 5 }, (_, i) => ({ name: `perftest_user_${i + 1}`, password: 'Test@123456', role: 'user' })),
  { name: 'perftest_admin', password: 'Admin@123456', role: 'admin' },
]
const SPECS = ['authorization-server', 'product-service', 'bff-service', 'order-service', 'payment-service', 'inventory-service']

const base = computed(() => `/api/envs/${env.value}/gateway`)
const suiteJob = computed(() => jobs.value.find((j) => j.kind === 'api-test' && j.target === env.value))
const busy = computed(() => jobs.value.some((j) => isActive(j.status)))

async function login() {
  loggingIn.value = true
  const u = USERS.find((x) => x.name === user.value)
  try {
    const res = await fetch(`${base.value}/authorization-server/v1/auth:login`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ username: u.name, password: u.password }),
    })
    const body = await res.json().catch(() => ({}))
    const t = body?.data?.access_token
    if (!res.ok || !t) throw new Error(body?.error || body?.message || `login answered ${res.status}`)
    token.value = t
    notify(`Logged in as ${u.name} on ${env.value} — every request below now carries the token.`)
  } catch (e) {
    notify(`Login failed: ${e.message}`, 'err')
  } finally { loggingIn.value = false }
}

function mount() {
  if (!host.value) return
  ui = SwaggerUIBundle({
    domNode: host.value,
    url: `${base.value}/${spec.value}/v3/api-docs`,
    deepLinking: false,
    tryItOutEnabled: true,
    displayRequestDuration: true,
    persistAuthorization: false,
    layout: 'BaseLayout',
    // The specs name the gateway by its in-cluster host; keep only path + query
    // and send it through the proxy, with the logged-in token.
    requestInterceptor: (req) => {
      const u = new URL(req.url, window.location.origin)
      if (!u.pathname.startsWith('/api/envs/')) req.url = `${base.value}${u.pathname}${u.search}`
      if (token.value && !req.headers.Authorization) req.headers.Authorization = `Bearer ${token.value}`
      return req
    },
  })
}

async function runSuite() {
  try {
    const job = await api.startJob('api-test', env.value)
    router.push(`/jobs/${job.name}`)
  } catch (e) { notify(e.message, 'err') }
}

async function remount() {
  host.value.innerHTML = ''
  await nextTick()
  mount()
}
watch(env, (v) => { remember.set('api.env', v); token.value = ''; remount() })
watch(spec, (v) => { remember.set('api.spec', v); remount() })
watch(user, (v) => { remember.set('api.user', v); token.value = '' })

let timer
onMounted(async () => {
  try {
    envs.value = (await api.envs()).map((e) => e.name)
    if (!envs.value.includes(env.value)) env.value = 'prod-like'
  } catch { envs.value = ['prod-like'] }
  mount()
  const poll = async () => { try { jobs.value = await api.jobs() } catch { /* not fatal */ } }
  poll()
  timer = setInterval(poll, 5000)
})
onUnmounted(() => clearInterval(timer))
</script>

<template>
  <h1>API testing</h1>
  <p class="muted lead">Call any endpoint of any env — the full OpenAPI of every service, live. Pick an env, log in as a
    seeded test user, then “Try it out”. Or run the whole contract suite.</p>

  <section class="panel bar">
    <label>Env
      <select v-model="env"><option v-for="e in envs" :key="e" :value="e">{{ e }}</option></select>
    </label>
    <label>Service
      <select v-model="spec"><option v-for="s in SPECS" :key="s" :value="s">{{ s }}</option></select>
    </label>
    <label>Log in as
      <select v-model="user"><option v-for="u in USERS" :key="u.name" :value="u.name">{{ u.name }} ({{ u.role }})</option></select>
    </label>
    <button class="primary" :disabled="loggingIn" @click="login">{{ token ? 'Logged in ✓ — log in again' : 'Log in' }}</button>
    <span class="sp"></span>
    <div class="suite">
      <button :disabled="busy" @click="runSuite" :title="busy ? 'Another job is running' : ''">▶ Run contract suite on {{ env }}</button>
      <RouterLink v-if="suiteJob" :to="`/jobs/${suiteJob.name}`" class="muted small">
        last run: {{ suiteJob.status.toLowerCase() }} ›</RouterLink>
    </div>
  </section>

  <section v-if="token" class="panel tokenbox">
    <span class="muted small">Bearer token (sent automatically; copy it for curl/Postman)</span>
    <SecretField :value="token" secret />
  </section>

  <div class="panel swagger"><div ref="host"></div></div>
</template>

<style scoped>
.lead { margin: 4px 0 16px; max-width: 760px; }
.bar { display: flex; flex-wrap: wrap; gap: 12px; align-items: flex-end; padding: 12px 16px; margin-bottom: 12px; }
.bar label { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: var(--ink2); }
.bar .primary { background: var(--acc); border-color: var(--acc); color: #fff; }
.sp { flex: 1; }
.suite { display: flex; flex-direction: column; align-items: flex-end; gap: 4px; }
.small { font-size: 12px; }
.tokenbox { padding: 10px 16px; margin-bottom: 12px; display: flex; flex-direction: column; gap: 6px; }
.swagger { padding: 4px 8px; overflow: hidden; background: #fff; }
/* Swagger UI is light-only; keep it readable inside a dark portal. */
.swagger :deep(.swagger-ui) { color: #3b4151; }
.swagger :deep(.topbar) { display: none; }
</style>
