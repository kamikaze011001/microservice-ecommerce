<script setup>
import { computed, onMounted, onUnmounted, reactive, ref, watch } from 'vue'
import { useRouter } from 'vue-router'
import { api, isActive } from '../api'
import { envUrls, remember } from '../format'
import { notify } from '../toast'
import { parseCollection } from '../bruno/parse'
import { interpolate, runRequest } from '../bruno/run'

// A Bruno-style console over the repo's own collection (api-tests/*.bru):
// the same requests, asserts and tests the contract suite runs — one at a
// time, a folder, or all of them — against any env, through the portal's
// proxy into that env's gateway. Edits live in this tab only.
const router = useRouter()
const collection = ref(null)
const envs = ref([])
const env = ref(remember.get('api.env', 'prod-like'))
const error = ref('')
const jobs = ref([])

const originals = {}                      // path → request as in the file
const edited = reactive({})                // path → working copy
const selected = ref(remember.get('api.request', ''))
const tab = ref('body')
const resTab = ref('body')
const result = ref(null)                   // last single run
const sending = ref(false)
const runtime = reactive({})               // bru.setVar values (accessToken, orderId…)
const envVars = reactive({})               // the collection environment, editable
const runAll = ref(null)                   // { name, items:[{req, out}] } of a folder/collection run
const openFolders = reactive({})

const req = computed(() => edited[selected.value])
const dirty = computed(() => req.value && JSON.stringify(req.value) !== JSON.stringify(originals[selected.value]))
const busy = computed(() => jobs.value.some((j) => isActive(j.status)))
const suiteJob = computed(() => jobs.value.find((j) => j.kind === 'api-test' && j.target === env.value))
const allVars = computed(() => ({ ...envVars, ...runtime, baseUrl: `/api/envs/${env.value}/gateway` }))
const resolvedUrl = computed(() => (req.value ? interpolate(req.value.url, allVars.value) : ''))
const tally = computed(() => {
  if (!runAll.value) return null
  const done = runAll.value.items.filter((i) => i.out)
  const ok = done.filter((i) => passed(i.out)).length
  return { ok, failed: done.length - ok, total: runAll.value.items.length }
})

/** The env's own API host: tests that check redirect links compare against it (as the CLI suite does). */
function resetEnvVars() {
  const base = collection.value?.environments.devbox || {}
  Object.keys(envVars).forEach((k) => delete envVars[k])
  Object.assign(envVars, base, { apiOrigin: envUrls(env.value).api })
}

async function load() {
  try {
    const [files, e] = await Promise.all([api.brunoFiles(), api.envs()])
    collection.value = parseCollection(files)
    envs.value = e.map((x) => x.name)
    if (!envs.value.includes(env.value)) env.value = 'prod-like'
    for (const f of collection.value.folders) {
      openFolders[f.name] = true
      for (const r of f.requests) { originals[r.path] = r; edited[r.path] = JSON.parse(JSON.stringify(r)) }
    }
    if (!edited[selected.value]) selected.value = collection.value.folders[0]?.requests[0]?.path || ''
    resetEnvVars()
  } catch (err) { error.value = err.message }
}

function select(path) { selected.value = path; remember.set('api.request', path) }
function reset() { edited[selected.value] = JSON.parse(JSON.stringify(originals[selected.value])) }

async function send() {
  sending.value = true
  runAll.value = null
  try { result.value = await runRequest(req.value, env.value, envVars, runtime) } finally { sending.value = false }
}

async function run(folders, name) {
  result.value = null
  runAll.value = { name, items: folders.flatMap((f) => f.requests.map((r) => ({ req: r, out: null }))) }
  for (const item of runAll.value.items) {
    item.out = await runRequest(edited[item.req.path], env.value, envVars, runtime)
  }
}

function showRunItem(item) {
  select(item.req.path)
  if (item.out) { result.value = item.out; runAll.value = null }
}

async function runSuiteJob() {
  try {
    const job = await api.startJob('api-test', env.value)
    router.push(`/jobs/${job.name}`)
  } catch (e) { notify(e.message, 'err') }
}

const passed = (out) => out && !out.error && out.results.every((r) => r.pass)
const pretty = (b) => (typeof b === 'string' ? b : JSON.stringify(b, null, 2))
const statusClass = (s) => (s >= 500 ? 'bad' : s >= 400 ? 'warn' : 'good')
const clearRuntime = () => Object.keys(runtime).forEach((k) => delete runtime[k])

watch(env, (v) => {
  remember.set('api.env', v)
  clearRuntime()   // a token from another env is useless here
  resetEnvVars()
  result.value = null
  runAll.value = null
})

let timer
onMounted(async () => {
  await load()
  const poll = async () => { try { jobs.value = await api.jobs() } catch { /* not fatal */ } }
  poll()
  timer = setInterval(poll, 5000)
})
onUnmounted(() => clearInterval(timer))
</script>

<template>
  <h1>API testing</h1>
  <p class="muted lead">The repo's Bruno collection (<code>api-tests/</code>), runnable against any env: edit a request, send
    it, see the response and its tests. Run a folder or the whole collection in order — login sets
    <code>accessToken</code> for everything after it, like in Bruno.</p>
  <p v-if="error" class="error">{{ error }}</p>

  <div v-if="collection" class="console">
    <!-- collection -->
    <aside class="panel side">
      <label class="envpick">Env
        <select v-model="env"><option v-for="e in envs" :key="e">{{ e }}</option></select>
      </label>
      <div class="runbtns">
        <button class="primary" @click="run(collection.folders, 'whole collection')">▶ Run collection</button>
        <button :disabled="busy" @click="runSuiteJob" :title="busy ? 'Another job is running' : 'The same suite via the Bruno CLI, as a job'">
          Run as job (Bruno CLI)</button>
      </div>
      <RouterLink v-if="suiteJob" :to="`/jobs/${suiteJob.name}`" class="muted small">last CLI run: {{ suiteJob.status.toLowerCase() }} ›</RouterLink>

      <div v-for="f in collection.folders" :key="f.name" class="folder">
        <div class="fhead">
          <button class="fold" @click="openFolders[f.name] = !openFolders[f.name]">{{ openFolders[f.name] ? '▾' : '▸' }} {{ f.label || f.name }}</button>
          <button class="mini" title="Run this folder" @click="run([f], f.label || f.name)">▶</button>
        </div>
        <template v-if="openFolders[f.name]">
          <button v-for="r in f.requests" :key="r.path" class="item" :class="{ on: r.path === selected }" @click="select(r.path)">
            <span class="m" :class="r.method">{{ r.method }}</span>
            <span class="n">{{ r.name }}</span>
          </button>
        </template>
      </div>

      <details class="vars">
        <summary>Variables</summary>
        <p class="muted small">Collection env (editable) and values set by scripts.</p>
        <div v-for="(v, k) in envVars" :key="k" class="var"><code>{{ k }}</code><input v-model="envVars[k]" class="mono" /></div>
        <div v-for="(v, k) in runtime" :key="'r' + k" class="var rt"><code>{{ k }}</code><input :value="v" readonly class="mono" :title="v" /></div>
        <button v-if="Object.keys(runtime).length" class="mini wide" @click="clearRuntime">Clear script vars</button>
      </details>
    </aside>

    <!-- request -->
    <section v-if="req" class="panel request">
      <div class="reqhead">
        <h2>{{ req.name }}</h2>
        <span class="muted small mono">{{ req.path }}</span>
      </div>
      <div class="urlbar">
        <select v-model="req.method" class="method"><option v-for="m in ['GET', 'POST', 'PUT', 'PATCH', 'DELETE']" :key="m">{{ m }}</option></select>
        <input v-model="req.url" class="mono url" spellcheck="false" @keydown.enter="send" />
        <button class="primary" :disabled="sending" @click="send">{{ sending ? 'Sending…' : 'Send' }}</button>
      </div>
      <div class="resolved muted small mono" :title="resolvedUrl">→ {{ resolvedUrl }}</div>
      <div v-if="dirty" class="edited small">Edited in this tab — <button class="link" @click="reset">reset to file</button>.
        To keep it, change <code>api-tests/{{ req.path }}</code> in git.</div>

      <nav class="tabs">
        <button v-for="t in ['body', 'auth', 'headers', 'tests', 'docs']" :key="t" :class="{ on: tab === t }" @click="tab = t">
          {{ { body: 'Body', auth: 'Auth', headers: 'Headers', tests: 'Script & tests', docs: 'Docs' }[t] }}</button>
      </nav>
      <div class="tabbody">
        <template v-if="tab === 'body'">
          <p v-if="req.bodyType === 'none'" class="muted small">No body.
            <button class="link" @click="req.bodyType = 'json'">Add a JSON body</button></p>
          <textarea v-else v-model="req.body" class="mono code" spellcheck="false" rows="10"></textarea>
        </template>
        <template v-else-if="tab === 'auth'">
          <label class="row"><span>Type</span>
            <select v-model="req.auth"><option value="none">none</option><option value="bearer">bearer token</option></select></label>
          <label v-if="req.auth === 'bearer'" class="row"><span>Token</span><input v-model="req.token" class="mono" /></label>
          <p v-if="req.auth === 'bearer' && req.token.includes('accessToken') && !runtime.accessToken" class="muted small">
            <code>accessToken</code> is set by <b>02 Auth / login</b> — send that first (or run the collection).</p>
        </template>
        <template v-else-if="tab === 'headers'">
          <p v-if="!req.headers.length" class="muted small">No extra headers (Authorization and Content-Type come from Auth and Body).</p>
          <div v-for="(h, i) in req.headers" :key="i" class="row"><input v-model="h[0]" class="mono" /><input v-model="h[1]" class="mono" /></div>
          <button class="mini" @click="req.headers.push(['', ''])">+ Header</button>
        </template>
        <template v-else-if="tab === 'tests'">
          <h3>assert</h3>
          <pre class="code">{{ req.asserts.map(([k, v]) => `${k}: ${v}`).join('\n') || '—' }}</pre>
          <h3>script:post-response</h3>
          <textarea v-model="req.postScript" class="mono code" spellcheck="false" rows="4"></textarea>
          <h3>tests</h3>
          <textarea v-model="req.tests" class="mono code" spellcheck="false" rows="10"></textarea>
        </template>
        <template v-else>
          <pre class="code">{{ req.docs || collection.docs || '—' }}</pre>
        </template>
      </div>
    </section>

    <!-- response / run results -->
    <section class="panel response">
      <template v-if="runAll">
        <div class="reshead">
          <h2>Run: {{ runAll.name }}</h2>
          <span class="pill" :class="tally.failed ? 'bad' : 'good'">{{ tally.ok }}/{{ tally.total }} passed</span>
        </div>
        <ul class="runlist">
          <li v-for="i in runAll.items" :key="i.req.path" @click="showRunItem(i)">
            <span class="dot" :class="!i.out ? 'wait' : passed(i.out) ? 'ok' : 'ko'"></span>
            <span class="m" :class="i.req.method">{{ i.req.method }}</span>
            <span class="n">{{ i.req.name }}</span>
            <span v-if="i.out?.res" class="muted small">{{ i.out.res.status }} · {{ i.out.res.responseTime }} ms</span>
            <div v-if="i.out && !passed(i.out)" class="why">
              {{ i.out.error || i.out.results.filter((r) => !r.pass).map((r) => `${r.name}: ${r.error}`).join(' · ') }}</div>
          </li>
        </ul>
        <p class="muted small">Click a row to open that request with its response.</p>
      </template>
      <template v-else-if="result">
        <div class="reshead">
          <h2>Response</h2>
          <template v-if="result.res">
            <span class="pill" :class="statusClass(result.res.status)">{{ result.res.status }}</span>
            <span class="muted small">{{ result.res.responseTime }} ms</span>
          </template>
        </div>
        <p v-if="result.error" class="error">{{ result.error }}</p>
        <nav class="tabs">
          <button :class="{ on: resTab === 'body' }" @click="resTab = 'body'">Body</button>
          <button :class="{ on: resTab === 'tests' }" @click="resTab = 'tests'">
            Tests <span v-if="result.results.length" class="pill" :class="result.results.every((r) => r.pass) ? 'good' : 'bad'">
              {{ result.results.filter((r) => r.pass).length }}/{{ result.results.length }}</span></button>
          <button :class="{ on: resTab === 'headers' }" @click="resTab = 'headers'">Headers</button>
        </nav>
        <pre v-if="resTab === 'body'" class="code out">{{ result.res ? pretty(result.res.body) : '' }}</pre>
        <ul v-else-if="resTab === 'tests'" class="checks">
          <li v-for="(r, i) in result.results" :key="i" :class="r.pass ? 'ok' : 'ko'">
            <span>{{ r.pass ? '✓' : '✕' }}</span>
            <div><span class="kind">{{ r.kind }}</span> {{ r.name }}<div v-if="r.error" class="why">{{ r.error }}</div></div>
          </li>
          <li v-if="!result.results.length" class="muted">This request has no asserts or tests.</li>
        </ul>
        <pre v-else class="code out">{{ result.res ? Object.entries(result.res.headers).map(([k, v]) => `${k}: ${v}`).join('\n') : '' }}</pre>
      </template>
      <p v-else class="muted empty">Send the request, or run a folder or the whole collection.</p>
    </section>
  </div>
</template>

<style scoped>
.lead { margin: 4px 0 14px; max-width: 820px; }
.console { display: grid; grid-template-columns: 250px minmax(0, 1fr) minmax(0, 1fr); gap: 12px; align-items: start; }
.panel { padding: 12px; }
.side { display: flex; flex-direction: column; gap: 8px; max-height: calc(100vh - 140px); overflow: auto; position: sticky; top: 12px; }
.envpick { display: flex; flex-direction: column; gap: 4px; font-size: 12px; color: var(--ink2); }
.runbtns { display: flex; flex-direction: column; gap: 6px; }
.primary { background: var(--acc); border-color: var(--acc); color: #fff; }
.folder { margin-top: 4px; }
.fhead { display: flex; justify-content: space-between; align-items: center; }
.fold { border: none; background: none; padding: 4px 2px; font-weight: 700; font-size: 13px; }
.mini { font-size: 11.5px; padding: 2px 8px; }
.mini.wide { width: 100%; justify-content: center; }
.item { display: flex; gap: 6px; align-items: center; width: 100%; border: none; background: none; padding: 5px 6px 5px 14px;
  border-radius: 6px; text-align: left; font-size: 12.5px; white-space: normal; }
.item:hover { background: var(--panel2); }
.item.on { background: var(--bg); font-weight: 600; }
.item .n { flex: 1; }
.m { font: 700 10px var(--mono); min-width: 38px; }
.m.GET { color: var(--good); } .m.POST { color: var(--warn); } .m.PUT, .m.PATCH { color: var(--info); } .m.DELETE { color: var(--bad); }
.dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; flex: none; }
.dot.ok { background: var(--good); } .dot.ko { background: var(--bad); } .dot.wait { background: var(--line); }
.vars { margin-top: 8px; font-size: 12.5px; }
.vars summary { cursor: pointer; font-weight: 700; }
.var { display: grid; grid-template-columns: 90px 1fr; gap: 4px; align-items: center; margin: 3px 0; }
.var code { overflow: hidden; text-overflow: ellipsis; }
.var input { font-size: 11.5px; padding: 3px 5px; min-width: 0; }
.var.rt code { color: var(--acc); }
.small { font-size: 12px; }
.reqhead { display: flex; flex-direction: column; gap: 2px; margin-bottom: 8px; }
.urlbar { display: flex; gap: 6px; }
.method { width: 92px; font-weight: 700; }
.url { flex: 1; min-width: 0; }
.resolved { margin: 6px 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.edited { background: color-mix(in srgb, var(--warn) 15%, transparent); padding: 6px 8px; border-radius: 8px; margin-bottom: 6px; }
.link { border: none; background: none; padding: 0; color: var(--acc); text-decoration: underline; font-size: inherit; }
.tabs { display: flex; gap: 2px; border-bottom: 1px solid var(--line); margin: 8px 0; flex-wrap: wrap; }
.tabs button { border: none; border-radius: 6px 6px 0 0; background: none; padding: 6px 10px; color: var(--ink2); }
.tabs button.on { color: var(--ink); background: var(--panel2); font-weight: 600; }
.tabbody h3 { font-size: 11.5px; text-transform: uppercase; letter-spacing: .05em; color: var(--ink2); margin: 10px 0 4px; }
.code { width: 100%; font: 12px/1.5 var(--mono); background: var(--panel2); border: 1px solid var(--line); border-radius: 8px;
  padding: 8px; margin: 0; white-space: pre-wrap; word-break: break-word; color: var(--ink); }
textarea.code { resize: vertical; }
.row { display: flex; gap: 8px; align-items: center; margin: 6px 0; }
.row span { width: 50px; font-size: 12px; color: var(--ink2); }
.row input { flex: 1; }
.reshead { display: flex; gap: 8px; align-items: center; margin-bottom: 6px; }
.out { max-height: 60vh; overflow: auto; }
.checks { list-style: none; padding: 0; margin: 0; font-size: 13px; }
.checks li { display: flex; gap: 8px; padding: 6px 0; border-bottom: 1px solid var(--line); }
.checks li.ok > span { color: var(--good); font-weight: 800; } .checks li.ko > span { color: var(--bad); font-weight: 800; }
.kind { font: 10px var(--mono); color: var(--ink2); text-transform: uppercase; margin-right: 4px; }
.why { color: var(--bad); font-size: 12px; margin-top: 2px; }
.runlist { list-style: none; padding: 0; margin: 0; }
.runlist li { display: flex; flex-wrap: wrap; gap: 8px; align-items: center; padding: 7px 4px; border-bottom: 1px solid var(--line); cursor: pointer; font-size: 13px; }
.runlist li:hover { background: var(--panel2); }
.runlist .n { flex: 1; }
.runlist .why { flex-basis: 100%; padding-left: 24px; }
.empty { padding: 30px 8px; text-align: center; }
.error { color: var(--bad); }
@media (max-width: 1200px) { .console { grid-template-columns: 230px minmax(0, 1fr); } .response { grid-column: 2; } }
@media (max-width: 760px) { .console { grid-template-columns: 1fr; } .response { grid-column: auto; } .side { position: static; max-height: none; } }
</style>
