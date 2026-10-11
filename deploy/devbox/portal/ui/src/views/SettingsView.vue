<script setup>
import { computed, onMounted, ref } from 'vue'
import { api } from '../api'
import { notify } from '../toast'
import { ago } from '../format'
import KeyValueTable from '../components/KeyValueTable.vue'
import ModalDialog from '../components/ModalDialog.vue'

const props = defineProps({ env: { type: String, required: true }, service: { type: String, required: true } })

const data = ref(null)
const spring = ref([])
const envVars = ref([])
const error = ref('')
const saving = ref(false)
const reviewing = ref(false)
const reverting = ref(null)
const showInherited = ref(false)
const filter = ref('')

const toRows = (m) => Object.entries(m || {}).map(([key, value]) => ({ key, value }))
const toMap = (rows) => Object.fromEntries(rows.filter((r) => r.key).map((r) => [r.key, r.value]))

async function load() {
  try {
    data.value = await api.settings(props.env, props.service)
    spring.value = toRows(data.value.spring)
    envVars.value = toRows(data.value.env_vars)
    error.value = ''
  } catch (e) { error.value = e.message }
}

function diff(before, after) {
  const keys = [...new Set([...Object.keys(before), ...Object.keys(after)])].sort()
  return keys.flatMap((k) => {
    if (!(k in before)) return [{ op: '+', key: k, to: after[k] }]
    if (!(k in after)) return [{ op: '−', key: k, from: before[k] }]
    if (before[k] !== after[k]) return [{ op: '~', key: k, from: before[k], to: after[k] }]
    return []
  })
}
const springDiff = computed(() => (data.value ? diff(data.value.spring, toMap(spring.value)) : []))
const envDiff = computed(() => (data.value ? diff(data.value.env_vars, toMap(envVars.value)) : []))
const dirty = computed(() => springDiff.value.length + envDiff.value.length > 0)
const dupes = computed(() => {
  const ks = [...spring.value, ...envVars.value].map((r) => r.key).filter(Boolean)
  return ks.filter((k, i) => ks.indexOf(k) !== i)
})
const inherited = computed(() => Object.entries(data.value?.inherited_spring || {})
  .filter(([k]) => !filter.value || k.toLowerCase().includes(filter.value.toLowerCase())))

function override(key, value) {
  if (!spring.value.some((r) => r.key === key)) spring.value = [...spring.value, { key, value }]
  notify(`${key} added to this service's properties — edit its value, then review & save.`)
}

async function save() {
  reviewing.value = false
  saving.value = true
  try {
    const r = await api.saveSettings(props.env, props.service,
      { spring: toMap(spring.value), env_vars: toMap(envVars.value), base_sha: data.value.file_sha })
    notify(r.changed ? `Saved as commit ${r.commit.slice(0, 7)} — Argo CD is restarting ${props.service} with it.` : 'Nothing changed.')
    await load()
  } catch (e) { notify(e.message, 'err') } finally { saving.value = false }
}

async function revert() {
  const c = reverting.value
  reverting.value = null
  saving.value = true
  try {
    const r = await api.revertSettings(props.env, props.service, c.sha)
    notify(r.changed ? `Reverted: ${r.summary} (commit ${r.commit.slice(0, 7)})` : r.summary)
    await load()
  } catch (e) { notify(e.message, 'err') } finally { saving.value = false }
}

onMounted(load)
</script>

<template>
  <RouterLink to="/envs" class="back muted">‹ Environments</RouterLink>
  <div class="head">
    <div>
      <h1>{{ service }} <span class="muted">settings</span></h1>
      <p class="muted">in <b>{{ env }}</b> · saved as a commit to the env repo; Argo CD restarts the service with them.</p>
    </div>
    <div class="actions">
      <button :disabled="!dirty || saving" @click="load">Discard changes</button>
      <button class="primary" :disabled="!dirty || saving || dupes.length > 0" @click="reviewing = true">Review &amp; save</button>
    </div>
  </div>
  <p v-if="error" class="error">{{ error }}</p>
  <p v-if="dupes.length" class="error">Duplicate key: {{ dupes.join(', ') }}</p>

  <div v-if="data" class="layout">
    <div class="main">
      <section v-if="!data.static_build" class="panel block">
        <h2>Spring properties</h2>
        <p class="muted small">Any Spring Boot property, e.g. <code>logging.level.org.aibles</code> = <code>DEBUG</code>. They override
          the shared Vault config and this env's defaults. A map key containing dots goes in brackets:
          <code>application.kafka.group-id[payment.success]</code>.</p>
        <KeyValueTable v-model="spring" :original="data.spring" key-placeholder="logging.level.root" value-placeholder="INFO" />
      </section>

      <section class="panel block">
        <h2>Environment variables</h2>
        <p class="muted small">Plain container env vars, e.g. <code>JAVA_TOOL_OPTIONS</code>. For a Spring property use the table
          above — an env var spelling of a dotted key can bind to the wrong name and silently lose to Vault.</p>
        <KeyValueTable v-model="envVars" :original="data.env_vars" key-placeholder="JAVA_TOOL_OPTIONS" value-placeholder="-Xss512k" />
      </section>

      <p class="muted small">Secrets (passwords, tokens, keys) are refused here — they stay in Vault, because git history keeps
        everything forever.</p>

      <section v-if="!data.static_build" class="panel block">
        <div class="inh-head">
          <h2>Inherited from {{ env }} <span class="muted">({{ Object.keys(data.inherited_spring).length }})</span></h2>
          <button @click="showInherited = !showInherited">{{ showInherited ? 'Hide' : 'Show' }}</button>
        </div>
        <p class="muted small">Every service in this env gets these (its own databases, topics, Redis). Override one for this
          service only with “Override”.</p>
        <template v-if="showInherited">
          <input v-model="filter" placeholder="filter…" class="filter" />
          <div class="tablewrap">
            <table>
              <tr v-for="[k, v] in inherited" :key="k">
                <td class="mono">{{ k }}</td><td class="mono muted">{{ v }}</td>
                <td><button @click="override(k, v)">Override</button></td>
              </tr>
            </table>
          </div>
        </template>
      </section>
    </div>

    <aside class="panel history">
      <h2>History of this file</h2>
      <p class="muted small">Deploys and setting changes. “Revert settings” puts the settings back to just before that
        commit — the version (image tag) is left alone.</p>
      <ul>
        <li v-for="c in data.history" :key="c.sha">
          <div>{{ c.message.split('\n')[0] }}</div>
          <div class="meta"><code>{{ c.sha.slice(0, 7) }}</code> · {{ c.author }} · {{ ago(c.date) }}</div>
          <button class="small-btn" :disabled="saving" @click="reverting = c">Revert settings</button>
        </li>
      </ul>
    </aside>
  </div>

  <ModalDialog v-if="reviewing" :title="`Save ${service} settings in ${env}`" @close="reviewing = false">
    <p class="muted">This change becomes one commit; the pods restart with it.</p>
    <table class="diff">
      <tr v-for="d in [...springDiff.map((x) => ({ ...x, kind: 'property' })), ...envDiff.map((x) => ({ ...x, kind: 'env var' }))]" :key="d.kind + d.key">
        <td :class="'op op' + d.op">{{ d.op }}</td>
        <td><code>{{ d.key }}</code> <span class="muted small">{{ d.kind }}</span></td>
        <td class="mono small">
          <span v-if="d.from !== undefined" class="from">{{ d.from }}</span>
          <span v-if="d.from !== undefined && d.to !== undefined"> → </span>
          <span v-if="d.to !== undefined">{{ d.to }}</span>
        </td>
      </tr>
    </table>
    <template #actions>
      <button @click="reviewing = false">Back</button>
      <button class="primary" @click="save">Save &amp; roll out</button>
    </template>
  </ModalDialog>

  <ModalDialog v-if="reverting" title="Revert settings?" @close="reverting = null">
    <p>Put {{ service }}'s settings in {{ env }} back to how they were just before
      <code>{{ reverting.sha.slice(0, 7) }}</code> — “{{ reverting.message.split('\n')[0] }}”.</p>
    <p class="muted">The revert is a new commit, so it can be reverted too.</p>
    <template #actions>
      <button @click="reverting = null">Cancel</button>
      <button class="primary" @click="revert">Revert</button>
    </template>
  </ModalDialog>
</template>

<style scoped>
.back { text-decoration: none; display: inline-block; margin-bottom: 10px; }
.head { display: flex; flex-wrap: wrap; justify-content: space-between; gap: 12px; margin-bottom: 16px; }
.head p { margin: 4px 0 0; }
.actions { display: flex; gap: 8px; align-items: flex-start; }
.layout { display: grid; grid-template-columns: minmax(0, 1fr) 320px; gap: 16px; align-items: start; }
.main { display: flex; flex-direction: column; gap: 16px; }
.block { padding: 14px 16px; display: flex; flex-direction: column; gap: 10px; }
.block p { margin: 0; }
.small { font-size: 12.5px; }
.inh-head { display: flex; justify-content: space-between; align-items: center; }
.filter { max-width: 280px; }
.history { padding: 14px 16px; position: sticky; top: 16px; max-height: calc(100vh - 32px); overflow: auto; }
.history p { margin: 4px 0 10px; }
.history ul { list-style: none; padding: 0; margin: 0; font-size: 13px; }
.history li { padding: 8px 0; border-bottom: 1px solid var(--line); }
.meta { color: var(--ink2); font-size: 12px; margin-bottom: 4px; }
.small-btn { font-size: 12px; padding: 2px 8px; }
.diff td { padding: 6px 8px; }
.op { font-weight: 800; width: 24px; }
.op\+ { color: var(--good); } .op\~ { color: var(--warn); } .op− { color: var(--bad); }
.from { text-decoration: line-through; color: var(--ink2); }
.error { color: var(--bad); }
@media (max-width: 980px) { .layout { grid-template-columns: 1fr; } .history { position: static; max-height: none; } }
</style>
